import Foundation

// MARK: - Claude snapshot (matches what StatusLineBridge and ClaudeUsageCollector write)

struct RLWindow: Codable {
    let used_percentage: Double?
    let resets_at: Double?          // unix epoch seconds

    /// True once the window's reset instant has passed.
    func hasEnded(at now: Date = Date()) -> Bool {
        guard let reset = resets_at, reset.isFinite else { return false }
        return now.timeIntervalSince1970 >= reset
    }

    /// What a window can still claim at `now`. Once its reset has passed, the
    /// stored percentage belonged to the window that ended, and the next
    /// window's numbers cannot be known locally — a 5-hour window opens with
    /// the next message, not on a fixed grid, and usage since then is unseen.
    /// So the percentage is dropped (nothing may draw it as 0%) while the reset
    /// instant is kept, letting the menu say when the window ended. The next
    /// poll brings the real values. (This used to roll the window forward to
    /// "0% used" with an invented reset time, which a stale snapshot then
    /// showed as if it were a fresh reading.)
    func endingIfPast(at now: Date = Date()) -> RLWindow {
        guard hasEnded(at: now) else { return self }
        return RLWindow(used_percentage: nil, resets_at: resets_at)
    }

    /// A window is only usable when the official source gave a finite
    /// percentage inside 0...100 *and* a reset instant to measure pace against.
    /// Anything else is treated as "no reading", never as 0% used.
    var isUsable: Bool {
        guard let used = used_percentage, used.isFinite, (0...100).contains(used) else { return false }
        guard let reset = resets_at, reset.isFinite else { return false }
        return true
    }
}

struct Snapshot: Codable {
    let capturedAt: Double?
    let fiveHour: RLWindow?
    let sevenDay: RLWindow?
    let sevenDayOpus: RLWindow?
    let sevenDaySonnet: RLWindow?
    /// Per-model weekly buckets as printed by `/usage` ("Current week (Opus)").
    /// Model names change between releases, so they are kept keyed instead of
    /// hard-coded into fixed fields.
    let modelWindows: [String: RLWindow]?
    let model: String?

    /// The snapshot as it reads at `now`: windows whose reset has passed keep
    /// their reset instant but lose their percentage (see `endingIfPast`).
    func droppingEndedWindows(at now: Date = Date()) -> Snapshot {
        Snapshot(
            capturedAt: capturedAt,
            fiveHour: fiveHour?.endingIfPast(at: now),
            sevenDay: sevenDay?.endingIfPast(at: now),
            sevenDayOpus: sevenDayOpus?.endingIfPast(at: now),
            sevenDaySonnet: sevenDaySonnet?.endingIfPast(at: now),
            modelWindows: modelWindows?.mapValues { $0.endingIfPast(at: now) },
            model: model
        )
    }

    /// What the menu can honestly say about one of this snapshot's windows.
    func reading(_ window: RLWindow?, at now: Date = Date()) -> WindowReading {
        guard let window else { return .unavailable }
        if window.hasEnded(at: now), let reset = window.resets_at {
            // A poll taken after the reset that still carried the old window
            // means `/usage` printed no new one (it omits the session line
            // between 5-hour windows): nothing is open right now.
            if let capturedAt, capturedAt.isFinite, capturedAt >= reset {
                return .noOpenWindow(endedAt: reset)
            }
            return .endedSinceLastPoll(endedAt: reset)
        }
        guard window.isUsable, let used = window.used_percentage, let reset = window.resets_at else {
            return .unavailable
        }
        return .current(used: used, resetsAt: reset)
    }

    /// The windows the menu bar can actually draw from.
    var usableFiveHour: RLWindow? { fiveHour?.isUsable == true ? fiveHour : nil }
    var usableSevenDay: RLWindow? { sevenDay?.isUsable == true ? sevenDay : nil }
    var hasUsableWindow: Bool { usableFiveHour != nil || usableSevenDay != nil }

