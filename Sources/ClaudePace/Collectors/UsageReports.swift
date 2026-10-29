import Foundation

/// The manual reports (formerly tools/usage-daily-deltas.sh and
/// tools/usage-monthly-summary.sh). Both read the active ledger and every
/// immutable archive segment; neither rotates, compresses, deletes or
/// rewrites anything.
///
/// Codex `token_count` records carry session-cumulative totals, so they are
/// never summed directly: records are grouped by session, and the delta is the
/// last observed total minus the first one.
enum UsageReports {
    enum Kind {
        case daily
        case monthly(period: String)
    }

    private static let usageFields = [
        "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"
    ]

    static func run(_ kind: Kind, log: String, environment: [String: String], io: CommandIO, now: Date = Date()) -> Int32 {
        let files = UsageLogFiles(log: log)
        var offsetText = Shell.setting(environment, "USAGE_DAY_OFFSET_SECONDS") ?? "32400"
        // `case "$offset" in ''|*[!0-9-]*)`
        if !offsetText.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }) {
            offsetText = "32400"
        }
        let timeout = Shell.digits(Shell.setting(environment, "USAGE_LOG_LOCK_TIMEOUT"), default: 120)

        guard Shell.makeDirectories(files.dir) else { return 73 }
        let lock: FileLock
        switch files.lock(timeoutSeconds: timeout, io: io) {
        case .success(let acquired): lock = acquired
        case .failure(let failure): return failure.status
        }
        defer { lock.release() }

        var sources: [String] = []
        if Shell.isNonEmpty(log) { sources.append(log) }
        if Shell.isDirectory(files.archiveDir) {
            sources += Shell.archivedSegments(in: files.archiveDir)
        }
        guard !sources.isEmpty else {
            io.out("usage history empty: \(log)")
            return 0
        }

        guard case .number(let offset)? = try? JSONParser.parse(offsetText) else {
            io.err("jq: Invalid JSON text passed to --argjson")
            return 2
        }

        var events: [JSONValue] = []
        for source in sources {
            guard let data = Shell.readData(source) else {
                io.err("jq: error: Could not open \(source)")
                return 2
            }
            let stream = JSONParser.parseStream(data)
            guard !stream.failed else {
                io.err("jq: error (at \(source)): not valid JSON")
                return 2
            }
            events += stream.values
        }

        let generatedAt = JSONValue.string(Shell.utcTimestamp(Int(now.timeIntervalSince1970)))
        let sourceFiles = JSONValue.array(sources.map(JSONValue.string))
        let report: JSONValue?
        switch kind {
        case .daily:
            report = daily(events, offset: offset, generatedAt: generatedAt, sourceFiles: sourceFiles)
        case .monthly(let period):
            report = monthly(events, period: period, offset: offset, generatedAt: generatedAt, sourceFiles: sourceFiles)
        }
        guard let report else {
            io.err("jq: error: usage events could not be summarized")
            return 5
        }
        io.out(report.prettyText)
        return 0
    }

    // MARK: - jq building blocks

    private enum Epoch {
        case seconds(Int)
        case dropped  // fromdateiso8601? produced nothing: the event is dropped
        case failure  // jq error
    }

    /// `(.timestamp // "") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?`
    private static func epoch(_ event: JSONValue) -> Epoch {
        guard let raw = event.jqValue(["timestamp"], or: .string("")),
              case .string(let stamp) = raw else { return .failure }
        guard let seconds = JQTime.fromISO8601(JQTime.droppingFractionalSeconds(stamp)) else { return .dropped }
        return .seconds(seconds)
    }

    /// `(epoch + $offset) | strftime(format)` with jq's gmtime.
    private static func localPeriod(_ seconds: Int, offset: JSONNumber, month: Bool) -> String? {
        let shifted = Double(seconds) + offset.doubleValue
        guard shifted.isFinite, abs(shifted) < 1e15 else { return nil }
        var time = time_t(shifted)
        var parts = tm()
        gmtime_r(&time, &parts)
        if month {
            return String(format: "%04d-%02d", parts.tm_year + 1900, parts.tm_mon + 1)
        }
        return String(format: "%04d-%02d-%02d", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday)
    }

    private static var zeroUsage: JSONObject {
        var usage = JSONObject()
        for field in usageFields { usage[field] = .int(0) }
        return usage
    }

    /// `($x.field // 0)` as a number, or nil where arithmetic would fail.
    private static func amount(_ usage: JSONValue, _ field: String) -> Double? {
        guard let raw = usage.jqValue([field], or: .int(0)), case .number(let number) = raw else { return nil }
        return number.doubleValue
    }

    /// `usage_delta($first; $last)` and `usage_add($a; $b)`.
    private static func combine(_ a: JSONValue, _ b: JSONValue, subtract: Bool) -> JSONObject? {
        var result = JSONObject()
        for field in usageFields {
            guard let x = amount(a, field), let y = amount(b, field) else { return nil }
            result[field] = .number(JSONNumber(computed: subtract ? y - x : x + y))
        }
        return result
    }

    private static func sum(_ deltas: [JSONValue]) -> JSONObject? {
        var total = zeroUsage
        for delta in deltas {
            guard let next = combine(.object(total), delta, subtract: false) else { return nil }
            total = next
        }
        return total
    }

    /// `session_summary` for the events of one session.
    private static func sessionSummary(_ group: [JSONValue]) -> JSONValue? {
        let events = jqStableSort(group, by: { $0.jqField("timestamp") ?? .null })
        guard let firstEvent = events.first, let lastEvent = events.last else { return nil }
        guard let first = firstEvent.jqValue(["tokenUsage", "total"], or: .object(zeroUsage)),
              let last = lastEvent.jqValue(["tokenUsage", "total"], or: .object(zeroUsage)),
              let delta = combine(first, last, subtract: true) else { return nil }

        var summary = JSONObject()
        summary["sourcePath"] = firstEvent.jqField("sourcePath") ?? .null
        summary["eventCount"] = .int(events.count)
        summary["firstTimestamp"] = firstEvent.jqField("timestamp") ?? .null
        summary["lastTimestamp"] = lastEvent.jqField("timestamp") ?? .null
        summary["firstObservedTotal"] = first
        summary["lastObservedTotal"] = last
        summary["observedDelta"] = .object(delta)
        return .object(summary)
    }

    private static func sessions(_ events: [JSONValue]) -> [JSONValue]? {
        var result: [JSONValue] = []
        for group in jqGroupBy(events, by: { $0.jqField("sourcePath") ?? .null }) {
            guard let summary = sessionSummary(group) else { return nil }
            result.append(summary)
        }
        return result
    }

    private static func isNull(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        if case .null = value { return true }
        return false
    }

    private static func isString(_ value: JSONValue?, _ expected: String) -> Bool {
        if case .string(let string)? = value { return string == expected }
        return false
    }

    /// `.tokenUsage.total.total_tokens != null`; nil when jq would error.
    private static func hasCodexTotal(_ event: JSONValue) -> Bool? {
        guard let total = event.jqPath(["tokenUsage", "total", "total_tokens"]) else { return nil }
        return !isNull(total)
    }

    // MARK: - Daily

    private static func daily(_ events: [JSONValue], offset: JSONNumber, generatedAt: JSONValue, sourceFiles: JSONValue) -> JSONValue? {
        var selected: [JSONValue] = []
        for event in events {
            guard let source = event.jqField("source") else { return nil }
            guard isString(source, "codex-session") else { continue }
            guard !isNull(event.jqField("timestamp")), !isNull(event.jqField("sourcePath")) else { continue }
            guard let hasTotal = hasCodexTotal(event) else { return nil }
            guard hasTotal else { continue }
            switch epoch(event) {
            case .failure: return nil
            case .dropped: continue
            case .seconds(let seconds):
                guard let day = localPeriod(seconds, offset: offset, month: false),
                      case .object(var object) = event else { return nil }
                object["localDay"] = .string(day)
                selected.append(.object(object))
            }
        }

        var days: [JSONValue] = []
        for group in jqGroupBy(selected, by: { $0.jqField("localDay") ?? .null }) {
            guard let sessions = sessions(group), let delta = sum(sessions.map { $0.jqField("observedDelta") ?? .null }) else {
                return nil
            }
            var day = JSONObject()
            day["day"] = group[0].jqField("localDay") ?? .null
            day["source"] = .string("codex-session")
            day["timezoneOffsetSeconds"] = .number(offset)
            day["eventCount"] = .int(group.count)
            day["sessionCount"] = .int(sessions.count)
            day["observedDelta"] = .object(delta)
            day["sessions"] = .array(sessions)
            days.append(.object(day))
        }

        var report = JSONObject()
        report["schema"] = .string("usage-daily-delta.v1")
        report["generatedAt"] = generatedAt
        report["sourceFiles"] = sourceFiles
        report["method"] = .string("group by local day and Codex session; observedDelta = last cumulative total - first cumulative total")
        report["caveat"] = .string("Conservative observed delta only. Tokens consumed before the first captured token_count event in a session-day are not inferred.")
        report["days"] = .array(days)
        return .object(report)
    }

    // MARK: - Monthly

    private static func monthly(_ events: [JSONValue], period: String, offset: JSONNumber, generatedAt: JSONValue, sourceFiles: JSONValue) -> JSONValue? {
        var inPeriod: [JSONValue] = []
        for event in events {
            guard let stamp = event.jqField("timestamp") else { return nil }
            guard !isNull(stamp) else { continue }
            switch epoch(event) {
            case .failure: return nil
            case .dropped: continue
            case .seconds(let seconds):
                guard let month = localPeriod(seconds, offset: offset, month: true),
                      case .object(var object) = event else { return nil }
                object["localMonth"] = .string(month)
                if month == period { inPeriod.append(.object(object)) }
            }
        }

        var codex: [JSONValue] = []
        var claude: [JSONValue] = []
        for event in inPeriod {
            let source = event.jqField("source") ?? .null
            if isString(source, "codex-session"), !isNull(event.jqField("sourcePath")) {
                guard let hasTotal = hasCodexTotal(event) else { return nil }
                if hasTotal { codex.append(event) }
            }
            if isString(source, "claude-statusline") { claude.append(event) }
        }

        guard let sessions = sessions(codex),
              let delta = sum(sessions.map { $0.jqField("observedDelta") ?? .null }) else { return nil }

        let sortedClaude = jqStableSort(claude, by: { $0.jqField("timestamp") ?? .null })
        func rateSnapshot(_ event: JSONValue?) -> JSONValue {
            // `.[0]? | {timestamp, rateLimits}`: an empty list still yields an
            // object of nulls, so the `// null` never applies.
            .object(JSONObject([
                "timestamp": event?.jqField("timestamp") ?? .null,
                "rateLimits": event?.jqField("rateLimits") ?? .null
            ]))
        }

        var report = JSONObject()
        report["schema"] = .string("usage-summary.v1")
        report["period"] = .string(period)
        report["timezone"] = .string("Asia/Seoul")
        report["timezoneOffsetSeconds"] = .number(offset)
        report["generatedAt"] = generatedAt
        report["sourceFiles"] = sourceFiles
        report["counts"] = .object(JSONObject([
            "totalEvents": .int(inPeriod.count),
            "claudeStatuslineEvents": .int(claude.count),
            "codexSessionEvents": .int(codex.count)
        ]))
        report["codexObservedDelta"] = .object(delta)
        report["claudeRateLimitSnapshots"] = .object(JSONObject([
            "first": rateSnapshot(sortedClaude.first),
            "last": rateSnapshot(sortedClaude.last)
        ]))
        report["notes"] = .array([
            .string("Codex observed deltas are last cumulative total minus first cumulative total per session within the month."),
            .string("Claude statusLine records are rate-limit snapshots, not directly comparable token counts."),
            .string("The raw JSONL log remains the source of truth; this summary is a reproducible index.")
        ])
        return .object(report)
    }
}
