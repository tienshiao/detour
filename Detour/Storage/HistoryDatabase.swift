import Foundation
import GRDB
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "storage")

struct HistoryDatabase {
    static let shared = HistoryDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        let dir = detourDataDirectory()
        let dbPath = dir.appendingPathComponent("history.db").path

        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try! DatabaseQueue(path: dbPath, configuration: config)
        try! migrator.migrate(dbQueue)
    }

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("h1") { db in
            try db.create(table: "historyURL") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("faviconURL", .text)
                t.column("visitCount", .integer).notNull()
                t.column("lastVisitTime", .double).notNull()
            }
            try db.create(index: "historyURL_lastVisitTime", on: "historyURL", columns: ["lastVisitTime"])

            try db.create(table: "historyVisit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("urlID", .integer).notNull()
                    .references("historyURL", onDelete: .cascade)
                t.column("spaceID", .text).notNull()
                t.column("visitTime", .double).notNull()
            }
            try db.create(index: "historyVisit_urlID", on: "historyVisit", columns: ["urlID"])
            try db.create(index: "historyVisit_visitTime", on: "historyVisit", columns: ["visitTime"])

            try db.create(virtualTable: "historySearch", using: FTS5()) { t in
                t.synchronize(withTable: "historyURL")
                t.tokenizer = .unicode61()
                t.column("url")
                t.column("title")
            }
        }

        return migrator
    }

    func recordVisit(url: String, title: String, faviconURL: String?, spaceID: String) {
        do {
            try dbQueue.write { db in
                let now = Date().timeIntervalSince1970

                // Upsert historyURL and get the row ID back in one query
                let urlID = try Int64.fetchOne(db, sql: """
                    INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                    VALUES (?, ?, ?, 1, ?)
                    ON CONFLICT(url) DO UPDATE SET
                        title = excluded.title,
                        faviconURL = excluded.faviconURL,
                        visitCount = visitCount + 1,
                        lastVisitTime = excluded.lastVisitTime
                    RETURNING id
                    """, arguments: [url, title, faviconURL, now])!
                let visit = HistoryVisit(urlID: urlID, spaceID: spaceID, visitTime: now)
                try visit.insert(db)
            }
        } catch {
            log.error("Failed to record history visit: \(error.localizedDescription)")
        }
    }

    func recentHistory(spaceID: String, limit: Int = 12) -> [HistoryURL] {
        do {
            return try dbQueue.read { db in
                try HistoryURL.fetchAll(db, sql: """
                    SELECT h.*
                    FROM historyURL h
                    JOIN historyVisit v ON v.urlID = h.id
                    WHERE v.spaceID = ?
                    GROUP BY h.url
                    ORDER BY MAX(v.visitTime) DESC
                    LIMIT ?
                    """, arguments: [spaceID, limit])
            }
        } catch {
            log.error("Failed to fetch recent history: \(error.localizedDescription)")
            return []
        }
    }

    func searchHistory(query: String, spaceID: String, limit: Int = 10) -> [HistoryURL] {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        let ftsQuery = tokens.map { "\($0)*" }.joined(separator: " OR ")

        do {
            return try dbQueue.read { db in
                try HistoryURL.fetchAll(db, sql: """
                    SELECT h.*
                    FROM historySearch s
                    JOIN historyURL h ON h.rowid = s.rowid
                    JOIN historyVisit v ON v.urlID = h.id
                    WHERE historySearch MATCH ? AND v.spaceID = ?
                    GROUP BY h.url
                    ORDER BY rank, -h.visitCount
                    LIMIT ?
                    """, arguments: [ftsQuery, spaceID, limit])
            }
        } catch {
            log.error("Failed to search history: \(error.localizedDescription)")
            return []
        }
    }

    /// Search history globally (all spaces) for the chrome.history.search() extension API.
    func searchHistoryGlobal(query: String, maxResults: Int = 100, startTime: Double? = nil, endTime: Double? = nil) -> [HistoryURL] {
        do {
            return try dbQueue.read { db in
                if query.isEmpty {
                    // Empty query returns recent history sorted by last visit
                    var sql = "SELECT * FROM historyURL"
                    var args: [DatabaseValueConvertible] = []
                    var conditions: [String] = []
                    if let start = startTime { conditions.append("lastVisitTime >= ?"); args.append(start) }
                    if let end = endTime { conditions.append("lastVisitTime <= ?"); args.append(end) }
                    if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
                    sql += " ORDER BY lastVisitTime DESC LIMIT ?"
                    args.append(maxResults)
                    return try HistoryURL.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                }

                let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
                guard !tokens.isEmpty else { return [] }
                let ftsQuery = tokens.map { "\($0)*" }.joined(separator: " OR ")

                var sql = """
                    SELECT h.*
                    FROM historySearch s
                    JOIN historyURL h ON h.rowid = s.rowid
                    WHERE historySearch MATCH ?
                    """
                var args: [DatabaseValueConvertible] = [ftsQuery]
                if let start = startTime { sql += " AND h.lastVisitTime >= ?"; args.append(start) }
                if let end = endTime { sql += " AND h.lastVisitTime <= ?"; args.append(end) }
                sql += " ORDER BY rank, -h.visitCount LIMIT ?"
                args.append(maxResults)
                return try HistoryURL.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            log.error("Failed to search history globally: \(error.localizedDescription)")
            return []
        }
    }

    /// Return the best URL completion for a typed prefix, matching against scheme-stripped URLs.
    /// Uses prefix-matching with schemes prepended so SQLite can use the index on `url`.
    func bestURLCompletion(prefix: String, spaceID: String) -> HistoryURL? {
        guard !prefix.isEmpty else { return nil }
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let patterns = [
            "https://\(escaped)%",
            "http://\(escaped)%",
            "https://www.\(escaped)%",
            "http://www.\(escaped)%",
        ]
        do {
            return try dbQueue.read { db in
                try HistoryURL.fetchOne(db, sql: """
                    SELECT h.*
                    FROM historyURL h
                    JOIN historyVisit v ON v.urlID = h.id
                    WHERE v.spaceID = ?
                      AND (h.url LIKE ? ESCAPE '\\' OR h.url LIKE ? ESCAPE '\\'
                        OR h.url LIKE ? ESCAPE '\\' OR h.url LIKE ? ESCAPE '\\')
                    GROUP BY h.url
                    ORDER BY h.visitCount DESC, MAX(v.visitTime) DESC
                    LIMIT 1
                    """, arguments: [spaceID, patterns[0], patterns[1], patterns[2], patterns[3]])
            }
        } catch {
            log.error("Failed to find URL completion: \(error.localizedDescription)")
            return nil
        }
    }

    /// Look up a stored favicon URL for a page URL. Tries exact URL match first, then host match.
    func faviconURL(for pageURL: String) -> String? {
        do {
            return try dbQueue.read { db in
                // Exact URL match
                if let url = try String.fetchOne(db, sql:
                    "SELECT faviconURL FROM historyURL WHERE url = ? AND faviconURL IS NOT NULL",
                    arguments: [pageURL]) {
                    return url
                }
                // Host match — most recently visited entry with same host
                guard let host = URL(string: pageURL)?.host else { return nil }
                return try String.fetchOne(db, sql: """
                    SELECT faviconURL FROM historyURL
                    WHERE faviconURL IS NOT NULL AND (
                        url LIKE ? OR url LIKE ?
                    )
                    ORDER BY lastVisitTime DESC LIMIT 1
                    """, arguments: ["https://\(host)%", "http://\(host)%"])
            }
        } catch {
            return nil
        }
    }

    func expireOldVisits(olderThan maxAge: TimeInterval = 90 * 24 * 3600) {
        do {
            try dbQueue.write { db in
                let cutoff = Date().timeIntervalSince1970 - maxAge
                // Delete old visits
                try HistoryVisit.filter(Column("visitTime") < cutoff).deleteAll(db)
                // Delete orphaned URLs (no remaining visits)
                try db.execute(sql: """
                    DELETE FROM historyURL WHERE id NOT IN (SELECT DISTINCT urlID FROM historyVisit)
                    """)
            }
        } catch {
            log.error("Failed to expire old history: \(error.localizedDescription)")
        }
    }
}
