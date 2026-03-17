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

    // MARK: - recordVisit

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
}
