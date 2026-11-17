import Foundation

// What the menu bar shows, as one pure function of what was read: no AppKit,
// no singletons, no clock of its own. AppController applies the result (ring
// image, tooltip, menu items); `ClaudePace menu-preview` prints it.

/// The "기록" block's numbers, as the menu shows them.
struct MenuHistory: Equatable {
    let totalRecords: Int
    let claudeRecords: Int
    let codexRecords: Int
    /// The newest record's time as the menu shows it ("8/17 20:56").
    let lastRecord: String?

    static let empty = MenuHistory(totalRecords: 0, claudeRecords: 0, codexRecords: 0, lastRecord: nil)

    var hasRecords: Bool { totalRecords > 0 }
}

/// The Claude window drawn as the menu-bar ring.
struct ClaudeRing: Equatable {
    let window: RingWindow
    /// 0...100.
    let used: Double
    /// Elapsed fraction of the window (0...1): the pace tick.
    let pace: Double
    /// The reading stopped updating: the ring is drawn faded.
    let dimmed: Bool
}

/// What the status item draws.
enum MenuBarImage: Equatable {
    case claudeRing(ClaudeRing)
    /// The Codex view's own ring (`CodexUsageSnapshot.menuBarWindow`).
    case codexRing(used: Double)
    /// The question mark: nothing trustworthy to draw.
    case unavailable(accessibilityDescription: String)
}

struct MenuComposition: Equatable {
    /// Dropdown rows, top to bottom. The app adds the fixed items after them
    /// ("메뉴바 링" when `ringOptions` is not empty, "지금 갱신", "종료").
    let entries: [MenuEntry]
    let image: MenuBarImage
    let toolTip: String
    /// The "메뉴바 링" submenu; empty (no submenu) unless the ring is Claude's.
    let ringOptions: [RingOption]

    /// The Claude window the ring shows; nil when it shows Codex or "?".
    var ring: ClaudeRing? {
        if case .claudeRing(let ring) = image { return ring }
        return nil
    }

    /// The whole menu bar state for one moment. Snapshots may be passed as
    /// stored: windows whose reset has passed by `now` are read as ended.
    /// Codex's rows and tooltip come in ready-made (`CodexUsageView`), and
    /// are only worked out when Codex is what the menu shows: a leftover
    /// codex-snapshot.json is never even formatted under another provider.
    static func compose(
        providerMode: PrimaryUsageProviderMode,
        claudeSnapshot storedClaudeSnapshot: Snapshot?,
        codexSnapshot: CodexUsageSnapshot? = nil,
        codexEntries: @autoclosure () -> [MenuEntry] = [],
        codexToolTip: @autoclosure () -> String = "",
        collectorState: ClaudeCollectorState? = nil,
        pollStatus: ClaudePollStatus = ClaudePollStatus(runningFor: nil, lastAttempt: nil),
        history: MenuHistory = .empty,
        ringSetting: RingSetting = .auto,
        now: Date
    ) -> MenuComposition {
        let claudeSnapshot = storedClaudeSnapshot?.droppingEndedWindows(at: now)
        let decision = PrimaryUsageSelector.decide(
            providerMode: providerMode,
            codexSnapshot: codexSnapshot,
            claudeSnapshot: claudeSnapshot,
            claudeCollectorState: collectorState,
            now: now
        )
        var entries: [MenuEntry]
        let image: MenuBarImage
        let toolTip: String
        switch decision {
        case .claude:
            let stale = SnapshotFreshness.of(claudeSnapshot, at: now).isStale
            let choice = RingChoice.choose(ringSetting, in: claudeSnapshot, at: now)
            let view = UsageView(
                snapshot: claudeSnapshot, polled: providerMode.shouldPollClaude, now: now, ring: choice
            )
            if let choice {
                image = .claudeRing(ClaudeRing(
                    window: choice.window, used: choice.candidate.used, pace: choice.candidate.pace, dimmed: stale
                ))
            } else {
                image = .unavailable(accessibilityDescription: "Claude 사용량 확인 불가")
            }
            toolTip = view.toolTip + (stale ? " · 갱신 멈춤" : "")
            entries = [.header("Claude")]
            // Say up front when the numbers below are old, before any of them.
            let freshness = FreshnessPresentation.entries(
                snapshot: claudeSnapshot, poll: pollStatus, numbersShown: true, now: now
            )
            if !freshness.isEmpty {
                entries.append(contentsOf: freshness)
                entries.append(.separator)
            }
            entries.append(contentsOf: view.entries)
            entries.append(contentsOf: collectorWarningEntries(collectorState))
        case .claudeUnavailable(let reason):
            image = .unavailable(accessibilityDescription: "Claude 사용량 확인 불가")
            toolTip = ClaudeUsageUnavailablePresentation.toolTip
            entries = claudeUnavailableEntries(reason: reason)
            // Same place as above: right under the "Claude" header.
            let freshness = FreshnessPresentation.entries(
                snapshot: claudeSnapshot, poll: pollStatus, numbersShown: false, now: now
            )
            if !freshness.isEmpty {
                entries.insert(contentsOf: freshness + [MenuEntry.separator], at: 1)
            }
        case .codex:
            if let used = codexSnapshot?.menuBarWindow?.usedPercent {
                image = .codexRing(used: used)
            } else {
                image = .unavailable(accessibilityDescription: "Codex 사용량 확인 불가")
            }
            toolTip = codexToolTip()
            entries = codexEntries()
        case .grokUnavailable(let reason):
            image = .unavailable(accessibilityDescription: "Grok 사용량 확인 불가")
            toolTip = GrokUsageUnavailablePresentation.toolTip
            entries = grokUnavailableEntries(reason: reason)
        }

        // Claude stays a secondary readout under the other providers; under the
        // Claude provider it is already the primary block above.
        if !providerMode.shouldPollClaude, isWithinADay(claudeSnapshot, now: now) {
            entries.append(.separator)
            entries.append(.header("Claude · 전환 보조"))
            entries.append(contentsOf: FreshnessPresentation.secondaryEntries(snapshot: claudeSnapshot, now: now))
            entries.append(contentsOf: UsageView(snapshot: claudeSnapshot, polled: false, now: now).entries)
        }

        if history.hasRecords {
            entries.append(.separator)
            entries.append(.header("기록"))
            entries.append(.line("총 \(history.totalRecords)건 · Claude \(history.claudeRecords) · Codex \(history.codexRecords)"))
            if let last = history.lastRecord {
                entries.append(.line("마지막 기록 \(last)"))
            }
        }

        // The ring setting only means something while the ring is Claude's,
        // and only a reading the menu shows offers its windows to pin.
        let ringOptions = providerMode == .claude
            ? RingChoice.options(for: ringSetting, in: decision == .claude ? claudeSnapshot : nil, at: now)
            : []
        return MenuComposition(entries: entries, image: image, toolTip: toolTip, ringOptions: ringOptions)
    }

