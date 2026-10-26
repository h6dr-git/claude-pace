import Foundation

enum PrimaryUsageProviderMode: Equatable {
    case claude
    case codex
    case grokTransition

    static let environmentKey = "AI_USAGE_PRIMARY_PROVIDER"

    static func from(environment: [String: String]) -> PrimaryUsageProviderMode {
        // Provider access is opt-in per provider. A missing, blank, or
        // unrecognised setting must not silently reactivate account polling or
        // local session ingestion after the primary provider changes.
        guard let rawValue = environment[environmentKey] else {
            return .grokTransition
        }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude":
            return .claude
        case "codex":
            return .codex
        case "grok", "grok-transition", "grok_transition":
            return .grokTransition
        default:
            // Unknown values fail closed for the same reason as a missing
            // setting: only an exact provider name authorises that provider.
            return .grokTransition
        }
    }

    var shouldPollCodex: Bool { self == .codex }
    var shouldIngestCodexHistory: Bool { self == .codex }
    var shouldPollClaude: Bool { self == .claude }
}

enum PrimaryUsageUnavailableReason: Equatable {
    case providerTransition
    case missingCodexSnapshot
    case staleCodexSnapshot
    case invalidCodexEntitlement
}

enum ClaudeUsageUnavailableReason: Equatable {
    case missingSnapshot
    case staleSnapshot
    case noUsableWindow
    case collectorBlocked(ClaudeCollectorStatus)
}

enum PrimaryUsageDecision: Equatable {
    case claude
    case codex
    case claudeUnavailable(ClaudeUsageUnavailableReason)
    case grokUnavailable(PrimaryUsageUnavailableReason)
}

enum PrimaryUsageSelector {
    static let maximumCodexSnapshotAge: TimeInterval = 10 * 60
    /// Claude percentages come from a 180s poll that only runs while this Mac is
    /// awake, so a short staleness bound would flap. The app rolls expired
    /// windows forward locally; past a day the reading is dropped instead.
    static let maximumClaudeSnapshotAge: TimeInterval = 24 * 3600
    static let maximumClockSkew: TimeInterval = 60

    static func decide(
        providerMode: PrimaryUsageProviderMode,
        codexSnapshot: CodexUsageSnapshot? = nil,
        claudeSnapshot: Snapshot? = nil,
        claudeCollectorState: ClaudeCollectorState? = nil,
        now: Date = Date()
    ) -> PrimaryUsageDecision {
        switch providerMode {
        case .claude:
            return decideClaude(
                snapshot: claudeSnapshot,
                collectorState: claudeCollectorState,
                now: now
            )
        case .grokTransition:
            return .grokUnavailable(.providerTransition)
        case .codex:
            return decideCodex(snapshot: codexSnapshot, now: now)
        }
    }

    private static func decideClaude(
        snapshot: Snapshot?,
        collectorState: ClaudeCollectorState?,
        now: Date
    ) -> PrimaryUsageDecision {
        let collectorStatus = collectorState?.parsedStatus

        // A usable, recent reading is shown even while the collector is failing:
        // the number on screen is still the last real account reading, and the
        // failure is surfaced as its own menu line rather than by blanking it.
        if let snapshot,
           snapshot.hasUsableWindow,
           snapshot.hasFreshCapture(
               at: now,
               maximumAge: maximumClaudeSnapshotAge,
               maximumClockSkew: maximumClockSkew
           ) {
            return .claude
        }

        // With nothing trustworthy to display, name the collector fault first —
        // it is the actionable cause ("log the CLI back in"), while "no
        // snapshot" only describes the symptom.
        if let collectorStatus, collectorStatus.blocksCollection {
            return .claudeUnavailable(.collectorBlocked(collectorStatus))
        }
        guard let snapshot else {
            return .claudeUnavailable(.missingSnapshot)
        }
        guard snapshot.hasUsableWindow else {
            return .claudeUnavailable(.noUsableWindow)
        }
        return .claudeUnavailable(.staleSnapshot)
    }

    private static func decideCodex(
        snapshot codexSnapshot: CodexUsageSnapshot?,
        now: Date
    ) -> PrimaryUsageDecision {
        guard let codexSnapshot else {
            return .grokUnavailable(.missingCodexSnapshot)
        }
        guard codexSnapshot.hasFreshCapture(
            at: now,
            maximumAge: maximumCodexSnapshotAge,
            maximumClockSkew: maximumClockSkew
        ) else {
            return .grokUnavailable(.staleCodexSnapshot)
        }
        guard codexSnapshot.hasUsableOfficialEntitlement else {
            return .grokUnavailable(.invalidCodexEntitlement)
        }
        return .codex
    }
}

enum GrokUsageUnavailablePresentation {
    static let toolTip = "Grok 사용량: 공식 기계판독 불가"
}

enum ClaudeUsageUnavailablePresentation {
    static let toolTip = "Claude 사용량: 공식 조회값 없음"
}

extension CodexUsageSnapshot {
    var primaryRateLimit: CodexRateLimitSnapshot? {
        rateLimits
            ?? rateLimitsByLimitId?["codex"]
            ?? rateLimitsByLimitId?.sorted(by: { $0.key < $1.key }).first?.value
    }

    func hasFreshCapture(
        at now: Date,
        maximumAge: TimeInterval,
        maximumClockSkew: TimeInterval
    ) -> Bool {
        guard let capturedAt, capturedAt.isFinite else { return false }
        let age = now.timeIntervalSince1970 - capturedAt
        return age >= -maximumClockSkew && age <= maximumAge
    }

    var hasUsableOfficialEntitlement: Bool {
        guard schema == "codex-usage.v1", source == "codex-app-server",
              let limit = primaryRateLimit else { return false }

        if limit.credits?.unlimited == true {
            return true
        }

        return [limit.primary, limit.secondary]
            .compactMap { $0 }
            .contains { window in
                guard let used = window.usedPercent else { return false }
                return used.isFinite && (0...100).contains(used)
            }
    }
}
