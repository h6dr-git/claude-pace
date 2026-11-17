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

    /// A session limit line, readable or not. Only output without one can
    /// count towards "this account has no 5-hour limit".
    private static let sessionHeading = try! NSRegularExpression(
        pattern: #"^\s*Current session\b"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )

    private static let fiveHours: Double = 5 * 3600

    /// How far clear of both bounds the "no 5-hour limit" evidence must be.
    /// capturedAt is stamped once the CLI has returned, a little after
    /// `/usage` looked; `/usage` prints resets to the minute; and usage can be
    /// counted a little late. Ten minutes covers all three and costs nothing
    /// on an account without the limit, whose last window ended long ago.
    private static let evidenceSlack: Double = 10 * 60

    private static func update(_ paths: AppPaths, from output: String, io: CommandIO) -> Int32 {
        let now = Date()
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
            fiveReset = UsageResetTime.epoch(text: group(match, 2), timeZoneName: group(match, 3), now: now)
        }
        let sessionLine = sessionHeading.firstMatch(in: output, range: whole) != nil

        var week: Int?
        var weekReset: Double?
        var modelWindows: [(name: String, used: Int, reset: Double?)] = []
        for match in weekPattern.matches(in: output, range: whole) {
            let name = (group(match, 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let used = group(match, 2).flatMap({ Int($0) }) else { continue }
            let reset = UsageResetTime.epoch(text: group(match, 3), timeZoneName: group(match, 4), now: now)
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
            if let reset {
                updated["resets_at"] = .number(JSONNumber(pythonFloat: reset))
            } else if case .number(let previous)? = updated["resets_at"],
                      previous.doubleValue < now.timeIntervalSince1970 {
                // A fresh percentage without a readable reset must not inherit
                // one that has already passed: that instant belongs to a window
                // that ended, and the menu would read the new number as "no
                // window open". No reset is honest; a stale one is not.
                updated["resets_at"] = .null
            }
            return .object(updated)
        }
        // A session line that could not be read still means a 5-hour window
        // may be open, so the stored one keeps its reset only while that is
        // ahead. A passed reset would read as ended: in the menu as "no window
        // open", and to later polls as "none open", the ground for concluding
        // there is no 5-hour limit. Without a reset the window counts as open
        // until 5 hours after this poll (`fiveHourSeenAt`, see `noWindowOpen`).
        func possiblyOpen(_ old: JSONValue) -> JSONValue {
            if let reset = finiteNumber(old.objectValue?["resets_at"]), reset > now.timeIntervalSince1970 {
                return old
            }
            var updated = old.objectValue ?? JSONObject()
            updated["resets_at"] = .null
            return .object(updated)
        }
        func oldWindow(_ key: String) -> JSONValue {
            // Python's `cur.get(key) or {}`
            guard let value = current[key], value.isPythonTruthy else { return .object(JSONObject()) }
            return value
        }

        let capturedAt = Int(now.timeIntervalSince1970)
        var snapshot = current
        snapshot["capturedAt"] = .int(capturedAt)
        snapshot["fiveHour"] = sessionLine && five == nil
            ? possiblyOpen(oldWindow("fiveHour"))
            : window(oldWindow("fiveHour"), five, fiveReset)
        // A session line, readable or not, means a 5-hour window may be open
        // now. Later polls judge "none open at the previous poll" by this
        // time too, not by the stored reset alone.
        if sessionLine {
            snapshot["fiveHourSeenAt"] = .int(capturedAt)
        }
        snapshot["sevenDay"] = window(oldWindow("sevenDay"), week, weekReset)

        // Per-model weekly buckets are keyed by the name `/usage` printed, so a
        // renamed or new model shows up without a code change. Buckets missing
        // a reset inherit the all-models weekly reset — the same window.
        var buckets = JSONObject()
        if let previous = current["modelWindows"], previous.isPythonTruthy, case .object(let object) = previous {
            buckets = object
        }
        // A bucket left out next to the all-models line is no reading any
        // more: `/usage` stopped printing it (a retired or renamed model, or
        // one it does not list right now). Its percentage goes and its reset
        // stays, so it no longer reads as current or draws the ring; a poll
        // that prints it again brings it back. Output without the all-models
        // line says nothing about the buckets, and they stay as they were.
        if week != nil, !buckets.isEmpty {
            let printed = Set(modelWindows.map { $0.name })
            for (name, value) in buckets.entries where !printed.contains(name) {
                guard case .object(var bucket) = value else { continue }
                bucket["used_percentage"] = .null
                buckets[name] = .object(bucket)
            }
            snapshot["modelWindows"] = .object(buckets)
        }
        if !modelWindows.isEmpty {
            var merged = buckets
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

        // On an account without a 5-hour limit the last window, long ended,
        // would otherwise stay in the snapshot for good.
        let absentSince = fiveHourAbsence(
            before: current,
            after: snapshot,
            models: modelWindows.map { $0.name },
            sessionLine: sessionLine,
            at: capturedAt
        )
        if absentSince != nil {
            snapshot["fiveHour"] = .null
        } else if !sessionLine {
            settleWithoutSessionLine(&snapshot, previous: current, at: now)
        }
        snapshot["fiveHourAbsentSince"] = absentSince
        snapshot["source"] = .string("usage-poll")

        let json = JSONValue.object(snapshot).pythonText(ensureASCII: true, compact: false)
        Shell.replaceAtomically(Data(json.utf8), at: paths.snapshot)
        writeState(paths, "ok", "")

        let models = modelWindows.map { "'\($0.name)'" }.sorted().joined(separator: ", ")
        var summary = "snapshot updated: 5h=\(five.map { String($0) } ?? "None")% week=\(week.map { String($0) } ?? "None")% models=[\(models)] capturedAt=\(capturedAt)"
        if let absentSince {
            summary += " fiveHourAbsentSince=\(absentSince.pythonText(ensureASCII: true, compact: true))"
        }
        io.out(summary)
        return 0
    }

    // MARK: - Accounts without a 5-hour limit

    /// `fiveHourAbsentSince` for this poll: since when the account is known
    /// to have no 5-hour limit, or nil while it may have one.
    ///
    /// Verified Ultra accounts lost the limit from 2026-10-30 (Pro and Max
    /// keep it), and `/usage` then prints no session line — the same output
    /// as between two 5-hour windows, so a missing line proves nothing alone.
    /// Two polls under 5 hours apart do, when weekly usage grew in between
    /// and no 5-hour window was open at the first: with the limit, that usage
    /// opened a window lasting 5 hours from its first message, still open at
    /// the second poll, which would have printed the session line. (A window
    /// already open at the first poll could have taken the usage and closed
    /// since, which is why none may be open then, see `noWindowOpen`.) Both
    /// bounds keep `evidenceSlack` clear: the last 5-hour window must have
    /// ended 10 minutes before the first poll, and the polls be 10 minutes
    /// under 5 hours apart. Once concluded it holds, with no new evidence
    /// needed, until a poll prints a session line again.
    private static func fiveHourAbsence(
        before previous: JSONObject,
        after updated: JSONObject,
        models: [String],
        sessionLine: Bool,
        at now: Int
    ) -> JSONValue? {
        guard !sessionLine else { return nil }
        if let since = previous["fiveHourAbsentSince"], finiteNumber(since) != nil {
            return since
        }

        guard let then = finiteNumber(previous["capturedAt"]) else { return nil }
        let elapsed = Double(now) - then
        guard elapsed > 0, elapsed < fiveHours - evidenceSlack,
              noWindowOpen(previous["fiveHour"], seenAt: finiteNumber(previous["fiveHourSeenAt"]), at: then)
        else { return nil }
        let oldBuckets = previous["modelWindows"]?.objectValue
        let newBuckets = updated["modelWindows"]?.objectValue
        let used = usageGrew(previous["sevenDay"], updated["sevenDay"])
            || models.contains { usageGrew(oldBuckets?[$0], newBuckets?[$0]) }
        return used ? .int(now) : nil
    }

    /// No 5-hour window was open at the previous poll, taken at `then`: the
    /// last one known had ended `evidenceSlack` before it.
    ///
    /// Two things bound when that was: the last poll that printed a session
    /// line (`seenAt`, a window may have been open then), and the stored
    /// window's reset, or for one without a reset (a percentage alone, or
    /// what an unreadable session line leaves) 5 hours after `seenAt`, since
    /// no window lasts longer. The later of them counts. A previous poll that
    /// printed the line itself proves nothing, whatever its reset says: the
    /// Mac's clock may run fast, or the reset fall in the hour a clock change
    /// repeats (stored at its first occurrence). No window stored and no line
    /// ever seen: none was open (a fresh install).
    private static func noWindowOpen(_ window: JSONValue?, seenAt: Double?, at then: Double) -> Bool {
        if let seenAt, seenAt >= then { return false }
        let end: Double?
        switch storedFiveHour(window) {
        case .none:
            end = nil
        case .resets(let reset):
            end = reset
        case .unbounded:
            // Undated so far; `settleWithoutSessionLine` dates it during this poll.
            guard let seenAt else { return false }
            end = seenAt + fiveHours
        }
        guard let bound = [end, seenAt].compactMap({ $0 }).max() else { return true }
        return bound <= then - evidenceSlack
    }

    /// A stored 5-hour window, as far as "was one open?" goes.
    private enum StoredFiveHour {
        /// None stored: missing, null or `{}`.
        case none
        /// One with a known reset.
        case resets(Double)
        /// One without a usable reset: a percentage alone, what an unreadable
        /// session line leaves, or anything else that is not a window.
        case unbounded
    }

    private static func storedFiveHour(_ window: JSONValue?) -> StoredFiveHour {
        switch window {
        case nil, .null?:
            return .none
        case .object(let object)?:
            if object.isEmpty { return .none }
            return finiteNumber(object["resets_at"]).map(StoredFiveHour.resets) ?? .unbounded
        default:
            return .unbounded
        }
    }

    /// A poll that printed no session line and concluded nothing keeps the
    /// stored 5-hour window, with two exceptions.
    ///
    /// A percentage whose reset is still ahead was not printed this time (the
    /// limit may have gone mid-window, or the line is just missing), so it
    /// loses its number: none may read as current that no poll printed as
    /// current. Its reset stays and still marks the window as possibly open
    /// for `noWindowOpen`; that it went missing proves nothing by itself, as
    /// an early reset on an account with the limit looks the same. And a
    /// window without a reset, from before `fiveHourSeenAt` existed, is dated
    /// by the previous poll, no earlier than its real sighting, so that it
    /// ends 5 hours on instead of blocking the conclusion for good.
    private static func settleWithoutSessionLine(
        _ snapshot: inout JSONObject, previous: JSONObject, at now: Date
    ) {
        switch storedFiveHour(previous["fiveHour"]) {
        case .resets(let reset) where reset > now.timeIntervalSince1970:
            guard case .object(var window)? = snapshot["fiveHour"] else { return }
            window["used_percentage"] = .null
            snapshot["fiveHour"] = .object(window)
        case .unbounded where finiteNumber(previous["fiveHourSeenAt"]) == nil:
            guard let then = previous["capturedAt"], finiteNumber(then) != nil else { return }
            snapshot["fiveHourSeenAt"] = then
        default:
            break
        }
    }

    /// The same weekly window (an equal reset, as stored) shows a higher
    /// percentage than before: Claude was used in between.
    private static func usageGrew(_ before: JSONValue?, _ after: JSONValue?) -> Bool {
        guard let old = before?.objectValue, let new = after?.objectValue,
              let oldUsed = finiteNumber(old["used_percentage"]),
              let newUsed = finiteNumber(new["used_percentage"]),
              let oldReset = finiteNumber(old["resets_at"]),
              let newReset = finiteNumber(new["resets_at"]) else { return false }
        return newUsed > oldUsed && newReset == oldReset
    }

    /// A JSON number as a finite Double; nil for anything else.
    private static func finiteNumber(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
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