    private static func isWithinADay(_ snapshot: Snapshot?, now: Date) -> Bool {
        guard let captured = snapshot?.capturedAt else { return false }
        return now.timeIntervalSince1970 - captured <= 24 * 3600
    }

    /// A displayed percentage plus a broken collector means the number is real
    /// but frozen — say so instead of letting it read as current.
    private static func collectorWarningEntries(_ state: ClaudeCollectorState?) -> [MenuEntry] {
        guard let status = state?.parsedStatus, status.blocksCollection else { return [] }
        var entries: [MenuEntry] = [.separator, .header("⚠ 수집 중단")]
        entries.append(.line(status.menuDescription))
        if let detail = state?.detail, !detail.isEmpty {
            entries.append(.line(detail))
        }
        return entries
    }

    private static func claudeUnavailableEntries(
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

    private static func grokUnavailableEntries(
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
}

// MARK: - Plain text

extension MenuComposition {
    /// The menu as text, for `ClaudePace menu-preview`: headers and lines as
    /// they are, bars as ten cells, separators as "—", then the ring and the
    /// tooltip.
    var previewText: String {
        var lines = entries.map { entry -> String in
            switch entry {
            case .header(let text), .line(let text): return text
            case .separator: return "—"
            case .bar(let used, _, let text): return "[\(MenuComposition.cells(used))] \(text)"
            }
        }
        if !ringOptions.isEmpty {
            lines.append("—")
            let items = ringOptions.map { ($0.isSelected ? "✓" : "") + $0.title }
            lines.append("메뉴바 링 ▸ " + items.joined(separator: " | "))
        }
        lines.append("ring: " + ringText)
        lines.append("tooltip: " + toolTip)
        return lines.joined(separator: "\n")
    }

    private var ringText: String {
        switch image {
        case .claudeRing(let ring): return "\(ring.window.label) \(MenuComposition.percent(ring.used))"
        case .codexRing(let used): return "Codex \(MenuComposition.percent(used))"
        case .unavailable: return "?"
        }
    }

    private static func percent(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e6 else { return "?" }
        return "\(Int(value.rounded()))%"
    }

    /// `used` (0...1) as ten cells, like the dropdown's bar.
    private static func cells(_ used: Double) -> String {
        let filled = used.isFinite ? Int(min(max((used * 10).rounded(), 0), 10)) : 0
        return String(repeating: "■", count: filled) + String(repeating: "□", count: 10 - filled)
    }
}
