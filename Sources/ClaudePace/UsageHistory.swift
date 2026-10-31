import Foundation

private struct UsageHistorySummaryDocument: Decodable {
    struct SourceCount: Decodable {
        let source: String
        let count: Int
    }

    let records: Int
    let bySource: [SourceCount]
    let lastTimestamp: String?
}

struct UsageHistorySummary {
    let totalRecords: Int
    let claudeRecords: Int
    let codexRecords: Int
    let lastTimestamp: String?

    var hasRecords: Bool { totalRecords > 0 }
}

/// Ledger timestamps are ISO 8601 in UTC ("2026-08-17T11:56:40.212Z"); the
/// menu shows them in local time like the other lines ("8/17 20:56").
/// Anything that does not parse is shown as written.
enum UsageHistoryTime {
    static func display(_ timestamp: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: timestamp)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: timestamp)
        }
        guard let date else { return timestamp }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}

final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    private let home: String
    private let summaryURL: URL
    private let queue = DispatchQueue(label: "ClaudePace.UsageHistory")
    private var lastIngest = Date.distantPast
    private var ingestRunning = false
    /// What the summary file on disk was built from (see rebuildSummary).
    private var summaryInputs: String?

    private init() {
        home = FileManager.default.homeDirectoryForCurrentUser.path
        summaryURL = URL(fileURLWithPath: AppPaths(home: home).historySummary)
    }

    /// Appends new session-log usage from `sources` to the ledger (at most
    /// once per `interval`) and refreshes the summary the menu reads.
    func ingestSessionsIfDue(
        sources: [SessionIngest.Source],
        interval: TimeInterval = 60,
        force: Bool = false
    ) {
        queue.async {
            guard !self.ingestRunning else { return }
            guard force || Date().timeIntervalSince(self.lastIngest) >= interval else { return }

            self.ingestRunning = true
            self.lastIngest = Date()

            // The menu bar must never fail just because history ingestion
            // failed, so the statuses are not checked (beyond the backfill
            // marker below).
            for source in sources {
                switch source {
                case .codex:
                    _ = SessionIngest.run(
                        .codex,
                        home: self.home,
                        environment: ["CODEX_USAGE_MTIME_DAYS": "2"],
                        io: .silent
                    )
                case .claude:
                    // Each minute only files touched in the last two days are
                    // looked at. The very first Claude pass reaches back 30 days
                    // — Claude Code deletes its own session logs after about a
                    // month — and a marker keeps later passes at two days.
                    let marker = AppPaths(home: self.home).appDir + "/.claude-session-backfill-done"
                    let backfilled = Shell.exists(marker)
                    let status = SessionIngest.run(
                        .claude,
                        home: self.home,
                        environment: ["CLAUDE_USAGE_MTIME_DAYS": backfilled ? "2" : "30"],
                        io: .silent
                    )
                    if !backfilled, status == 0 {
                        Shell.touch(marker)
                    }
                }
            }

            self.rebuildSummary()

            self.ingestRunning = false
        }
    }

    func loadSummary() -> UsageHistorySummary {
        guard let data = try? Data(contentsOf: summaryURL),
              let document = try? JSONDecoder().decode(UsageHistorySummaryDocument.self, from: data) else {
            return UsageHistorySummary(totalRecords: 0, claudeRecords: 0, codexRecords: 0, lastTimestamp: nil)
        }

        var claude = 0
        var codex = 0
        for entry in document.bySource {
            if entry.source == "claude-statusline" || entry.source == "claude-session" {
                claude += entry.count
            }
            if entry.source == "codex-session" {
                codex += entry.count
            }
        }
        return UsageHistorySummary(
            totalRecords: document.records,
            claudeRecords: claude,
            codexRecords: codex,
            lastTimestamp: document.lastTimestamp
        )
    }

    private func rebuildSummary() {
        let log = AppPaths(home: home).usageLog
        // Most minutes nothing was appended. Re-reading the active ledger (up
        // to 50 MB, under the usage-log lock) would only rewrite the same
        // summary, so skip it while the inputs look exactly as they did when
        // the current summary file was written. Taken before the build: a
        // change that lands during the build is seen next time.
        let inputs = UsageHistorySummaryBuilder.inputFingerprint(log)
        if let inputs, inputs == summaryInputs, FileManager.default.fileExists(atPath: summaryURL.path) {
            return
        }

        let result = UsageHistorySummaryBuilder.build(log, environment: [:], io: .silent)
        // Keep the last good summary when log summarization fails.
        guard result.status == 0, let summary = result.summary else { return }
        let data = Data((summary.prettyText + "\n").utf8)
        guard (try? JSONDecoder().decode(UsageHistorySummaryDocument.self, from: data)) != nil else { return }
        do {
            try data.write(to: summaryURL, options: .atomic)
            summaryInputs = inputs
        } catch {
            summaryInputs = nil
        }
    }
}
