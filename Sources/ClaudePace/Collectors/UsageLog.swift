import Foundation

/// File locations, built from a HOME string exactly the way the scripts built
/// them from "$HOME": paths are hashed into offsets and event ids, so their
/// spelling is part of the data.
struct AppPaths {
    let home: String

    var appDir: String { home + "/Library/Application Support/ClaudePace" }
    var snapshot: String { appDir + "/snapshot.json" }
    var collectorState: String { appDir + "/claude-collector-state.json" }
    var usageRaw: String { appDir + "/.usage-raw.txt" }
    var codexSnapshot: String { appDir + "/codex-snapshot.json" }
    var usageLog: String { appDir + "/usage-log.jsonl" }
    var historySummary: String { appDir + "/usage-history-summary.json" }
    var debugDir: String { appDir + "/.debug" }
    var scratch: String { home + "/.claudepace/cwd" }
}

/// The files that sit next to a usage ledger.
struct UsageLogFiles {
    let log: String

    var dir: String { Shell.dirname(log) }
    var archiveDir: String { dir + "/archive" }
    var periodMarker: String { dir + "/.usage-log-active-period" }
    var lockPath: String { dir + "/.usage-log.lock" }

    /// `exec 9>>"$lock_path"; lockf -s -t "$timeout" 9`, with the scripts'
    /// exit codes (73 cannot open, 75 timed out).
    func lock(timeoutSeconds: Int, io: CommandIO) -> Result<FileLock, CommandFailure> {
        switch FileLock.acquire(lockPath, timeoutSeconds: timeoutSeconds) {
        case .success(let lock):
            return .success(lock)
        case .failure(.cannotOpen):
            return .failure(CommandFailure(status: 73))
        case .failure(.timedOut):
            io.err("timed out waiting for usage-log lock: \(lockPath)")
            return .failure(CommandFailure(status: 75))
        }
    }

    static func summaryPath(forSegment segment: String) -> String {
        Shell.removingJSONLSuffix(segment) + ".summary.json"
    }
}

struct CommandFailure: Error {
    let status: Int32
}

private func newlineCount(_ data: Data) -> Int {
    data.withUnsafeBytes { buffer -> Int in
        var count = 0
        for byte in buffer where byte == 0x0A { count += 1 }
        return count
    }
}

// MARK: - Segment summary

enum UsageLogSegment {
    /// tools/usage-log-segment-summary.sh: the small index stored beside one
    /// immutable segment. The segment is parsed once and never rewritten, and
    /// it is valid only if it holds exactly one JSON object per line.
    static func summary(of path: String, label: String, io: CommandIO, now: Date = Date()) -> JSONObject? {
        guard !path.isEmpty, Shell.isRegularFile(path) else {
            io.err("usage segment missing: \(path)")
            return nil
        }
        guard let data = Shell.readData(path) else {
            io.err("invalid segment byte count")
            return nil
        }
        let bytes = data.count
        let lines = newlineCount(data)

        // Folded one event at a time (like jq's `reduce inputs`), so a 50 MB
        // ledger never has to sit in memory as a parsed tree.
        var tally = Tally()
        var valid = true
        let parsed = JSONParser.forEachValue(in: data) { value in
            if valid && !tally.add(value) { valid = false }
        }
        guard parsed, valid else {
            io.err("usage segment is not valid JSON: \(path)")
            return nil
        }

        var summary = JSONObject()
        summary["schema"] = JSONValue.string("usage-segment-summary.v1")
        summary["sourceFile"] = JSONValue.string(label)
        summary["generatedAt"] = JSONValue.string(Shell.utcTimestamp(Int(now.timeIntervalSince1970)))
        summary["bytes"] = JSONValue.int(bytes)
        summary["lines"] = JSONValue.int(lines)
        summary["records"] = JSONValue.int(tally.records)
        summary["lastTimestamp"] = tally.lastTimestamp.map(JSONValue.string) ?? JSONValue.null
        summary["latestCodexTimestamp"] = tally.latestCodexTimestamp.map(JSONValue.string) ?? JSONValue.null
        summary["latestCodexTotal"] = tally.latestCodexTotal ?? JSONValue.null
        summary["latestCodexLast"] = tally.latestCodexLast ?? JSONValue.null
        var bySource: [JSONValue] = []
        for source in Shell.sortedBytewise(Array(tally.sourceCounts.keys)) {
            bySource.append(JSONValue.object(JSONObject([
                "source": JSONValue.string(source),
                "count": JSONValue.int(tally.sourceCounts[source] ?? 0)
            ])))
        }
        summary["bySource"] = JSONValue.array(bySource)

        guard tally.records == lines else {
            io.err("usage segment is not one JSON object per line: lines=\(lines) records=\(tally.records) path=\(path)")
            return nil
        }
        return summary
    }

