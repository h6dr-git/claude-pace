import Foundation

// Everything the menu says about Claude, without AppKit: the provider-selection
// tests compile this file next to the snapshot model (ClaudeUsageSnapshot.swift).
// Drawing stays in Bar.swift; AppController applies MenuComposition's result.

final class SnapshotStore {
    static let shared = SnapshotStore()
    let url: URL
    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudePace/snapshot.json")) {
        self.url = url
    }
    /// The stored reading as it stands now: windows whose reset has passed
    /// since it was taken carry no percentage (see `RLWindow.endingIfPast`).
    func load(at now: Date = Date()) -> Snapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: d).droppingEndedWindows(at: now)
    }
}

// MARK: - Pace math

enum PaceVerdict { case warmup, under, onpace, over }

/// A usage window. Window is `length` long and ends at `resetsAt` — holds for
/// both rolling-7d and fixed-weekly resets.
struct WindowCalc {
    static let weekLength: TimeInterval = 7 * 24 * 3600
    static let fiveHourLength: TimeInterval = 5 * 3600

    let used: Double                // 0..100
    let resetsAt: Date
    let length: TimeInterval
    /// The instant the window is read at.
    var now = Date()

    var windowStart: Date { resetsAt.addingTimeInterval(-length) }
    var elapsedFrac: Double { min(max(now.timeIntervalSince(windowStart) / length, 0), 1) }
    var remaining: TimeInterval { max(resetsAt.timeIntervalSince(now), 0) }
    /// Projected final % if the so-far average rate continues. nil during warm-up.
    var projected: Double? { let f = elapsedFrac; guard f > 0.05 else { return nil }; return used / f }
    var verdict: PaceVerdict {
        guard let p = projected else { return .warmup }
        if p < 90 { return .under }
        if p <= 110 { return .onpace }
        return .over
    }
}

// MARK: - Presentation

enum MenuEntry: Equatable {
    case header(String)
    case bar(used: Double, pace: Double?, text: String)
    case line(String)
    case separator
}

struct UsageView {
    /// The snapshot as it reads at `now` (ended windows carry no percentage).
    let snapshot: Snapshot?
    /// Whether this app is polling Claude (claude mode). Under another
    /// provider the block is a leftover reading that will not be refreshed.
    let polled: Bool
    let now: Date
    /// The window the menu-bar ring shows: its section header says so and
    /// the tooltip names it first. nil where the ring shows something else.
    let ring: RingChoice?

    init(snapshot: Snapshot?, polled: Bool = true, now: Date = Date(), ring: RingChoice? = nil) {
        self.snapshot = snapshot?.droppingEndedWindows(at: now)
        self.polled = polled
        self.now = now
        self.ring = ring
    }

    private func calc(_ window: RLWindow?, length: TimeInterval) -> WindowCalc? {
        guard let window, window.isUsable,
              let u = window.used_percentage, let r = window.resets_at else { return nil }
        return WindowCalc(used: u, resetsAt: Date(timeIntervalSince1970: r), length: length, now: now)
    }

    private var week: WindowCalc? { calc(snapshot?.sevenDay, length: WindowCalc.weekLength) }
    /// Never set for an account without a 5-hour limit.
    private var five: WindowCalc? { calc(snapshot?.usableFiveHour, length: WindowCalc.fiveHourLength) }

    var toolTip: String {
        guard let snapshot else { return "AI Usage · Claude 조회 대기" }
        var parts: [String] = []
        if let ring { parts.append("링 \(ring.window.label) \(pct(ring.candidate.used))") }
        if let w = week, ring?.window != .week { parts.append("주 \(pct(w.used))") }
        if let f = five, ring?.window != .five { parts.append("5h \(pct(f.used))") }
        guard !parts.isEmpty else { return "AI Usage · Claude 한도 미확인" }
        var tip = "AI Usage · Claude · " + parts.joined(separator: " · ")
        if let m = snapshot.displayedModel { tip += " · \(m)" }
        return tip
    }

