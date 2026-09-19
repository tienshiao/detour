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

        migrator.registerMigration("h2") { db in
            try db.alter(table: "historyVisit") { t in
                t.add(column: "isTyped", .boolean).notNull().defaults(to: false)
            }
        }

        // The History page pages through the visits of one profile, i.e. a set
        // of spaceIDs, newest first. Without this index SQLite walks
        // historyVisit_visitTime and discards the out-of-scope rows: fine when
        // the profile owns most of the history, ~150× slower when it owns a
        // sliver of it. With a single space in scope the planner seeks straight
        // to (spaceID, visitTime); with several it falls back to the visitTime
        // index, which still satisfies the ORDER BY without a sort.
        migrator.registerMigration("h3") { db in
            try db.create(index: "historyVisit_spaceID_visitTime",
                          on: "historyVisit", columns: ["spaceID", "visitTime"])
        }

        return migrator
    }

    /// Records a visit. `typed` marks a deliberate navigation (the user submitted
    /// the URL or picked it in the command palette, vs following a link); typed
    /// visits weigh more in `bestURLCompletion` frecency ranking.
    func recordVisit(url: String, title: String, faviconURL: String?, spaceID: String, typed: Bool = false) {
        // Fire-and-forget async write. Serialized on the writer queue, so visits
        // are committed in call order (FIFO); callers that read afterwards on the
        // same DatabaseQueue observe the write because their access is enqueued
        // behind it.
        dbQueue.asyncWrite({ db in
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
            let visit = HistoryVisit(urlID: urlID, spaceID: spaceID, visitTime: now, isTyped: typed)
            try visit.insert(db)
        }, completion: { _, result in
            if case .failure(let error) = result {
                log.error("Failed to record history visit: \(error.localizedDescription)")
            }
        })
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

    // MARK: - History page (profile-scoped)

    /// Largest page the History page may ask for in one query.
    static let maxVisitPageSize = 500

    /// One page of visits for a profile, newest first.
    ///
    /// The history DB has no notion of profiles: a profile's history is the
    /// visits of the spaces it owns, so the caller passes those space IDs in
    /// (from `TabStore`). Every field but `title`/`faviconURL` comes from the
    /// in-scope `historyVisit` rows — `historyURL.visitCount` and
    /// `lastVisitTime` aggregate across *all* profiles and must never leak into
    /// a profile-scoped view, neither as a value nor as a sort key.
    ///
    /// Pass the previous page's last entry as `cursor` to get the next page;
    /// see `HistoryCursor` for why this is keyset paging and not OFFSET.
    func visits(spaceIDs: [String], before cursor: HistoryCursor? = nil, limit: Int) -> [HistoryVisitEntry] {
        guard !spaceIDs.isEmpty else { return [] }
        let limit = clampedPageSize(limit)
        let placeholders = databaseQuestionMarks(count: spaceIDs.count)

        var sql = """
            SELECT v.id AS visitID, h.url AS url, h.title AS title,
                   h.faviconURL AS faviconURL, v.visitTime AS visitTime
            FROM historyVisit v
            JOIN historyURL h ON h.id = v.urlID
            WHERE v.spaceID IN (\(placeholders))
            """
        var args: [DatabaseValueConvertible] = spaceIDs
        if let cursor {
            sql += " AND (v.visitTime < ? OR (v.visitTime = ? AND v.id < ?))"
            args.append(cursor.visitTime)
            args.append(cursor.visitTime)
            args.append(cursor.visitID)
        }
        sql += " ORDER BY v.visitTime DESC, v.id DESC LIMIT ?"
        args.append(limit)

        do {
            return try dbQueue.read { db in
                try HistoryVisitEntry.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            log.error("Failed to fetch profile history visits: \(error.localizedDescription)")
            return []
        }
    }

    /// One page of search results for a profile, newest first.
    ///
    /// Tokenized like `searchHistory` (alphanumeric tokens, each prefix-matched,
    /// joined with OR) so the History page's search behaves like the command
    /// palette's. Unlike `visits`, results are deduplicated by URL: each match
    /// appears once, represented by its most recent *in-scope* visit — the
    /// window function resolves that unambiguously, including when two visits of
    /// the same URL share a `visitTime` (a bare `MAX(v.visitTime)` would leave
    /// the accompanying `v.id` up to SQLite). Paging is the same keyset walk
    /// over `(visitTime DESC, visitID DESC)`.
    func searchVisits(query: String, spaceIDs: [String], before cursor: HistoryCursor? = nil, limit: Int) -> [HistoryVisitEntry] {
        guard !spaceIDs.isEmpty else { return [] }
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        let ftsQuery = tokens.map { "\($0)*" }.joined(separator: " OR ")
        let limit = clampedPageSize(limit)
        let placeholders = databaseQuestionMarks(count: spaceIDs.count)

        var sql = """
            SELECT l.visitID AS visitID, h.url AS url, h.title AS title,
                   h.faviconURL AS faviconURL, l.visitTime AS visitTime
            FROM (
                SELECT v.urlID AS urlID, v.id AS visitID, v.visitTime AS visitTime,
                       ROW_NUMBER() OVER (
                           PARTITION BY v.urlID ORDER BY v.visitTime DESC, v.id DESC
                       ) AS rn
                FROM historyVisit v
                WHERE v.spaceID IN (\(placeholders))
                  AND v.urlID IN (
                      SELECT m.id FROM historySearch s
                      JOIN historyURL m ON m.rowid = s.rowid
                      WHERE historySearch MATCH ?
                  )
            ) l
            JOIN historyURL h ON h.id = l.urlID
            WHERE l.rn = 1
            """
        var args: [DatabaseValueConvertible] = spaceIDs
        args.append(ftsQuery)
        if let cursor {
            sql += " AND (l.visitTime < ? OR (l.visitTime = ? AND l.visitID < ?))"
            args.append(cursor.visitTime)
            args.append(cursor.visitTime)
            args.append(cursor.visitID)
        }
        sql += " ORDER BY l.visitTime DESC, l.visitID DESC LIMIT ?"
        args.append(limit)

        do {
            return try dbQueue.read { db in
                try HistoryVisitEntry.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            log.error("Failed to search profile history visits: \(error.localizedDescription)")
            return []
        }
    }

    private func clampedPageSize(_ limit: Int) -> Int {
        min(max(limit, 1), Self.maxVisitPageSize)
    }

    /// `?, ?, …` for an `IN` list — space IDs are bound as arguments, never
    /// interpolated into the SQL.
    private func databaseQuestionMarks(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Return the best URL completion for a typed prefix, matching against scheme-stripped URLs.
    /// Uses prefix-matching with schemes prepended so SQLite can use the index on `url`.
    ///
    /// Candidates are ranked by a Firefox-style frecency score: each visit
    /// contributes a recency-bucket weight (visits in the last 4 days count 10×
    /// more than ones older than 90 days), doubled for typed visits, so the site
    /// the user deliberately navigates to daily beats one they clicked into many
    /// times weeks ago. Visits older than 90 days (the expiry window) are ignored.
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
        let now = Date().timeIntervalSince1970
        let day = 24.0 * 3600
        do {
            return try dbQueue.read { db in
                try HistoryURL.fetchOne(db, sql: """
                    SELECT h.*
                    FROM historyURL h
                    JOIN historyVisit v ON v.urlID = h.id
                    WHERE v.spaceID = ?
                      AND (h.url LIKE ? ESCAPE '\\' OR h.url LIKE ? ESCAPE '\\'
                        OR h.url LIKE ? ESCAPE '\\' OR h.url LIKE ? ESCAPE '\\')
                      AND v.visitTime >= ?
                    GROUP BY h.url
                    ORDER BY SUM(
                        (CASE WHEN v.isTyped THEN 2.0 ELSE 1.0 END) *
                        (CASE
                            WHEN v.visitTime >= ? THEN 100.0
                            WHEN v.visitTime >= ? THEN 70.0
                            WHEN v.visitTime >= ? THEN 50.0
                            WHEN v.visitTime >= ? THEN 30.0
                            ELSE 10.0
                        END)) DESC,
                        MAX(v.visitTime) DESC
                    LIMIT 1
                    """, arguments: [spaceID, patterns[0], patterns[1], patterns[2], patterns[3],
                                     now - 90 * day,
                                     now - 4 * day, now - 14 * day, now - 31 * day, now - 90 * day])
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

    /// Prunes visits older than `maxAge` and any URLs left with no visits.
    /// Runs as a fire-and-forget async write so it never blocks the caller
    /// (e.g. launch, before first paint). Serialized on the writer queue, so a
    /// subsequent read on the same DatabaseQueue observes the pruning.
    func expireOldVisits(olderThan maxAge: TimeInterval = 90 * 24 * 3600) {
        dbQueue.asyncWrite({ db in
            let cutoff = Date().timeIntervalSince1970 - maxAge
            // Delete old visits
            try HistoryVisit.filter(Column("visitTime") < cutoff).deleteAll(db)
            // Delete orphaned URLs (no remaining visits)
            try db.execute(sql: """
                DELETE FROM historyURL WHERE id NOT IN (SELECT DISTINCT urlID FROM historyVisit)
                """)
        }, completion: { _, result in
            if case .failure(let error) = result {
                log.error("Failed to expire old history: \(error.localizedDescription)")
            }
        })
    }
}
