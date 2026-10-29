import CryptoKit
import Foundation

/// Exact stand-ins for the shell tools the collectors used to call (`cat`,
/// `wc -c`, `shasum`, `find`, `lockf`...). Each mirrors the behaviour the
/// scripts relied on, so file names, hashes and edge cases come out the same.
enum Shell {
    // MARK: Text

    /// What `$(...)` does to command output: drops every trailing "\n" byte.
    static func trimmingTrailingNewlines(_ text: String) -> String {
        var bytes = Array(text.utf8)
        while bytes.last == 0x0A { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `case "$v" in ''|*[!0-9]*) ...`: a non-empty run of ASCII digits.
    static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// A numeric setting the scripts validated with the pattern above.
    static func digits(_ text: String?, default fallback: Int) -> Int {
        guard let text, isDigits(text) else { return fallback }
        return Int(text) ?? Int.max
    }

    /// `${NAME:-default}`: unset and empty both mean "not given".
    static func setting(_ environment: [String: String], _ key: String) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }

    /// `${value%.*}`: cut at the last dot.
    static func removingLastDotSuffix(_ text: String) -> String {
        guard let dot = text.lastIndex(of: ".") else { return text }
        return String(text[..<dot])
    }

    /// `printf '%s' "$text" | shasum -a 256 | awk '{print $1}'`
    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// POSIX `dirname`.
    static func dirname(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        var parent = String(trimmed[..<slash])
        while parent.count > 1, parent.hasSuffix("/") { parent.removeLast() }
        return parent.isEmpty ? "/" : parent
    }

    /// POSIX `basename`.
    static func basename(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        let name = String(trimmed[trimmed.index(after: slash)...])
        return name.isEmpty ? "/" : name
    }

    /// `${path%.jsonl}`
    static func removingJSONLSuffix(_ path: String) -> String {
        path.hasSuffix(".jsonl") ? String(path.dropLast(".jsonl".count)) : path
    }

    // MARK: Files

    private static func statInfo(_ path: String, followLinks: Bool = true) -> stat? {
        var info = stat()
        let result = followLinks ? stat(path, &info) : lstat(path, &info)
        return result == 0 ? info : nil
    }

    static func fileSize(_ path: String) -> Int? {
        statInfo(path).map { Int($0.st_size) }
    }

    /// `[ -e path ]`
    static func exists(_ path: String) -> Bool { statInfo(path) != nil }

    /// `[ -f path ]`
    static func isRegularFile(_ path: String) -> Bool {
        guard let info = statInfo(path) else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    /// `[ -d path ]`
    static func isDirectory(_ path: String) -> Bool {
        guard let info = statInfo(path) else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// `[ -x path ]`
    static func isExecutable(_ path: String) -> Bool {
        !path.isEmpty && access(path, X_OK) == 0
    }

    /// `[ -s path ]`
    static func isNonEmpty(_ path: String) -> Bool {
        (fileSize(path) ?? 0) > 0
    }

    static func readData(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    /// `$(cat file)`
    static func readText(_ path: String) -> String? {
        guard let data = readData(path) else { return nil }
        return trimmingTrailingNewlines(String(decoding: data, as: UTF8.self))
    }

    /// `mkdir -p`
    @discardableResult
    static func makeDirectories(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return true
        } catch {
            return isDirectory(path)
        }
    }

    /// `touch path`: create when missing, bump the modification time.
    @discardableResult
    static func touch(_ path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        close(fd)
        return utimes(path, nil) == 0
    }

    /// `printf '%s' "$text" > file`
    @discardableResult
    static func overwrite(_ text: String, to path: String) -> Bool {
        overwrite(Data(text.utf8), to: path)
    }

    @discardableResult
    static func overwrite(_ data: Data, to path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return writeAll(fd, data)
    }

    /// `printf '%s' "$text" >> file` — one write per call, as the shell did.
    @discardableResult
    static func append(_ text: String, to path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return writeAll(fd, Data(text.utf8))
    }

    /// Write to a temporary file and rename over the target (`os.replace`).
    @discardableResult
    static func replaceAtomically(_ data: Data, at path: String) -> Bool {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `mv` within one directory.
    static func move(_ source: String, to destination: String) -> Bool {
        rename(source, destination) == 0
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    // MARK: find

    /// `find "$dir" -type f -name '*.jsonl' -mtime "-$days" -print | sort`, with
    /// BSD find's rules: symbolic links (including a linked starting
    /// directory) are not followed, and `-mtime -N` keeps files whose age,
    /// rounded up to whole days, is below N. Paths are spelled the way find
    /// prints them, because they are hashed into offsets and event ids.
    static func recentJSONLFiles(in root: String, days: Int, now: Int) -> [String] {
        guard let rootInfo = statInfo(root, followLinks: false),
              (rootInfo.st_mode & S_IFMT) == S_IFDIR else { return [] }

        var results: [String] = []
        func visit(_ prefix: String, _ directory: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
            for name in names {
                let child = prefix + "/" + name
                guard let info = statInfo(child, followLinks: false) else { continue }
                let type = info.st_mode & S_IFMT
                if type == S_IFDIR {
                    visit(child, child)
                } else if type == S_IFREG,
                          name.hasSuffix(".jsonl"),
                          isRecent(modified: Int(info.st_mtimespec.tv_sec), days: days, now: now) {
                    results.append(child)
                }
            }
        }
        // fts drops one trailing slash before appending "/name".
        let prefix = root.hasSuffix("/") ? String(root.dropLast()) : root
        visit(prefix, root)
        return sortedBytewise(results)
    }

    /// `-mtime -N` in BSD find: `(now - mtime + 86399) / 86400 < N`.
    static func isRecent(modified: Int, days: Int, now: Int) -> Bool {
        (now - modified + 86_399) / 86_400 < days
    }

    /// `find "$archive_dir" -maxdepth 1 -type f -name 'usage-log-*.jsonl' -print0 | sort -z`
    static func archivedSegments(in archiveDirectory: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: archiveDirectory) else { return [] }
        let paths = names.compactMap { name -> String? in
            guard name.utf8.count >= 16, name.hasPrefix("usage-log-"), name.hasSuffix(".jsonl") else { return nil }
            let path = archiveDirectory + "/" + name
            guard let info = statInfo(path, followLinks: false), (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return path
        }
        return sortedBytewise(paths)
    }

    /// `sort` in the C locale the app runs with: plain byte order.
    static func sortedBytewise(_ values: [String]) -> [String] {
        values.sorted { JSONValue.compareBytes($0, $1) < 0 }
    }

    // MARK: Time

    /// `date -u '+%Y-%m-%dT%H:%M:%SZ'` and jq's `todateiso8601`.
    static func utcTimestamp(_ seconds: Int) -> String {
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
            parts.tm_hour, parts.tm_min, parts.tm_sec
        )
    }

    /// `TZ=Asia/Seoul date '+%Y-%m'`
    static func seoulMonth(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? TimeZone(secondsFromGMT: 9 * 3600)!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04ld-%02ld", parts.year ?? 0, parts.month ?? 0)
    }

    static func nowSeconds() -> Int {
        Int(Date().timeIntervalSince1970)
    }
}

// MARK: - Lock

enum FileLockError: Error {
    case cannotOpen
    case timedOut
}

/// The usage-log lock: `exec 9>>"$lock_path"; /usr/bin/lockf -s -t "$t" 9`.
/// Same file and the same flock(2) lock as the scripts, so an old script still
/// running somewhere and this code exclude each other.
final class FileLock {
    private var fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    static func acquire(_ path: String, timeoutSeconds: Int) -> Result<FileLock, FileLockError> {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failure(.cannotOpen) }
        let deadline = Date().addingTimeInterval(TimeInterval(min(timeoutSeconds, 100_000_000)))
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return .success(FileLock(fd: fd))
            }
            if errno != EWOULDBLOCK && errno != EINTR || Date() >= deadline {
                close(fd)
                return .failure(.timedOut)
            }
            usleep(20_000)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

// MARK: - Output

/// Where a collector's messages go: the terminal for the command-line form,
/// nowhere for the menu bar app (which always sent script output to /dev/null).
struct CommandIO {
    let out: (String) -> Void
    let err: (String) -> Void

    static let silent = CommandIO(out: { _ in }, err: { _ in })

    static let console = CommandIO(
        out: { Shell.writeAll(1, Data(($0 + "\n").utf8)) },
        err: { Shell.writeAll(2, Data(($0 + "\n").utf8)) }
    )

    /// `command >/dev/null`: keep stderr, drop stdout.
    var droppingOutput: CommandIO {
        CommandIO(out: { _ in }, err: err)
    }
}

/// The environment the app has always handed to its collectors. launchd gives
/// a menu bar app almost nothing, so PATH is spelled out.
enum CollectorEnvironment {
    static let appSearchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// `command -v name` / `shutil.which(name)` over a PATH string.
    static func which(_ name: String, path: String?) -> String? {
        for entry in (path ?? "").split(separator: ":", omittingEmptySubsequences: false) {
            let directory = entry.isEmpty ? "." : String(entry)
            let candidate = directory + "/" + name
            if Shell.isExecutable(candidate), !Shell.isDirectory(candidate) {
                return candidate
            }
        }
        return nil
    }
}
