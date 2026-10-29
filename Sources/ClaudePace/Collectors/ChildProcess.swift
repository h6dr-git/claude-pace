import Foundation

/// Launching the official CLIs (`claude`, `codex`). Everything else the
/// collectors do now happens inside this process.
enum ChildProcess {
    /// How a time-limited run ended.
    enum Outcome {
        case exited(Int32)
        /// Still running at the deadline, so it was stopped (SIGTERM, then
        /// SIGKILL two seconds later).
        case timedOut
        case notStarted(Error)
    }

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

    /// Start `process` and wait at most `timeout` seconds for it to exit.
    /// The scripts had no limit, so a hung CLI stalled every later poll; the
    /// app runs these on one serial queue and has to get the queue back.
    private static func run(_ process: Process, timeout: TimeInterval) -> Outcome {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .notStarted(error)
        }
        if exited.wait(timeout: .now() + timeout) == .success {
            return .exited(process.terminationStatus)
        }
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
        return .timedOut
    }

    /// `out=$("$bin" args 2>/dev/null)`, limited to `timeout` seconds. stdout
    /// goes to an unlinked temporary file instead of a pipe, so the wait ends
    /// with the program itself even if something it started keeps the
    /// descriptor open.
    static func captureOutput(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        directory: String?,
        timeout: TimeInterval
    ) -> (outcome: Outcome, output: Data) {
        let fd = unlinkedTemporaryFile()
        guard fd >= 0 else {
            return (.notStarted(CocoaError(.fileWriteUnknown)), Data())
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }

        let process = makeProcess(executable, arguments, environment: environment, directory: directory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = FileHandle.nullDevice
        let outcome = run(process, timeout: timeout)
        if case .notStarted = outcome { return (outcome, Data()) }

        lseek(fd, 0, SEEK_SET)
        let output = (try? file.readToEnd()) ?? Data()
        return (outcome, output)
    }

    /// `"$bin" args </dev/null >"$file" 2>&1`, limited to `timeout` seconds.
    /// When the program cannot be started the reason is written into the
    /// file, as the shell would have printed it there.
    @discardableResult
    static func runRedirectingOutput(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        directory: String?,
        to outputPath: String,
        timeout: TimeInterval
    ) -> Outcome {
        let fd = open(outputPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .notStarted(CocoaError(.fileWriteNoPermission)) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }

        let process = makeProcess(executable, arguments, environment: environment, directory: directory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let outcome = run(process, timeout: timeout)
        if case .notStarted(let error) = outcome {
            Shell.writeAll(fd, Data("\(executable): \(error.localizedDescription)\n".utf8))
        }
        return outcome
    }

    /// An open temporary file whose name is already gone (or -1).
    private static func unlinkedTemporaryFile() -> Int32 {
        let template = (NSTemporaryDirectory() as NSString).appendingPathComponent("claudepace.XXXXXX")
        var name = Array(template.utf8CString)
        return name.withUnsafeMutableBufferPointer { (buffer: inout UnsafeMutableBufferPointer<CChar>) -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            let fd = mkstemp(base)
            if fd >= 0 {
                unlink(base)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            }
            return fd
        }
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
    /// Set by `shutDown()`. The scripts' poller was its own process, so a
    /// stray grandchild holding stdout open (an npm wrapper's child, say) only
    /// delayed its exit; here the reader thread would wait for that EOF inside
    /// the app, one thread and one descriptor per poll.
    private var stopped = false

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

    private var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    private func readLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !isStopped {
            // Wake up now and then to notice shutDown().
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }

            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            if count == 0 { break }

            condition.lock()
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(pending.subdata(in: pending.startIndex..<newline))
                pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
            }
            condition.broadcast()
            condition.unlock()
        }

        condition.lock()
        if !pending.isEmpty {
            lines.append(pending)
            pending = Data()
        }
        finished = true
        condition.broadcast()
        condition.unlock()
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
    /// poller's `finally` block did. The reader thread then stops whether or
    /// not stdout ever reaches EOF.
    func shutDown() {
        try? input.close()
        defer { stopReading() }
        if waitForExit(seconds: 1) { return }
        process.terminate()
        if waitForExit(seconds: 1) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(seconds: 1)
    }

    private func stopReading() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
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
