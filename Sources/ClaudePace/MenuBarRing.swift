import Foundation

// Which Claude window the menu-bar ring shows. Foundation only, so the
// provider-selection tests compile it next to the snapshot model.

/// A Claude window the ring can show.
enum RingWindow: Equatable {
    /// The all-models weekly window.
    case week
    case five
    /// A per-model weekly bucket, by the name `/usage` printed.
    case model(String)

    /// What the menu calls it ("주간 전체", "5시간", "Fable 주간").
    var label: String {
        switch self {
        case .week: return "주간 전체"
        case .five: return "5시간"
        case .model(let name): return "\(name) 주간"
        }
    }

    /// The same window; model names compare case-insensitively, the way
    /// `Snapshot.modelBuckets` merges them.
    func matches(_ other: RingWindow) -> Bool {
        switch (self, other) {
        case (.week, .week), (.five, .five): return true
        case (.model(let a), .model(let b)): return a.caseInsensitiveCompare(b) == .orderedSame
        default: return false
        }
    }
}

/// The "ring" value in settings.json.
enum RingSetting: Equatable {
    /// The usable window closest to exhaustion.
    case auto
    case pinned(RingWindow)

    private static let modelPrefix = "model:"

    /// "auto" | "week" | "five" | "model:<bucket name>"; nil for anything else.
    init?(rawValue: String) {
        switch rawValue {
        case "auto": self = .auto
        case "week": self = .pinned(.week)
        case "five": self = .pinned(.five)
        default:
            guard rawValue.hasPrefix(RingSetting.modelPrefix) else { return nil }
            let name = String(rawValue.dropFirst(RingSetting.modelPrefix.count))
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .pinned(.model(name))
        }
    }

    var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .pinned(.week): return "week"
        case .pinned(.five): return "five"
        case .pinned(.model(let name)): return RingSetting.modelPrefix + name
        }
    }
}

/// A window with a real reading right now, as the ring would draw it.
struct RingCandidate: Equatable {
    let window: RingWindow
    /// 0...100, as read.
    let used: Double
    /// Elapsed fraction of the window (0...1): the pace tick.
    let pace: Double

    /// Every usable window of `snapshot` (as read at `now`) in tie-break
    /// order: weekly, 5-hour, then the model buckets by name.
    static func all(in snapshot: Snapshot, at now: Date) -> [RingCandidate] {
        let reading = snapshot.droppingEndedWindows(at: now)
        var candidates: [RingCandidate] = []
        func add(_ window: RingWindow, _ rl: RLWindow?, length: TimeInterval) {
            guard let rl, rl.isUsable, let used = rl.used_percentage, let reset = rl.resets_at else { return }
            let calc = WindowCalc(used: used, resetsAt: Date(timeIntervalSince1970: reset), length: length, now: now)
            candidates.append(RingCandidate(window: window, used: used, pace: calc.elapsedFrac))
        }
        add(.week, reading.usableSevenDay, length: WindowCalc.weekLength)
        add(.five, reading.usableFiveHour, length: WindowCalc.fiveHourLength)
        for bucket in reading.usableModelBuckets {
            add(.model(bucket.name), bucket.window, length: WindowCalc.weekLength)
        }
        return candidates
    }
}

/// The window the ring shows, and whether that was the setting's own pick.
struct RingChoice: Equatable {
    let candidate: RingCandidate
    /// The pinned window that has no reading right now, so auto picked
    /// instead. nil when the setting was honoured as is.
    let fellBackFrom: RingWindow?

    var window: RingWindow { candidate.window }

    /// nil when nothing is usable: the ring then draws "?", never 0%.
    static func choose(_ setting: RingSetting, in snapshot: Snapshot?, at now: Date) -> RingChoice? {
        guard let snapshot else { return nil }
        let candidates = RingCandidate.all(in: snapshot, at: now)
        switch setting {
        case .auto:
            return closestToExhaustion(candidates).map { RingChoice(candidate: $0, fellBackFrom: nil) }
        case .pinned(let window):
            if let pinned = candidates.first(where: { $0.window.matches(window) }) {
                return RingChoice(candidate: pinned, fellBackFrom: nil)
            }
            return closestToExhaustion(candidates).map { RingChoice(candidate: $0, fellBackFrom: window) }
        }
    }

    /// Highest used% wins; on a tie the earlier candidate (weekly, then
    /// 5-hour, then buckets by name).
    static func closestToExhaustion(_ candidates: [RingCandidate]) -> RingCandidate? {
        var best: RingCandidate?
        for candidate in candidates {
            if let current = best, candidate.used <= current.used { continue }
            best = candidate
        }
        return best
    }

    /// The "메뉴바 링" submenu: auto, the all-models week, the 5-hour window
    /// while it has a reading, and every bucket that has one.
    static func options(for setting: RingSetting, in snapshot: Snapshot?, at now: Date) -> [RingOption] {
        var options = [RingOption(title: "자동 (가장 많이 쓴 한도)", setting: .auto, isSelected: setting == .auto)]
        var windows: [RingWindow] = [.week]
        if let reading = snapshot?.droppingEndedWindows(at: now) {
            if reading.usableFiveHour != nil { windows.append(.five) }
            windows += reading.usableModelBuckets.map { RingWindow.model($0.name) }
        }
        for window in windows {
            var selected = false
            if case .pinned(let pinned) = setting { selected = pinned.matches(window) }
            options.append(RingOption(title: window.label, setting: .pinned(window), isSelected: selected))
        }
        return options
    }
}

/// One item of the "메뉴바 링" submenu.
struct RingOption: Equatable {
    let title: String
    let setting: RingSetting
    /// Checkmark: this is the current setting.
    let isSelected: Bool
}

// MARK: - settings.json

/// ~/Library/Application Support/ClaudePace/settings.json:
/// {"schema":"claudepace-settings.v1","ring":"auto"}
enum ClaudePaceSettings {
    static let schema = "claudepace-settings.v1"

    /// Missing, unreadable, another schema or an unknown value all read as
    /// auto: a settings problem must never blank the ring.
    static func ring(from data: Data?) -> RingSetting {
        guard let object = settingsObject(data),
              let raw = object["ring"] as? String,
              let setting = RingSetting(rawValue: raw) else { return .auto }
        return setting
    }

    /// The file with `ring` set. Other keys of a v1 file are kept, so a
    /// newer build's settings survive this one changing the ring.
    static func data(setting ring: RingSetting, over existing: Data?) -> Data? {
        var object = settingsObject(existing) ?? [:]
        object["schema"] = schema
        object["ring"] = ring.rawValue
        guard var data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        data.append(0x0A)
        return data
    }

    private static func settingsObject(_ data: Data?) -> [String: Any]? {
        guard let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["schema"] as? String == schema else { return nil }
        return object
    }
}

struct ClaudePaceSettingsStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(home: String) {
        url = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/ClaudePace/settings.json")
    }

    func loadRing() -> RingSetting {
        ClaudePaceSettings.ring(from: try? Data(contentsOf: url))
    }

    /// Written only when the user changes the ring, through a temporary
    /// file renamed into place: a reader never sees half a file.
    @discardableResult
    func saveRing(_ ring: RingSetting) -> Bool {
        guard let data = ClaudePaceSettings.data(setting: ring, over: try? Data(contentsOf: url)) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
