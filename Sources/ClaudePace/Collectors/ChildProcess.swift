import Foundation

/// Launching the official CLIs (`claude`, `codex`). Everything else the
/// collectors do now happens inside this process.
enum ChildProcess {
    private static func makeProcess(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        directory: String?
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        return process
    }

    /// `out=$("$bin" args 2>/dev/null)`: stdout of a finished run, or nil when
    /// the program could not be started.
    static func captureOutput(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        directory: String?
    ) -> Data? {
        let process = makeProcess(executable, arguments, environment: environment, directory: directory)
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return output
    }

    /// `"$bin" args </dev/null >"$file" 2>&1`. Returns the exit status, or nil
    /// when the program could not be started (the reason is written into the
    /// file, as the shell would have printed it there).
    @discardableResult
    static func runRedirectingOutput(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        directory: String?,
        to outputPath: String
    ) -> Int32? {
        let fd = open(outputPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }

        let process = makeProcess(executable, arguments, environment: environment, directory: directory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            Shell.writeAll(fd, Data("\(executable): \(error.localizedDescription)\n".utf8))
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// A child process spoken to over stdin/stdout one line at a time (the Codex
/// app-server protocol). A reader thread collects stdout lines so reads can
/// time out, like the Python poller's `select` loop.
final class LineChannel {
    let process: Process
    private let input: FileHandle
    private let condition = NSCondition()
    private var lines: [Data] = []
    private var pending = Data()
    private var finished = false

    init?(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: String?
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        self.process = process
        input = stdinPipe.fileHandleForWriting

        let reader = stdoutPipe.fileHandleForReading
        let thread = Thread { [self] in
            self.readLoop(reader.fileDescriptor)
            try? reader.close()
        }
        thread.start()
    }

    private func readLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            condition.lock()
            if count <= 0 {
                if !pending.isEmpty {
                    lines.append(pending)
                    pending = Data()
                }
                finished = true
                condition.broadcast()
                condition.unlock()
                return
            }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(pending.subdata(in: pending.startIndex..<newline))
                pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Write one line. False once the other side has gone away.
    @discardableResult
    func send(_ line: String) -> Bool {
        Shell.writeAll(input.fileDescriptor, Data((line + "\n").utf8))
    }

    /// The next stdout line, or nil at end of output or once `deadline` passes.
    func nextLine(before deadline: Date) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty && !finished {
            if !condition.wait(until: deadline) { break }
        }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    /// Close stdin, then wait 1s, terminate, wait 1s, kill — as the Python
    /// poller's `finally` block did.
    func shutDown() {
        try? input.close()
        if waitForExit(seconds: 1) { return }
        process.terminate()
        if waitForExit(seconds: 1) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(seconds: 1)
    }

    private func waitForExit(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }
}