    var entries: [MenuEntry] {
        guard let snapshot else {
            return [.line("스냅샷 없음"), .line("Claude Code를 한 번 쓰면 채워집니다")]
        }
        var e: [MenuEntry] = []
        let weekEnded = endedLine(snapshot.reading(snapshot.sevenDay, at: now), fiveHour: false)
        // An account without a 5-hour limit has no 5-hour window to end either.
        let fiveEnded = snapshot.hasNoFiveHourLimit
            ? nil : endedLine(snapshot.reading(snapshot.fiveHour, at: now), fiveHour: true)
        if let w = week {
            e.append(.header(title("주간 전체 (7일)", .week)))
            appendWeekly(w, resetLine: true, to: &e)
        } else if let weekEnded {
            e.append(.header("주간 전체 (7일)"))
            e.append(.line(weekEnded))
        }
        // Neither is set for an account without a 5-hour limit: that is said
        // once, after the limits that do apply (below the buckets).
        if let f = five {
            e.append(.separator)
            e.append(.header(title("5시간", .five)))
            e.append(.bar(used: f.used / 100, pace: f.elapsedFrac, text: "사용 \(pct(f.used))"))
            e.append(.line("리셋까지 \(dur(f.remaining)) (\(clock(f.resetsAt)))"))
        } else if let fiveEnded {
            e.append(.separator)
            e.append(.header("5시간"))
            e.append(.line(fiveEnded))
        }
        let buckets = bucketEntries(snapshot)
        e.append(contentsOf: buckets)
        if snapshot.hasNoFiveHourLimit {
            e.append(.separator)
            e.append(.line(noFiveHourLimitLine(since: snapshot.fiveHourAbsentSince)))
        }
        if week == nil && five == nil && weekEnded == nil && fiveEnded == nil && buckets.isEmpty {
            e.append(.line("한도 값 없음 — 공식 조회에서 퍼센트를 받지 못함"))
        }
        e.append(.separator)
        e.append(.line("│ 세로선 = 지금 페이스 (여기까지면 딱 맞음)"))
        if let pinned = ring?.fellBackFrom {
            e.append(.line("링: \(pinned.label) 지금 값 없음 · 자동으로 표시"))
        }
        var foot = ""
        if let c = snapshot.capturedAt { foot = "\(dur(now.timeIntervalSince1970 - c)) 전 갱신" }
        if let m = snapshot.displayedModel { foot += foot.isEmpty ? m : " · \(m)" }
        if !foot.isEmpty { e.append(.line(foot)) }
        return e
    }

    /// A weekly window's bar, its reset line (unless left out) and the
    /// planning line under them.
    private func appendWeekly(_ w: WindowCalc, resetLine: Bool, to e: inout [MenuEntry]) {
        var d = "사용 \(pct(w.used))"
        if let p = w.projected { d += " · 예상 \(pct(p)) \(verdict(w.verdict))" }
        e.append(.bar(used: w.used / 100, pace: w.elapsedFrac, text: d))
        if resetLine {
            e.append(.line("리셋까지 \(dur(w.remaining)) (\(clock(w.resetsAt))) · 경과 \(pct(w.elapsedFrac * 100))"))
        }
        if let plan = UsageView.planningLine(used: w.used, remaining: w.remaining) {
            e.append(.line(plan))
        }
    }

    /// Each model's weekly bucket, shown like the all-models week. Its reset
    /// line is left out when it shares that window's reset (the usual case).
    /// Legacy fixed Opus/Sonnet fields come in through `modelBuckets`.
    private func bucketEntries(_ snapshot: Snapshot) -> [MenuEntry] {
        var e: [MenuEntry] = []
        for bucket in snapshot.modelBuckets {
            let name = "\(bucket.name) 주간"
            let reading = snapshot.reading(bucket.window, at: now)
            switch reading {
            case .current(let used, let resetsAt):
                let w = WindowCalc(
                    used: used, resetsAt: Date(timeIntervalSince1970: resetsAt),
                    length: WindowCalc.weekLength, now: now
                )
                e.append(.separator)
                e.append(.header(title(name, .model(bucket.name))))
                appendWeekly(w, resetLine: !sharesWeeklyReset(resetsAt), to: &e)
            case .endedSinceLastPoll:
                guard let ended = endedLine(reading, fiveHour: false) else { continue }
                e.append(.separator)
                e.append(.header(name))
                e.append(.line(ended))
            case .noOpenWindow, .unavailable:
                // A poll after its reset left the bucket as it was, so
                // `/usage` no longer prints it (a renamed or retired model).
                continue
            }
        }
        return e
    }

