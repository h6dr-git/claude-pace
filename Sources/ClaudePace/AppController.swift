import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let menu = NSMenu()
    private let primaryProviderMode = PrimaryUsageProviderMode.from(
        environment: ProcessInfo.processInfo.environment
    )

    // Sleep and wake are timed on systemUptime, which stops while the Mac
    // sleeps and never jumps with clock changes.
    /// Set at "will sleep": nothing should start a poll until the wake notice,
    /// since the timer can fire on the way back before it arrives.
    private var sleepingSinceUptime: TimeInterval?
    private var wokeAtUptime: TimeInterval?
    /// Bumped on every sleep and wake, so a wake poll scheduled before a newer
    /// sleep does not fire after it.
    private var wakeGeneration = 0
    /// Wi-Fi usually needs a few seconds after wake; a poll before that fails
    /// and would flash "⚠ 수집 중단" until the next regular poll.
    private static let wakePollDelay: TimeInterval = 8
    /// One more try when the first poll after waking did not come back ok.
    private static let wakeRetryDelay: TimeInterval = 30
    /// If a wake notice were ever missed, regular polls resume after this much
    /// awake time instead of staying held for good.
    private static let missedWakeGrace: TimeInterval = 60

    /// An open menu is not rebuilt under the pointer (a poll finishing would
    /// otherwise shift "지금 갱신"/"종료"); it is rebuilt when it closes.
    private var menuIsOpen = false
    private var menuNeedsRebuild = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly

        refresh()
        // Default run-loop mode on purpose: the timer pauses while the menu is
        // open, so items are not rebuilt under the pointer. menuWillOpen
        // redraws once on opening instead.
        let t = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = 5                       // let macOS coalesce wake-ups (energy)
        timer = t

        // A sleeping Mac runs no polls, so the first thing on screen after
        // waking is an old reading. Poll again as soon as the network is back.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        workspace.addObserver(
            self, selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    private func refresh() {
        if pollsAllowed() {
            if primaryProviderMode.shouldPollClaude {
                ClaudeUsagePoller.shared.refreshIfDue { [weak self] _ in
                    self?.render()
                }
            }
            if primaryProviderMode.shouldPollCodex {
                CodexUsagePoller.shared.refreshIfDue { [weak self] _ in
                    self?.render()
                }
            }
        }
        let sources = historySources
        if !sources.isEmpty {
            UsageHistoryStore.shared.ingestSessionsIfDue(sources: sources)
        }
        render()
    }

    /// Session logs the current provider mode may feed into the "기록" ledger.
    private var historySources: [SessionIngest.Source] {
        var sources: [SessionIngest.Source] = []
        if primaryProviderMode.shouldIngestClaudeHistory { sources.append(.claude) }
        if primaryProviderMode.shouldIngestCodexHistory { sources.append(.codex) }
        return sources
    }

    /// Regular polls wait while the Mac sleeps and for a moment after it
    /// wakes; the wake handler starts the first one itself.
    private func pollsAllowed() -> Bool {
        let uptime = ProcessInfo.processInfo.systemUptime
        if let since = sleepingSinceUptime {
            // Uptime does not advance during sleep, so this only grows while
            // the Mac is awake.
            if uptime - since < AppController.missedWakeGrace { return false }
            sleepingSinceUptime = nil
        }
        if let woke = wokeAtUptime, uptime - woke < AppController.wakePollDelay { return false }
        return true
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        sleepingSinceUptime = ProcessInfo.processInfo.systemUptime
        wakeGeneration += 1
    }

    @objc private func systemDidWake(_ notification: Notification) {
        sleepingSinceUptime = nil
        wokeAtUptime = ProcessInfo.processInfo.systemUptime
        wakeGeneration += 1
        let generation = wakeGeneration
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + AppController.wakePollDelay) { [weak self] in
            self?.pollAfterWake(retrying: true, generation: generation)
        }
    }

    /// The first poll after waking runs right away rather than on the 180s
    /// cadence — unless the reading is still newer than one regular interval
    /// (a short nap), when the cadence just carries on. If it does not come
    /// back ok — the network is often still returning — it is tried once more
    /// shortly after. Nothing scheduled here survives a later sleep or wake.
    private func pollAfterWake(retrying: Bool, generation: Int) {
        guard generation == wakeGeneration else { return }
        if primaryProviderMode.shouldPollClaude,
           !AppController.isWithinOnePoll(SnapshotStore.shared.load()?.capturedAt) {
            ClaudeUsagePoller.shared.refreshIfDue(force: true) { [weak self] _ in
                guard let self else { return }
                self.render()
                let status = ClaudeCollectorStateStore.shared.load()?.parsedStatus
                if retrying, status != .ok {
                    DispatchQueue.main.asyncAfter(deadline: .now() + AppController.wakeRetryDelay) { [weak self] in
                        self?.pollAfterWake(retrying: false, generation: generation)
                    }
                }
            }
        }
        if primaryProviderMode.shouldPollCodex,
           !AppController.isWithinOnePoll(CodexSnapshotStore.shared.load()?.capturedAt) {
            CodexUsagePoller.shared.refreshIfDue(force: true) { [weak self] _ in
                self?.render()
            }
        }
        render()
    }

    /// Captured less than one regular 180s poll ago.
    private static func isWithinOnePoll(_ capturedAt: Double?) -> Bool {
        guard let capturedAt, capturedAt.isFinite else { return false }
        let age = Date().timeIntervalSince1970 - capturedAt
        return age >= 0 && age < 180
    }

    /// Opening the menu builds it with current relative times and starts a
    /// poll if one is due, instead of waiting for the next timer tick.
    func menuWillOpen(_ menu: NSMenu) {
        // An open menu is itself proof the Mac is awake.
        sleepingSinceUptime = nil
        menuIsOpen = false
        refresh()
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if menuNeedsRebuild { render() }
    }

    private func render() {
        let codexSnapshot = CodexSnapshotStore.shared.load()
        let codexView = CodexUsageView(snapshot: codexSnapshot)
        let claudeSnapshot = SnapshotStore.shared.load()
        let claudeView = UsageView(snapshot: claudeSnapshot, polled: primaryProviderMode.shouldPollClaude)
        let collectorState = ClaudeCollectorStateStore.shared.load()

        let decision = PrimaryUsageSelector.decide(
            providerMode: primaryProviderMode,
            codexSnapshot: codexSnapshot,
            claudeSnapshot: claudeSnapshot,
            claudeCollectorState: collectorState
        )
        let claudeStale = SnapshotFreshness.of(claudeSnapshot).isStale
        let pollStatus = ClaudeUsagePoller.shared.status
        var entries: [MenuEntry]
        switch decision {
        case .claude:
            statusItem.button?.image = claudeView.menuBarImage(dimmed: claudeStale) ?? unavailableStatusImage(
                accessibilityDescription: "Claude 사용량 확인 불가"
            )
            statusItem.button?.toolTip = claudeView.toolTip + (claudeStale ? " · 갱신 멈춤" : "")
            entries = [.header("Claude")]
            // Say up front when the numbers below are old, before any of them.
            let freshness = FreshnessPresentation.entries(
                snapshot: claudeSnapshot, poll: pollStatus, numbersShown: true
            )
            if !freshness.isEmpty {
                entries.append(contentsOf: freshness)
                entries.append(.separator)
            }
            entries.append(contentsOf: claudeView.entries)
            entries.append(contentsOf: collectorWarningEntries(collectorState))
        case .claudeUnavailable(let reason):
            statusItem.button?.image = unavailableStatusImage(
                accessibilityDescription: "Claude 사용량 확인 불가"
            )
            statusItem.button?.toolTip = ClaudeUsageUnavailablePresentation.toolTip
            entries = claudeUnavailableEntries(reason: reason)
            // Same place as above: right under the "Claude" header.
            let freshness = FreshnessPresentation.entries(
                snapshot: claudeSnapshot, poll: pollStatus, numbersShown: false
            )
            if !freshness.isEmpty {
                entries.insert(contentsOf: freshness + [MenuEntry.separator], at: 1)
            }
        case .codex:
            statusItem.button?.image = codexView.menuBarImage ?? unavailableStatusImage(
                accessibilityDescription: "Codex 사용량 확인 불가"
            )
            statusItem.button?.toolTip = codexView.toolTip
            entries = codexView.entries
        case .grokUnavailable(let reason):
            statusItem.button?.image = unavailableStatusImage(
                accessibilityDescription: "Grok 사용량 확인 불가"
            )
            statusItem.button?.toolTip = GrokUsageUnavailablePresentation.toolTip
            entries = grokUnavailableEntries(reason: reason)
        }

        // Claude stays a secondary readout under the other providers; under the
        // Claude provider it is already the primary block above.
        if !primaryProviderMode.shouldPollClaude, shouldShowClaude(claudeSnapshot) {
            entries.append(.separator)
            entries.append(.header("Claude · 전환 보조"))
            entries.append(contentsOf: FreshnessPresentation.secondaryEntries(snapshot: claudeSnapshot))
            entries.append(contentsOf: claudeView.entries)
        }

        let history = UsageHistoryStore.shared.loadSummary()
        if history.hasRecords {
            entries.append(.separator)
            entries.append(.header("기록"))
            entries.append(.line("총 \(history.totalRecords)건 · Claude \(history.claudeRecords) · Codex \(history.codexRecords)"))
            if let last = history.lastTimestamp {
                entries.append(.line("마지막 기록 \(UsageHistoryTime.display(last))"))
            }
        }
        // The menu-bar ring and tooltip above update right away; the open menu
        // itself waits until it closes.
        if menuIsOpen {
            menuNeedsRebuild = true
        } else {
            menuNeedsRebuild = false
            rebuildMenu(entries)
        }
    }

    private func shouldShowClaude(_ snapshot: Snapshot?) -> Bool {
        guard let captured = snapshot?.capturedAt else { return false }
        return Date().timeIntervalSince1970 - captured <= 24 * 3600
    }

    private func unavailableStatusImage(accessibilityDescription: String) -> NSImage? {
        let image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: accessibilityDescription
        )
        image?.isTemplate = true
        return image
    }

    /// A displayed percentage plus a broken collector means the number is real
    /// but frozen — say so instead of letting it read as current.
    private func collectorWarningEntries(_ state: ClaudeCollectorState?) -> [MenuEntry] {
        guard let status = state?.parsedStatus, status.blocksCollection else { return [] }
        var entries: [MenuEntry] = [.separator, .header("⚠ 수집 중단")]
        entries.append(.line(status.menuDescription))
        if let detail = state?.detail, !detail.isEmpty {
            entries.append(.line(detail))
        }
        return entries
    }

    private func claudeUnavailableEntries(
        reason: ClaudeUsageUnavailableReason
    ) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .header("Claude"),
            .line("사용량: 공식 조회값 없음"),
            .line("한도를 추정하거나 화면에서 긁어오지 않음")
        ]

        switch reason {
        case .missingSnapshot:
            entries.append(.line("스냅샷 없음 · 아직 한 번도 수집되지 않음"))
        case .staleSnapshot:
            entries.append(.line("마지막 수집이 24시간을 넘어 표시에서 제외"))
        case .noUsableWindow:
            entries.append(.line("지금 쓸 수 있는 한도 값 없음 — 리셋이 지났거나 조회값에 퍼센트가 없음"))
        case .collectorBlocked(let status):
            entries.append(.line(status.menuDescription))
        }
        return entries
    }

    private func grokUnavailableEntries(
        reason: PrimaryUsageUnavailableReason
    ) -> [MenuEntry] {
        var entries: [MenuEntry] = [
            .header("Grok"),
            .line("사용량: 공식 기계판독 불가"),
            .line("주간 한도를 추정하거나 화면에서 긁어오지 않음")
        ]

        switch reason {
        case .providerTransition:
            entries.append(.line("Codex 스냅샷은 공급자 전환으로 기본 링에서 제외"))
        case .missingCodexSnapshot:
            entries.append(.line("Codex 스냅샷 없음 · 기본 링에서 제외"))
        case .staleCodexSnapshot:
            entries.append(.line("Codex 스냅샷이 10분을 넘어 기본 링에서 제외"))
        case .invalidCodexEntitlement:
            entries.append(.line("Codex 사용 권한을 확인할 수 없어 기본 링에서 제외"))
        }
        return entries
    }

    private func rebuildMenu(_ entries: [MenuEntry]) {
        menu.removeAllItems()
        for e in entries {
            switch e {
            case .separator:
                menu.addItem(.separator())
            case .header(let s):
                let it = NSMenuItem(title: s, action: nil, keyEquivalent: "")
                it.attributedTitle = NSAttributedString(
                    string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
                menu.addItem(it)
            case .line(let s):
                menu.addItem(NSMenuItem(title: s, action: nil, keyEquivalent: ""))
            case .bar(let u, let p, let t):
                let it = NSMenuItem(title: "  " + t, action: nil, keyEquivalent: "")
                it.image = Bar.image(used: u, pace: p)
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
        let r = NSMenuItem(title: "지금 갱신", action: #selector(manualRefresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        let q = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    @objc private func manualRefresh() {
        let sources = historySources
        if !sources.isEmpty {
            UsageHistoryStore.shared.ingestSessionsIfDue(sources: sources, force: true)
        }
        if primaryProviderMode.shouldPollClaude {
            ClaudeUsagePoller.shared.refreshIfDue(force: true) { [weak self] _ in
                self?.render()
            }
        }
        if primaryProviderMode.shouldPollCodex {
            CodexUsagePoller.shared.refreshIfDue(force: true) { [weak self] _ in
                self?.render()
            }
        }
        render()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
