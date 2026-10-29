import Foundation

/// Reads the real account rate-limit percentages through the official
/// `claude -p "/usage"` command and merges them into snapshot.json.
/// (Formerly tools/poll-usage.sh and the Python embedded in it.)
///
/// `/usage` is a read-only query: it does not consume the 5h/weekly quota.
/// Official command only — no private endpoints, token scraping or proxies.
/// Poll no more often than ~180s to stay clear of the endpoint's rate cap. On
/// any failure the snapshot is left untouched and the reason is recorded in
/// claude-collector-state.json, so the menu can say why instead of silently
/// showing a frozen number.
enum ClaudeUsageCollector {
    struct Context {
        let home: String
        /// The environment `claude` runs with (and whose PATH finds it).
        let environment: [String: String]
        /// CLAUDE_BIN: use exactly this executable.
        let claudeBin: String?
    }

    static func poll(_ context: Context, io: CommandIO) -> Int32 {
        let paths = AppPaths(home: context.home)
        Shell.makeDirectories(paths.appDir)

        // `claude` may not be on PATH under launchd, so fall back to the known
        // install locations. CLAUDE_BIN overrides all of them, which is also
        // how the isolated test keeps the real CLI out of the loop.
        let claude: String
        if let override = context.claudeBin, !override.isEmpty {
            claude = override
        } else {
            claude = CollectorEnvironment.which("claude", path: context.environment["PATH"])
                ?? ["/opt/homebrew/bin/claude", context.home + "/.local/bin/claude"]
                    .first(where: Shell.isExecutable)
                ?? "/opt/homebrew/bin/claude"
        }
        guard Shell.isExecutable(claude) else {
            writeState(paths, "cli-missing", "claude 실행 파일을 찾지 못했습니다")
            io.err("claude cli not found")
            return 0
        }

        // Run from an empty scratch directory. Without a working directory
        // Claude Code takes $HOME as the project root and walks it, reaching
        // TCC-protected app data — macOS then asks "allow claude?" on every
        // poll. An empty directory has nothing to walk.
        let directory = Shell.makeDirectories(paths.scratch) ? paths.scratch : "/"

        // Each `claude` call gets CLAUDE_USAGE_TIMEOUT seconds (default 60).
        // Without a limit a CLI that never returns — a network stall, a
        // keychain prompt nobody answers — stopped every later poll.
        let seconds = min(max(Shell.digits(Shell.setting(context.environment, "CLAUDE_USAGE_TIMEOUT"), default: 60), 1), 86_400)
        let timeout = TimeInterval(seconds)

        // Ask whether the CLI is signed in before spending a `/usage` round
        // trip: a logged-out CLI prints no auth error there, just a cost
        // summary without limit lines, which would read as "the output format
        // changed". `auth status` is a local, offline check.
        let auth = ChildProcess.captureOutput(
            claude, ["auth", "status"], environment: context.environment, directory: directory, timeout: timeout
        )
        switch auth.outcome {
        case .timedOut:
            writeState(paths, "timed-out", "`claude auth status`가 \(seconds)초 안에 끝나지 않았습니다")
            io.err("claude auth status timed out after \(seconds)s, keeping snapshot")
            return 0
        case .exited:
            let status = Shell.trimmingTrailingNewlines(String(decoding: auth.output, as: UTF8.self))
            if !status.isEmpty, signedInState(status) == false {
                writeState(paths, "signed-out", "터미널 claude가 로그아웃 상태입니다")
                io.err("claude cli reports signed out, keeping snapshot")
                return 0
            }
        case .notStarted:
            break
        }

        // --no-session-persistence keeps the 180s poll from leaving a throwaway
        // session file behind on every run (it once buried the real session
        // list under 314 stubs). No MCP servers or browser bridge are needed.
        let query = ChildProcess.runRedirectingOutput(
            claude,
            ["-p", "/usage",
             "--no-session-persistence",
             "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-chrome"],
            environment: context.environment,
            directory: directory,
            to: paths.usageRaw,
            timeout: timeout
        )
        if case .timedOut = query {
            writeState(paths, "timed-out", "`/usage` 조회가 \(seconds)초 안에 끝나지 않았습니다")
            io.err("usage query timed out after \(seconds)s, keeping snapshot")
            return 0
        }

        guard Shell.isNonEmpty(paths.usageRaw), let raw = Shell.readData(paths.usageRaw) else {
            writeState(paths, "empty-output", "/usage 출력이 비어 있습니다")
            io.err("usage output empty, keeping snapshot")
            return 0
        }
        let output = String(decoding: raw, as: UTF8.self)

        // An expired login prints an auth error instead of the limit lines.
        let authErrors = ["failed to authenticate", "oauth session expired", "invalid api key",
                          "please run /login", "not logged in"]
        if authErrors.contains(where: { output.range(of: $0, options: .caseInsensitive) != nil }) {
            writeState(paths, "signed-out", "터미널 claude 로그인이 만료됐습니다")
            io.err("claude cli signed out, keeping snapshot")
            return 0
        }

        return update(paths, from: output, io: io)
    }