    /// The jq `reduce` over the events of one segment.
    private struct Tally {
        var records = 0
        var sourceCounts: [String: Int] = [:]
        var lastTimestamp: String?
        var latestCodexTimestamp: String?
        var latestCodexTotal: JSONValue?
        var latestCodexLast: JSONValue?

        /// False where jq would stop with an error: a non-object line, or a
        /// Codex record whose tokenUsage cannot be indexed.
        mutating func add(_ value: JSONValue) -> Bool {
            guard case .object(let event) = value else { return false }
            records += 1

            var source = "unknown"
            if let raw = event["source"], raw.isTruthy {
                source = raw.jqToString
            }
            sourceCounts[source, default: 0] += 1

            var timestamp: String?
            if case .string(let stamp)? = event["timestamp"] {
                timestamp = stamp
            }
            if let stamp = timestamp {
                if lastTimestamp == nil || JSONValue.compareBytes(stamp, lastTimestamp ?? "") > 0 {
                    lastTimestamp = stamp
                }
            }

            guard case .string("codex-session")? = event["source"] else { return true }
            guard let total = value.jqPath(["tokenUsage", "total", "total_tokens"]) else { return false }
            if case .null = total { return true }
            guard let stamp = timestamp else { return true }
            if latestCodexTimestamp == nil || JSONValue.compareBytes(stamp, latestCodexTimestamp ?? "") >= 0 {
                latestCodexTimestamp = stamp
                latestCodexTotal = total
                latestCodexLast = value.jqValue(["tokenUsage", "last", "total_tokens"], or: JSONValue.null)
            }
            return true
        }
    }
}

// MARK: - Rotation

