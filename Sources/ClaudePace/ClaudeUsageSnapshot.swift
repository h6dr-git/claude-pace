import Foundation

// MARK: - Claude snapshot (matches what bridge/statusline.sh and tools/poll-usage.sh write)

struct RLWindow: Codable {
    let used_percentage: Double?
    let resets_at: Double?          // unix epoch seconds

    func rolledForward(length: TimeInterval, at now: Date = Date()) -> RLWindow {
        guard var reset = resets_at else { return self }
        let nowTs = now.timeIntervalSince1970
        guard nowTs >= reset else { return self }

        let elapsedResetCount = floor((nowTs - reset) / length) + 1
        reset += elapsedResetCount * length
        return RLWindow(used_percentage: 0, resets_at: reset)
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

    func rolledForward(at now: Date = Date()) -> Snapshot {
        let week: TimeInterval = 7 * 24 * 3600
        return Snapshot(
            capturedAt: capturedAt,
            fiveHour: fiveHour?.rolledForward(length: 5 * 3600, at: now),
            sevenDay: sevenDay?.rolledForward(length: week, at: now),
            sevenDayOpus: sevenDayOpus?.rolledForward(length: week, at: now),
            sevenDaySonnet: sevenDaySonnet?.rolledForward(length: week, at: now),
            modelWindows: modelWindows?.mapValues { $0.rolledForward(length: week, at: now) },
            model: model
        )
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

// MARK: - Collector state

/// Why the Claude collector last succeeded or failed. Written by
/// `tools/poll-usage.sh` on every poll so a silent collector failure (an expired
/// CLI login, a `/usage` output that no longer prints limits) shows up in the
/// menu instead of looking like "no usage yet".
enum ClaudeCollectorStatus: Equatable {
    case ok
    case signedOut
    case noLimits
    case cliMissing
    case emptyOutput
    case parseFailed
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
        case let other: return .unknown(other)
        }
    }

    /// Collector problems that mean the stored percentages cannot be trusted to
    /// keep up with the account, even if a snapshot file still exists.
    var blocksCollection: Bool {
        switch self {
        case .ok: return false
        case .signedOut, .noLimits, .cliMissing, .emptyOutput, .parseFailed: return true
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
