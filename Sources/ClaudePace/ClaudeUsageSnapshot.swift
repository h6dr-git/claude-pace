import Foundation

// MARK: - Claude snapshot (matches what StatusLineBridge and ClaudeUsageCollector write)

struct RLWindow: Codable, Equatable {
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
    /// Anything else is treated as "no reading", never as 0% used. (A reset
    /// further ahead than its window reaches is blanked by
    /// `Snapshot.droppingEndedWindows`, see `blankIfOutOfRange`.)
    var isUsable: Bool {
        guard let used = used_percentage, used.isFinite, (0...100).contains(used) else { return false }
        guard let reset = resets_at, reset.isFinite else { return false }
        return true
    }

    /// How much further than its own length a reset may lie ahead of `now`
    /// and still be a reading: clock skew between capture and display, and a
    /// reset `/usage` printed in a time zone the collector could not name.
    static let resetSlack: TimeInterval = 24 * 3600

    /// No reading at all when the reset lies further ahead of `now` than a
    /// window of `length` reaches. No official source prints such a reset (a
    /// weekly window resets within the week), so it is out of range like a
    /// percentage over 100 — and an absurd one (1e19) cannot even be shown
    /// as a duration. A reset in the past is left to `endingIfPast`.
    func blankIfOutOfRange(length: TimeInterval, at now: Date = Date()) -> RLWindow {
        guard let reset = resets_at, reset - now.timeIntervalSince1970 > length + RLWindow.resetSlack else {
            return self
        }
        return RLWindow(used_percentage: nil, resets_at: nil)
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
    /// The model of the statusLine render that wrote this snapshot. The
    /// `/usage` poll never updates it, so it is only shown for snapshots that
    /// did not come from the poll (see `source`).
    let model: String?
    /// When the collector concluded that this account has no 5-hour limit
    /// (epoch seconds) — Ultra accounts lose it in a rollout that began
    /// 2026-10-30, while weekly limits stay. `fiveHour` is null while it is
    /// set, and it goes away as soon as `/usage` prints a "Current session"
    /// line again.
    let fiveHourAbsentSince: Double?
    /// The capture time of the last `/usage` poll that printed a "Current
    /// session" line, readable or not (epoch seconds; the poll only).
    let fiveHourSeenAt: Double?
    /// Who wrote the snapshot: "usage-poll" for the `/usage` collector,
    /// nothing for the statusLine bridge.
    let source: String?

    init(
        capturedAt: Double?,
        fiveHour: RLWindow?,
        sevenDay: RLWindow?,
        sevenDayOpus: RLWindow?,
        sevenDaySonnet: RLWindow?,
        modelWindows: [String: RLWindow]?,
        model: String?,
        fiveHourAbsentSince: Double? = nil,
        fiveHourSeenAt: Double? = nil,
        source: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.modelWindows = modelWindows
        self.model = model
        self.fiveHourAbsentSince = fiveHourAbsentSince
        self.fiveHourSeenAt = fiveHourSeenAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case capturedAt, fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet, modelWindows, model
        case fiveHourAbsentSince, fiveHourSeenAt, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try c.decodeIfPresent(Double.self, forKey: .capturedAt)
        fiveHour = try c.decodeIfPresent(RLWindow.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(RLWindow.self, forKey: .sevenDay)
        sevenDayOpus = try c.decodeIfPresent(RLWindow.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try c.decodeIfPresent(RLWindow.self, forKey: .sevenDaySonnet)
        modelWindows = try c.decodeIfPresent([String: RLWindow].self, forKey: .modelWindows)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        // Extras on top of the readings: one of the wrong type must not cost
        // the whole snapshot, it just reads as absent.
        fiveHourAbsentSince = try? c.decodeIfPresent(Double.self, forKey: .fiveHourAbsentSince)
        fiveHourSeenAt = try? c.decodeIfPresent(Double.self, forKey: .fiveHourSeenAt)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }

    /// The snapshot as it reads at `now`: windows whose reset has passed keep
    /// their reset instant but lose their percentage (see `endingIfPast`),
    /// and a window whose reset lies further ahead than it reaches is no
    /// reading at all (see `blankIfOutOfRange`).
    func droppingEndedWindows(at now: Date = Date()) -> Snapshot {
        func read(_ window: RLWindow, length: TimeInterval) -> RLWindow {
            window.endingIfPast(at: now).blankIfOutOfRange(length: length, at: now)
        }
        let week = WindowCalc.weekLength
        return Snapshot(
            capturedAt: capturedAt,
            fiveHour: fiveHour.map { read($0, length: WindowCalc.fiveHourLength) },
            sevenDay: sevenDay.map { read($0, length: week) },
            sevenDayOpus: sevenDayOpus.map { read($0, length: week) },
            sevenDaySonnet: sevenDaySonnet.map { read($0, length: week) },
            modelWindows: modelWindows?.mapValues { read($0, length: week) },
            model: model,
            fiveHourAbsentSince: fiveHourAbsentSince,
            fiveHourSeenAt: fiveHourSeenAt,
            source: source
        )
    }

    /// The collector found no 5-hour limit on this account: there is no
    /// 5-hour window to show, ended or otherwise.
    var hasNoFiveHourLimit: Bool { fiveHourAbsentSince != nil }

    /// The poll that wrote this snapshot printed a session line: one that
    /// gave no usable window, when there is no 5-hour reading to go with it.
    /// Only such a poll stores `fiveHourSeenAt` at its own capture time (one
    /// without the line moves a sighting that late back a second).
    var latestPollPrintedSessionLine: Bool {
        guard source == "usage-poll", let seen = fiveHourSeenAt, let capturedAt else { return false }
        return seen == capturedAt
    }

    /// `model` when it describes the reading. The `/usage` poll leaves the
    /// statusLine era's value behind and never updates it.
    var displayedModel: String? {
        guard source != "usage-poll", let model, !model.isEmpty else { return nil }
        return model
    }

    /// Per-model weekly buckets, sorted by name: the keyed `modelWindows`
    /// plus the statusLine era's fixed Opus/Sonnet fields. On a name clash
    /// the keyed bucket wins — the poll keeps the old fixed fields around
    /// untouched, while a statusLine write replaces the whole file, so the
    /// keyed bucket is always the newer of the two.
    var modelBuckets: [ModelBucket] {
        var buckets = (modelWindows ?? [:]).map { ModelBucket(name: $0.key, window: $0.value) }
        for (name, window) in [("Opus", sevenDayOpus), ("Sonnet", sevenDaySonnet)] {
            guard let window,
                  !buckets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            buckets.append(ModelBucket(name: name, window: window))
        }
        return buckets.sorted { $0.name < $1.name }
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
    var usableFiveHour: RLWindow? {
        guard !hasNoFiveHourLimit, fiveHour?.isUsable == true else { return nil }
        return fiveHour
    }
    var usableSevenDay: RLWindow? { sevenDay?.isUsable == true ? sevenDay : nil }
    var usableModelBuckets: [ModelBucket] { modelBuckets.filter { $0.window.isUsable } }
    /// A per-model bucket counts too: an account whose only reading is one
    /// model's weekly limit still has a real number to draw.
    var hasUsableWindow: Bool {
        usableFiveHour != nil || usableSevenDay != nil || !usableModelBuckets.isEmpty
    }

    func hasFreshCapture(at now: Date, maximumAge: TimeInterval, maximumClockSkew: TimeInterval) -> Bool {
        guard let capturedAt, capturedAt.isFinite else { return false }
        let age = now.timeIntervalSince1970 - capturedAt
        return age >= -maximumClockSkew && age <= maximumAge
    }
}

/// One model's weekly limit ("Current week (Fable)").
struct ModelBucket: Equatable {
    let name: String
    let window: RLWindow
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

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudePace/claude-collector-state.json")) {
        self.url = url
    }

    func load() -> ClaudeCollectorState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeCollectorState.self, from: data)
    }
}
