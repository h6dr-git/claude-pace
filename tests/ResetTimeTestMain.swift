import Foundation

// Reset times as `/usage` prints them (no year, ':00' dropped on whole hours),
// read against explicit "now" values so the year is checked across New Year
// and on leap days whatever today's date is.
@main
struct ResetTimeTestMain {
    private static var failures = 0
    private static let seoul = TimeZone(identifier: "Asia/Seoul")!
    private static let utc = TimeZone(identifier: "UTC")!
    /// The process zone for this run: neither Seoul nor UTC, so a time read
    /// in the wrong zone shows.
    private static let currentZone = "Pacific/Honolulu"

    static func main() {
        setenv("TZ", currentZone, 1)
        NSTimeZone.resetSystemTimeZone()

        testJanuaryResetSeenInLateDecemberIsNextYear()
        testDecemberResetSeenOnNewYearsDayStaysInThePast()
        testOrdinaryFutureWeeklyReset()
        testPassedResetIsNotRolledForward()
        testWholeHourAndMinuteForms()
        testSpacedAndMixedCaseForms()
        testLeapDayResolvesToTheLeapYear()
        testDayTheMonthDoesNotHaveIsNil()
        testGarbageIsNil()
        testUnknownZoneFallsBackToCurrentZone()
        testTieGoesToTheEarlierYear()

        guard failures == 0 else {
            fputs("FAIL: \(failures) reset-time assertions failed\n", stderr)
            exit(1)
        }
        print("PASS: usage reset time assertions")
    }

    // MARK: - Cases

    /// On Dec 28, "Jan 2 at 2pm" is five days ahead. It used to be read as
    /// this year's and rolled forward 52 weeks, landing on Jan 1.
    private static func testJanuaryResetSeenInLateDecemberIsNextYear() {
        expect("Jan 2 at 2pm", now: at(2026, 12, 28, 12), equals: at(2027, 1, 2, 14), "Dec 28: Jan 2 is next year's")
        expect("Jan 1 at 2:50am", now: at(2026, 12, 31, 22), equals: at(2027, 1, 1, 2, 50),
               "New Year's Eve: a 5-hour reset after midnight")
    }

    /// Just after midnight on Jan 1, "Dec 31 at 11pm" passed an hour ago,
    /// last year, and stays there.
    private static func testDecemberResetSeenOnNewYearsDayStaysInThePast() {
        let now = at(2027, 1, 1, 1)
        expect("Dec 31 at 11pm", now: now, equals: at(2026, 12, 31, 23), "Jan 1 01:00: Dec 31 is last year's")
        expect((read("Dec 31 at 11pm", now: now) ?? .infinity) < now, "Jan 1 01:00: Dec 31 stays in the past")
    }

    private static func testOrdinaryFutureWeeklyReset() {
        let now = at(2026, 11, 17, 9, 34)
        // The weekly reset in the 2026-11-17 capture (snapshot.json: 1794978000.0).
        expect("Nov 18 at 2pm", now: now, equals: 1_794_978_000, "weekly reset tomorrow")
        expect("Nov 24 at 2pm", now: now, equals: at(2026, 11, 24, 14), "weekly reset a week ahead")
    }

    /// A reset that already passed comes back as printed: the app reads it
    /// as an ended window. Rolled forward it paired the ended window's
    /// percentage with an invented reset of the next one.
    private static func testPassedResetIsNotRolledForward() {
        expect("Nov 17 at 8:50pm", now: at(2026, 11, 17, 21), equals: at(2026, 11, 17, 20, 50),
               "5-hour reset ten minutes ago")
        // The ended window still in the 2026-11-17 snapshot (resets_at 1794637200.0).
        expect("Nov 14 at 3:20pm", now: at(2026, 11, 17, 9, 34), equals: 1_794_637_200, "5-hour reset three days ago")
    }

    private static func testWholeHourAndMinuteForms() {
        let now = at(2026, 11, 17, 10)
        expect("Nov 18 at 2pm", now: now, equals: at(2026, 11, 18, 14), "whole hour")
        expect("Nov 17 at 8:50pm", now: now, equals: at(2026, 11, 17, 20, 50), "hour and minutes")
        expect("Nov 17 at 12pm", now: now, equals: at(2026, 11, 17, 12), "noon")
        expect("Nov 18 at 12am", now: now, equals: at(2026, 11, 18, 0), "midnight")
        expect("Nov 17 at 12:30am", now: now, equals: at(2026, 11, 17, 0, 30), "half past midnight")
        expect("Nov 17 at 08:05am", now: now, equals: at(2026, 11, 17, 8, 5), "leading zeros")
        expect("Nov 17 at 8:5pm", now: now, equals: at(2026, 11, 17, 20, 5), "one-digit minutes, as strptime takes them")
    }

