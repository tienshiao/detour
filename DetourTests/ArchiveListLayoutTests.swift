import XCTest
@testable import Detour

/// TASK-119: the Archived Tabs page's pure row layout — relative-date buckets,
/// ordering, search, the space filter and the URL line.
final class ArchiveListLayoutTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-09-26 15:00 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 15))!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private func bucket(_ date: Date) -> ArchiveBucket {
        archiveBucket(for: date, now: now, calendar: calendar)
    }

    private let spaceA = UUID()
    private let spaceB = UUID()

    private func entry(_ id: Int64, _ title: String = "Page", url: String? = "https://example.com/",
                       closedAt: Date?, space: UUID? = nil) -> ArchiveEntry {
        ArchiveEntry(id: id, spaceID: space ?? spaceA, title: title, url: url, faviconURL: nil,
                     closedAt: closedAt, isRestorable: true)
    }

    private func rows(_ entries: [ArchiveEntry], query: String = "", filter: UUID? = nil) -> [ArchiveRow] {
        archiveRows(entries: entries, query: query, spaceFilter: filter, now: now, calendar: calendar)
    }

    private func entryIDs(_ rows: [ArchiveRow]) -> [Int64] {
        rows.compactMap { if case .entry(let e) = $0 { return e.id } else { return nil } }
    }

    // MARK: - Buckets

    func testDayBuckets() {
        XCTAssertEqual(bucket(daysAgo(0, hour: 0)), .today, "start of today")
        XCTAssertEqual(bucket(daysAgo(1, hour: 23)), .yesterday, "calendar days, not 24-hour spans")
        XCTAssertEqual(bucket(daysAgo(1, hour: 0)), .yesterday)
        XCTAssertEqual(bucket(daysAgo(2)), .daysAgo(2))
        XCTAssertEqual(bucket(daysAgo(6)), .daysAgo(6))
    }

    func testWeekBuckets() {
        XCTAssertEqual(bucket(daysAgo(7)), .weeksAgo(1))
        XCTAssertEqual(bucket(daysAgo(13)), .weeksAgo(1))
        XCTAssertEqual(bucket(daysAgo(14)), .weeksAgo(2))
        XCTAssertEqual(bucket(daysAgo(28)), .weeksAgo(4))
        XCTAssertEqual(bucket(daysAgo(29)), .weeksAgo(4))
    }

    func testMonthAndYearBuckets() {
        XCTAssertEqual(bucket(daysAgo(30)), .monthsAgo(1), "Aug 27 is under a calendar month back, floored to 1")
        XCTAssertEqual(bucket(daysAgo(59)), .monthsAgo(1), "Jul 29 → 1 month 28 days")
        XCTAssertEqual(bucket(date(2026, 7, 26)), .monthsAgo(2))
        XCTAssertEqual(bucket(date(2025, 9, 27)), .monthsAgo(11), "a day short of a year")
        XCTAssertEqual(bucket(date(2025, 9, 26)), .yearsAgo(1))
        XCTAssertEqual(bucket(date(2024, 9, 25)), .yearsAgo(2))
        XCTAssertEqual(bucket(date(2023, 1, 1)), .yearsAgo(3))
    }

    func testFutureDateIsToday() {
        XCTAssertEqual(bucket(now.addingTimeInterval(3 * 86_400)), .today)
    }

    func testBucketTitles() {
        XCTAssertEqual(archiveBucketTitle(.today), "Today")
        XCTAssertEqual(archiveBucketTitle(.yesterday), "Yesterday")
        XCTAssertEqual(archiveBucketTitle(.daysAgo(3)), "3 days ago")
        XCTAssertEqual(archiveBucketTitle(.weeksAgo(1)), "1 week ago")
        XCTAssertEqual(archiveBucketTitle(.weeksAgo(3)), "3 weeks ago")
        XCTAssertEqual(archiveBucketTitle(.monthsAgo(1)), "1 month ago")
        XCTAssertEqual(archiveBucketTitle(.monthsAgo(5)), "5 months ago")
        XCTAssertEqual(archiveBucketTitle(.yearsAgo(1)), "1 year ago")
        XCTAssertEqual(archiveBucketTitle(.yearsAgo(2)), "2 years ago")
        XCTAssertEqual(archiveBucketTitle(.undated), "Undated")
    }

    // MARK: - Rows

    func testRowsSortNewestFirstUnderHeaders() {
        let entries = [
            entry(1, closedAt: daysAgo(3)),
            entry(2, closedAt: daysAgo(0, hour: 9)),
            entry(3, closedAt: daysAgo(0, hour: 14)),
            entry(4, closedAt: daysAgo(1)),
        ]
        let result = rows(entries)
        XCTAssertEqual(result, [
            .header(.today), .entry(entries[2]), .entry(entries[1]),
            .header(.yesterday), .entry(entries[3]),
            .header(.daysAgo(3)), .entry(entries[0]),
        ])
    }

    func testTiesBreakByIDDescending() {
        let stamp = daysAgo(0, hour: 10)
        let result = rows([entry(5, closedAt: stamp), entry(9, closedAt: stamp), entry(7, closedAt: stamp)])
        XCTAssertEqual(entryIDs(result), [9, 7, 5])
    }

    func testUndatedEntriesGoLastByIDDescending() {
        let result = rows([
            entry(1, closedAt: nil),
            entry(2, closedAt: daysAgo(400)),
            entry(3, closedAt: nil),
            entry(4, closedAt: daysAgo(0)),
        ])
        XCTAssertEqual(entryIDs(result), [4, 2, 3, 1])
        XCTAssertEqual(result.filter { if case .header = $0 { return true } else { return false } },
                       [.header(.today), .header(.yearsAgo(1)), .header(.undated)])
        XCTAssertEqual(result[result.count - 3], .header(.undated))
    }

    func testEmptyInputHasNoRows() {
        XCTAssertEqual(rows([]), [])
    }

    // MARK: - Search

    func testSearchNeedsEveryTermInTitleOrURL() {
        let entries = [
            entry(1, "Swift Forums", url: "https://forums.swift.org/t/1", closedAt: daysAgo(0)),
            entry(2, "Swift Package Index", url: "https://swiftpackageindex.com/", closedAt: daysAgo(0)),
            entry(3, "Rust Forums", url: "https://users.rust-lang.org/", closedAt: daysAgo(0)),
        ]
        XCTAssertEqual(entryIDs(rows(entries, query: "swift forums")), [1])
        XCTAssertEqual(entryIDs(rows(entries, query: "  FORUMS  ")), [3, 1], "trimmed, case-insensitive")
        XCTAssertEqual(entryIDs(rows(entries, query: "swiftpackage")), [2], "matches the URL")
        XCTAssertEqual(entryIDs(rows(entries, query: "forums rust-lang")), [3], "one term per field is enough")
        XCTAssertEqual(entryIDs(rows(entries, query: "")), [3, 2, 1])
    }

    func testSearchIgnoresDiacritics() {
        let entries = [entry(1, "Café Crème", closedAt: daysAgo(0))]
        XCTAssertEqual(entryIDs(rows(entries, query: "cafe creme")), [1])
        XCTAssertEqual(entryIDs(rows([entry(2, "Cafe", closedAt: daysAgo(0))], query: "café")), [2])
    }

    func testSearchDoesNotMatchTheScheme() {
        let entries = [entry(1, "Page", url: "https://example.com/", closedAt: daysAgo(0))]
        XCTAssertEqual(entryIDs(rows(entries, query: "https")), [])
        XCTAssertEqual(entryIDs(rows(entries, query: "example.com")), [1])
    }

    func testHeadersOnlyForBucketsWithSurvivingEntries() {
        let entries = [
            entry(1, "Keep", closedAt: daysAgo(0)),
            entry(2, "Drop", closedAt: daysAgo(1)),
            entry(3, "Keep too", closedAt: daysAgo(10)),
        ]
        XCTAssertEqual(rows(entries, query: "keep"), [
            .header(.today), .entry(entries[0]),
            .header(.weeksAgo(1)), .entry(entries[2]),
        ])
    }

    func testSpaceFilterKeepsOnlyThatSpace() {
        let entries = [
            entry(1, closedAt: daysAgo(0), space: spaceA),
            entry(2, closedAt: daysAgo(1), space: spaceB),
            entry(3, closedAt: daysAgo(2), space: spaceA),
        ]
        XCTAssertEqual(entryIDs(rows(entries, filter: spaceA)), [1, 3])
        XCTAssertEqual(rows(entries, filter: spaceB), [.header(.yesterday), .entry(entries[1])])
        XCTAssertEqual(entryIDs(rows(entries, filter: UUID())), [])
    }

    // MARK: - Display URL

    func testDisplayURL() {
        XCTAssertEqual(archiveDisplayURL("https://www.youtube.com/watch?v=abc"), "youtube.com/watch?v=abc")
        XCTAssertEqual(archiveDisplayURL("https://example.com/"), "example.com")
        XCTAssertEqual(archiveDisplayURL("http://www.example.com/"), "example.com")
        XCTAssertEqual(archiveDisplayURL("https://example.com/docs/"), "example.com/docs/",
                       "a trailing slash stays when it is not the whole path")
        XCTAssertEqual(archiveDisplayURL("https://example.com/?q=1"), "example.com/?q=1")
        XCTAssertEqual(archiveDisplayURL("detour://history"), "history")
        XCTAssertEqual(archiveDisplayURL("about:blank"), "about:blank")
        XCTAssertEqual(archiveDisplayURL(nil), "")
    }
}
