import Foundation

/// `ClaudePace menu-preview`: the menu the app would show right now, as plain
/// text, for the HOME and AI_USAGE_PRIMARY_PROVIDER it runs under. It reads
/// the files the app reads and nothing else — no app, no poll, no writes.
enum MenuPreview {
    static func run(home: String, environment: [String: String], io: CommandIO) -> Int32 {
        let paths = AppPaths(home: home)
        let now = Date()
        // Every file by path under `home`: the app's own stores sit on the
        // login home, which ignores HOME.
        let claudeSnapshot = SnapshotStore(url: URL(fileURLWithPath: paths.snapshot)).load(at: now)
        let codexSnapshot = Shell.readData(paths.codexSnapshot)
            .flatMap { try? JSONDecoder().decode(CodexUsageSnapshot.self, from: $0) }
        let codexView = CodexUsageView(snapshot: codexSnapshot)
        let collectorState = ClaudeCollectorStateStore(url: URL(fileURLWithPath: paths.collectorState)).load()
        // No poller runs in this process: nothing is in flight, and the last
        // attempt is the one the collector recorded.
        let lastAttempt = collectorState?.capturedAt
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }

        let composition = MenuComposition.compose(
            providerMode: PrimaryUsageProviderMode.from(environment: environment),
            claudeSnapshot: claudeSnapshot,
            codexSnapshot: codexSnapshot,
            // Worked out only in Codex mode, as in the app.
            codexEntries: codexView.entries,
            codexToolTip: codexView.toolTip,
            collectorState: collectorState,
            pollStatus: ClaudePollStatus(runningFor: nil, lastAttempt: lastAttempt),
            history: MenuHistory(historySummary(at: paths.historySummary)),
            ringSetting: ClaudePaceSettingsStore(home: home).loadRing(),
            now: now
        )
        io.out(composition.previewText)
        return 0
    }

    /// usage-history-summary.json read the way `UsageHistoryStore.loadSummary`
    /// reads the app's own copy (that store is fixed to the login home).
    private static func historySummary(at path: String) -> UsageHistorySummary {
        struct Document: Decodable {
            struct SourceCount: Decodable {
                let source: String
                let count: Int
            }
            let records: Int
            let bySource: [SourceCount]
            let lastTimestamp: String?
        }
        guard let data = Shell.readData(path),
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return UsageHistorySummary(totalRecords: 0, claudeRecords: 0, codexRecords: 0, lastTimestamp: nil)
        }
        let claude = document.bySource
            .filter { $0.source == "claude-statusline" || $0.source == "claude-session" }
            .reduce(0) { $0 + $1.count }
        let codex = document.bySource
            .filter { $0.source == "codex-session" }
            .reduce(0) { $0 + $1.count }
        return UsageHistorySummary(
            totalRecords: document.records,
            claudeRecords: claude,
            codexRecords: codex,
            lastTimestamp: document.lastTimestamp
        )
    }
}

extension MenuHistory {
    /// The ledger summary as the "기록" block shows it.
    init(_ summary: UsageHistorySummary) {
        self.init(
            totalRecords: summary.totalRecords,
            claudeRecords: summary.claudeRecords,
            codexRecords: summary.codexRecords,
            lastRecord: summary.lastTimestamp.map(UsageHistoryTime.display)
        )
    }
}
