import XCTest
import GRDB
import SQLite3
@testable import Detour

/// `HistoryDatabase.searchURLs` — the profile-scoped, one-row-per-URL search
/// behind `chrome.history.search` (TASK-138).
///
/// The database has no notion of profiles: a profile is the list of space ids
/// the caller passes in. Here profile A is `["A"]` (or `["A1", "A2"]` where
/// the test is about a profile with two spaces) and profile B is `["B"]`.
/// Every value a row carries must come from the scope's own visits, because
/// the `historyURL` row it would otherwise be read from is shared by every
/// profile that visited the URL.
final class HistoryURLSearchTests: XCTestCase {

    private func makeDatabase() throws -> HistoryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(configuration: config) // in-memory
        return try HistoryDatabase(dbQueue: dbQueue)
    }

    /// Inserts a visit with a caller-chosen timestamp, the way
    /// `HistoryDatabaseTests` does: the shared row's `title`, `visitCount` and
    /// `lastVisitTime` move with every visit from anywhere, exactly like the
    /// real upsert, so a test can tell the cross-profile aggregate apart from
    /// the scope's own values. `visitTitle` nil seeds a visit as the database
    /// held them before per-visit titles existed (TASK-91).
    @discardableResult
    private func seedVisit(_ db: HistoryDatabase, url: String, title: String = "Page",
                           visitTitle: String? = nil, spaceID: String, visitTime: Double,
                           typed: Bool = false) throws -> Int64 {
        try db.dbQueue.write { conn in
            let urlID = try Int64.fetchOne(conn, sql: """
                INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                VALUES (?, ?, NULL, 1, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title = excluded.title,
                    visitCount = visitCount + 1,
                    lastVisitTime = MAX(lastVisitTime, excluded.lastVisitTime)
                RETURNING id
                """, arguments: [url, title, visitTime])!
            try conn.execute(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime, isTyped, title) VALUES (?, ?, ?, ?, ?)
                """, arguments: [urlID, spaceID, visitTime, typed, visitTitle])
            return conn.lastInsertedRowID
        }
    }

    /// A titled visit: the visit row and the shared row both get `title`.
    @discardableResult
    private func seedTitledVisit(_ db: HistoryDatabase, url: String, title: String, spaceID: String,
                                 visitTime: Double, typed: Bool = false) throws -> Int64 {
        try seedVisit(db, url: url, title: title, visitTitle: title, spaceID: spaceID,
                      visitTime: visitTime, typed: typed)
    }

    // MARK: - Isolation

    /// The leak itself: B's URL must not come back to A, whether A lists
    /// everything, searches the URL text or searches the title.
    func testAURLVisitedOnlyInAnotherProfileIsNotReturned() throws {
        let db = try makeDatabase()
        try seedTitledVisit(db, url: "https://mine.example/", title: "Mine", spaceID: "A", visitTime: 100)
        try seedTitledVisit(db, url: "https://work.example/payroll", title: "Payroll secrets",
                            spaceID: "B", visitTime: 200)

        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: ["A"], limit: 100).map(\.url),
                       ["https://mine.example/"], "listing everything")
        XCTAssertTrue(db.searchURLs(query: "payroll", spaceIDs: ["A"], limit: 100).isEmpty,
                      "the URL text matches, but A never visited it")
        XCTAssertTrue(db.searchURLs(query: "secrets", spaceIDs: ["A"], limit: 100).isEmpty,
                      "the title matches, but A never visited it")

        XCTAssertEqual(db.searchURLs(query: "payroll", spaceIDs: ["B"], limit: 100).map(\.url),
                       ["https://work.example/payroll"], "positive control: its own profile finds it")
    }

    /// A URL both profiles visited: each profile's row is built from its own
    /// visits. The shared row says 5 visits, last at 500, titled by B.
    func testAURLVisitedInBothProfilesReportsThisProfilesCountTimeAndTitle() throws {
        let db = try makeDatabase()
        let url = "https://mail.example/inbox"
        try seedTitledVisit(db, url: url, title: "Inbox - me@home", spaceID: "A", visitTime: 100)
        try seedTitledVisit(db, url: url, title: "Inbox (2) - me@home", spaceID: "A", visitTime: 200)
        try seedTitledVisit(db, url: url, title: "Inbox - me@work", spaceID: "B", visitTime: 300)
        try seedTitledVisit(db, url: url, title: "Inbox (7) - me@work", spaceID: "B", visitTime: 400)
        try seedTitledVisit(db, url: url, title: "Inbox (9) - me@work", spaceID: "B", visitTime: 500)

        let mine = try XCTUnwrap(db.searchURLs(query: "", spaceIDs: ["A"], limit: 100).first)
        XCTAssertEqual(mine.url, url)
        XCTAssertEqual(mine.visitCount, 2, "A's two visits, not the shared row's five")
        XCTAssertEqual(mine.lastVisitTime, 200, "A's own latest visit, not B's at 500")
        XCTAssertEqual(mine.title, "Inbox (2) - me@home", "the title A's own latest visit recorded")

        let theirs = try XCTUnwrap(db.searchURLs(query: "inbox", spaceIDs: ["B"], limit: 100).first)
        XCTAssertEqual(theirs.visitCount, 3)
        XCTAssertEqual(theirs.lastVisitTime, 500)
        XCTAssertEqual(theirs.title, "Inbox (9) - me@work")
        XCTAssertEqual(mine.urlID, theirs.urlID, "one shared URL row, two views of it")
    }

    func testTypedCountCountsOnlyTheScopesTypedVisits() throws {
        let db = try makeDatabase()
        let url = "https://typed.example/"
        try seedTitledVisit(db, url: url, title: "Typed", spaceID: "A", visitTime: 100, typed: true)
        try seedTitledVisit(db, url: url, title: "Typed", spaceID: "A", visitTime: 200)
        try seedTitledVisit(db, url: url, title: "Typed", spaceID: "B", visitTime: 300, typed: true)
        try seedTitledVisit(db, url: url, title: "Typed", spaceID: "B", visitTime: 400, typed: true)

        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: ["A"], limit: 10).map(\.typedCount), [1])
        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: ["B"], limit: 10).map(\.typedCount), [2])
    }

    /// A profile is every space that uses it: their visits add up, and a
    /// sibling space is not a stranger.
    func testTheScopeIsAllOfTheProfilesSpaces() throws {
        let db = try makeDatabase()
        let url = "https://shared.example/"
        try seedTitledVisit(db, url: url, title: "From space one", spaceID: "A1", visitTime: 100)
        try seedTitledVisit(db, url: url, title: "From space two", spaceID: "A2", visitTime: 200)
        try seedTitledVisit(db, url: url, title: "From the other profile", spaceID: "B", visitTime: 300)
        try seedTitledVisit(db, url: "https://two.example/", title: "Only in space two",
                            spaceID: "A2", visitTime: 50)

        let rows = db.searchURLs(query: "", spaceIDs: ["A1", "A2"], limit: 10)
        XCTAssertEqual(rows.map(\.url), [url, "https://two.example/"])
        XCTAssertEqual(rows.first?.visitCount, 2)
        XCTAssertEqual(rows.first?.lastVisitTime, 200)
        XCTAssertEqual(rows.first?.title, "From space two")
    }

    // MARK: - Own-title rule

    /// A title only another profile's visit gave the page can neither produce
    /// a result nor label one (the TASK-93 rule, here for extensions).
    func testATitleOnlyAnotherProfileGaveThePageDoesNotMatchOrLabel() throws {
        let db = try makeDatabase()
        let url = "https://docs.example/d/1"
        try seedTitledVisit(db, url: url, title: "Shopping list", spaceID: "A", visitTime: 100)
        try seedTitledVisit(db, url: url, title: "Redundancy plan", spaceID: "B", visitTime: 200)

        XCTAssertTrue(db.searchURLs(query: "redundancy", spaceIDs: ["A"], limit: 10).isEmpty,
                      "only B's title has the word")
        XCTAssertEqual(db.searchURLs(query: "shopping", spaceIDs: ["A"], limit: 10).map(\.title),
                       ["Shopping list"],
                       "A's own title still finds it although the shared title is B's now")
        XCTAssertEqual(db.searchURLs(query: "docs", spaceIDs: ["A"], limit: 10).map(\.title),
                       ["Shopping list"], "a URL-text match is labelled with A's own title")
        XCTAssertEqual(db.searchURLs(query: "redundancy", spaceIDs: ["B"], limit: 10).map(\.title),
                       ["Redundancy plan"], "positive control")
    }

    /// The row a title search returns stands for the newest in-scope visit
    /// that itself matched, as on the History page; its count and last-visit
    /// time still cover all of the scope's visits of the URL.
    func testAnEarlierOwnTitleStillMatchesAndLabelsTheRow() throws {
        let db = try makeDatabase()
        let url = "https://app.example/"
        try seedTitledVisit(db, url: url, title: "Budget 2026", spaceID: "A", visitTime: 100)
        try seedTitledVisit(db, url: url, title: "Dashboard", spaceID: "A", visitTime: 200)

        let row = try XCTUnwrap(db.searchURLs(query: "budget", spaceIDs: ["A"], limit: 10).first)
        XCTAssertEqual(row.title, "Budget 2026", "a row that matched on a title shows a title that matched")
        XCTAssertEqual(row.visitCount, 2)
        XCTAssertEqual(row.lastVisitTime, 200)
    }

    /// A visit from before per-visit titles (TASK-91) has no title of its own.
    /// The shared title stands in only while no space outside the scope has
    /// visited the URL; once one has, that title is, or may have become, the
    /// other profile's, and an extension gets none rather than theirs.
    func testALegacyVisitTakesTheSharedTitleOnlyWhileNoOtherProfileVisitedTheURL() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://solo.example/", title: "Solo legacy title",
                      spaceID: "A1", visitTime: 100)
        try seedVisit(db, url: "https://solo.example/", title: "Solo legacy title",
                      spaceID: "A2", visitTime: 150)
        try seedVisit(db, url: "https://both.example/", title: "Mine once", spaceID: "A1", visitTime: 200)
        try seedTitledVisit(db, url: "https://both.example/", title: "Theirs now", spaceID: "B", visitTime: 300)

        let rows = db.searchURLs(query: "", spaceIDs: ["A1", "A2"], limit: 10)
        XCTAssertEqual(rows.map(\.url), ["https://both.example/", "https://solo.example/"])
        XCTAssertEqual(rows.map(\.title), ["", "Solo legacy title"],
                       "a sibling space of the same profile is not a stranger; profile B is")

        XCTAssertEqual(db.searchURLs(query: "legacy", spaceIDs: ["A1", "A2"], limit: 10).map(\.url),
                       ["https://solo.example/"], "the shared title still finds the unshared URL")
        XCTAssertTrue(db.searchURLs(query: "theirs", spaceIDs: ["A1", "A2"], limit: 10).isEmpty,
                      "B's title must not find A's title-less visit")
        XCTAssertEqual(db.searchURLs(query: "both", spaceIDs: ["A1", "A2"], limit: 10).map(\.title), [""],
                       "found by its URL text, labelled with nothing")
    }

    // MARK: - Time range

    /// The range selects URLs by the scope's own visits, half-open
    /// `[from, until)`. Another profile's visit inside the range qualifies
    /// nothing, and a qualifying row still reports all of the scope's visits.
    func testTheTimeRangeQualifiesByInScopeVisitsOnly() throws {
        let db = try makeDatabase()
        let url = "https://range.example/"
        try seedTitledVisit(db, url: url, title: "Range early", spaceID: "A", visitTime: 100)
        try seedTitledVisit(db, url: url, title: "Range late", spaceID: "A", visitTime: 900)
        try seedTitledVisit(db, url: url, title: "Range other", spaceID: "B", visitTime: 500)
        try seedTitledVisit(db, url: "https://old.example/", title: "Old", spaceID: "A", visitTime: 50)

        XCTAssertTrue(db.searchURLs(query: "", spaceIDs: ["A"], from: 400, until: 600, limit: 10).isEmpty,
                      "only B visited inside the window")

        let early = db.searchURLs(query: "", spaceIDs: ["A"], from: 100, until: 200, limit: 10)
        XCTAssertEqual(early.map(\.url), [url], "a visit exactly on `from` is inside; old.example is before it")
        XCTAssertEqual(early.first?.title, "Range early", "labelled by the visit inside the window")
        XCTAssertEqual(early.first?.visitCount, 2, "the count covers all of A's visits of the URL")
        XCTAssertEqual(early.first?.lastVisitTime, 900, "and so does the last-visit time")

        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: ["A"], from: 50, until: 100, limit: 10).map(\.url),
                       ["https://old.example/"], "a visit exactly on `until` is outside")
        XCTAssertEqual(db.searchURLs(query: "range", spaceIDs: ["A"], from: 800, limit: 10).map(\.title),
                       ["Range late"])
    }

    // MARK: - Order, limit, degenerate input

    func testResultsAreNewestInScopeVisitFirstAndLimited() throws {
        let db = try makeDatabase()
        try seedTitledVisit(db, url: "https://one.example/", title: "Swift one", spaceID: "A", visitTime: 100)
        try seedTitledVisit(db, url: "https://two.example/", title: "Swift two", spaceID: "A", visitTime: 200)
        try seedTitledVisit(db, url: "https://three.example/", title: "Swift three", spaceID: "A", visitTime: 300)
        // B's later visit must not move one.example to the front for A.
        try seedTitledVisit(db, url: "https://one.example/", title: "Swift one", spaceID: "B", visitTime: 999)

        let all = ["https://three.example/", "https://two.example/", "https://one.example/"]
        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: ["A"], limit: 10).map(\.url), all)
        XCTAssertEqual(db.searchURLs(query: "swift", spaceIDs: ["A"], limit: 10).map(\.url), all)
        XCTAssertEqual(db.searchURLs(query: "swift", spaceIDs: ["A"], limit: 2).map(\.url), Array(all.prefix(2)))
        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: ["A"], limit: 1).map(\.url), Array(all.prefix(1)))
        XCTAssertTrue(db.searchURLs(query: "", spaceIDs: ["A"], limit: 0).isEmpty)
    }

    func testAnEmptyScopeReturnsNothing() throws {
        let db = try makeDatabase()
        try seedTitledVisit(db, url: "https://one.example/", title: "One", spaceID: "A", visitTime: 100)

        XCTAssertTrue(db.searchURLs(query: "", spaceIDs: [], limit: 10).isEmpty,
                      "no scope is no history, never all of it")
        XCTAssertTrue(db.searchURLs(query: "one", spaceIDs: [], limit: 10).isEmpty)
    }

    /// Text with nothing searchable in it is a search that finds nothing, not
    /// the full listing an empty text asks for.
    func testTextWithoutAnAlphanumericTokenFindsNothing() throws {
        let db = try makeDatabase()
        try seedTitledVisit(db, url: "https://one.example/", title: "One", spaceID: "A", visitTime: 100)

        XCTAssertTrue(db.searchURLs(query: "!!!", spaceIDs: ["A"], limit: 10).isEmpty)
        XCTAssertEqual(db.searchURLs(query: "   ", spaceIDs: ["A"], limit: 10).count, 1,
                       "whitespace alone is an empty text")
    }

    // MARK: - The listing (empty text, TASK-153)

    /// The same walk order whatever the scope's spaces: each space's visits
    /// are read newest first and merged, so a URL two spaces visited comes
    /// back once, at its newest visit, and visits sharing a time are ordered
    /// by id like everywhere else.
    func testTheListingMergesTheScopesSpacesNewestFirst() throws {
        let db = try makeDatabase()
        try seedTitledVisit(db, url: "https://one.example/", title: "One in A1", spaceID: "A1", visitTime: 100)
        try seedTitledVisit(db, url: "https://two.example/", title: "Two in A2", spaceID: "A2", visitTime: 200)
        try seedTitledVisit(db, url: "https://one.example/", title: "One in A2", spaceID: "A2", visitTime: 300)
        try seedTitledVisit(db, url: "https://three.example/", title: "Three in A1", spaceID: "A1", visitTime: 300)
        try seedTitledVisit(db, url: "https://four.example/", title: "Four in B", spaceID: "B", visitTime: 400)
        try seedTitledVisit(db, url: "https://two.example/", title: "Two in B", spaceID: "B", visitTime: 500)

        let rows = db.searchURLs(query: "", spaceIDs: ["A1", "A2"], limit: 10)
        XCTAssertEqual(rows.map(\.url),
                       ["https://three.example/", "https://one.example/", "https://two.example/"],
                       "three and one share a time; three's visit has the higher id")
        XCTAssertEqual(rows.map(\.title), ["Three in A1", "One in A2", "Two in A2"])
        XCTAssertEqual(rows.map(\.visitCount), [1, 2, 1])
        XCTAssertEqual(rows.map(\.lastVisitTime), [300, 300, 200])
        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: ["A2", "A1"], limit: 10), rows,
                       "the order the scope lists its spaces in changes nothing")
        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: ["A1", "A2", "A1"], limit: 10), rows,
                       "nor does naming a space twice")
        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: ["A1", "A2"], limit: 2), Array(rows.prefix(2)))
    }

    /// `limit` counts URLs, not visits: a page revisited many times is one row
    /// and does not use up the list.
    func testTheListingCountsURLsNotVisitsTowardsTheLimit() throws {
        let db = try makeDatabase()
        try seedTitledVisit(db, url: "https://first.example/", title: "First", spaceID: "A", visitTime: 10)
        try seedTitledVisit(db, url: "https://second.example/", title: "Second", spaceID: "A", visitTime: 20)
        for n in 0 ..< 60 {
            try seedTitledVisit(db, url: "https://inbox.example/", title: "Inbox (\(n))", spaceID: "A",
                                visitTime: 100 + Double(n), typed: n % 2 == 0)
        }

        let rows = db.searchURLs(query: "", spaceIDs: ["A"], limit: 3)
        XCTAssertEqual(rows.map(\.url),
                       ["https://inbox.example/", "https://second.example/", "https://first.example/"])
        XCTAssertEqual(rows.first?.title, "Inbox (59)")
        XCTAssertEqual(rows.first?.visitCount, 60)
        XCTAssertEqual(rows.first?.typedCount, 30)
        XCTAssertEqual(rows.first?.lastVisitTime, 159)
    }

    /// More rows than one statement describes at a time (the rows are fetched
    /// in batches): every URL comes back once, in order, with its own values.
    func testALongListingKeepsItsOrderAcrossBatches() throws {
        let db = try makeDatabase()
        let count = 1_234
        try db.dbQueue.write { conn in
            for i in 0 ..< count {
                try conn.execute(sql: """
                    INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                    VALUES (?, ?, NULL, 2, ?)
                    """, arguments: ["https://long.example/\(i)", "Page \(i)", Double(i)])
                let urlID = conn.lastInsertedRowID
                // An older visit from the other space of the profile, and one
                // from a stranger that is newer than both.
                for (space, time) in [("A2", Double(i) - 0.5), ("A1", Double(i)), ("B", Double(i) + 5_000)] {
                    try conn.execute(sql: """
                        INSERT INTO historyVisit (urlID, spaceID, visitTime, isTyped, title)
                        VALUES (?, ?, ?, 0, ?)
                        """, arguments: [urlID, space, time, "Page \(i) in \(space)"])
                }
            }
        }

        let rows = db.searchURLs(query: "", spaceIDs: ["A1", "A2"], limit: 5_000)
        XCTAssertEqual(rows.count, count)
        XCTAssertEqual(rows.map(\.url), (0 ..< count).reversed().map { "https://long.example/\($0)" })
        XCTAssertTrue(rows.allSatisfy { $0.visitCount == 2 }, "the profile's two visits, not the stranger's third")
        XCTAssertEqual(rows.first?.title, "Page \(count - 1) in A1")
        XCTAssertEqual(rows.last?.lastVisitTime, 0)
    }

    /// The listing is a second way to compute what the windowed select
    /// computes with no text, so the two are compared directly: random
    /// histories with few distinct times (ties within a URL, across URLs and
    /// across spaces), strangers on the same URLs, and visits with a title, an
    /// empty title or none. Rows, order, counts, times and titles must be
    /// equal for every scope, range and limit.
    func testTheListingAgreesWithTheWindowedSelect() throws {
        var rng = SplitMix(seed: 153)
        let scopes = [["A1", "A2", "A3"], ["A2"], ["A3", "A1"]]
        let ranges: [(from: Double?, until: Double?)] = [
            (nil, nil), (10, nil), (nil, 30), (10, 30), (39, 40), (100, nil), (0, nil),
        ]
        var compared = 0
        for round in 0 ..< 10 {
            let db = try makeDatabase()
            let urlCount = 1 + rng.below(30)
            for _ in 0 ..< (20 + rng.below(160)) {
                let space = rng.below(4) == 0 ? ["B", "C"][rng.below(2)] : ["A1", "A2", "A3"][rng.below(3)]
                let visitTitle: String? = [nil, "", "Own \(rng.below(4))", "Own \(rng.below(4))"][rng.below(4)]
                try seedVisit(db, url: "https://u\(rng.below(urlCount)).example/", title: "Shared \(rng.below(4))",
                              visitTitle: visitTitle, spaceID: space, visitTime: Double(rng.below(40)),
                              typed: rng.below(3) == 0)
            }
            for scope in scopes {
                for range in ranges {
                    for limit in [1, 2, 7, 1_000] {
                        let expected = try db.dbQueue.read { conn in
                            try db.windowedURLEntries(conn, text: "", tokens: [], spaceIDs: scope,
                                                      from: range.from, until: range.until, limit: limit)
                        }
                        XCTAssertEqual(db.searchURLs(query: "", spaceIDs: scope, from: range.from,
                                                     until: range.until, limit: limit),
                                       expected,
                                       "round \(round), scope \(scope), range \(range), limit \(limit)")
                        compared += expected.count
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 1_000, "the comparison must not be between empty lists")
    }

    /// What the task is about: listing the ten most recently visited URLs must
    /// cost what ten URLs cost, not what the profile's whole history costs.
    /// Counted in SQLite virtual-machine steps rather than timed, so the test
    /// is deterministic: a history ten times the size may not take more than
    /// twice the work. Windowing over every in-scope visit took ten times.
    func testListingTheNewestURLsDoesNotWalkTheWholeScope() throws {
        func steps(visits: Int) throws -> Int {
            let db = try makeDatabase()
            let urls = visits / 5
            try db.dbQueue.write { conn in
                for i in 0 ..< urls {
                    try conn.execute(sql: """
                        INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                        VALUES (?, ?, NULL, 5, 0)
                        """, arguments: ["https://scale.example/\(i)", "Scale \(i)"])
                }
                for n in 0 ..< visits {
                    let index = (n * 7_919) % urls
                    // Every fifth visit has no title of its own (TASK-91).
                    try conn.execute(sql: """
                        INSERT INTO historyVisit (urlID, spaceID, visitTime, isTyped, title)
                        VALUES (?, ?, ?, 0, ?)
                        """, arguments: [index + 1, ["A1", "A2", "B"][n % 3], Double(n),
                                         n % 5 == 0 ? nil : "Scale \(index)"])
                }
            }
            var rows = 0
            let count = countingSteps(db) { rows = db.searchURLs(query: "", spaceIDs: ["A1", "A2"], limit: 10).count }
            XCTAssertEqual(rows, 10)
            return count
        }

        let small = try steps(visits: 1_500)
        let large = try steps(visits: 15_000)
        XCTAssertGreaterThan(small, 0, "the counter must have seen the query")
        XCTAssertLessThanOrEqual(large, small * 2,
                                 "10 rows of a 15,000-visit history took \(large) steps, of a 1,500-visit one \(small)")
    }

    /// The SQLite virtual-machine steps `body` makes the database run, counted
    /// by a progress handler on the queue's one connection.
    private func countingSteps(_ db: HistoryDatabase, _ body: () -> Void) -> Int {
        let period: Int32 = 10
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        defer { counter.deallocate() }
        db.dbQueue.inDatabase { conn in
            sqlite3_progress_handler(conn.sqliteConnection, period, { context in
                context?.assumingMemoryBound(to: Int.self).pointee += 1
                return 0
            }, counter)
        }
        body()
        db.dbQueue.inDatabase { conn in sqlite3_progress_handler(conn.sqliteConnection, 0, nil, nil) }
        return counter.pointee * Int(period)
    }

    /// Deterministic random numbers for the differential test.
    private struct SplitMix {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func below(_ bound: Int) -> Int {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
    }

    /// FTS5 reserves AND / OR / NOT; every MATCH this builds quotes its tokens
    /// (TASK-94).
    func testFTSKeywordTokensAreSearchable() throws {
        let db = try makeDatabase()
        try seedTitledVisit(db, url: "https://found.example/page", title: "Found it", spaceID: "A", visitTime: 100)

        for query in ["NOT found", "OR found", "AND found", "NEAR found"] {
            XCTAssertEqual(db.searchURLs(query: query, spaceIDs: ["A"], limit: 10).map(\.url),
                           ["https://found.example/page"], "searchURLs(\(query))")
        }
    }

    /// Folding agrees with the History page: "strasse" finds "Straße".
    func testTitleMatchingFoldsLikeTheHistoryPage() throws {
        let db = try makeDatabase()
        try seedTitledVisit(db, url: "https://maps.example/x", title: "Hauptstraße 5", spaceID: "A", visitTime: 100)

        XCTAssertEqual(db.searchURLs(query: "hauptstrasse", spaceIDs: ["A"], limit: 10).map(\.title),
                       ["Hauptstraße 5"])
        XCTAssertEqual(db.searchURLs(query: "hauptstrasse", spaceIDs: ["A"], limit: 10).map(\.url),
                       db.searchVisits(query: "hauptstrasse", spaceIDs: ["A"], limit: 10).map(\.url))
    }
}