    private func sharesWeeklyReset(_ resetsAt: Double) -> Bool {
        guard let week else { return false }
        return abs(week.resetsAt.timeIntervalSince1970 - resetsAt) < 60
    }

    /// `base`, marked when the menu-bar ring shows this window.
    private func title(_ base: String, _ window: RingWindow) -> String {
        guard let ring, ring.window.matches(window) else { return base }
        return base + " · 링"
    }

    private func noFiveHourLimitLine(since: Double?) -> String {
        var line = "5시간 한도 없는 계정 · 주간 한도만 적용"
        if let since, since.isFinite, since > 0 {
            line += " (\(day(Date(timeIntervalSince1970: since))) 확인)"
        }
        return line
    }

    /// The line for a window whose reset has passed: say it ended and where
    /// the new value comes from, instead of drawing it as 0%.
    private func endedLine(_ reading: WindowReading, fiveHour: Bool) -> String? {
        let next = polled ? "새 값은 다음 조회 때" : "이 모드에선 새로 조회하지 않음"
        switch reading {
        case .endedSinceLastPoll(let endedAt):
            let when = clock(Date(timeIntervalSince1970: endedAt))
            return fiveHour ? "\(when)에 창 끝남 · \(next)" : "\(when)에 리셋됨 · \(next)"
        case .noOpenWindow(let endedAt):
            let when = clock(Date(timeIntervalSince1970: endedAt))
            guard polled, fiveHour else {
                return fiveHour ? "\(when)에 창 끝남 · \(next)" : "\(when)에 리셋됨 · \(next)"
            }
            return "지금 열린 창 없음 (\(when)에 끝남) · 다음 메시지부터 새로 시작"
        case .current, .unavailable:
            return nil
        }
    }

    /// What is left of a weekly window and the even rate that lands exactly
    /// on 100% at the reset: per day with a day or more to go, per hour in
    /// the last day. Plain arithmetic on the official values; nil once there
    /// is nothing to plan (used up, or under a minute to the reset).
    static func planningLine(used: Double, remaining: TimeInterval) -> String? {
        guard used.isFinite, (0...100).contains(used), remaining.isFinite, remaining >= 60 else { return nil }
        let shown = Int(used.rounded())
        // The bar already says "사용 100%" from 99.5 up: nothing left to plan.
        guard shown < 100 else { return nil }
        let day: TimeInterval = 24 * 3600
        let perDay = remaining >= day
        let rate = (100 - used) / (remaining / (perDay ? day : 3600))
        return "남은 \(100 - shown)% · 리셋까지 \(perDay ? "하루" : "시간당") \(rateText(rate))"
    }
}

// MARK: - Freshness

/// What the menu needs to tell "polling right now" from "not polling at
/// all" when the reading on screen is old (`ClaudeUsagePoller.Status`).
struct ClaudePollStatus: Equatable {
    /// Awake time the running poll has taken so far (nil: none running).
    /// Measured on systemUptime, which stops while the Mac sleeps, so a
    /// poll that slept along with the Mac is not mistaken for a stuck one.
    let runningFor: TimeInterval?
    /// When the last poll started (nil: none since the app launched).
    let lastAttempt: Date?

    /// Every `claude` call in a poll is time-limited (CLAUDE_USAGE_TIMEOUT,
    /// 60s by default), so a whole poll ends within about two minutes. One
    /// still running after this long means something under those limits is
    /// stuck, and the menu says so instead of quietly showing the last number.
    static let stuckAfter: TimeInterval = 5 * 60
}