    private static func testSpacedAndMixedCaseForms() {
        let now = at(2026, 11, 17, 10)
        expect("Nov 17 at 8:50 PM", now: now, equals: at(2026, 11, 17, 20, 50), "8:50 PM")
        expect("nov 17 AT 8:50 pm", now: now, equals: at(2026, 11, 17, 20, 50), "mixed case")
        expect("Nov 17 at 8 Pm", now: now, equals: at(2026, 11, 17, 20), "8 Pm")
        expect("  Nov  17   at  8:50pm \n", now: now, equals: at(2026, 11, 17, 20, 50), "runs of spaces, outer whitespace")
        expect("Nov 7 at 9am", now: at(2026, 11, 5, 10), equals: at(2026, 11, 7, 9), "one-digit day")
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        expect("jul 22 at 8:50 PM", zone: "America/Los_Angeles", now: at(2026, 7, 22, 10, in: losAngeles),
               equals: at(2026, 7, 22, 20, 50, in: losAngeles), "another printed zone")
    }

    /// Feb 29 exists only in leap years; the other candidate years are skipped.
    private static func testLeapDayResolvesToTheLeapYear() {
        expect("Feb 29 at 2pm", now: at(2028, 2, 26, 10), equals: at(2028, 2, 29, 14), "Feb 29 this year")
        expect("Feb 29 at 2pm", now: at(2027, 12, 30, 10), equals: at(2028, 2, 29, 14), "Feb 29 next year")
        expect("Feb 29 at 2pm", now: at(2029, 1, 10, 10), equals: at(2028, 2, 29, 14), "Feb 29 last year")
        expect("Feb 29 at 2pm", now: at(2026, 6, 1, 10), equals: nil, "no leap year a year either way")
    }

    private static func testDayTheMonthDoesNotHaveIsNil() {
        expect("Feb 30 at 1pm", now: at(2026, 11, 17, 10), equals: nil, "Feb 30")
        expect("Feb 30 at 1pm", now: at(2028, 2, 1, 10), equals: nil, "Feb 30 in a leap year")
        expect("Apr 31 at 1pm", now: at(2026, 4, 1, 10), equals: nil, "Apr 31")
    }

    private static func testGarbageIsNil() {
        let now = at(2026, 11, 17, 10)
        let texts: [String?] = [
            nil, "", "   ", "soon", "in 3 hours", "Nov 18", "Nov 18 at", "Nov 18 at 2", "18 Nov at 2pm",
            "Nov 18 at 13pm", "Nov 18 at 0am", "Nov 18 at 8:60pm", "Nov 32 at 2pm", "Nov 0 at 2pm",
            "Nov 18 at 2pm 2026", "Nov 18 at 2pmx", "Nob 18 at 2pm"
        ]
        for text in texts {
            expect(text, now: now, equals: nil, "not a reset time")
        }
    }

    /// A zone name Foundation does not know reads the time in the current
    /// zone, as the script read a naive datetime.
    private static func testUnknownZoneFallsBackToCurrentZone() {
        let now = at(2026, 11, 17, 10)
        let expected = at(2026, 11, 18, 14, in: TimeZone(identifier: currentZone)!)
        expect(TimeZone.current.identifier == currentZone, "this run's zone is \(currentZone)")
        expect("Nov 18 at 2pm", zone: "Mars/Base", now: now, equals: expected, "unknown zone")
        expect("Nov 18 at 2pm", zone: nil, now: now, equals: expected, "no zone")
        expect("Nov 18 at 2pm", zone: "", now: now, equals: expected, "empty zone")
    }

    /// Exactly halfway between two candidates the earlier year wins; a
    /// second later the later one does.
    private static func testTieGoesToTheEarlierYear() {
        // 2026 has 365 days: halfway through it is Jul 2, 12:00.
        let halfway = at(2026, 1, 1, 0, in: utc) + 182.5 * 86_400
        expect("Jan 1 at 12am", zone: "UTC", now: halfway, equals: at(2026, 1, 1, 0, in: utc), "tie: the earlier year")
        expect("Jan 1 at 12am", zone: "UTC", now: halfway + 1, equals: at(2027, 1, 1, 0, in: utc),
               "just past the tie: the later year")
    }

    // MARK: - Helpers

    /// Epoch seconds of a wall-clock time in `zone`.
    private static func at(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone = seoul
    ) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: components)!.timeIntervalSince1970
    }

    private static func read(_ text: String?, zone: String? = "Asia/Seoul", now: Double) -> Double? {
        UsageResetTime.epoch(text: text, timeZoneName: zone, now: Date(timeIntervalSince1970: now))
    }

    private static func expect(
        _ text: String?, zone: String? = "Asia/Seoul", now: Double, equals expected: Double?, _ name: String
    ) {
        let actual = read(text, zone: zone, now: now)
        guard actual != expected else { return }
        failures += 1
        let shown = text.map { "\"\($0)\"" } ?? "nil"
        fputs("FAIL: \(name): \(shown) at \(describe(now)): expected \(describe(expected)), got \(describe(actual))\n", stderr)
    }

    private static func expect(_ condition: Bool, _ name: String) {
        if !condition {
            failures += 1
            fputs("FAIL: \(name)\n", stderr)
        }
    }

    private static func describe(_ epoch: Double?) -> String {
        guard let epoch else { return "nil" }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = seoul
        return "\(epoch) (\(formatter.string(from: Date(timeIntervalSince1970: epoch))))"
    }
}
