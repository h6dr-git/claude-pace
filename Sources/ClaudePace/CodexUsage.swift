import AppKit
import Foundation

// MARK: - Codex app-server snapshot

final class CodexSnapshotStore {
    static let shared = CodexSnapshotStore()
    let url: URL

    private init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudePace/codex-snapshot.json")
    }

    func load() -> CodexUsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CodexUsageSnapshot.self, from: data)
    }
}

// MARK: - Short-lived official poller

final class CodexUsagePoller {
    static let shared = CodexUsagePoller()

    private let queue = DispatchQueue(label: "ClaudePace.CodexUsagePoller")
    private var lastAttempt = Date.distantPast
    private var running = false

    private init() {}

    func refreshIfDue(
        interval: TimeInterval = 180,
        force: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        queue.async {
            guard !self.running else { return }
            guard force || Date().timeIntervalSince(self.lastAttempt) >= interval else { return }

            self.running = true
            self.lastAttempt = Date()

            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let context = CodexUsageCollector.Context(
                home: home,
                environment: ["HOME": home, "PATH": CollectorEnvironment.appSearchPath],
                searchPath: CollectorEnvironment.appSearchPath,
                codexBin: nil
            )
            let status = CodexUsageCollector.poll(context, io: .silent)

            self.running = false
            DispatchQueue.main.async { completion?(status == 0) }
        }
    }
}

// MARK: - Presentation

struct CodexUsageView {
    let snapshot: CodexUsageSnapshot?

    private var mainLimit: CodexRateLimitSnapshot? {
        snapshot?.primaryRateLimit
    }

    private var menuWindow: CodexRateLimitWindow? {
        mainLimit?.primary ?? mainLimit?.secondary
    }

    var menuBarImage: NSImage? {
        guard let window = menuWindow, let used = window.usedPercent else { return nil }
        return Bar.ringImage(
            used: used / 100,
            pace: calculation(for: window)?.elapsedFrac
        )
    }

    var toolTip: String {
        guard let limit = mainLimit else { return "AI Usage · Codex 조회 대기" }
        if limit.credits?.unlimited == true && limit.primary == nil && limit.secondary == nil {
            return "AI Usage · Codex 무제한"
        }
        if let used = menuWindow?.usedPercent {
            return "AI Usage · Codex \(codexPercent(used))"
        }
        return "AI Usage · Codex"
    }

    var entries: [MenuEntry] {
        guard let snapshot else {
            return [.header("Codex"), .line("공식 사용량 조회 대기…")]
        }

        var entries: [MenuEntry] = []
        let plan = displayPlan(mainLimit?.planType)
        entries.append(.header(plan == nil ? "Codex" : "Codex · \(plan!)"))

        let buckets = displayBuckets(from: snapshot)
        if buckets.isEmpty {
            if mainLimit?.credits?.unlimited == true {
                entries.append(.line("계정 한도 없음 · 무제한"))
            } else {
                entries.append(.line("한도 정보 없음"))
            }
        } else {
            for (index, bucket) in buckets.enumerated() {
                if index > 0 { entries.append(.separator) }
                append(bucket: bucket, to: &entries)
            }
        }

        if let credits = mainLimit?.credits {
            if credits.unlimited == true {
                entries.append(.line("추가 크레딧 · 무제한"))
            } else if credits.hasCredits == true, let balance = credits.balance {
                entries.append(.line("추가 크레딧 \(balance)"))
            }
        }
        if let resets = snapshot.rateLimitResetCredits?.availableCount, resets > 0 {
            entries.append(.line("한도 리셋권 \(resets)개"))
        }

        if let summary = snapshot.accountUsage?.summary,
           summary.lifetimeTokens != nil || summary.peakDailyTokens != nil {
            entries.append(.separator)
            entries.append(.header("토큰 기록"))
            var values: [String] = []
            if let lifetime = summary.lifetimeTokens {
                values.append("누적 \(codexNumber(lifetime))")
            }
            if let peak = summary.peakDailyTokens {
                values.append("최고 일 \(codexNumber(peak))")
            }
            entries.append(.line(values.joined(separator: " · ")))
        }

        if let captured = snapshot.capturedAt {
            entries.append(.line("\(codexDuration(Date().timeIntervalSince1970 - captured)) 전 갱신"))
        }
        return entries
    }

