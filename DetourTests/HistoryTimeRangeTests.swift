import XCTest
@testable import Detour

/// The History page's time filter, as a pure type (TASK-92).
///
/// Two things are pinned here and nowhere else: what the bridge accepts as a
/// `range` — the page names a period, never an instant, so everything that is
/// not one of two exact shapes has to be refused rather than guessed at — and
/// what each period *means* in a local calendar, including on the two days a
/// year that are not 24 hours long.
final class HistoryTimeRangeTests: XCTestCase {

    /// A calendar whose answers do not depend on where the test runs. Los
    /// Angeles because it has the DST transitions the day arithmetic has to
    /// survive.
    private func losAngeles() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 0, _ minute: Int = 0,
                      file: StaticString = #filePath, line: UInt = #line) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return try XCTUnwrap(calendar.date(from: components), "no such date", file: file, line: line)
    }

    /// Midnight of a day, spelled out in components rather than derived with
    /// `startOfDay` — the expectation must not be computed the way the code
    /// under test computes it. (Every midnight these tests name exists: the
    /// Los Angeles DST jumps are at 02:00.)
    private func seconds(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        try date(calendar, year, month, day, 0, 0, file: file, line: line).timeIntervalSince1970
    }

    // MARK: - parse

    func testAnAbsentRangeIsAllTime() {
        XCTAssertEqual(HistoryTimeRange.parse(nil), .allTime)
        XCTAssertEqual(HistoryTimeRange.parse(NSNull()), .allTime)
    }

    func testEachPresetParses() {
        XCTAssertEqual(HistoryTimeRange.parse(["preset": "today"]), .range(.today))
        XCTAssertEqual(HistoryTimeRange.parse(["preset": "yesterday"]), .range(.yesterday))
        XCTAssertEqual(HistoryTimeRange.parse(["preset": "week"]), .range(.week))
        XCTAssertEqual(HistoryTimeRange.parse(["preset": "month"]), .range(.month))
    }

    func testAValidDayParses() {
        XCTAssertEqual(HistoryTimeRange.parse(["day": "2026-09-19"]),
                       .range(.day(year: 2026, month: 9, day: 19)))
        XCTAssertEqual(HistoryTimeRange.parse(["day": "2024-02-29"]),
                       .range(.day(year: 2024, month: 2, day: 29)), "a leap day is a real day")
    }

    /// A day the retention window no longer holds is not an error — it is a
    /// period nothing was recorded in, and the caller answers it with an empty
    /// list (AC #3).
    func testADayOutsideTheRetentionWindowIsStillValid() {
        XCTAssertEqual(HistoryTimeRange.parse(["day": "1999-01-01"]),
                       .range(.day(year: 1999, month: 1, day: 1)))
    }

    func testEverythingElseIsMalformed() {
        let cases: [Any] = [
            "today",                                    // not a dictionary
            7,
            ["today"],
            [String: Any](),                            // present, but says nothing
            ["preset": "decade"],                       // unknown preset
            ["preset": "day"],                          // the page's own sentinel is not a preset
            ["preset": "Today"],                        // and the names are exact
            ["preset": 1],                              // not a string
            ["preset": NSNull()],
            ["day": "2026-09-19", "preset": "today"],   // both at once
            ["preset": "today", "extra": 1],            // an extra key
            ["range": "today"],                         // the wrong key
            ["day": "2026-2-3"],                        // not zero-padded
            ["day": "2026-02-3"],
            ["day": "26-02-03"],
            ["day": "20260203"],
            ["day": "2026-02-30"],                      // no such day
            ["day": "2026-13-01"],                      // no such month
            ["day": "2026-00-10"],
            ["day": "2026-02-00"],
            ["day": "2025-02-29"],                      // not a leap year
            ["day": "2026-09-19T00:00:00Z"],
            ["day": ""],
            ["day": 20260203],                          // not a string
        ]
        for value in cases {
            XCTAssertEqual(HistoryTimeRange.parse(value), .malformed, "\(value) was accepted")
        }
    }

    // MARK: - bounds

    func testPresetBounds() throws {
        let calendar = try losAngeles()
        let now = try date(calendar, 2026, 9, 19, 14, 30)
        let startOfToday = try seconds(calendar, 2026, 9, 19)

        var window = HistoryTimeRange.today.bounds(now: now, calendar: calendar)
        XCTAssertEqual(window.from, startOfToday)
        XCTAssertNil(window.until, "today is still running, so it has no end")

        window = HistoryTimeRange.yesterday.bounds(now: now, calendar: calendar)
        XCTAssertEqual(window.from, try seconds(calendar, 2026, 9, 18))
        XCTAssertEqual(window.until, startOfToday, "half-open: today is not yesterday")

        window = HistoryTimeRange.week.bounds(now: now, calendar: calendar)
        XCTAssertEqual(window.from, try seconds(calendar, 2026, 9, 13), "today and the six days before")
        XCTAssertNil(window.until)

        window = HistoryTimeRange.month.bounds(now: now, calendar: calendar)
        XCTAssertEqual(window.from, try seconds(calendar, 2026, 8, 21), "today and the 29 days before")
        XCTAssertNil(window.until)
    }

    /// The bound is the start of the *local* day, not of the UTC one, whatever
    /// time of day it is asked at.
    func testBoundsAreTheStartOfTheLocalDay() throws {
        let calendar = try losAngeles()
        let startOfToday = try seconds(calendar, 2026, 9, 19)
        for hour in [0, 7, 16, 23] {
            let now = try date(calendar, 2026, 9, 19, hour, 45)
            XCTAssertEqual(HistoryTimeRange.today.bounds(now: now, calendar: calendar).from, startOfToday,
                           "at \(hour):45")
        }
    }

    func testADayIsTheWholeCalendarDay() throws {
        let calendar = try losAngeles()
        let window = HistoryTimeRange.day(year: 2026, month: 9, day: 19)
            .bounds(now: try date(calendar, 2026, 9, 25), calendar: calendar)

        XCTAssertEqual(window.from, try seconds(calendar, 2026, 9, 19))
        XCTAssertEqual(window.until, try seconds(calendar, 2026, 9, 20), "up to, and not including, the next day")
        XCTAssertEqual(try XCTUnwrap(window.until) - window.from, 24 * 3600)
    }

    /// The reason none of this is `86400` arithmetic: in Los Angeles 8 March
    /// 2026 is 23 hours long and 1 November 2026 is 25.
    func testADayAcrossADSTTransitionIsNot24Hours() throws {
        let calendar = try losAngeles()
        let now = try date(calendar, 2026, 12, 1)

        let spring = HistoryTimeRange.day(year: 2026, month: 3, day: 8).bounds(now: now, calendar: calendar)
        XCTAssertEqual(spring.from, try seconds(calendar, 2026, 3, 8))
        XCTAssertEqual(try XCTUnwrap(spring.until) - spring.from, 23 * 3600, "the day the clocks went forward")

        let fall = HistoryTimeRange.day(year: 2026, month: 11, day: 1).bounds(now: now, calendar: calendar)
        XCTAssertEqual(fall.from, try seconds(calendar, 2026, 11, 1))
        XCTAssertEqual(try XCTUnwrap(fall.until) - fall.from, 25 * 3600, "and the day they went back")
    }

    /// The same for the presets, which walk backwards over those days: an
    /// interval subtraction would put "yesterday" an hour inside the day before.
    func testPresetsLandOnMidnightAcrossADSTTransition() throws {
        let calendar = try losAngeles()
        let now = try date(calendar, 2026, 11, 2, 9, 0)

        let yesterday = HistoryTimeRange.yesterday.bounds(now: now, calendar: calendar)
        XCTAssertEqual(yesterday.from, try seconds(calendar, 2026, 11, 1))
        XCTAssertEqual(yesterday.until, try seconds(calendar, 2026, 11, 2))
        XCTAssertEqual(try XCTUnwrap(yesterday.until) - yesterday.from, 25 * 3600)

        XCTAssertEqual(HistoryTimeRange.week.bounds(now: now, calendar: calendar).from,
                       try seconds(calendar, 2026, 10, 27), "midnight six days back, not 6 × 86400")
        XCTAssertEqual(HistoryTimeRange.month.bounds(now: now, calendar: calendar).from,
                       try seconds(calendar, 2026, 10, 4))
    }

    /// The same day means different instants in different places; the bounds
    /// follow the calendar they are given.
    func testBoundsFollowTheGivenTimeZone() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let losAngeles = try self.losAngeles()
        let day = HistoryTimeRange.day(year: 2026, month: 9, day: 19)
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        XCTAssertEqual(day.bounds(now: now, calendar: tokyo).from,
                       try seconds(tokyo, 2026, 9, 19))
        XCTAssertNotEqual(day.bounds(now: now, calendar: tokyo).from,
                          day.bounds(now: now, calendar: losAngeles).from)
    }

    // MARK: - Parsed.bounds

    func testParsedBoundsDistinguishAllTimeFromMalformed() throws {
        let calendar = try losAngeles()
        let now = try date(calendar, 2026, 9, 19, 14, 30)

        let allTime = try XCTUnwrap(HistoryTimeRange.Parsed.allTime.bounds(now: now, calendar: calendar))
        XCTAssertNil(allTime.from, "no window at all")
        XCTAssertNil(allTime.until)

        let today = try XCTUnwrap(HistoryTimeRange.Parsed.range(.today).bounds(now: now, calendar: calendar))
        XCTAssertEqual(today.from, try seconds(calendar, 2026, 9, 19))
        XCTAssertNil(today.until)

        XCTAssertNil(HistoryTimeRange.Parsed.malformed.bounds(now: now, calendar: calendar),
                     "a malformed range has no bounds — the caller must refuse it")
    }
}