    /// `json.load(...).get("loggedIn")`: true / false, or nil when unknown.
    private static func signedInState(_ text: String) -> Bool? {
        guard let value = try? JSONParser.parse(text), case .object(let object) = value,
              case .bool(let loggedIn)? = object["loggedIn"] else { return nil }
        return loggedIn
    }

    // MARK: - Parsing /usage

    private static let sessionPattern = try! NSRegularExpression(
        pattern: #"^\s*Current session:\s*(\d+)%\s*used(?:[^\S\n]*·[^\S\n]*resets\s+(.+?))?(?:\s*\(([^)]*)\))?\s*$"#,
        options: [.anchorsMatchLines]
    )

    private static let weekPattern = try! NSRegularExpression(
        pattern: #"^\s*Current week\s*\(([^)]*)\):\s*(\d+)%\s*used(?:[^\S\n]*·[^\S\n]*resets\s+(.+?))?(?:\s*\(([^)]*)\))?\s*$"#,
        options: [.anchorsMatchLines]
    )

    private static let limitHeading = try! NSRegularExpression(
        pattern: "Current (session|week)",
        options: [.caseInsensitive]
    )

    private static let fiveHours: Double = 5 * 3600
    private static let oneWeek: Double = 7 * 24 * 3600

    private static func update(_ paths: AppPaths, from output: String, io: CommandIO) -> Int32 {
        let text = output as NSString
        let whole = NSRange(location: 0, length: text.length)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }

        var five: Int?
        var fiveReset: Double?
        if let match = sessionPattern.firstMatch(in: output, range: whole) {
            five = group(match, 1).flatMap { Int($0) }
            fiveReset = UsageResetTime.epoch(text: group(match, 2), timeZoneName: group(match, 3), windowLength: fiveHours)
        }

        var week: Int?
        var weekReset: Double?
        var modelWindows: [(name: String, used: Int, reset: Double?)] = []
        for match in weekPattern.matches(in: output, range: whole) {
            let name = (group(match, 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let used = group(match, 2).flatMap({ Int($0) }) else { continue }
            let reset = UsageResetTime.epoch(text: group(match, 3), timeZoneName: group(match, 4), windowLength: oneWeek)
            if ["all models", "all model", "all"].contains(name.lowercased()) {
                week = used
                weekReset = reset
            } else if !name.isEmpty {
                if let existing = modelWindows.firstIndex(where: { $0.name == name }) {
                    modelWindows[existing] = (name, used, reset)
                } else {
                    modelWindows.append((name, used, reset))
                }
            }
        }

        // Never overwrite with garbage, and say which failure shape this was.
        if five == nil && week == nil {
            if limitHeading.firstMatch(in: output, range: whole) != nil {
                writeState(paths, "parse-failed", "한도 줄은 있으나 형식을 해석하지 못했습니다")
                io.err("limit lines present but unparsed, keeping snapshot")
            } else {
                writeState(paths, "no-limits", "`/usage` 출력에 한도 줄이 없습니다")
                io.err("no limit lines in output, keeping snapshot")
            }
            return 0
        }

        var current = JSONObject()
        if let data = Shell.readData(paths.snapshot),
           case .object(let object)? = try? JSONParser.parse(data) {
            current = object
        }

        func window(_ old: JSONValue, _ used: Int?, _ reset: Double?) -> JSONValue {
            guard let used else { return old }
            var updated = old.objectValue ?? JSONObject()
            updated["used_percentage"] = .int(used)
            if let reset { updated["resets_at"] = .number(JSONNumber(pythonFloat: reset)) }
            return .object(updated)
        }
        func oldWindow(_ key: String) -> JSONValue {
            // Python's `cur.get(key) or {}`
            guard let value = current[key], value.isPythonTruthy else { return .object(JSONObject()) }
            return value
        }

        let capturedAt = Shell.nowSeconds()
        var snapshot = current
        snapshot["capturedAt"] = .int(capturedAt)
        snapshot["fiveHour"] = window(oldWindow("fiveHour"), five, fiveReset)
        snapshot["sevenDay"] = window(oldWindow("sevenDay"), week, weekReset)

        // Per-model weekly buckets are keyed by the name `/usage` printed, so a
        // renamed or new model shows up without a code change. Buckets missing
        // a reset inherit the all-models weekly reset — the same window.
        if !modelWindows.isEmpty {
            var merged = JSONObject()
            if let previous = current["modelWindows"], previous.isPythonTruthy, case .object(let object) = previous {
                merged = object
            }
            for bucket in modelWindows {
                var resetValue = JSONValue.null
                if let reset = bucket.reset ?? weekReset {
                    resetValue = .number(JSONNumber(pythonFloat: reset))
                }
                merged[bucket.name] = .object(JSONObject([
                    "used_percentage": .int(bucket.used),
                    "resets_at": resetValue
                ]))
            }
            snapshot["modelWindows"] = .object(merged)
        }
        snapshot["source"] = .string("usage-poll")

        let json = JSONValue.object(snapshot).pythonText(ensureASCII: true, compact: false)
        Shell.replaceAtomically(Data(json.utf8), at: paths.snapshot)
        writeState(paths, "ok", "")

        let models = modelWindows.map { "'\($0.name)'" }.sorted().joined(separator: ", ")
        io.out("snapshot updated: 5h=\(five.map { String($0) } ?? "None")% week=\(week.map { String($0) } ?? "None")% models=[\(models)] capturedAt=\(capturedAt)")
        return 0
    }

    /// claude-collector-state.json: why this poll ended the way it did. The
    /// app treats a missing or unknown status as "collection blocked".
    private static func writeState(_ paths: AppPaths, _ status: String, _ detail: String) {
        let state = JSONValue.object(JSONObject([
            "schema": .string("claude-collector-state.v1"),
            "status": .string(status),
            "capturedAt": .int(Shell.nowSeconds()),
            "detail": .string(detail)
        ]))
        Shell.replaceAtomically(Data(state.pythonText(ensureASCII: false, compact: false).utf8), at: paths.collectorState)
    }
}

/// Reset instants as `/usage` prints them: "Jul 22 at 8:50pm", "Jul 29 at
/// 2pm" — no year, and ':00' dropped on whole hours. Ports `reset_epoch`,
/// including Python's `strptime` matching rules.
enum UsageResetTime {
    private struct Format {
        let regex: NSRegularExpression
        let hasMinutes: Bool
    }

