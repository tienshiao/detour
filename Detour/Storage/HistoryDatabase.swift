import Foundation
import GRDB
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "storage")

/// What a history delete actually changed (TASK-87).
///
/// The caller needs more than "done": `TabStore.historyDidDelete` invalidates its
/// per-`url|spaceID` dedup cache for `affectedURLs`, and forgets a tab's pending
/// title correction (TASK-88) only for `removedURLs` — the subset whose
/// `historyURL` row is gone entirely, i.e. the URLs that also vanished from FTS
/// search and URL completion. An affected URL still has a row worth correcting.
struct HistoryDeletionResult: Equatable {
    /// Number of `historyVisit` rows deleted. Only ever counts in-scope rows.
    var deletedVisitCount: Int = 0
    /// Every URL that lost at least one visit, ascending by `historyURL.id`.
    var affectedURLs: [String] = []
    /// The subset of `affectedURLs` whose `historyURL` row was deleted because no
    /// visit of it remained in *any* space.
    var removedURLs: [String] = []

    static let empty = HistoryDeletionResult()
}

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

    /// Corrects the title of a URL already in the history. A single-page app
    /// changes `document.title` after the navigation has finished, so the title
    /// stored with the visit is the previous page's (TASK-88); `historyURL`
    /// holds one title per URL, so leaving it there renames every visit of that
    /// URL. This is a correction, not a visit: no `historyVisit` row, and
    /// `visitCount` / `lastVisitTime` are untouched. A URL with no row is a
    /// no-op — the update never creates one. `historySearch` is synchronized
    /// with `historyURL`, so the FTS index follows via its triggers.
    func updateTitle(url: String, title: String) {
        // Fire-and-forget like `recordVisit`, and serialized behind it on the
        // same writer queue, so a title correction can never overtake the visit
        // it corrects.
        dbQueue.asyncWrite({ db in
            try db.execute(sql: """
                UPDATE historyURL SET title = ? WHERE url = ? AND title <> ?
                """, arguments: [title, url, title])
        }, completion: { _, result in
            if case .failure(let error) = result {
                log.error("Failed to update history title: \(error.localizedDescription)")
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

    // MARK: - Deletion (profile-scoped, TASK-87)

    /// Largest `IN (…)` list bound in one statement. SQLite's variable limit is
    /// 32766 on modern builds, but it is a compile-time option — chunk instead of
    /// trusting it. (The History page bridge caps a request at
    /// `maxVisitPageSize` ids anyway.)
    private static let deleteChunkSize = 500

    /// The temporary table a delete stages its per-URL counts in, so the
    /// `historyURL` repair afterwards is two set-based statements rather than a
    /// statement per URL (TASK-87). A literal, never interpolated from input.
    private static let stageTable = "historyDeleteStage"

    /// Deletes the visits `ids` names that belong to `spaceIDs`.
    ///
    /// With `allVisitsOfURL`, deletes every *in-scope* visit of the URLs those
    /// ids point at — the History page's search mode shows one row per URL, so
    /// deleting that row has to take the URL's whole in-scope history with it.
    ///
    /// Scope is enforced in SQL (`WHERE id IN (…) AND spaceID IN (…)`): an id
    /// naming another profile's visit deletes nothing and is absent from the
    /// result. The URL set behind `allVisitsOfURL` is derived only from ids that
    /// are themselves in scope, so a forged id cannot even be used as a pointer
    /// to delete the caller's *own* visits of that URL.
    ///
    /// `completion` runs on GRDB's writer queue (`asyncWrite`), not on the
    /// caller's — hop to main yourself. The two guarded no-op cases below call it
    /// synchronously on the calling queue without touching the database.
    ///
    /// A failed write is reported as `.failure` rather than smoothed into an
    /// empty result: the caller's UI would otherwise take rows off screen — and
    /// the store would forget cache entries — for rows still in the database
    /// (TASK-87).
    func deleteVisits(ids: [Int64], spaceIDs: [String], allVisitsOfURL: Bool = false,
                      completion: @escaping (Result<HistoryDeletionResult, Error>) -> Void) {
        let visitIDs = Array(Set(ids))
        guard !visitIDs.isEmpty, !spaceIDs.isEmpty else { return completion(.success(.empty)) }

        dbQueue.asyncWrite({ db -> HistoryDeletionResult in
            try self.staging(db) { db in
                guard allVisitsOfURL else {
                    try self.stageAndDeleteVisits(db, driving: "id", values: visitIDs, spaceIDs: spaceIDs)
                    return
                }
                // Resolve the URLs *through the scope filter* first, then delete
                // by URL. Two steps because the second one's row set is wider
                // than the ids it came from.
                var urlIDs: Set<Int64> = []
                for chunk in self.chunked(visitIDs) {
                    var args: [DatabaseValueConvertible] = chunk
                    args.append(contentsOf: spaceIDs)
                    let sql = """
                        SELECT DISTINCT urlID FROM historyVisit
                        WHERE id IN (\(self.databaseQuestionMarks(count: chunk.count)))
                          AND \(self.pinnedSpaceScope(count: spaceIDs.count))
                        """
                    let found = try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                    urlIDs.formUnion(found)
                }
                try self.stageAndDeleteVisits(db, driving: "urlID", values: urlIDs.sorted(),
                                              spaceIDs: spaceIDs)
            }
        }, completion: { _, result in
            self.complete(result, "delete history visits", completion)
        })
    }

    /// Deletes the in-scope visits made at or after `since` (`nil` = every visit
    /// of the scope — "clear all history" for this profile). The boundary is
    /// inclusive, so a caller computing "today" passes the start of the local day.
    ///
    /// `completion` runs on GRDB's writer queue; the empty-scope guard calls it
    /// synchronously on the calling queue. A failed write is `.failure`, never an
    /// empty result.
    func deleteVisits(spaceIDs: [String], since: Double?,
                      completion: @escaping (Result<HistoryDeletionResult, Error>) -> Void) {
        guard !spaceIDs.isEmpty else { return completion(.success(.empty)) }

        dbQueue.asyncWrite({ db -> HistoryDeletionResult in
            try self.staging(db) { db in
                var condition = "spaceID IN (\(self.databaseQuestionMarks(count: spaceIDs.count)))"
                var args: [DatabaseValueConvertible] = spaceIDs
                if let since {
                    condition += " AND visitTime >= ?"
                    args.append(since)
                }
                try self.stageAndDeleteVisits(db, where: condition, arguments: args)
            }
        }, completion: { _, result in
            self.complete(result, "clear history range", completion)
        })
    }

    /// Launch sweep: deletes the visits of spaces that no longer exist (TASK-87 F).
    ///
    /// A deleted space's visits are invisible to every profile but keep occupying
    /// the DB until the 90-day expiry. They are not deleted at `deleteSpace` time
    /// because Undo Delete Space restores the space under the same id and must get
    /// its history back; the undo stack does not survive a relaunch, so the sweep
    /// belongs at launch, after `TabStore` has restored its spaces.
    ///
    /// Two guards, because this is the one delete whose scope is "everything
    /// else":
    /// 1. An empty `existingSpaceIDs` deletes nothing — a store that failed to
    ///    load its spaces must not wipe the history.
    /// 2. At least one of `existingSpaceIDs` must actually own a visit. `history.db`
    ///    and the session database are separate files: if the session DB was reset,
    ///    replaced, or failed to restore, the store comes up with a fresh default
    ///    space whose id matches no visit, and every visit would look orphaned.
    ///    One shared space is the proof that the two files belong together. The
    ///    cost is that a brand-new space with no browsing yet in any surviving
    ///    space keeps the orphans until the 90-day expiry — acceptable.
    ///
    /// `completion` runs on GRDB's writer queue; the empty-list guard calls it
    /// synchronously on the calling queue. A failed write is `.failure`, never an
    /// empty result.
    ///
    /// `existingSpaceIDs` is what the caller considers to exist, which is not
    /// only what it currently holds: `TabStore` adds the spaces deleted since
    /// launch, because Undo Delete Space can still bring them back (TASK-87).
    func deleteVisits(notInSpaceIDs existingSpaceIDs: [String],
                      completion: @escaping (Result<HistoryDeletionResult, Error>) -> Void) {
        let spaceIDs = Array(Set(existingSpaceIDs))
        guard !spaceIDs.isEmpty else { return completion(.success(.empty)) }

        dbQueue.asyncWrite({ db -> HistoryDeletionResult in
            let placeholders = self.databaseQuestionMarks(count: spaceIDs.count)
            // Guard 2, inside the same transaction as the delete so nothing can
            // slip in between the check and the sweep.
            let recognized = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM historyVisit WHERE spaceID IN (\(placeholders)))
                """, arguments: StatementArguments(spaceIDs)) ?? false
            guard recognized else {
                log.notice("History sweep skipped: no visit belongs to any existing space")
                return .empty
            }

            return try self.staging(db) { db in
                try self.stageAndDeleteVisits(db, where: "spaceID NOT IN (\(placeholders))",
                                              arguments: spaceIDs)
            }
        }, completion: { _, result in
            self.complete(result, "sweep history of deleted spaces", completion)
        })
    }

    /// `+spaceID IN (?, …)` — the scope filter for statements whose *driving*
    /// term is `id IN (…)` or `urlID IN (…)`.
    ///
    /// SQLite's unary `+` is a no-op on the value (and here on the type too:
    /// `spaceID` is `TEXT NOT NULL` and the bound values are strings, so no
    /// affinity conversion is at stake) but makes the term unusable as an index
    /// constraint. Without it, `EXPLAIN QUERY PLAN` on a fresh DB — the app never
    /// runs `ANALYZE`, so the planner works from defaults — picks
    /// `historyVisit_spaceID_visitTime` for `id IN (<500 ids>) AND spaceID = ?`
    /// and walks *every* visit of the profile to delete 500 rows. Pinned, it
    /// seeks the 500 rowids (and, for `allVisitsOfURL`, `historyVisit_urlID`).
    /// The scope is still enforced in SQL; only the access path changes.
    private func pinnedSpaceScope(count: Int) -> String {
        "+spaceID IN (\(databaseQuestionMarks(count: count)))"
    }

    /// Runs `delete` — which stages its per-URL counts and removes the visits —
    /// against a staging table of its own, then repairs the `historyURL` rows
    /// from what it staged. All inside the caller's write transaction.
    private func staging(_ db: Database,
                         _ delete: (Database) throws -> Void) throws -> HistoryDeletionResult {
        // A DatabaseQueue is one connection, so a temp table outlives the
        // transaction that made it: start from an empty one every time.
        try db.execute(sql: "DROP TABLE IF EXISTS temp.\(Self.stageTable)")
        try db.execute(sql: """
            CREATE TEMP TABLE \(Self.stageTable) (urlID INTEGER PRIMARY KEY, n INTEGER NOT NULL)
            """)
        defer { try? db.execute(sql: "DROP TABLE IF EXISTS temp.\(Self.stageTable)") }
        try delete(db)
        return try reconcileStagedURLs(db)
    }

    /// Stages and deletes the in-scope visits named by `values` of the `driving`
    /// column — `id` (one visit each) or `urlID` (every in-scope visit of those
    /// URLs). Both are this file's own literals; every value is bound.
    private func stageAndDeleteVisits(_ db: Database, driving column: String, values: [Int64],
                                      spaceIDs: [String]) throws {
        for chunk in chunked(values) {
            var args: [DatabaseValueConvertible] = chunk
            args.append(contentsOf: spaceIDs)
            // A URL can own visits in more than one chunk, which is what the
            // staging table's `n = n + excluded.n` is for.
            try stageAndDeleteVisits(db, where: """
                \(column) IN (\(databaseQuestionMarks(count: chunk.count)))
                  AND \(pinnedSpaceScope(count: spaceIDs.count))
                """, arguments: args)
        }
    }

    /// Stages how many visits `condition` selects per URL, then deletes them.
    ///
    /// `condition` is assembled from this file's own SQL literals and
    /// `databaseQuestionMarks`; every value travels in `arguments`. The counts
    /// are what `reconcileStagedURLs` needs to repair the shared `historyURL`
    /// rows, and they are taken before the delete because afterwards the rows
    /// they count are gone.
    private func stageAndDeleteVisits(_ db: Database, where condition: String,
                                      arguments: [DatabaseValueConvertible]) throws {
        try db.execute(sql: """
            INSERT INTO \(Self.stageTable) (urlID, n)
            SELECT urlID, COUNT(*) FROM historyVisit WHERE \(condition) GROUP BY urlID
            ON CONFLICT(urlID) DO UPDATE SET n = n + excluded.n
            """, arguments: StatementArguments(arguments))
        try db.execute(sql: "DELETE FROM historyVisit WHERE \(condition)",
                       arguments: StatementArguments(arguments))
    }

    /// Repairs the `historyURL` rows of every staged URL, in the same
    /// transaction, and reports what changed.
    ///
    /// `historyURL` is one global row per URL shared by every profile, so:
    /// - `lastVisitTime` becomes the newest *remaining* visit across **all**
    ///   spaces, not just the deleting profile's.
    /// - `visitCount` becomes `max(visitCount - deletedHere, remaining rows)`.
    ///   It is deliberately not a plain `COUNT(*)`: `visitCount` historically
    ///   runs ahead of the visit rows because `expireOldVisits` deletes rows
    ///   without decrementing it, and recomputing it as a count would silently
    ///   demote the URL for every *other* profile sharing the row (it feeds
    ///   `bestURLCompletion` ranking and the FTS ordering). Subtracting exactly
    ///   what this delete removed, floored at what is still there, keeps both
    ///   the surplus and the floor honest.
    /// - a URL with no visit left in any space loses its `historyURL` row, which
    ///   takes the FTS entry with it via the synchronized-table triggers.
    ///
    /// Four statements whatever the delete's size, rather than one per URL: a
    /// "clear all history" of a busy profile stages tens of thousands of URLs,
    /// and per-URL work inside the write transaction blocks every reader behind
    /// it (TASK-87). Both repairs drive off the staging table's own rowids, so
    /// nothing scans `historyURL`, and the correlated subqueries seek
    /// `historyVisit_urlID`.
    private func reconcileStagedURLs(_ db: Database) throws -> HistoryDeletionResult {
        let deleted = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(n), 0) FROM \(Self.stageTable)") ?? 0
        guard deleted > 0 else { return .empty }

        var result = HistoryDeletionResult()
        result.deletedVisitCount = deleted
        // Both lists are read while the orphaned `historyURL` rows are still
        // there — the delete below is what takes their URLs out of reach.
        result.affectedURLs = try String.fetchAll(db, sql: """
            SELECT h.url FROM \(Self.stageTable) s
            JOIN historyURL h ON h.id = s.urlID
            ORDER BY s.urlID
            """)
        result.removedURLs = try String.fetchAll(db, sql: """
            SELECT h.url FROM \(Self.stageTable) s
            JOIN historyURL h ON h.id = s.urlID
            WHERE NOT EXISTS (SELECT 1 FROM historyVisit v WHERE v.urlID = h.id)
            ORDER BY s.urlID
            """)

        try db.execute(sql: """
            UPDATE historyURL SET
                lastVisitTime = (SELECT MAX(v.visitTime) FROM historyVisit v WHERE v.urlID = historyURL.id),
                visitCount = MAX(visitCount - (SELECT s.n FROM \(Self.stageTable) s WHERE s.urlID = historyURL.id),
                                 (SELECT COUNT(*) FROM historyVisit v WHERE v.urlID = historyURL.id))
            WHERE id IN (SELECT urlID FROM \(Self.stageTable))
              AND EXISTS (SELECT 1 FROM historyVisit v WHERE v.urlID = historyURL.id)
            """)
        try db.execute(sql: """
            DELETE FROM historyURL
            WHERE id IN (SELECT urlID FROM \(Self.stageTable))
              AND NOT EXISTS (SELECT 1 FROM historyVisit v WHERE v.urlID = historyURL.id)
            """)
        return result
    }

    /// Logs a failed delete and passes the outcome on as it is: a caller that
    /// took a failure for an empty result would tell the user rows are gone that
    /// are still in the database (TASK-87).
    private func complete(_ result: Result<HistoryDeletionResult, Error>, _ what: String,
                          _ completion: (Result<HistoryDeletionResult, Error>) -> Void) {
        if case .failure(let error) = result {
            log.error("Failed to \(what, privacy: .public): \(error.localizedDescription)")
        }
        completion(result)
    }

    /// Splits `values` into `IN (…)` sized batches; see `deleteChunkSize`.
    private func chunked<T>(_ values: [T]) -> [[T]] {
        stride(from: 0, to: values.count, by: Self.deleteChunkSize).map {
            Array(values[$0 ..< Swift.min($0 + Self.deleteChunkSize, values.count)])
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