enum UsageLogRotation {
    /// tools/usage-log-rotate.sh: once the active ledger passes the size limit
    /// or the month (Asia/Seoul) changes, move the whole file into archive/ as
    /// one immutable segment with its index. Source JSONL is only ever moved —
    /// never split, copied, compressed or deleted — and a ledger that fails
    /// validation is not rotated at all.
    static func rotate(_ log: String, environment: [String: String], io: CommandIO, now: Date = Date()) -> Int32 {
        let files = UsageLogFiles(log: log)
        let maxSetting = Shell.setting(environment, "USAGE_LOG_MAX_BYTES") ?? "52428800"
        let currentPeriod = Shell.setting(environment, "USAGE_LOG_CURRENT_PERIOD") ?? Shell.seoulMonth(now)
        let timeoutSetting = Shell.setting(environment, "USAGE_LOG_LOCK_TIMEOUT") ?? "120"

        guard Shell.isDigits(maxSetting) else {
            io.err("invalid USAGE_LOG_MAX_BYTES: \(maxSetting)")
            return 64
        }
        guard isPeriod(currentPeriod) else {
            io.err("invalid usage-log period: \(currentPeriod)")
            return 64
        }
        guard Shell.isDigits(timeoutSetting) else {
            io.err("invalid USAGE_LOG_LOCK_TIMEOUT: \(timeoutSetting)")
            return 64
        }
        let maxBytes = Int(maxSetting) ?? Int.max

        guard Shell.makeDirectories(files.dir), Shell.makeDirectories(files.archiveDir) else {
            io.err("cannot create usage-log directories under: \(files.dir)")
            return 73
        }

        let lock: FileLock
        switch files.lock(timeoutSeconds: Int(timeoutSetting) ?? Int.max, io: io) {
        case .success(let acquired): lock = acquired
        case .failure(let failure): return failure.status
        }
        defer { lock.release() }

        guard Shell.touch(log) else {
            io.err("cannot create active usage log: \(log)")
            return 73
        }

        // Repair only crash-interrupted, missing indexes. Existing indexes are
        // immutable and are checked by the lightweight reader before use.
        for segment in Shell.archivedSegments(in: files.archiveDir) {
            let summaryPath = UsageLogFiles.summaryPath(forSegment: segment)
            guard !Shell.isRegularFile(summaryPath) else { continue }
            guard writeSummary(of: segment, to: summaryPath, label: "archive/" + Shell.basename(segment), io: io, now: now) else {
                io.err("cannot index archived usage segment: \(segment)")
                return 65
            }
            io.out("indexed archive=\(segment) summary=\(summaryPath)")
        }

        var activePeriod = Shell.readText(files.periodMarker) ?? ""
        if !isPeriod(activePeriod) { activePeriod = currentPeriod }

        guard let activeBytes = Shell.fileSize(log) else {
            io.err("cannot measure active usage log")
            return 74
        }

        var reason = ""
        if activePeriod != currentPeriod && activeBytes > 0 {
            reason = "month"
        }
        if activeBytes > maxBytes {
            reason = reason.isEmpty ? "threshold" : reason + "+threshold"
        }

        if reason.isEmpty {
            Shell.overwrite(currentPeriod + "\n", to: files.periodMarker)
            io.out("rotation_not_needed bytes=\(activeBytes) maxBytes=\(maxSetting) period=\(currentPeriod)")
            return 0
        }

        var number = 1
        var archivePath = segmentPath(files, period: activePeriod, number: number)
        while Shell.exists(archivePath) {
            number += 1
            archivePath = segmentPath(files, period: activePeriod, number: number)
        }

        let archiveSummary = UsageLogFiles.summaryPath(forSegment: archivePath)
        guard let summary = UsageLogSegment.summary(of: log, label: "archive/" + Shell.basename(archivePath), io: io, now: now) else {
            io.err("rotation refused because active usage log failed validation")
            return 65
        }
        let temporary = archiveSummary + ".tmp.\(getpid())"
        guard Shell.overwrite(JSONValue.object(summary).compactText + "\n", to: temporary) else { return 74 }

        // The only operation that relocates source data: the whole active file
        // becomes one archive inode, with no line-level rewrite.
        guard Shell.move(log, to: archivePath) else { return 74 }
        guard Shell.touch(log) else { return 74 }
        guard Shell.move(temporary, to: archiveSummary) else { return 74 }
        Shell.overwrite(currentPeriod + "\n", to: files.periodMarker)

        let expectedBytes = summary["bytes"].flatMap { value -> Int? in
            if case .number(let number) = value { return number.intValue }
            return nil
        } ?? -1
        let expectedLines = summary["lines"].flatMap { value -> Int? in
            if case .number(let number) = value { return number.intValue }
            return nil
        } ?? -1
        let records = summary["records"].map { $0.compactText } ?? "0"
        let archivedBytes = Shell.fileSize(archivePath) ?? -1
        let archivedLines = Shell.readData(archivePath).map(newlineCount) ?? -1
        guard archivedBytes == expectedBytes, archivedLines == expectedLines else {
            io.err("post-move verification failed: expected bytes=\(expectedBytes) lines=\(expectedLines) got bytes=\(archivedBytes) lines=\(archivedLines)")
            return 74
        }

        io.out("rotated reason=\(reason) archive=\(archivePath) bytes=\(archivedBytes) lines=\(archivedLines) records=\(records)")
        return 0
    }

    /// `case "$p" in ????-??)`: seven characters with a dash in the middle.
    private static func isPeriod(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.count == 7 && scalars[4] == "-"
    }

    private static func segmentPath(_ files: UsageLogFiles, period: String, number: Int) -> String {
        files.archiveDir + "/usage-log-\(period)-" + String(format: "%03ld", number) + ".jsonl"
    }

    private static func writeSummary(of segment: String, to summaryPath: String, label: String, io: CommandIO, now: Date) -> Bool {
        guard let summary = UsageLogSegment.summary(of: segment, label: label, io: io, now: now) else { return false }
        let temporary = summaryPath + ".tmp.\(getpid())"
        guard Shell.overwrite(JSONValue.object(summary).compactText + "\n", to: temporary) else { return false }
        return Shell.move(temporary, to: summaryPath)
    }
}

// MARK: - Lightweight history summary

