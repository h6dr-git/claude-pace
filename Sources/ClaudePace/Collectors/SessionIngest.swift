import Foundation

/// Appends token usage from local CLI session logs to the normalized usage
/// ledger (formerly tools/ingest-codex-sessions.sh and
/// tools/ingest-claude-sessions.sh). Local only: reads ~/.codex/sessions or
/// ~/.claude/projects and writes Application Support.
///
/// Per-file byte offsets plus a list of seen event ids keep it incremental and
/// idempotent. Event ids are hashes of the session file path and of jq's text
/// form of a few fields, so they come out identical to the ones the scripts
/// already wrote — switching over does not re-ingest anything.
enum SessionIngest {
    enum Source {
        /// Codex `token_count` events: cumulative and last-turn totals.
        case codex
        /// Claude Code / Agent SDK assistant turns (terminal CLI, Agent
        /// Client/ACP, SDK subagents). The statusLine bridge only sees the
        /// terminal TUI, so this is the token-usage axis for everything else.
        case claude
    }

    private struct Settings {
        let sessionsDir: String
        let seenPath: String
        let offsetDir: String
        let days: Int
        let needle: Data
        let missingMessage: String
    }

    private static func makeSettings(_ source: Source, paths: AppPaths, environment: [String: String]) -> Settings {
        switch source {
        case .codex:
            let dir = Shell.setting(environment, "CODEX_SESSIONS_DIR") ?? paths.home + "/.codex/sessions"
            return Settings(
                sessionsDir: dir,
                seenPath: paths.appDir + "/.codex-usage-seen",
                offsetDir: paths.appDir + "/.codex-offsets",
                days: Shell.digits(Shell.setting(environment, "CODEX_USAGE_MTIME_DAYS"), default: 2),
                needle: Data("\"type\":\"token_count\"".utf8),
                missingMessage: "codex sessions dir missing: \(dir)"
            )
        case .claude:
            let dir = Shell.setting(environment, "CLAUDE_PROJECTS_DIR") ?? paths.home + "/.claude/projects"
            return Settings(
                sessionsDir: dir,
                seenPath: paths.appDir + "/.claude-session-seen",
                offsetDir: paths.appDir + "/.claude-session-offsets",
                days: Shell.digits(Shell.setting(environment, "CLAUDE_USAGE_MTIME_DAYS"), default: 2),
                needle: Data("\"type\":\"assistant\"".utf8),
                missingMessage: "claude projects dir missing: \(dir)"
            )
        }
    }

    static func run(_ source: Source, home: String, environment: [String: String], io: CommandIO) -> Int32 {
        let paths = AppPaths(home: home)
        let settings = makeSettings(source, paths: paths, environment: environment)
        let files = UsageLogFiles(log: paths.usageLog)

        Shell.makeDirectories(paths.appDir)
        Shell.makeDirectories(settings.offsetDir)
        Shell.touch(paths.usageLog)
        Shell.touch(settings.seenPath)

        guard Shell.isDirectory(settings.sessionsDir) else {
            io.err(settings.missingMessage)
            return 0
        }
        let timeout = Shell.digits(Shell.setting(environment, "USAGE_LOG_LOCK_TIMEOUT"), default: 120)

        // The app runs this every 60 seconds. Rotate both before and after, so
        // an already-large ledger and a batch that crosses the limit are both
        // handled in the same pass.
        if UsageLogRotation.rotate(paths.usageLog, environment: environment, io: io.droppingOutput) != 0 {
            io.err("usage-log rotation check failed; continuing without discarding source events")
        }

        let lock: FileLock
        switch files.lock(timeoutSeconds: timeout, io: io) {
        case .success(let acquired): lock = acquired
        case .failure(let failure): return failure.status
        }

        // Every event id ever ingested, one per line. The app runs this each
        // minute and most runs find nothing new, so the list is only read
        // once a candidate event turns up (still under the lock).
        var seenIDs: Set<String>?
        func isNew(_ id: String) -> Bool {
            if seenIDs == nil {
                seenIDs = Set((Shell.readData(settings.seenPath).map { String(decoding: $0, as: UTF8.self) } ?? "")
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init))
            }
            return seenIDs?.contains(id) == false
        }

