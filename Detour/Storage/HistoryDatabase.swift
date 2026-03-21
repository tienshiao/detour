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
