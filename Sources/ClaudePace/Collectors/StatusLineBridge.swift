import Foundation

/// The Claude Code `statusLine` command (formerly bridge/statusline.sh).
/// Claude Code pipes a JSON blob (including `rate_limits`, when it has them)
/// on stdin at every render; this writes a snapshot the menu bar reads,
/// records a history line when something changed, and prints the status text.
/// It must stay fast: no network, one stdin read.
enum StatusLineBridge {
    static func run(input rawInput: Data, home: String, environment: [String: String]) -> String {
        let paths = AppPaths(home: home)
        // `input=$(cat)`: trailing newlines go, and the shell cannot hold NULs.
        let input = Shell.trimmingTrailingNewlines(
            String(decoding: rawInput.filter { $0 != 0 }, as: UTF8.self)
        )

        Shell.makeDirectories(paths.appDir)
        Shell.makeDirectories(paths.debugDir)

        // 1) Raw dump: shows the exact schema Claude Code sends.
        Shell.overwrite(input, to: paths.debugDir + "/last-input.json")

        let now = Shell.nowSeconds()
        let stream = JSONParser.parseStream(input)

        // `jq -e .`: valid JSON whose last value is neither null nor false.
        if !stream.failed, let last = stream.values.last, last.isTruthy {
            record(stream.values, now: now, paths: paths, environment: environment)
        }

        // 3) Status text (secondary: the menu bar app is the real UI).
        let week = rendered(stream.values, ["rate_limits", "seven_day", "used_percentage"])
        let five = rendered(stream.values, ["rate_limits", "five_hour", "used_percentage"])
        guard !week.isEmpty || !five.isEmpty else {
            return "⏱ AI Usage · Claude (rate_limits 대기…)"
        }
        var text = "⏱ AI Usage · Claude"
        if !week.isEmpty { text += " · 주 \(Shell.removingLastDotSuffix(week))%" }
        if !five.isEmpty { text += " · 5h \(Shell.removingLastDotSuffix(five))%" }
        return text
    }

    /// 2) Snapshot (atomic) and history.
    private static func record(_ values: [JSONValue], now: Int, paths: AppPaths, environment: [String: String]) {
        // jq runs its filter once per input value and keeps going after an
        // error, but the `&& mv` only happens when every value succeeded.
        var snapshotText = ""
        var snapshotFailed = false
        for value in values {
            if let snapshot = makeSnapshot(value, now: now) {
                snapshotText += JSONValue.object(snapshot).prettyText + "\n"
            } else {
                snapshotFailed = true
            }
        }
        let temporary = paths.snapshot + ".tmp"
        if Shell.overwrite(snapshotText, to: temporary), !snapshotFailed {
            _ = Shell.move(temporary, to: paths.snapshot)
        }

        // The signature decides whether a history line is due.
        var signatureInput = ""
        for value in values {
            signatureInput += JSONValue.array([model(value), value.jqValue(["rate_limits"], or: .object(JSONObject()))]).compactText + "\n"
        }
        let signature = Shell.sha256Hex(signatureInput)
        let interval = Shell.digits(Shell.setting(environment, "CLAUDEPACE_HISTORY_INTERVAL"), default: 300)
        let timeout = Shell.digits(Shell.setting(environment, "USAGE_LOG_LOCK_TIMEOUT"), default: 120)

        let history = paths.appDir + "/.claude-history.sig"
        let historyTime = paths.appDir + "/.claude-history.ts"

        _ = UsageLogRotation.rotate(paths.usageLog, environment: environment, io: .silent)

        let files = UsageLogFiles(log: paths.usageLog)
        if case .success(let lock) = files.lock(timeoutSeconds: timeout, io: .silent) {
            let lastSignature = Shell.readText(history) ?? ""
            let lastTime = Shell.digits(Shell.readText(historyTime), default: 0)

            if signature != lastSignature || now - lastTime >= interval {
                var lines = ""
                for value in values {
                    var entry = JSONObject()
                    entry["schema"] = JSONValue.string("usage.v1")
                    entry["source"] = JSONValue.string("claude-statusline")
                    entry["event_id"] = JSONValue.string("claude-statusline:\(now):\(signature)")
                    entry["capturedAt"] = JSONValue.int(now)
                    entry["timestamp"] = JSONValue.string(Shell.utcTimestamp(now))
                    entry["model"] = model(value)
                    entry["rateLimits"] = value.jqValue(["rate_limits"], or: .object(JSONObject()))
                    entry["tokenUsage"] = JSONValue.null
                    entry["sourcePath"] = JSONValue.string("Claude Code statusLine")
                    lines += JSONValue.object(entry).compactText + "\n"
                }
                if Shell.append(lines, to: paths.usageLog) {
                    Shell.overwrite(signature, to: history)
                    Shell.overwrite(String(now), to: historyTime)
                }
            }
            lock.release()
        }

        _ = UsageLogRotation.rotate(paths.usageLog, environment: environment, io: .silent)
    }

    /// `(.model.display_name // .model.id // null)`
    private static func model(_ value: JSONValue) -> JSONValue {
        value.jqValue(["model", "display_name"]) ?? value.jqValue(["model", "id"]) ?? .null
    }

    /// The snapshot filter, or nil where jq would raise an error.
    private static func makeSnapshot(_ value: JSONValue, now: Int) -> JSONObject? {
        let limits = value.jqValue(["rate_limits"], or: .object(JSONObject()))
        guard let fiveHour = limits.jqField("five_hour"),
              let sevenDay = limits.jqField("seven_day"),
              let sevenDayOpus = limits.jqField("seven_day_opus"),
              let sevenDaySonnet = limits.jqField("seven_day_sonnet") else { return nil }

        // `.model.display_name // .model.id`: the right-hand side is not
        // protected, so an unindexable `.model` is an error.
        let model: JSONValue
        if let name = value.jqValue(["model", "display_name"]) {
            model = name
        } else {
            guard let id = value.jqPath(["model", "id"]) else { return nil }
            model = id
        }

        var snapshot = JSONObject()
        snapshot["capturedAt"] = JSONValue.int(now)
        snapshot["fiveHour"] = fiveHour
        snapshot["sevenDay"] = sevenDay
        snapshot["sevenDayOpus"] = sevenDayOpus
        snapshot["sevenDaySonnet"] = sevenDaySonnet
        snapshot["model"] = model
        snapshot["raw_rate_limits"] = limits
        return snapshot
    }

    /// `$(jq -r 'path // empty')` over every input value.
    private static func rendered(_ values: [JSONValue], _ path: [String]) -> String {
        let outputs = values.compactMap { $0.jqValue(path)?.jqRawText }
        return Shell.trimmingTrailingNewlines(outputs.joined(separator: "\n"))
    }
}