        var scanned = 0
        for file in Shell.recentJSONLFiles(in: settings.sessionsDir, days: settings.days, now: Shell.nowSeconds()) {
            guard Shell.isRegularFile(file), let size = Shell.fileSize(file) else { continue }
            scanned += 1

            let offsetPath = settings.offsetDir + "/" + Shell.sha256Hex(file) + ".offset"
            var offset = Shell.digits(Shell.readText(offsetPath), default: 0)
            if offset > size { offset = 0 }
            if offset == size { continue }

            forEachNewLine(of: file, from: offset) { line in
                guard line.range(of: settings.needle) != nil,
                      let value = try? JSONParser.parse(line) else { return }
                let event: (id: String, record: JSONObject)?
                switch source {
                case .codex: event = codexEvent(value, file: file)
                case .claude: event = claudeEvent(value, file: file)
                }
                guard let event, isNew(event.id) else { return }
                Shell.append(JSONValue.object(event.record).compactText + "\n", to: paths.usageLog)
                Shell.append(event.id + "\n", to: settings.seenPath)
                seenIDs?.insert(event.id)
            }

            Shell.overwrite(String(size), to: offsetPath)
        }

        lock.release()

        if UsageLogRotation.rotate(paths.usageLog, environment: environment, io: io.droppingOutput) != 0 {
            io.err("post-ingest usage-log rotation check failed")
        }

        io.out("scanned_files=\(scanned) history=\(paths.usageLog)")
        return 0
    }

    /// `tail -c +$((offset + 1)) "$file"`, one line at a time. A final
    /// fragment without a newline still counts as a line, as it does for grep.
    /// The file is read in pieces, so the first pass over a long session never
    /// holds the whole tail (and a copy of it) in memory.
    private static func forEachNewLine(of file: String, from offset: Int, _ body: (Data) -> Void) {
        guard let handle = FileHandle(forReadingAtPath: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return
        }
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                body(pending[start..<newline])
                start = pending.index(after: newline)
            }
            pending = Data(pending[start...])
        }
        if !pending.isEmpty { body(pending) }
    }

    /// `$(jq -r 'path // empty')`: jq's raw text of the value, or "".
    private static func rawText(_ value: JSONValue, _ path: [String]) -> String {
        guard let found = value.jqValue(path) else { return "" }
        return Shell.trimmingTrailingNewlines(found.jqRawText)
    }

    /// `(((.timestamp // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // null)`.
    /// nil where jq raises an error — `sub` on a timestamp that is not a
    /// string — which makes the whole record fail (the line is skipped).
    private static func captureTime(_ value: JSONValue) -> JSONValue? {
        guard let raw = value.jqValue(["timestamp"], or: .string("")),
              case .string(let stamp) = raw else { return nil }
        guard let seconds = JQTime.fromISO8601(JQTime.droppingFractionalSeconds(stamp)) else {
            return JSONValue.null
        }
        return JSONValue.int(seconds)
    }

    private static func codexEvent(_ value: JSONValue, file: String) -> (id: String, record: JSONObject)? {
        let timestamp = rawText(value, ["timestamp"])
        guard !timestamp.isEmpty else { return nil }
        let total = rawText(value, ["payload", "info", "total_token_usage", "total_tokens"])
        let last = rawText(value, ["payload", "info", "last_token_usage", "total_tokens"])
        let id = "codex-session:" + Shell.sha256Hex("\(file):\(timestamp):\(total):\(last)")

        // Any field that errors fails the jq program, and the line is skipped.
        guard let capturedAt = captureTime(value),
              let stamp = value.jqValue(["timestamp"], or: .null),
              let contextWindow = value.jqValue(["payload", "info", "model_context_window"], or: .null),
              let totalUsage = value.jqValue(["payload", "info", "total_token_usage"], or: .null),
              let lastUsage = value.jqValue(["payload", "info", "last_token_usage"], or: .null),
              let rateLimits = value.jqValue(["payload", "rate_limits"], or: .null) else { return nil }

        var record = JSONObject()
        record["schema"] = JSONValue.string("usage.v1")
        record["source"] = JSONValue.string("codex-session")
        record["event_id"] = JSONValue.string(id)
        record["capturedAt"] = capturedAt
        record["timestamp"] = stamp
        record["model"] = JSONValue.null
        record["modelContextWindow"] = contextWindow
        record["tokenUsage"] = JSONValue.object(JSONObject([
            "total": totalUsage,
            "last": lastUsage
        ]))
        record["rateLimits"] = rateLimits
        record["sourcePath"] = JSONValue.string(file)
        return (id, record)
    }

    private static func claudeEvent(_ value: JSONValue, file: String) -> (id: String, record: JSONObject)? {
        // jq -e '.message.usage != null and (.message.usage.output_tokens != null)'
        guard let usage = value.jqPath(["message", "usage"]) else { return nil }
        if case .null = usage { return nil }
        guard let outputTokens = usage.jqField("output_tokens") else { return nil }
        if case .null = outputTokens { return nil }

        // requestId is unique per API call, so it is the dedupe key; fall back
        // to message.id, then the timestamp:
        // (.requestId // .message.id // .timestamp // empty)
        let requestValue = value.jqValue(["requestId"])
            ?? value.jqValue(["message", "id"])
            ?? value.jqValue(["timestamp"])
        let requestID = requestValue.map { Shell.trimmingTrailingNewlines($0.jqRawText) } ?? ""
        let timestamp = rawText(value, ["timestamp"])
        guard !requestID.isEmpty, !timestamp.isEmpty else { return nil }
        let id = "claude-session:" + Shell.sha256Hex("\(file):\(requestID)")

        func tokens(_ key: String) -> JSONValue? {
            value.jqValue(["message", "usage", key], or: .int(0))
        }
        guard let capturedAt = captureTime(value),
              let stamp = value.jqValue(["timestamp"], or: .null),
              let model = value.jqValue(["message", "model"], or: .null),
              let entrypoint = value.jqValue(["entrypoint"], or: .null),
              let input = tokens("input_tokens"),
              let output = tokens("output_tokens"),
              let cacheCreation = tokens("cache_creation_input_tokens"),
              let cacheRead = tokens("cache_read_input_tokens") else { return nil }

        var record = JSONObject()
        record["schema"] = JSONValue.string("usage.v1")
        record["source"] = JSONValue.string("claude-session")
        record["event_id"] = JSONValue.string(id)
        record["capturedAt"] = capturedAt
        record["timestamp"] = stamp
        record["model"] = model
        record["entrypoint"] = entrypoint
        record["tokenUsage"] = JSONValue.object(JSONObject([
            "input_tokens": input,
            "output_tokens": output,
            "cache_creation_input_tokens": cacheCreation,
            "cache_read_input_tokens": cacheRead
        ]))
        record["rateLimits"] = JSONValue.null
        record["sourcePath"] = JSONValue.string(file)
        return (id, record)
    }
}