/// The block at the top of the menu that says whether the numbers under it
/// are current. Nothing when they are; otherwise how old they are and whether
/// a poll is under way, so a reading that stopped updating cannot pass for a
/// live one (the footer's "N시간 전 갱신" alone was easy to miss).
enum FreshnessPresentation {
    static func entries(
        snapshot: Snapshot?,
        poll: ClaudePollStatus,
        numbersShown: Bool,
        now: Date = Date()
    ) -> [MenuEntry] {
        if let running = poll.runningFor, running > ClaudePollStatus.stuckAfter {
            return [
                .header("⚠ 조회가 멈춤"),
                .line("조회 하나가 \(dur(running))째 끝나지 않음 — 앱을 다시 시작해 주세요")
            ]
        }
        guard case .stale(let age) = SnapshotFreshness.of(snapshot, at: now),
              let capturedAt = snapshot?.capturedAt else { return [] }
        let when = "\(dur(age)) 전(\(clock(Date(timeIntervalSince1970: capturedAt))))"
        if poll.runningFor != nil {
            return [
                .header("↻ 다시 조회하는 중"),
                .line(numbersShown ? "아래 숫자는 \(when) 값" : "마지막 값은 \(when)")
            ]
        }
        var entries: [MenuEntry] = [
            .header("⚠ 갱신 멈춤"),
            .line(numbersShown ? "아래 숫자는 \(when) 값 — 지금과 다를 수 있음" : "마지막 값은 \(when)")
        ]
        if let attempt = poll.lastAttempt {
            entries.append(.line("마지막 조회 시도 \(dur(now.timeIntervalSince(attempt))) 전"))
        } else {
            entries.append(.line("앱이 켜진 뒤 아직 조회 시도 없음"))
        }
        return entries
    }

    /// For the "Claude · 전환 보조" block under another provider, where Claude
    /// is never polled: an old reading only gets its age, with no promise of
    /// a next poll.
    static func secondaryEntries(snapshot: Snapshot?, now: Date = Date()) -> [MenuEntry] {
        guard case .stale(let age) = SnapshotFreshness.of(snapshot, at: now),
              let capturedAt = snapshot?.capturedAt else { return [] }
        let when = clock(Date(timeIntervalSince1970: capturedAt))
        return [.line("마지막 값 \(dur(age)) 전(\(when)) · 이 모드에선 Claude를 조회하지 않음")]
    }
}

// MARK: - Helpers

private func pct(_ x: Double) -> String { "\(Int(x.rounded()))%" }

private func verdict(_ v: PaceVerdict) -> String {
    switch v {
    case .under:  return "→ 더 써도 됨"
    case .onpace: return "→ 딱 맞음"
    case .over:   return "→ 아껴 써"
    case .warmup: return ""
    }
}

/// A planning rate: whole percent from 10% up, below that at most one
/// decimal with no trailing ".0". One that rounds to nothing says so rather
/// than reading as 0%.
private func rateText(_ rate: Double) -> String {
    let tenths = (rate * 10).rounded()
    guard tenths >= 1 else { return "0.1% 미만" }
    if tenths >= 100 { return "\(Int(rate.rounded()))%씩" }
    if tenths.truncatingRemainder(dividingBy: 10) == 0 { return "\(Int(tenths / 10))%씩" }
    return String(format: "%.1f%%씩", tenths / 10)
}

/// A span as the menu says it ("1일 4시간"). Nothing real here comes near a
/// century, so one that does (a capture time far off) reads "?" rather than
/// trapping on its way to Int.
private func dur(_ s: TimeInterval) -> String {
    guard s.isFinite, abs(s) < 100 * 365 * 24 * 3600 else { return "?" }
    let t = Int(s.rounded())
    if t < 60 { return "\(t)초" }
    let m = t / 60
    if m < 60 { return "\(m)분" }
    let h = m / 60, mm = m % 60
    if h < 24 { return mm > 0 ? "\(h)시간 \(mm)분" : "\(h)시간" }
    let d = h / 24, hh = h % 24
    return hh > 0 ? "\(d)일 \(hh)시간" : "\(d)일"
}

private func clock(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "M/d HH:mm"
    return f.string(from: d)
}

private func day(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "M/d"
    return f.string(from: d)
}