    func hasFreshCapture(at now: Date, maximumAge: TimeInterval, maximumClockSkew: TimeInterval) -> Bool {
        guard let capturedAt, capturedAt.isFinite else { return false }
        let age = now.timeIntervalSince1970 - capturedAt
        return age >= -maximumClockSkew && age <= maximumAge
    }
}

/// One window as the menu may present it.
enum WindowReading: Equatable {
    /// A real percentage with its reset still ahead.
    case current(used: Double, resetsAt: Double)
    /// The reset passed after the last poll: the stored number belonged to the
    /// window that ended, and the new one arrives with the next poll.
    case endedSinceLastPoll(endedAt: Double)
    /// A poll after the reset still saw no new window: none is open now.
    case noOpenWindow(endedAt: Double)
    /// No usable reading at all.
    case unavailable
}

/// How current a Claude reading is. The official poll runs every 180s while
/// the Mac is awake, so a reading older than a few missed polls means
/// collection is not keeping up — the Mac slept, the poller stalled, or polls
/// are failing — and the menu has to say so instead of letting an old number
/// pass for the current one.
enum SnapshotFreshness: Equatable {
    case fresh
    case stale(age: TimeInterval)
    case unknown

    /// Three missed 180s polls plus slack.
    static let staleAfter: TimeInterval = 10 * 60

    static func of(_ snapshot: Snapshot?, at now: Date = Date()) -> SnapshotFreshness {
        guard let capturedAt = snapshot?.capturedAt, capturedAt.isFinite else { return .unknown }
        let age = now.timeIntervalSince1970 - capturedAt
        return age > staleAfter ? .stale(age: age) : .fresh
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}

// MARK: - Collector state

/// Why the Claude collector last succeeded or failed. Written by
/// `ClaudeUsageCollector` on every poll so a silent collector failure (an expired
/// CLI login, a `/usage` output that no longer prints limits) shows up in the
/// menu instead of looking like "no usage yet".
enum ClaudeCollectorStatus: Equatable {
    case ok
    case signedOut
    case noLimits
    case cliMissing
    case emptyOutput
    case parseFailed
    case timedOut
    case unknown(String)

    static func from(rawValue: String?) -> ClaudeCollectorStatus? {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": return nil
        case "ok": return .ok
        case "signed-out": return .signedOut
        case "no-limits": return .noLimits
        case "cli-missing": return .cliMissing
        case "empty-output": return .emptyOutput
        case "parse-failed": return .parseFailed
        case "timed-out": return .timedOut
        case let other: return .unknown(other)
        }
    }

    /// Collector problems that mean the stored percentages cannot be trusted to
    /// keep up with the account, even if a snapshot file still exists.
    var blocksCollection: Bool {
        switch self {
        case .ok: return false
        case .signedOut, .noLimits, .cliMissing, .emptyOutput, .parseFailed, .timedOut: return true
        case .unknown: return true
        }
    }

    var menuDescription: String {
        switch self {
        case .ok: return "수집 정상"
        case .signedOut: return "터미널 claude 로그아웃 — `claude auth login` 필요"
        case .noLimits: return "`/usage`가 한도 줄을 내지 않음"
        case .cliMissing: return "claude 명령을 찾을 수 없음"
        case .emptyOutput: return "`/usage` 출력이 비어 있음"
        case .parseFailed: return "`/usage` 출력을 해석하지 못함"
        case .timedOut: return "claude가 응답하지 않음 — 시간 초과로 중단"
        case .unknown(let raw): return "수집기 상태 미상 (\(raw))"
        }
    }
}

struct ClaudeCollectorState: Codable {
    let schema: String?
    let status: String?
    let capturedAt: Double?
    let detail: String?

    var parsedStatus: ClaudeCollectorStatus? {
        guard schema == "claude-collector-state.v1" else { return nil }
        return ClaudeCollectorStatus.from(rawValue: status)
    }
}

final class ClaudeCollectorStateStore {
    static let shared = ClaudeCollectorStateStore()
    let url: URL

    private init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudePace/claude-collector-state.json")
    }

    func load() -> ClaudeCollectorState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeCollectorState.self, from: data)
    }
}