/// jq's date helpers as the ingest scripts used them.
enum JQTime {
    /// `sub("\\.[0-9]+Z$"; "Z")`: drop fractional seconds before a final Z.
    static func droppingFractionalSeconds(_ stamp: String) -> String {
        var scalars = Array(stamp.unicodeScalars)
        // `$` also matches just before one final newline.
        var tail: [Unicode.Scalar] = []
        if scalars.last == "\n" {
            tail = [scalars.removeLast()]
        }
        guard scalars.last == "Z" else { return stamp }
        let digits: ClosedRange<Unicode.Scalar> = "0"..."9"
        var index = scalars.count - 2
        while index >= 0, digits.contains(scalars[index]) { index -= 1 }
        guard index >= 0, index < scalars.count - 2, scalars[index] == "." else { return stamp }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: scalars[0..<index])
        result.append("Z")
        result.append(contentsOf: tail)
        return String(result)
    }

    /// `fromdateiso8601`: strptime("%Y-%m-%dT%H:%M:%SZ") | mktime, with the
    /// field rules of the macOS (BSD) strptime jq calls. nil = no match.
    static func fromISO8601(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        var index = 0

        func number(maxDigits: Int) -> Int? {
            guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else { return nil }
            var value = 0
            var count = 0
            while count < maxDigits, index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                value = value * 10 + Int(bytes[index] - 0x30)
                index += 1
                count += 1
            }
            return value
        }
        func literal(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        guard let year = number(maxDigits: 4), literal(UInt8(ascii: "-")),
              let month = number(maxDigits: 2), (1...12).contains(month), literal(UInt8(ascii: "-")),
              let day = number(maxDigits: 2), day <= 31, literal(UInt8(ascii: "T")),
              let hour = number(maxDigits: 2), hour <= 23, literal(UInt8(ascii: ":")),
              let minute = number(maxDigits: 2), minute <= 59, literal(UInt8(ascii: ":")),
              let second = number(maxDigits: 2), second <= 60, literal(UInt8(ascii: "Z")) else { return nil }
        // jq accepts trailing whitespace after the format, nothing else.
        if index < bytes.count {
            let next = bytes[index]
            guard next == 0x20 || (0x09...0x0D).contains(next) else { return nil }
        }
        // timegm, which normalizes out-of-range days (Feb 31 -> Mar 3).
        let days = daysFromCivil(year: year, month: month, day: 1) + (day - 1)
        return days * 86_400 + hour * 3600 + minute * 60 + second
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
