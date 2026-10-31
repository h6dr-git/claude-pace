import AppKit
import Foundation

// The Claude snapshot model lives in ClaudeUsageSnapshot.swift so the
// provider-selection tests can compile it without pulling in AppKit UI code.

final class SnapshotStore {
    static let shared = SnapshotStore()
    let url: URL
    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudePace/snapshot.json")
    }
    /// The stored reading as it stands now: windows whose reset has passed
    /// since it was taken carry no percentage (see `RLWindow.endingIfPast`).
    func load() -> Snapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: d).droppingEndedWindows()
    }
}

// MARK: - Pace math

enum PaceVerdict { case warmup, under, onpace, over }

/// A usage window. Window is `length` long and ends at `resetsAt` — holds for
/// both rolling-7d and fixed-weekly resets.
struct WindowCalc {
    let used: Double                // 0..100
    let resetsAt: Date
    let length: TimeInterval

    var windowStart: Date { resetsAt.addingTimeInterval(-length) }
    var elapsedFrac: Double { min(max(Date().timeIntervalSince(windowStart) / length, 0), 1) }
    var remaining: TimeInterval { max(resetsAt.timeIntervalSinceNow, 0) }
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

enum MenuEntry {
    case header(String)
    case bar(used: Double, pace: Double?, text: String)
    case line(String)
    case separator
}

struct UsageView {
    let snapshot: Snapshot?

    private func calc(_ window: RLWindow?, length: TimeInterval) -> WindowCalc? {
        guard let window, window.isUsable,
              let u = window.used_percentage, let r = window.resets_at else { return nil }
        return WindowCalc(used: u, resetsAt: Date(timeIntervalSince1970: r), length: length)
    }

    private var week: WindowCalc? { calc(snapshot?.sevenDay, length: 7 * 24 * 3600) }
    private var five: WindowCalc? { calc(snapshot?.fiveHour, length: 5 * 3600) }

    /// Menu bar prefers the real-time 5h view. When `/usage` only reports the
    /// weekly window — or the 5h window has ended — the ring falls back to the
    /// weekly one rather than drawing a false 0%, and with no usable window at
    /// all it draws nothing. `dimmed` marks a reading that stopped updating.
    func menuBarImage(dimmed: Bool) -> NSImage? {
        guard let w = five ?? week else { return nil }
        return Bar.ringImage(used: w.used / 100, pace: w.elapsedFrac, dimmed: dimmed)
    }

    var toolTip: String {
        guard let snapshot else { return "AI Usage · Claude 조회 대기" }
        var parts: [String] = []
        if let w = week { parts.append("주 \(pct(w.used))") }
        if let f = five { parts.append("5h \(pct(f.used))") }
        guard !parts.isEmpty else { return "AI Usage · Claude 한도 미확인" }
        var tip = "AI Usage · Claude · " + parts.joined(separator: " · ")
        if let m = snapshot.model { tip += " · \(m)" }
        return tip
    }

