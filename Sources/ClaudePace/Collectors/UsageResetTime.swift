import Foundation

/// Reset instants as `/usage` prints them: "Jul 22 at 8:50pm", "Jul 29 at
/// 2pm" — no year, and ':00' dropped on whole hours. Ports `reset_epoch`,
/// including Python's `strptime` matching rules. Needs nothing but
/// Foundation, so a test can compile it on its own.
enum UsageResetTime {
    private struct Format {
        let regex: NSRegularExpression
        let hasMinutes: Bool
    }

    // Python builds these from "%b %d at %I:%M%p %Y" and friends: whitespace
    // in the format matches one or more spaces, matching ignores case, and the
    // first match must consume the whole string.
    private static let month = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)"
    private static let day = "(3[01]|[12]\\d|0[1-9]|[1-9]| [1-9])"
    private static let hour = "(1[0-2]|0[1-9]|[1-9])"
    private static let minute = "([0-5]\\d|\\d)"
    private static let ampm = "(am|pm)"
    private static let year = "(\\d\\d\\d\\d)"

    private static let formats: [Format] = [
        Format(regex: make("\(month)\\s+\(day)\\s+at\\s+\(hour):\(minute)\(ampm)\\s+\(year)"), hasMinutes: true),
        Format(regex: make("\(month)\\s+\(day)\\s+at\\s+\(hour)\(ampm)\\s+\(year)"), hasMinutes: false),
        Format(regex: make("\(month)\\s+\(day)\\s+at\\s+\(hour):\(minute)\\s+\(ampm)\\s+\(year)"), hasMinutes: true),
        Format(regex: make("\(month)\\s+\(day)\\s+at\\s+\(hour)\\s+\(ampm)\\s+\(year)"), hasMinutes: false)
    ]

    private static func make(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "^" + pattern, options: [.caseInsensitive])
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun",
                                 "jul", "aug", "sep", "oct", "nov", "dec"]

    /// The reset instant as epoch seconds, exactly as printed; nil when the
    /// text is not a reset time.
    ///
    /// The text has no year, so the year before, the year of `now` (in the
    /// printed zone) and the year after are tried, skipping a year without
    /// that day (Feb 29), and the instant closest to `now` wins — the earlier
    /// one on a tie. A reset that already passed stays in the past, where the
    /// app reads it as an ended window. (It used to be rolled forward by whole
    /// windows. Just after a reset that paired the ended window's percentage
    /// with an invented reset of the next window, and in late December
    /// "Jan 2" was read as this year's and pushed 52 weeks ahead: a day early.)
    static func epoch(text: String?, timeZoneName: String?, now: Date = Date()) -> Double? {
        guard let raw = text, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        var zone = TimeZone.current
        if let name = timeZoneName, !name.isEmpty, let named = TimeZone(identifier: name) {
            zone = named
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let currentYear = calendar.component(.year, from: now)
        let reference = now.timeIntervalSince1970

        for format in formats {
            var closest: Double?
            for candidate in [currentYear - 1, currentYear, currentYear + 1] {
                guard let epoch = instant(trimmed, year: candidate, format: format, calendar: calendar) else { continue }
                if let best = closest, abs(best - reference) <= abs(epoch - reference) { continue }
                closest = epoch
            }
            if let closest { return closest }
        }
        return nil
    }

    /// `datetime.strptime(f"{text} {year}", fmt + " %Y")` read in the
    /// calendar's zone; nil where Python raises ValueError.
    private static func instant(_ text: String, year candidate: Int, format: Format, calendar: Calendar) -> Double? {
        let input = "\(text) \(candidate)"
        let nsInput = input as NSString
        guard let match = format.regex.firstMatch(in: input, range: NSRange(location: 0, length: nsInput.length)),
              match.range.location == 0,
              match.range.length == nsInput.length else { return nil }
        func part(_ index: Int) -> String {
            nsInput.substring(with: match.range(at: index))
        }
        guard let monthIndex = months.firstIndex(of: part(1).lowercased()),
              let dayValue = Int(part(2).trimmingCharacters(in: .whitespaces)),
              let hour12 = Int(part(3)) else { return nil }
        var group = 4
        var minuteValue = 0
        if format.hasMinutes {
            guard let parsed = Int(part(group)) else { return nil }
            minuteValue = parsed
            group += 1
        }
        let isPM = part(group).lowercased() == "pm"
        guard let yearValue = Int(part(group + 1)) else { return nil }

        var hour24 = hour12 == 12 ? 0 : hour12
        if isPM { hour24 += 12 }

        // datetime() rejects a day the month does not have (Feb 30, and Feb 29
        // outside leap years).
        var components = DateComponents()
        components.year = yearValue
        components.month = monthIndex + 1
        guard let firstOfMonth = calendar.date(from: components),
              let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count,
              dayValue >= 1, dayValue <= daysInMonth else { return nil }

        components.day = dayValue
        components.hour = hour24
        components.minute = minuteValue
        components.second = 0
        return calendar.date(from: components)?.timeIntervalSince1970
    }
}
