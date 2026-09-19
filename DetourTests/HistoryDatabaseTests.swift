import XCTest
import GRDB
@testable import Detour

final class HistoryDatabaseTests: XCTestCase {

    private func makeDatabase() throws -> HistoryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(configuration: config) // in-memory
        return try HistoryDatabase(dbQueue: dbQueue)
    }

    /// Inserts a visit with a caller-chosen timestamp. `recordVisit` stamps
    /// `Date()` and writes asynchronously, so the History page tests seed rows
    /// directly (the same upsert, with an explicit `visitTime`) and get stable
    /// ordering. `lastVisitTime` keeps the newest time across *all* spaces,
    /// like the real one, so the cross-profile tests can tell the aggregate
    /// apart from the in-scope visit time.
    @discardableResult
    private func seedVisit(_ db: HistoryDatabase,
                           url: String,
                           title: String = "Page",
                           faviconURL: String? = nil,
                           spaceID: String,
                           visitTime: Double) throws -> Int64 {
        try db.dbQueue.write { conn in
            let urlID = try Int64.fetchOne(conn, sql: """
                INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                VALUES (?, ?, ?, 1, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title = excluded.title,
                    faviconURL = excluded.faviconURL,
                    visitCount = visitCount + 1,
                    lastVisitTime = MAX(lastVisitTime, excluded.lastVisitTime)
                RETURNING id
                """, arguments: [url, title, faviconURL, visitTime])!
            try conn.execute(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime) VALUES (?, ?, ?)
                """, arguments: [urlID, spaceID, visitTime])
            return conn.lastInsertedRowID
        }
    }

    /// Walks every page of `visits` with the given page size, following the
    /// keyset cursor, and returns the concatenation.
    private func walkVisits(_ db: HistoryDatabase, spaceIDs: [String], pageSize: Int) -> [HistoryVisitEntry] {
        var all: [HistoryVisitEntry] = []
        var cursor: HistoryCursor?
        while true {
            let page = db.visits(spaceIDs: spaceIDs, before: cursor, limit: pageSize)
            if page.isEmpty { break }
            all.append(contentsOf: page)
            cursor = HistoryCursor(after: page[page.count - 1])
            if all.count > 500 {
                XCTFail("Pagination did not terminate")
                break
            }
        }
        return all
    }

    // MARK: - bestURLCompletion

    func testBestURLCompletionMatchesPrefixIgnoringSchemeAndWWW() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://www.youtube.com/", title: "YouTube", faviconURL: nil, spaceID: "space1")

        let match = db.bestURLCompletion(prefix: "youtu", spaceID: "space1")

        XCTAssertEqual(match?.url, "https://www.youtube.com/")
    }

    func testBestURLCompletionPrefersTypedVisits() throws {
        let db = try makeDatabase()
        // 3 link visits (3 × 100 = 300) vs 2 typed visits (2 × 2.0 × 100 = 400):
        // the typed bonus outweighs the higher visit count.
        for _ in 1...3 {
            db.recordVisit(url: "https://apple.com", title: "Apple", faviconURL: nil, spaceID: "space1")
        }
        for _ in 1...2 {
            db.recordVisit(url: "https://appfigures.com", title: "Appfigures", faviconURL: nil, spaceID: "space1", typed: true)
        }

        let match = db.bestURLCompletion(prefix: "ap", spaceID: "space1")

        XCTAssertEqual(match?.url, "https://appfigures.com")
    }

    func testBestURLCompletionPrefersRecentOverOldFrequent() throws {
        let db = try makeDatabase()
        // 5 visits ~60 days ago (5 × 30 = 150) vs 2 today (2 × 100 = 200):
        // recency decay outweighs the higher visit count.
        for _ in 1...5 {
            db.recordVisit(url: "https://apple.com", title: "Apple", faviconURL: nil, spaceID: "space1")
        }
        for _ in 1...2 {
            db.recordVisit(url: "https://appfigures.com", title: "Appfigures", faviconURL: nil, spaceID: "space1")
        }
        let sixtyDaysAgo = Date().timeIntervalSince1970 - 60 * 24 * 3600
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                UPDATE historyVisit SET visitTime = ?
                WHERE urlID = (SELECT id FROM historyURL WHERE url = 'https://apple.com')
                """, arguments: [sixtyDaysAgo])
        }

        let match = db.bestURLCompletion(prefix: "ap", spaceID: "space1")

        XCTAssertEqual(match?.url, "https://appfigures.com")
    }

    func testBestURLCompletionIgnoresVisitsOlderThan90Days() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://apple.com", title: "Apple", faviconURL: nil, spaceID: "space1")
        let hundredDaysAgo = Date().timeIntervalSince1970 - 100 * 24 * 3600
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                UPDATE historyVisit SET visitTime = ?
                WHERE urlID = (SELECT id FROM historyURL WHERE url = 'https://apple.com')
                """, arguments: [hundredDaysAgo])
        }

        let match = db.bestURLCompletion(prefix: "ap", spaceID: "space1")

        XCTAssertNil(match, "Visits older than 90 days must not produce a completion")
    }

    // MARK: - recordVisit

    func testRecordVisitStoresTypedFlag() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1", typed: true)
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")

        try db.dbQueue.read { conn in
            let typedCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyVisit WHERE isTyped = 1")
            XCTAssertEqual(typedCount, 1)
            let total = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyVisit")
            XCTAssertEqual(total, 2)
        }
    }

    func testRecordVisitCreatesURLAndVisit() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com", title: "Example", faviconURL: nil, spaceID: "space1")

        try db.dbQueue.read { conn in
            let urlCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyURL")
            XCTAssertEqual(urlCount, 1)

            let visitCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyVisit")
            XCTAssertEqual(visitCount, 1)

            let row = try Row.fetchOne(conn, sql: "SELECT * FROM historyURL")!
            XCTAssertEqual(row["url"] as String, "https://example.com")
            XCTAssertEqual(row["title"] as String, "Example")
            XCTAssertEqual(row["visitCount"] as Int, 1)
        }
    }

    func testRepeatVisitIncrementsCount() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com", title: "Example", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://example.com", title: "Example - Updated", faviconURL: "https://example.com/favicon.ico", spaceID: "space1")

        try db.dbQueue.read { conn in
            let urlCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyURL")
            XCTAssertEqual(urlCount, 1, "Should still be one URL row")

            let visitCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyVisit")
            XCTAssertEqual(visitCount, 2, "Should have two visit rows")

            let row = try Row.fetchOne(conn, sql: "SELECT * FROM historyURL")!
            XCTAssertEqual(row["visitCount"] as Int, 2)
            XCTAssertEqual(row["title"] as String, "Example - Updated")
            XCTAssertEqual(row["faviconURL"] as String, "https://example.com/favicon.ico")
        }
    }

    func testDifferentURLsCreateSeparateRows() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://b.com", title: "B", faviconURL: nil, spaceID: "space1")

        try db.dbQueue.read { conn in
            let urlCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyURL")
            XCTAssertEqual(urlCount, 2)
        }
    }

    func testVisitRecordsSpaceID() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com", title: "Example", faviconURL: nil, spaceID: "space-abc")

        try db.dbQueue.read { conn in
            let spaceID = try String.fetchOne(conn, sql: "SELECT spaceID FROM historyVisit")
            XCTAssertEqual(spaceID, "space-abc")
        }
    }

    // MARK: - expireOldVisits

    func testExpireDeletesOldVisitsAndOrphanedURLs() throws {
        let db = try makeDatabase()
        let now = Date().timeIntervalSince1970
        let old = now - (91 * 24 * 3600) // 91 days ago

        // Insert an old visit directly
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT INTO historyURL (url, title, visitCount, lastVisitTime)
                VALUES ('https://old.com', 'Old', 1, ?)
                """, arguments: [old])
            let urlID = conn.lastInsertedRowID
            try conn.execute(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime)
                VALUES (?, 'space1', ?)
                """, arguments: [urlID, old])
        }

        // Insert a recent visit
        db.recordVisit(url: "https://recent.com", title: "Recent", faviconURL: nil, spaceID: "space1")

        db.expireOldVisits()

        try db.dbQueue.read { conn in
            let urls = try String.fetchAll(conn, sql: "SELECT url FROM historyURL")
            XCTAssertEqual(urls, ["https://recent.com"])

            let visitCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyVisit")
            XCTAssertEqual(visitCount, 1)
        }
    }

    // MARK: - recentHistory

    func testRecentHistoryReturnsEntriesOrderedByVisitTime() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")
        Thread.sleep(forTimeInterval: 0.01)
        db.recordVisit(url: "https://b.com", title: "B", faviconURL: nil, spaceID: "space1")
        Thread.sleep(forTimeInterval: 0.01)
        db.recordVisit(url: "https://c.com", title: "C", faviconURL: nil, spaceID: "space1")

        let results = db.recentHistory(spaceID: "space1")
        XCTAssertEqual(results.map(\.url), ["https://c.com", "https://b.com", "https://a.com"])
    }

    func testRecentHistoryRespectsLimit() throws {
        let db = try makeDatabase()
        for i in 1...5 {
            db.recordVisit(url: "https://\(i).com", title: "\(i)", faviconURL: nil, spaceID: "space1")
        }

        let results = db.recentHistory(spaceID: "space1", limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    func testRecentHistoryFiltersbySpaceID() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://b.com", title: "B", faviconURL: nil, spaceID: "space2")

        let results = db.recentHistory(spaceID: "space1")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://a.com")
    }

    func testRecentHistoryDeduplicatesURL() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")

        let results = db.recentHistory(spaceID: "space1")
        XCTAssertEqual(results.count, 1)
    }

    func testRecentHistoryReturnsEmptyForUnknownSpace() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")

        let results = db.recentHistory(spaceID: "space-nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - searchHistory

    func testSearchHistoryMatchesTitle() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com", title: "Swift Programming", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://other.com", title: "Cooking Recipes", faviconURL: nil, spaceID: "space1")

        let results = db.searchHistory(query: "swift", spaceID: "space1")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://example.com")
    }

    func testSearchHistoryMatchesURL() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://github.com/swift", title: "GitHub", faviconURL: nil, spaceID: "space1")

        let results = db.searchHistory(query: "github", spaceID: "space1")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchHistoryPrefixMatch() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com", title: "Programming Guide", faviconURL: nil, spaceID: "space1")

        let results = db.searchHistory(query: "prog", spaceID: "space1")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchHistoryMultipleTokens() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "Swift Programming Guide", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://b.com", title: "Swift Reference", faviconURL: nil, spaceID: "space1")

        // OR matching: both entries match "swift", but the one with both tokens ranks first
        let results = db.searchHistory(query: "swift guide", spaceID: "space1")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.url, "https://a.com")
    }

    func testSearchHistoryFiltersbySpaceID() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "Swift", faviconURL: nil, spaceID: "space1")
        db.recordVisit(url: "https://b.com", title: "Swift", faviconURL: nil, spaceID: "space2")

        let results = db.searchHistory(query: "swift", spaceID: "space1")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://a.com")
    }

    func testSearchHistoryRespectsLimit() throws {
        let db = try makeDatabase()
        for i in 1...10 {
            db.recordVisit(url: "https://swift\(i).com", title: "Swift \(i)", faviconURL: nil, spaceID: "space1")
        }

        let results = db.searchHistory(query: "swift", spaceID: "space1", limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    func testSearchHistoryReturnsEmptyForEmptyQuery() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")

        let results = db.searchHistory(query: "", spaceID: "space1")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchHistoryReturnsEmptyForWhitespaceQuery() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "A", faviconURL: nil, spaceID: "space1")

        let results = db.searchHistory(query: "   ", spaceID: "space1")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchHistorySanitizesSpecialChars() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "Test", faviconURL: nil, spaceID: "space1")

        // Should not crash with FTS5 special characters
        let results = db.searchHistory(query: "test\"*'()", spaceID: "space1")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchHistoryDotsInQuery() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://github.com", title: "GitHub", faviconURL: nil, spaceID: "space1")

        // Dots caused the original FTS5 syntax error bug — splits into ["github", "com"]
        let results = db.searchHistory(query: "github.com", spaceID: "space1")
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.url, "https://github.com")
    }

    func testSearchHistoryColonsAndSlashes() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com/page", title: "Example Page", faviconURL: nil, spaceID: "space1")

        // Splits into ["https", "example"] — both are valid tokens
        let results = db.searchHistory(query: "https://example", spaceID: "space1")
        XCTAssertFalse(results.isEmpty)
    }

    func testSearchHistoryHyphens() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://stackoverflow.com", title: "Stack Overflow", faviconURL: nil, spaceID: "space1")

        let results = db.searchHistory(query: "stack-overflow", spaceID: "space1")
        XCTAssertFalse(results.isEmpty, "Should match on 'stack' and 'overflow' tokens")
    }

    func testSearchHistoryFTSOperators() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://cplusplus.com", title: "C++ Reference test", faviconURL: nil, spaceID: "space1")

        // +, ~, ^, {, } are FTS5 operators that must be stripped
        let results = db.searchHistory(query: "C++ {test}", spaceID: "space1")
        XCTAssertFalse(results.isEmpty, "Should match on 'C' and 'test' tokens")
    }

    func testSearchHistoryAllSpecialInput() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com", title: "Example", faviconURL: nil, spaceID: "space1")

        // No alphanumeric tokens remain — should return empty, not crash
        let results = db.searchHistory(query: "...", spaceID: "space1")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchHistoryMixedSpecialAndAlpha() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://github.com/repo", title: "GitHub Repo", faviconURL: nil, spaceID: "space1")

        // Splits into ["site", "github", "com", "repo"] — OR matching means
        // "site" doesn't block results; "github", "com", "repo" all match
        let results = db.searchHistory(query: "site:github.com/repo", spaceID: "space1")
        XCTAssertFalse(results.isEmpty, "Should match on 'github', 'com', 'repo' tokens")
    }

    func testSearchHistoryIncludesFaviconURL() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://a.com", title: "Test", faviconURL: "https://a.com/favicon.ico", spaceID: "space1")

        let results = db.searchHistory(query: "test", spaceID: "space1")
        XCTAssertEqual(results.first?.faviconURL, "https://a.com/favicon.ico")
    }

    // MARK: - faviconURL(for:)

    func testFaviconURLExactMatch() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com/page", title: "Page", faviconURL: "https://example.com/favicon.ico", spaceID: "space1")

        let result = db.faviconURL(for: "https://example.com/page")
        XCTAssertEqual(result, "https://example.com/favicon.ico")
    }

    func testFaviconURLHostFallback() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com/other", title: "Other", faviconURL: "https://example.com/fav.png", spaceID: "space1")

        // Different path, same host — should match via host fallback
        let result = db.faviconURL(for: "https://example.com/page")
        XCTAssertEqual(result, "https://example.com/fav.png")
    }

    func testFaviconURLReturnsNilWhenNoFavicon() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com", title: "Example", faviconURL: nil, spaceID: "space1")

        let result = db.faviconURL(for: "https://example.com")
        XCTAssertNil(result)
    }

    func testFaviconURLReturnsNilForUnknownHost() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com", title: "Example", faviconURL: "https://example.com/fav.ico", spaceID: "space1")

        let result = db.faviconURL(for: "https://unknown.com/page")
        XCTAssertNil(result)
    }

    func testFaviconURLPrefersMostRecentForHost() throws {
        let db = try makeDatabase()
        db.recordVisit(url: "https://example.com/old", title: "Old", faviconURL: "https://example.com/old.ico", spaceID: "space1")
        db.recordVisit(url: "https://example.com/new", title: "New", faviconURL: "https://example.com/new.ico", spaceID: "space1")

        // Host fallback should return the most recent entry's favicon
        let result = db.faviconURL(for: "https://example.com/unknown")
        XCTAssertEqual(result, "https://example.com/new.ico")
    }

    // MARK: - expireOldVisits

    func testExpireKeepsURLWithRecentVisits() throws {
        let db = try makeDatabase()
        let now = Date().timeIntervalSince1970
        let old = now - (91 * 24 * 3600)

        // Insert a URL with both an old and a recent visit
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT INTO historyURL (url, title, visitCount, lastVisitTime)
                VALUES ('https://example.com', 'Example', 2, ?)
                """, arguments: [now])
            let urlID = conn.lastInsertedRowID
            try conn.execute(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime) VALUES (?, 'space1', ?);
                INSERT INTO historyVisit (urlID, spaceID, visitTime) VALUES (?, 'space1', ?);
                """, arguments: [urlID, old, urlID, now])
        }

        db.expireOldVisits()

        try db.dbQueue.read { conn in
            let urlCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyURL")
            XCTAssertEqual(urlCount, 1, "URL should be kept because it has a recent visit")

            let visitCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyVisit")
            XCTAssertEqual(visitCount, 1, "Only the recent visit should remain")
        }
    }

    // MARK: - visits(spaceIDs:before:limit:)

    func testVisitsScopedToGivenSpaces() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.com", spaceID: "A", visitTime: 100)
        try seedVisit(db, url: "https://b.com", spaceID: "B", visitTime: 200)

        XCTAssertEqual(db.visits(spaceIDs: ["A"], limit: 10).map(\.url), ["https://a.com"])
        XCTAssertEqual(db.visits(spaceIDs: ["A", "B"], limit: 10).map(\.url),
                       ["https://b.com", "https://a.com"])
        XCTAssertTrue(db.visits(spaceIDs: [], limit: 10).isEmpty)
    }

    func testVisitsReturnsOneEntryPerVisitNewestFirst() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.com", spaceID: "A", visitTime: 100)
        try seedVisit(db, url: "https://a.com", spaceID: "A", visitTime: 300)
        try seedVisit(db, url: "https://b.com", spaceID: "A", visitTime: 200)

        let results = db.visits(spaceIDs: ["A"], limit: 10)
        XCTAssertEqual(results.map(\.url), ["https://a.com", "https://b.com", "https://a.com"])
        XCTAssertEqual(results.map(\.visitTime), [300, 200, 100])
    }

    func testVisitsCarryPageMetadata() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.com", title: "Alpha", faviconURL: "https://a.com/f.ico",
                      spaceID: "A", visitTime: 100)

        let entry = db.visits(spaceIDs: ["A"], limit: 10).first
        XCTAssertEqual(entry?.title, "Alpha")
        XCTAssertEqual(entry?.faviconURL, "https://a.com/f.ico")
        XCTAssertNotNil(entry?.visitID)
    }

    /// The URL row is shared by every profile: its `lastVisitTime` is whenever
    /// *anyone* last visited. A profile-scoped query must report its own visit.
    func testVisitsNeverLeakAnotherProfilesVisitTime() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://shared.com", spaceID: "A", visitTime: 100)
        try seedVisit(db, url: "https://shared.com", spaceID: "B", visitTime: 900)

        let results = db.visits(spaceIDs: ["A"], limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.visitTime, 100, "Must be A's visit, not B's and not lastVisitTime")

        try db.dbQueue.read { conn in
            let aggregate = try Double.fetchOne(conn, sql: "SELECT lastVisitTime FROM historyURL")
            XCTAssertEqual(aggregate, 900, "Precondition: the shared row does aggregate across profiles")
        }
    }

    func testSearchVisitsNeverLeakAnotherProfilesVisitTime() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://shared.com", title: "Shared Page", spaceID: "A", visitTime: 100)
        try seedVisit(db, url: "https://shared.com", title: "Shared Page", spaceID: "B", visitTime: 900)

        let results = db.searchVisits(query: "shared", spaceIDs: ["A"], limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.visitTime, 100)
    }

    func testVisitsPaginationCoversEveryRowExactlyOnce() throws {
        let db = try makeDatabase()
        for i in 1...17 {
            try seedVisit(db, url: "https://\(i).com", spaceID: "A", visitTime: Double(i))
        }

        let full = db.visits(spaceIDs: ["A"], limit: 100)
        XCTAssertEqual(full.count, 17)

        let walked = walkVisits(db, spaceIDs: ["A"], pageSize: 5)
        XCTAssertEqual(walked, full, "Paged walk must equal the single-shot ordering")
        XCTAssertEqual(Set(walked.map(\.visitID)).count, 17, "No duplicates across pages")
    }

    /// Identical timestamps are common (a redirect chain lands in the same
    /// millisecond); the visit id has to break the tie or paging loops or skips.
    func testVisitsPaginationHandlesIdenticalVisitTimes() throws {
        let db = try makeDatabase()
        for i in 1...9 {
            // Three groups of three visits sharing a timestamp.
            try seedVisit(db, url: "https://\(i).com", spaceID: "A", visitTime: Double((i - 1) / 3))
        }

        let full = db.visits(spaceIDs: ["A"], limit: 100)
        XCTAssertEqual(full.count, 9)

        let walked = walkVisits(db, spaceIDs: ["A"], pageSize: 2)
        XCTAssertEqual(walked, full)
        XCTAssertEqual(Set(walked.map(\.visitID)).count, 9)
    }

    func testVisitsPaginationIsUndisturbedByANewerVisit() throws {
        let db = try makeDatabase()
        for i in 1...10 {
            try seedVisit(db, url: "https://\(i).com", spaceID: "A", visitTime: Double(i))
        }

        let firstPage = db.visits(spaceIDs: ["A"], limit: 4)
        XCTAssertEqual(firstPage.map(\.visitTime), [10, 9, 8, 7])

        // A visit arrives (newer than anything) between page fetches.
        try seedVisit(db, url: "https://new.com", spaceID: "A", visitTime: 1000)

        let secondPage = db.visits(spaceIDs: ["A"], before: HistoryCursor(after: firstPage[3]), limit: 4)
        XCTAssertEqual(secondPage.map(\.visitTime), [6, 5, 4, 3],
                       "Keyset paging must not shift later pages when new rows land at the head")
    }

    func testVisitsLimitClamping() throws {
        let db = try makeDatabase()
        try db.dbQueue.write { conn in
            for i in 1...520 {
                try conn.execute(sql: """
                    INSERT INTO historyURL (url, title, visitCount, lastVisitTime)
                    VALUES (?, 'P', 1, ?)
                    """, arguments: ["https://\(i).com", Double(i)])
                try conn.execute(sql: """
                    INSERT INTO historyVisit (urlID, spaceID, visitTime) VALUES (?, 'A', ?)
                    """, arguments: [conn.lastInsertedRowID, Double(i)])
            }
        }

        XCTAssertEqual(db.visits(spaceIDs: ["A"], limit: 10_000).count, 500, "Clamped to the page cap")
        XCTAssertEqual(db.visits(spaceIDs: ["A"], limit: 0).count, 1, "Clamped up to one row")
        XCTAssertEqual(db.visits(spaceIDs: ["A"], limit: -5).count, 1)
    }

    // MARK: - searchVisits(query:spaceIDs:before:limit:)

    func testSearchVisitsMatchesTitleAndURL() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://example.com", title: "Swift Programming", spaceID: "A", visitTime: 100)
        try seedVisit(db, url: "https://github.com/repo", title: "Repo", spaceID: "A", visitTime: 200)
        try seedVisit(db, url: "https://other.com", title: "Cooking", spaceID: "A", visitTime: 300)

        XCTAssertEqual(db.searchVisits(query: "swift", spaceIDs: ["A"], limit: 10).map(\.url),
                       ["https://example.com"])
        XCTAssertEqual(db.searchVisits(query: "github", spaceIDs: ["A"], limit: 10).map(\.url),
                       ["https://github.com/repo"])
    }

    func testSearchVisitsPrefixMatch() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://example.com", title: "Programming Guide", spaceID: "A", visitTime: 100)

        XCTAssertEqual(db.searchVisits(query: "prog", spaceIDs: ["A"], limit: 10).count, 1)
    }

    func testSearchVisitsReturnsLatestInScopeVisitPerURL() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.com", title: "Swift", spaceID: "A", visitTime: 100)
        let latestInA = try seedVisit(db, url: "https://a.com", title: "Swift", spaceID: "A", visitTime: 300)
        try seedVisit(db, url: "https://a.com", title: "Swift", spaceID: "B", visitTime: 500)
        try seedVisit(db, url: "https://b.com", title: "Swift Too", spaceID: "A", visitTime: 200)

        let results = db.searchVisits(query: "swift", spaceIDs: ["A"], limit: 10)
        XCTAssertEqual(results.map(\.url), ["https://a.com", "https://b.com"],
                       "One entry per URL, ordered by its latest in-scope visit")
        XCTAssertEqual(results.first?.visitTime, 300)
        XCTAssertEqual(results.first?.visitID, latestInA)
    }

    /// Two visits of the same URL at the same instant: the entry must be one of
    /// them, with its own id — not a `MAX()` time glued to an arbitrary row.
    func testSearchVisitsPicksHighestIDOnTiedVisitTimes() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.com", title: "Swift", spaceID: "A", visitTime: 100)
        let second = try seedVisit(db, url: "https://a.com", title: "Swift", spaceID: "A", visitTime: 100)

        let results = db.searchVisits(query: "swift", spaceIDs: ["A"], limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.visitID, second)
        XCTAssertEqual(results.first?.visitTime, 100)
    }

    func testSearchVisitsIgnoresOutOfScopeSpaces() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.com", title: "Swift", spaceID: "A", visitTime: 100)
        try seedVisit(db, url: "https://b.com", title: "Swift", spaceID: "B", visitTime: 200)

        XCTAssertEqual(db.searchVisits(query: "swift", spaceIDs: ["A"], limit: 10).map(\.url),
                       ["https://a.com"])
        XCTAssertEqual(db.searchVisits(query: "swift", spaceIDs: ["A", "B"], limit: 10).map(\.url),
                       ["https://b.com", "https://a.com"])
        XCTAssertTrue(db.searchVisits(query: "swift", spaceIDs: [], limit: 10).isEmpty)
    }

    func testSearchVisitsReturnsEmptyForUnusableQuery() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.com", title: "Swift", spaceID: "A", visitTime: 100)

        XCTAssertTrue(db.searchVisits(query: "", spaceIDs: ["A"], limit: 10).isEmpty)
        XCTAssertTrue(db.searchVisits(query: "   ", spaceIDs: ["A"], limit: 10).isEmpty)
        XCTAssertTrue(db.searchVisits(query: "...", spaceIDs: ["A"], limit: 10).isEmpty)
        XCTAssertFalse(db.searchVisits(query: "swift\"*'()", spaceIDs: ["A"], limit: 10).isEmpty,
                       "Punctuation around a real token must not break the FTS query")
    }

    func testSearchVisitsPaginationCoversEveryURLExactlyOnce() throws {
        let db = try makeDatabase()
        for i in 1...11 {
            try seedVisit(db, url: "https://swift\(i).com", title: "Swift \(i)", spaceID: "A", visitTime: Double(i))
            // A second, older visit of each URL — must not produce a second entry.
            try seedVisit(db, url: "https://swift\(i).com", title: "Swift \(i)", spaceID: "A", visitTime: Double(i) - 0.5)
        }

        let full = db.searchVisits(query: "swift", spaceIDs: ["A"], limit: 100)
        XCTAssertEqual(full.count, 11)

        var walked: [HistoryVisitEntry] = []
        var cursor: HistoryCursor?
        while true {
            let page = db.searchVisits(query: "swift", spaceIDs: ["A"], before: cursor, limit: 3)
            if page.isEmpty { break }
            walked.append(contentsOf: page)
            cursor = HistoryCursor(after: page[page.count - 1])
            if walked.count > 50 { XCTFail("Pagination did not terminate"); break }
        }
        XCTAssertEqual(walked, full)
        XCTAssertEqual(Set(walked.map(\.url)).count, 11)
    }

    func testSearchVisitsLimitClamping() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://a.com", title: "Swift", spaceID: "A", visitTime: 100)
        try seedVisit(db, url: "https://b.com", title: "Swift", spaceID: "A", visitTime: 200)

        XCTAssertEqual(db.searchVisits(query: "swift", spaceIDs: ["A"], limit: 0).count, 1)
    }
}
