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

final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    private let home: String
    private let summaryURL: URL
    private let queue = DispatchQueue(label: "ClaudePace.UsageHistory")
    private var lastIngest = Date.distantPast
    private var ingestRunning = false

    private init() {
        home = FileManager.default.homeDirectoryForCurrentUser.path
        summaryURL = URL(fileURLWithPath: AppPaths(home: home).historySummary)
    }

    func ingestSessionsIfDue(interval: TimeInterval = 60, force: Bool = false) {
        queue.async {
            guard !self.ingestRunning else { return }
            guard force || Date().timeIntervalSince(self.lastIngest) >= interval else { return }

            self.ingestRunning = true
            self.lastIngest = Date()

            // The menu bar must never fail just because history ingestion
            // failed, so the status is not checked.
            _ = SessionIngest.run(
                .codex,
                home: self.home,
                environment: ["CODEX_USAGE_MTIME_DAYS": "2"],
                io: .silent
            )

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
        let result = UsageHistorySummaryBuilder.build(
            AppPaths(home: home).usageLog,
            environment: [:],
            io: .silent
        )
        // Keep the last good summary when log summarization fails.
        guard result.status == 0, let summary = result.summary else { return }
        let data = Data((summary.prettyText + "\n").utf8)
        guard (try? JSONDecoder().decode(UsageHistorySummaryDocument.self, from: data)) != nil else { return }
        try? data.write(to: summaryURL, options: .atomic)
    }
}