enum UsageHistorySummaryBuilder {
    /// tools/usage-history-summary.sh: the app's compact summary. Archived
    /// JSONL is never re-read; their immutable indexes are merged with one
    /// fresh summary of the bounded active log.
    static func build(_ log: String, environment: [String: String], io: CommandIO, now: Date = Date()) -> (status: Int32, summary: JSONValue?) {
        let files = UsageLogFiles(log: log)
        let timeout = Shell.digits(Shell.setting(environment, "USAGE_LOG_LOCK_TIMEOUT"), default: 120)

        guard Shell.makeDirectories(files.dir), Shell.touch(log) else { return (73, nil) }

        let lock: FileLock
        switch files.lock(timeoutSeconds: timeout, io: io) {
        case .success(let acquired): lock = acquired
        case .failure(let failure): return (failure.status, nil)
        }

        guard let active = UsageLogSegment.summary(of: log, label: "usage-log.jsonl", io: io, now: now) else {
            lock.release()
            return (65, nil)
        }
        var documents: [JSONValue] = [.object(active)]

        if Shell.isDirectory(files.archiveDir) {
            for segment in Shell.archivedSegments(in: files.archiveDir) {
                let summaryPath = UsageLogFiles.summaryPath(forSegment: segment)
                guard Shell.isRegularFile(summaryPath) else {
                    io.err("archived usage segment is missing its precomputed summary: \(segment)")
                    lock.release()
                    return (65, nil)
                }
                guard let expectedBytes = Shell.fileSize(segment),
                      let data = Shell.readData(summaryPath) else {
                    lock.release()
                    return (65, nil)
                }
                let stream = JSONParser.parseStream(data)
                guard !stream.failed else {
                    lock.release()
                    return (65, nil)
                }
                // `[ "$indexed_bytes" -ne "$expected_bytes" ]` only fires for a
                // single document whose `.bytes // -1` reads as an integer.
                if stream.values.count == 1,
                   let indexed = Int(stream.values[0].jqValue(["bytes"], or: .int(-1)).jqRawText),
                   indexed != expectedBytes {
                    io.err("archived usage segment changed after indexing: \(segment)")
                    lock.release()
                    return (65, nil)
                }
                documents.append(contentsOf: stream.values)
            }
        }

        // The active file and the archive set could not change until here.
        lock.release()

        guard let merged = merge(documents) else { return (5, nil) }
        return (0, merged)
    }

    /// The `jq -s` merge of the per-segment summaries.
    static func merge(_ summaries: [JSONValue]) -> JSONValue? {
        var objects: [JSONObject] = []
        for summary in summaries {
            guard case .object(let object) = summary else { return nil }
            objects.append(object)
        }

        // records: (map(.records) | add // 0)
        var records: Double?
        for object in objects {
            switch object["records"] ?? .null {
            case .null: continue
            case .number(let number): records = (records ?? 0) + number.doubleValue
            default: return nil
            }
        }

        // bySource: (map(.bySource[]?) | group_by(.source) | map({source, count: sum}))
        var entries: [JSONValue] = []
        for object in objects {
            if case .array(let items)? = object["bySource"] { entries.append(contentsOf: items) }
        }
        for entry in entries {
            guard case .object = entry else { return nil }
        }
        var bySource: [JSONValue] = []
        for group in jqGroupBy(entries, by: { $0.jqField("source") ?? JSONValue.null }) {
            var count: Double?
            for entry in group {
                switch entry.jqField("count") ?? JSONValue.null {
                case .null: continue
                case .number(let number): count = (count ?? 0) + number.doubleValue
                default: return nil
                }
            }
            var countValue = JSONValue.null
            if let count { countValue = JSONValue.number(JSONNumber(computed: count)) }
            bySource.append(JSONValue.object(JSONObject([
                "source": group[0].jqField("source") ?? JSONValue.null,
                "count": countValue
            ])))
        }

        // lastTimestamp: max of the non-null lastTimestamps
        var stamps: [JSONValue] = []
        for object in objects {
            if let stamp = object["lastTimestamp"], !isNull(stamp) { stamps.append(stamp) }
        }
        let lastTimestamp = jqMaxBy(stamps, by: { $0 }) ?? JSONValue.null

        // the latest Codex cumulative total, by timestamp
        var candidates: [JSONValue] = []
        for object in objects {
            guard let stamp = object["latestCodexTimestamp"], !isNull(stamp),
                  let total = object["latestCodexTotal"], !isNull(total) else { continue }
            candidates.append(JSONValue.object(JSONObject([
                "timestamp": stamp,
                "total": total,
                "last": object["latestCodexLast"] ?? JSONValue.null
            ])))
        }
        let latest = jqMaxBy(candidates, by: { $0.jqField("timestamp") ?? JSONValue.null })

        var result = JSONObject()
        if let records {
            result["records"] = JSONValue.number(JSONNumber(computed: records))
        } else {
            result["records"] = JSONValue.int(0)
        }
        result["bySource"] = JSONValue.array(bySource)
        result["lastTimestamp"] = lastTimestamp
        result["latestCodexTotal"] = latest?.jqValue(["total"], or: JSONValue.null) ?? JSONValue.null
        result["latestCodexLast"] = latest?.jqValue(["last"], or: JSONValue.null) ?? JSONValue.null
        return JSONValue.object(result)
    }

    private static func isNull(_ value: JSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }
}
