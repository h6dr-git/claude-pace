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

    private let appDir: URL
    private let summaryURL: URL
    private let codexIngestURL: URL
    private let summaryScriptURL: URL
    private let queue = DispatchQueue(label: "ClaudePace.UsageHistory")
    private var lastIngest = Date.distantPast
    private var ingestRunning = false

    private init() {
        appDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudePace")
        summaryURL = appDir.appendingPathComponent("usage-history-summary.json")
        codexIngestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/claude-pace/tools/ingest-codex-sessions.sh")
        summaryScriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/claude-pace/tools/usage-history-summary.sh")
    }

    func ingestSessionsIfDue(interval: TimeInterval = 60, force: Bool = false) {
        queue.async {
            guard !self.ingestRunning else { return }
            guard force || Date().timeIntervalSince(self.lastIngest) >= interval else { return }

            self.ingestRunning = true
            self.lastIngest = Date()

            if FileManager.default.isExecutableFile(atPath: self.codexIngestURL.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [self.codexIngestURL.path]
                process.environment = [
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    "CODEX_USAGE_MTIME_DAYS": "2"
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    // The menu bar must never fail just because history ingestion failed.
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
        guard FileManager.default.isExecutableFile(atPath: summaryScriptURL.path) else { return }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [summaryScriptURL.path]
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  (try? JSONDecoder().decode(UsageHistorySummaryDocument.self, from: data)) != nil else {
                return
            }
            try data.write(to: summaryURL, options: .atomic)
        } catch {
            // Keep the last good summary when log summarization fails.
        }
    }
}
