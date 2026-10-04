import XCTest
import GRDB
@testable import Detour

/// TASK-152: the favicon lookup an extension reaches
/// (`HistoryDatabase.faviconURL(for:visitedInSpaces:)`) answers only for pages
/// visited in the spaces it is given.
///
/// `historyURL` holds one row per URL for every profile, so the row existing —
/// and having an icon — says only that *someone* visited the page. The scoped
/// lookup therefore asks `historyVisit` first: a URL (or, for the same-host
/// fallback, a host) with no visit in scope gets the answer a URL nobody
/// visited gets.
final class FaviconLookupScopeTests: XCTestCase {

    private let spaceA = "space-a"
    private let spaceA2 = "space-a2"
    private let spaceB = "space-b"

    private func makeDatabase() throws -> HistoryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config)) // in-memory
    }

    /// One visit, with the shared `historyURL` row moved the way the real
    /// upsert moves it: the latest visit from anywhere sets the icon.
    private func seedVisit(_ db: HistoryDatabase, url: String, favicon: String?, space: String,
                           visitTime: Double) throws {
        try db.dbQueue.write { conn in
            let urlID = try Int64.fetchOne(conn, sql: """
                INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                VALUES (?, '', ?, 1, ?)
                ON CONFLICT(url) DO UPDATE SET
                    faviconURL = excluded.faviconURL,
                    visitCount = visitCount + 1,
                    lastVisitTime = MAX(lastVisitTime, excluded.lastVisitTime)
                RETURNING id
                """, arguments: [url, favicon, visitTime])!
            try conn.execute(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime, isTyped, title) VALUES (?, ?, ?, 0, '')
                """, arguments: [urlID, space, visitTime])
        }
    }

    // MARK: - Exact URL

    func testAnExactURLVisitedInScopeAnswersWithItsIcon() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.example/notes", favicon: "https://a.example/icon.png",
                      space: spaceA, visitTime: 100)

        XCTAssertEqual(db.faviconURL(for: "https://a.example/notes", visitedInSpaces: [spaceA]),
                       "https://a.example/icon.png")
    }

    /// The leak: the page was visited, and its icon recorded, by another
    /// profile's space only.
    func testAURLVisitedOnlyOutOfScopeAnswersLikeAURLNeverVisited() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://b.example/payroll", favicon: "https://b.example/icon.png",
                      space: spaceB, visitTime: 100)

        XCTAssertNil(db.faviconURL(for: "https://b.example/payroll", visitedInSpaces: [spaceA]),
                     "a page only another profile visited must not answer")
        XCTAssertNil(db.faviconURL(for: "https://never.example/", visitedInSpaces: [spaceA]))
        // POSITIVE: the same row answers the profile that did visit it.
        XCTAssertEqual(db.faviconURL(for: "https://b.example/payroll", visitedInSpaces: [spaceB]),
                       "https://b.example/icon.png")
    }

    func testAURLVisitedInAnySpaceOfTheScopeAnswers() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.example/notes", favicon: "https://a.example/icon.png",
                      space: spaceA2, visitTime: 100)

        XCTAssertEqual(db.faviconURL(for: "https://a.example/notes", visitedInSpaces: [spaceA, spaceA2]),
                       "https://a.example/icon.png")
        XCTAssertNil(db.faviconURL(for: "https://a.example/notes", visitedInSpaces: [spaceA]))
    }

    func testAnEmptyScopeAnswersNothing() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.example/notes", favicon: "https://a.example/icon.png",
                      space: spaceA, visitTime: 100)

        XCTAssertNil(db.faviconURL(for: "https://a.example/notes", visitedInSpaces: []))
    }

    /// A URL both profiles visited answers both, with the URL's one icon: which
    /// icon a URL has is shared (`historyURL.faviconURL`), whether the lookup
    /// answers is not.
    func testAURLVisitedByBothAnswersBoth() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://shared.example/inbox", favicon: "https://shared.example/old.png",
                      space: spaceA, visitTime: 100)
        try seedVisit(db, url: "https://shared.example/inbox", favicon: "https://shared.example/new.png",
                      space: spaceB, visitTime: 200)

        XCTAssertEqual(db.faviconURL(for: "https://shared.example/inbox", visitedInSpaces: [spaceA]),
                       "https://shared.example/new.png")
        XCTAssertEqual(db.faviconURL(for: "https://shared.example/inbox", visitedInSpaces: [spaceB]),
                       "https://shared.example/new.png")
    }

    // MARK: - Same-host fallback

    func testTheHostFallbackAnswersFromAnInScopePageOfTheSameHost() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.example/notes", favicon: "https://a.example/icon.png",
                      space: spaceA, visitTime: 100)

        XCTAssertEqual(db.faviconURL(for: "https://a.example/never-opened", visitedInSpaces: [spaceA]),
                       "https://a.example/icon.png")
        XCTAssertEqual(db.faviconURL(for: "http://a.example/never-opened", visitedInSpaces: [spaceA]),
                       "https://a.example/icon.png", "the fallback is by host, either web scheme")
    }

    /// The leak through the fallback: nothing on the host was visited in scope,
    /// so a page of it must not answer with another profile's icon.
    func testTheHostFallbackIgnoresPagesVisitedOnlyOutOfScope() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://b.example/payroll", favicon: "https://b.example/icon.png",
                      space: spaceB, visitTime: 100)

        XCTAssertNil(db.faviconURL(for: "https://b.example/", visitedInSpaces: [spaceA]),
                     "the host was visited by another profile only")
        XCTAssertEqual(db.faviconURL(for: "https://b.example/", visitedInSpaces: [spaceB]),
                       "https://b.example/icon.png")
    }

    /// Of several in-scope pages on the host the most recently visited *in
    /// scope* wins; a newer page that only another profile visited is not a
    /// candidate, however recent.
    func testTheHostFallbackPicksTheNewestInScopeVisit() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://site.example/a-old", favicon: "https://site.example/a-old.png",
                      space: spaceA, visitTime: 100)
        try seedVisit(db, url: "https://site.example/a-new", favicon: "https://site.example/a-new.png",
                      space: spaceA, visitTime: 200)
        try seedVisit(db, url: "https://site.example/b-newest", favicon: "https://site.example/b-newest.png",
                      space: spaceB, visitTime: 300)

        XCTAssertEqual(db.faviconURL(for: "https://site.example/other", visitedInSpaces: [spaceA]),
                       "https://site.example/a-new.png")
    }

    /// An exact row with no icon falls through to the host, as before.
    func testAnExactURLWithoutAnIconFallsBackToItsHost() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.example/plain", favicon: nil, space: spaceA, visitTime: 200)
        try seedVisit(db, url: "https://a.example/notes", favicon: "https://a.example/icon.png",
                      space: spaceA, visitTime: 100)

        XCTAssertEqual(db.faviconURL(for: "https://a.example/plain", visitedInSpaces: [spaceA]),
                       "https://a.example/icon.png")
    }

    /// "Same host" is the host, not a string prefix: `a.example.evil.test` and
    /// `a.examplexyz.test` are other sites, a port and a bare origin are not.
    func testTheHostFallbackStopsAtTheEndOfTheHost() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.example.evil.test/", favicon: "https://evil.test/icon.png",
                      space: spaceA, visitTime: 300)
        try seedVisit(db, url: "https://a.examplexyz.test/", favicon: "https://xyz.test/icon.png",
                      space: spaceA, visitTime: 200)

        XCTAssertNil(db.faviconURL(for: "https://a.example/", visitedInSpaces: [spaceA]),
                     "a longer host that merely starts with this one is another site")

        try seedVisit(db, url: "https://a.example:8443/admin", favicon: "https://a.example:8443/icon.png",
                      space: spaceA, visitTime: 100)
        XCTAssertEqual(db.faviconURL(for: "https://a.example/", visitedInSpaces: [spaceA]),
                       "https://a.example:8443/icon.png", "a port is the same host")
        XCTAssertEqual(db.faviconURL(for: "https://A.Example/", visitedInSpaces: [spaceA]),
                       "https://a.example:8443/icon.png", "hosts compare without case")
    }

    /// The unscoped lookup (the History page's own rows) shares the host rule.
    func testTheUnscopedLookupUsesTheSameHostRule() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.example.evil.test/", favicon: "https://evil.test/icon.png",
                      space: spaceB, visitTime: 300)
        XCTAssertNil(db.faviconURLInAnyProfile(for: "https://a.example/"))

        try seedVisit(db, url: "https://a.example/notes", favicon: "https://a.example/icon.png",
                      space: spaceB, visitTime: 100)
        XCTAssertEqual(db.faviconURLInAnyProfile(for: "https://a.example/other"), "https://a.example/icon.png")
    }

    /// Not a web URL, or not a URL: nothing to look up by host.
    func testAPageURLWithoutAHostAnswersNothing() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.example/notes", favicon: "https://a.example/icon.png",
                      space: spaceA, visitTime: 100)

        XCTAssertNil(db.faviconURL(for: "", visitedInSpaces: [spaceA]))
        XCTAssertNil(db.faviconURL(for: "not a url", visitedInSpaces: [spaceA]))
        XCTAssertNil(db.faviconURL(for: "%", visitedInSpaces: [spaceA]))
    }
}