    // Python builds these from "%b %d at %I:%M%p %Y" and friends: whitespace
    // in the format matches one or more spaces, matching ignores case, and the
    // first match must consume the whole string.
    private static let month = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"
    private static let day = "(3[01]|[12]\\d|0[1-9]|[1-9]| [1-9])"
    private static let hour = "(1[0-2]|0[1-9]|[1-9])"
    private static let minute = "([0-5]\\d|\\d)"
    private static let ampm = "(am|pm)"
    private static let year = "(\\d\\d\\d\\d)"

    private static let formats: [Format] = [
        Format(regex: make("\(month)\\s+\(day)\\s+at\\s+\(hour):\(minute)\(ampm)\\s+\(year)"), hasMinutes: true),
        Format(regex: make("\(month)\\s+\(day)\\s+at\\s+\(hour)\(ampm)\\s+\(year)"), hasMinutes: false),
        Format(regex: make("\(month)\\s+\(day)\\s+at\\s+\(hour):\(minute)\\s+\(ampm)\\s+\(year)"), hasMinutes: true),
        Format(regex: make("\(month)\\s+\(day)\\s+at\\s+\(hour)\\s+\(ampm)\\s+\(year)"), hasMinutes: false)
    ]

    private static func make(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "^" + pattern, options: [.caseInsensitive])
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun",
                                 "jul", "aug", "sep", "oct", "nov", "dec"]

    /// The reset instant as epoch seconds, rolled forward by whole windows
    /// until it is not in the past; nil when the text is not a reset time.
    static func epoch(text: String?, timeZoneName: String?, windowLength: Double, now: Date = Date()) -> Double? {
        guard let raw = text, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        var zone = TimeZone.current
        if let name = timeZoneName, !name.isEmpty, let named = TimeZone(identifier: name) {
            zone = named
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let currentYear = calendar.component(.year, from: now)

        let input = "\(trimmed) \(currentYear)"
        let nsInput = input as NSString
        for format in formats {
            guard let match = format.regex.firstMatch(in: input, range: NSRange(location: 0, length: nsInput.length)),
                  match.range.location == 0,
                  match.range.length == nsInput.length else { continue }
            func part(_ index: Int) -> String {
                nsInput.substring(with: match.range(at: index))
            }
            guard let monthIndex = months.firstIndex(of: part(1).lowercased()),
                  let dayValue = Int(part(2).trimmingCharacters(in: .whitespaces)),
                  let hour12 = Int(part(3)) else { continue }
            var group = 4
            var minuteValue = 0
            if format.hasMinutes {
                guard let parsed = Int(part(group)) else { continue }
                minuteValue = parsed
                group += 1
            }
            let isPM = part(group).lowercased() == "pm"
            guard let yearValue = Int(part(group + 1)) else { continue }

            var hour24 = hour12 == 12 ? 0 : hour12
            if isPM { hour24 += 12 }

            // datetime() rejects a day the month does not have (Feb 30).
            var components = DateComponents()
            components.year = yearValue
            components.month = monthIndex + 1
            guard let firstOfMonth = calendar.date(from: components),
                  let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count,
                  dayValue >= 1, dayValue <= daysInMonth else { continue }

            components.day = dayValue
            components.hour = hour24
            components.minute = minuteValue
            components.second = 0
            guard let date = calendar.date(from: components) else { continue }

            // The printed instant may already have passed; walk it forward.
            var epoch = date.timeIntervalSince1970
            let current = now.timeIntervalSince1970
            while epoch < current { epoch += windowLength }
            return epoch
        }
        return nil
    }
}