    private func displayBuckets(
        from snapshot: CodexUsageSnapshot
    ) -> [(key: String, value: CodexRateLimitSnapshot)] {
        if let byId = snapshot.rateLimitsByLimitId, !byId.isEmpty {
            return byId.sorted { left, right in
                if left.key == "codex" { return true }
                if right.key == "codex" { return false }
                return bucketName(left.value, fallback: left.key)
                    .localizedCaseInsensitiveCompare(bucketName(right.value, fallback: right.key)) == .orderedAscending
            }
        }
        if let rateLimits = snapshot.rateLimits {
            return [(rateLimits.limitId ?? "codex", rateLimits)]
        }
        return []
    }

    private func append(
        bucket: (key: String, value: CodexRateLimitSnapshot),
        to entries: inout [MenuEntry]
    ) {
        let name = bucketName(bucket.value, fallback: bucket.key)
        let windows = [bucket.value.primary, bucket.value.secondary].compactMap { $0 }
        if windows.isEmpty {
            entries.append(.header(name))
            if bucket.value.credits?.unlimited == true {
                entries.append(.line("무제한"))
            } else {
                entries.append(.line("현재 한도 창 없음"))
            }
            return
        }

        for (index, window) in windows.enumerated() {
            let label = "\(name) · \(windowLabel(window.windowDurationMins))"
            if index > 0 { entries.append(.separator) }
            entries.append(.header(label))
            let used = window.usedPercent ?? 0
            let calc = calculation(for: window)
            var detail = "사용 \(codexPercent(used))"
            if let projected = calc?.projected {
                detail += " · 예상 \(codexPercent(projected)) \(codexVerdict(calc!.verdict))"
            }
            entries.append(.bar(used: used / 100, pace: calc?.elapsedFrac, text: detail))
            if let calc {
                entries.append(.line("리셋까지 \(codexDuration(calc.remaining)) (\(codexClock(calc.resetsAt)))"))
            }
        }
    }

    private func calculation(for window: CodexRateLimitWindow) -> WindowCalc? {
        guard let reset = window.resetsAt,
              let minutes = window.windowDurationMins,
              minutes > 0 else { return nil }
        return WindowCalc(
            used: window.usedPercent ?? 0,
            resetsAt: Date(timeIntervalSince1970: reset),
            length: minutes * 60
        )
    }

    private func bucketName(_ bucket: CodexRateLimitSnapshot, fallback: String) -> String {
        if fallback == "codex" || bucket.limitId == "codex" { return "전체" }
        if let name = bucket.limitName, !name.isEmpty { return name }
        return "모델별 한도"
    }
}

private func displayPlan(_ plan: String?) -> String? {
    guard let plan, !plan.isEmpty else { return nil }
    if plan.lowercased() == "pro" { return "Pro" }
    return plan.replacingOccurrences(of: "_", with: " ").capitalized
}

private func windowLabel(_ minutes: Double?) -> String {
    guard let minutes, minutes > 0 else { return "사용량" }
    let rounded = Int(minutes.rounded())
    if rounded % 1440 == 0 { return "\(rounded / 1440)일" }
    if rounded % 60 == 0 { return "\(rounded / 60)시간" }
    return "\(rounded)분"
}

private func codexPercent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
}

private func codexVerdict(_ verdict: PaceVerdict) -> String {
    switch verdict {
    case .under: return "→ 더 써도 됨"
    case .onpace: return "→ 딱 맞음"
    case .over: return "→ 아껴 써"
    case .warmup: return ""
    }
}

private func codexDuration(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds.rounded()), 0)
    if total < 60 { return "\(total)초" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)분" }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours < 24 {
        return remainingMinutes > 0 ? "\(hours)시간 \(remainingMinutes)분" : "\(hours)시간"
    }
    let days = hours / 24
    let remainingHours = hours % 24
    return remainingHours > 0 ? "\(days)일 \(remainingHours)시간" : "\(days)일"
}

private func codexClock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}

private func codexNumber(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}