    var entries: [MenuEntry] {
        guard let snapshot else {
            return [.line("스냅샷 없음"), .line("Claude Code를 한 번 쓰면 채워집니다")]
        }
        var e: [MenuEntry] = []
        let weekEnded = endedLine(snapshot, snapshot.sevenDay, fiveHour: false)
        let fiveEnded = endedLine(snapshot, snapshot.fiveHour, fiveHour: true)
        if let w = week {
            e.append(.header("주간 (7일)"))
            var d = "사용 \(pct(w.used))"
            if let p = w.projected { d += " · 예상 \(pct(p)) \(verdict(w.verdict))" }
            e.append(.bar(used: w.used / 100, pace: w.elapsedFrac, text: d))
            e.append(.line("리셋까지 \(dur(w.remaining)) (\(clock(w.resetsAt))) · 경과 \(pct(w.elapsedFrac * 100))"))
        } else if let weekEnded {
            e.append(.header("주간 (7일)"))
            e.append(.line(weekEnded))
        }
        if let f = five {
            e.append(.separator)
            e.append(.header("5시간"))
            e.append(.bar(used: f.used / 100, pace: f.elapsedFrac, text: "사용 \(pct(f.used))"))
            e.append(.line("리셋까지 \(dur(f.remaining)) (\(clock(f.resetsAt)))"))
        } else if let fiveEnded {
            e.append(.separator)
            e.append(.header("5시간"))
            e.append(.line(fiveEnded))
        }
        let modelLines = modelWindowLines(snapshot)
        if !modelLines.isEmpty {
            e.append(.separator)
            e.append(.header("모델별 주간"))
            e.append(contentsOf: modelLines.map { MenuEntry.line($0) })
        }
        if week == nil && five == nil && weekEnded == nil && fiveEnded == nil {
            e.append(.line("한도 값 없음 — 공식 조회에서 퍼센트를 받지 못함"))
        }
        e.append(.separator)
        e.append(.line("│ 세로선 = 지금 페이스 (여기까지면 딱 맞음)"))
        var foot = ""
        if let c = snapshot.capturedAt { foot = "\(dur(Date().timeIntervalSince1970 - c)) 전 갱신" }
        if let m = snapshot.model { foot += foot.isEmpty ? m : " · \(m)" }
        if !foot.isEmpty { e.append(.line(foot)) }
        return e
    }

    /// Per-model weekly buckets. Keeps the legacy fixed Opus/Sonnet fields
    /// working for snapshots written by the statusLine bridge.
    private func modelWindowLines(_ snapshot: Snapshot) -> [String] {
        var named: [(String, RLWindow)] = []
        if let o = snapshot.sevenDayOpus { named.append(("Opus", o)) }
        if let s = snapshot.sevenDaySonnet { named.append(("Sonnet", s)) }
        for (name, window) in (snapshot.modelWindows ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !named.contains(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            named.append((name, window))
        }
        return named.compactMap { name, window in
            guard window.isUsable, let used = window.used_percentage else { return nil }
            return "\(name) 주간 \(pct(used))"
        }
    }

    /// The line for a window whose reset has passed: say it ended and that the
    /// new value comes with the next poll, instead of drawing it as 0%.
    private func endedLine(_ snapshot: Snapshot, _ window: RLWindow?, fiveHour: Bool) -> String? {
        switch snapshot.reading(window) {
        case .endedSinceLastPoll(let endedAt):
            let when = clock(Date(timeIntervalSince1970: endedAt))
            return fiveHour
                ? "\(when)에 창 끝남 · 새 값은 다음 조회 때"
                : "\(when)에 리셋됨 · 새 값은 다음 조회 때"
        case .noOpenWindow(let endedAt):
            let when = clock(Date(timeIntervalSince1970: endedAt))
            return fiveHour
                ? "지금 열린 창 없음 (\(when)에 끝남) · 다음 메시지부터 새로 시작"
                : "\(when)에 리셋됨 · 새 값은 다음 조회 때"
        case .current, .unavailable:
            return nil
        }
    }
}

// MARK: - Freshness

/// The block at the top of the menu that says whether the numbers under it
/// are current. Nothing when they are; otherwise how old they are and whether
/// a poll is under way, so a reading that stopped updating cannot pass for a
/// live one (the footer's "N시간 전 갱신" alone was easy to miss).
enum FreshnessPresentation {
    static func entries(
        snapshot: Snapshot?,
        poll: ClaudeUsagePoller.Status,
        numbersShown: Bool,
        now: Date = Date()
    ) -> [MenuEntry] {
        if let since = poll.runningSince, now.timeIntervalSince(since) > ClaudeUsagePoller.stuckAfter {
            return [
                .header("⚠ 조회가 멈춤"),
                .line("조회 하나가 \(dur(now.timeIntervalSince(since)))째 끝나지 않음 — 앱을 다시 시작해 주세요")
            ]
        }
        guard case .stale(let age) = SnapshotFreshness.of(snapshot, at: now),
              let capturedAt = snapshot?.capturedAt else { return [] }
        let when = "\(dur(age)) 전(\(clock(Date(timeIntervalSince1970: capturedAt))))"
        if poll.runningSince != nil {
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

private func dur(_ s: TimeInterval) -> String {
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
