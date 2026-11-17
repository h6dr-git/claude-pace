import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let menu = NSMenu()
    private let primaryProviderMode = PrimaryUsageProviderMode.from(
        environment: ProcessInfo.processInfo.environment
    )
    /// settings.json: which Claude window the menu-bar ring shows.
    private let settings = ClaudePaceSettingsStore(
        home: FileManager.default.homeDirectoryForCurrentUser.path
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

    /// Reads everything the menu shows, lets MenuComposition decide what it
    /// says, and applies that: ring image, tooltip, menu items.
    private func render() {
        let codexSnapshot = CodexSnapshotStore.shared.load()
        let codexView = CodexUsageView(snapshot: codexSnapshot)
        let composition = MenuComposition.compose(
            providerMode: primaryProviderMode,
            claudeSnapshot: SnapshotStore.shared.load(),
            codexSnapshot: codexSnapshot,
            codexEntries: codexView.entries,
            codexToolTip: codexView.toolTip,
            collectorState: ClaudeCollectorStateStore.shared.load(),
            pollStatus: ClaudeUsagePoller.shared.status,
            history: MenuHistory(UsageHistoryStore.shared.loadSummary()),
            ringSetting: settings.loadRing(),
            now: Date()
        )
        statusItem.button?.image = statusImage(composition.image, codexView: codexView)
        statusItem.button?.toolTip = composition.toolTip
        // The menu-bar ring and tooltip above update right away; the open menu
        // itself waits until it closes.
        if menuIsOpen {
            menuNeedsRebuild = true
        } else {
            menuNeedsRebuild = false
            rebuildMenu(composition)
        }
    }

    /// Monochrome and geometry-only either way (Bar.ringImage); a reading
    /// that stopped updating is drawn faded.
    private func statusImage(_ image: MenuBarImage, codexView: CodexUsageView) -> NSImage? {
        switch image {
        case .claudeRing(let ring):
            return Bar.ringImage(used: ring.used / 100, pace: ring.pace, dimmed: ring.dimmed)
        case .codexRing:
            return codexView.menuBarImage ?? unavailableStatusImage(
                accessibilityDescription: "Codex 사용량 확인 불가"
            )
        case .unavailable(let description):
            return unavailableStatusImage(accessibilityDescription: description)
        }
    }

    private func unavailableStatusImage(accessibilityDescription: String) -> NSImage? {
        let image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: accessibilityDescription
        )
        image?.isTemplate = true
        return image
    }

    private func rebuildMenu(_ composition: MenuComposition) {
        menu.removeAllItems()
        for e in composition.entries {
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
        if !composition.ringOptions.isEmpty {
            menu.addItem(ringMenuItem(composition.ringOptions))
        }
        let r = NSMenuItem(title: "지금 갱신", action: #selector(manualRefresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        let q = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    /// "메뉴바 링" and its choices. The submenu gets no delegate: the main
    /// menu's menuWillOpen/menuDidClose drive refreshes, and opening the
    /// submenu must not count as the menu opening again.
    private func ringMenuItem(_ options: [RingOption]) -> NSMenuItem {
        let submenu = NSMenu(title: "메뉴바 링")
        submenu.autoenablesItems = false
        for option in options {
            let item = NSMenuItem(title: option.title, action: #selector(chooseRing(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = option.isEnabled
            item.state = option.isSelected ? .on : .off
            item.representedObject = option.setting.rawValue
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "메뉴바 링", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func chooseRing(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let ring = RingSetting(rawValue: raw) else { return }
        // settings.json is written only when the choice actually changes.
        if ring != settings.loadRing() {
            settings.saveRing(ring)
        }
        // The ring and tooltip change now; an open menu is rebuilt once it closes.
        render()
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
