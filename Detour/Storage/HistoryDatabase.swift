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
        config.prepareDatabase { db in db.add(function: Self.titleMatchFunction) }
        dbQueue = try! DatabaseQueue(path: dbPath, configuration: config)
        try! Self.migrator.migrate(dbQueue)
    }

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        // The queue arrives already configured (tests build their own), so
        // `Configuration.prepareDatabase` above cannot have run for it. A
        // `DatabaseQueue` is one connection, so registering on it here covers
        // the whole queue for as long as it lives.
        dbQueue.writeWithoutTransaction { db in db.add(function: Self.titleMatchFunction) }
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Title matching (TASK-93)

    /// `history_title_matches(title, tokens)` — the SQL face of
    /// `titleMatches(_:query:)`, so `searchVisits` can test a *visit's own*
    /// title without a per-visit FTS index. Pure, so SQLite may hoist and cache
    /// it; registered on every connection (see the two initializers).
    ///
    /// The second argument is the same text for every row of a statement, so
    /// the tokens are folded once and reused (`queryTokenCache`) instead of
    /// being re-derived per visit.
    static let titleMatchFunction = DatabaseFunction(
        "history_title_matches", argumentCount: 2, pure: true
    ) { values in
        guard let title = String.fromDatabaseValue(values[0]), !title.isEmpty else { return false }
        let query = String.fromDatabaseValue(values[1]) ?? ""
        return titleMatches(title, tokens: queryTokenCache.tokens(for: query))
    }

    /// Does `title` match `query` the way `historySearch` would?
    ///
    /// Deliberately equivalent to what the FTS side does with the same query —
    /// `unicode61` tokens, each term prefix-matched, terms OR'd — so a title
    /// scan and an FTS hit never disagree about what counts as a match: both
    /// sides are case- and diacritic-folded, cut into maximal alphanumeric runs,
    /// and a title token matches when it *starts with* a query token. A query
    /// token never matches mid-token ("box" does not find "Inbox"), exactly as
    /// `inbox*` does not.
    ///
    /// Pure and free of GRDB so it can be tested directly. This overload folds
    /// the query every time; the SQL function goes through the cached tokens.
    static func titleMatches(_ title: String?, query: String) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return titleMatches(title, tokens: QueryTokens(query))
    }

    /// The matcher proper, over query tokens that were folded once.
    ///
    /// Three attempts, one answer. A title whose UTF-8 is plain ASCII is walked
    /// byte by byte with no allocation at all — folding an ASCII string only
    /// lowercases it, so a byte-wise lowercase compare is the same test. A
    /// title that is not ASCII but *folds* to ASCII (`Résumé`, `ÅNGSTRÖM`) is
    /// folded once and then walked the same way. Only what is still not ASCII
    /// after folding — Cyrillic, CJK, emoji — is tokenized into an array of
    /// strings, the general definition this has to agree with.
    static func titleMatches(_ title: String, tokens: QueryTokens) -> Bool {
        guard !tokens.isEmpty else { return false }
        switch scanASCII(title, tokens.ascii) {
        case .matched: return true
        case .rejected: return false
        case .notASCII: break
        }
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        switch scanASCII(folded, tokens.ascii) {
        case .matched: return true
        case .rejected: return false
        case .notASCII: break
        }
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains { titleToken in
                !titleToken.isEmpty && tokens.folded.contains { titleToken.hasPrefix($0) }
            }
    }

    /// `asciiMatch` over a string's UTF-8, or `.notASCII` when that storage is
    /// not contiguous (a bridged `NSString`) and the general path must answer.
    private static func scanASCII(_ text: String, _ tokens: [[UInt8]]) -> ASCIIScan {
        text.utf8.withContiguousStorageIfAvailable { asciiMatch($0, tokens) } ?? .notASCII
    }

    private enum ASCIIScan { case matched, rejected, notASCII }

    /// Walks an all-ASCII title once: maximal `[0-9A-Za-z]` runs, each compared
    /// case-insensitively against the (already lowercased) query tokens. The
    /// whole buffer is checked for ASCII first, so a match is never declared on
    /// the strength of a prefix that `folding` might have reshaped later on.
    private static func asciiMatch(_ bytes: UnsafeBufferPointer<UInt8>,
                                   _ tokens: [[UInt8]]) -> ASCIIScan {
        for byte in bytes where byte >= 0x80 { return .notASCII }
        guard !tokens.isEmpty else { return .rejected }

        let count = bytes.count
        var index = 0
        while index < count {
            guard isASCIIAlphanumeric(bytes[index]) else {
                index += 1
                continue
            }
            let start = index
            repeat { index += 1 } while index < count && isASCIIAlphanumeric(bytes[index])
            let length = index - start
            for token in tokens where token.count <= length {
                var offset = 0
                while offset < token.count, asciiLowercase(bytes[start + offset]) == token[offset] {
                    offset += 1
                }
                if offset == token.count { return .matched }
            }
        }
        return .rejected
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    /// One query's tokens, folded once: as strings for the general path, and as
    /// UTF-8 bytes for the ASCII one. A token that is not itself ASCII is left
    /// out of `ascii` — it can never match inside an ASCII title.
    struct QueryTokens {
        let folded: [String]
        let ascii: [[UInt8]]

        var isEmpty: Bool { folded.isEmpty }

        init(_ query: String) {
            folded = HistoryDatabase.searchTokens(query)
            ascii = folded.compactMap { token in
                let bytes = Array(token.utf8)
                return bytes.allSatisfy { $0 < 0x80 } ? bytes : nil
            }
        }
    }

    /// Remembers the last query's tokens. Every row of one statement passes the
    /// same text, and `searchVisits` may call the function tens of thousands of
    /// times for a single keystroke.
    private final class QueryTokenCache: @unchecked Sendable {
        private let lock = NSLock()
        private var query: String?
        private var tokens = QueryTokens("")

        func tokens(for query: String) -> QueryTokens {
            lock.lock()
            defer { lock.unlock() }
            if self.query != query {
                tokens = QueryTokens(query)
                self.query = query
            }
            return tokens
        }
    }

    private static let queryTokenCache = QueryTokenCache()

    /// Folded, alphanumeric-only tokens — the split every history query already
    /// applies to the user's text, applied to both sides of a title comparison.
    private static func searchTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Static, and not private, so a test can build a database as an earlier
    /// version left it (`migrate(_:upTo:)`) and then let the real migrator bring
    /// it forward — the only way to see a migration run over existing data.
    static var migrator: DatabaseMigrator {
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

        // A title per visit (TASK-91). `historyURL.title` is one row per URL
        // shared by every profile, so the newest title relabelled every older
        // visit — and one profile's "(3) Inbox — you@work" became the title
        // another profile's History page showed. The visit now carries the title
        // it was recorded with; the URL row keeps the latest known one for what
        // wants one row per URL (FTS, suggestions, completion, the extensions
        // API). Nullable, and deliberately not backfilled: what a page was
        // called at the time of an older visit was never stored, so those visits
        // fall back to the URL title via `COALESCE(v.title, h.title)`.
        migrator.registerMigration("h4") { db in
            try db.alter(table: "historyVisit") { t in
                t.add(column: "title", .text)
            }
        }

        return migrator
    }

    /// Records a visit. `typed` marks a deliberate navigation (the user submitted
    /// the URL or picked it in the command palette, vs following a link); typed
    /// visits weigh more in `bestURLCompletion` frecency ranking.
    ///
    /// The title is written twice: onto the new `historyVisit` row, which keeps
    /// it for good (TASK-91), and onto the shared `historyURL` row as the latest
    /// known title of that URL.
    ///
    /// `completion` hands back the id of the inserted visit — what a late title
    /// correction needs to find its own row again (`updateTitle(visitID:url:title:)`).
    /// It runs on GRDB's writer queue, not the caller's, so hop to main
    /// yourself; a failed write reports nil.
    func recordVisit(url: String, title: String, faviconURL: String?, spaceID: String,
                     typed: Bool = false, completion: ((Int64?) -> Void)? = nil) {
        // Fire-and-forget async write. Serialized on the writer queue, so visits
        // are committed in call order (FIFO); callers that read afterwards on the
        // same DatabaseQueue observe the write because their access is enqueued
        // behind it.
        dbQueue.asyncWrite({ db -> Int64 in
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
            let visit = HistoryVisit(urlID: urlID, spaceID: spaceID, visitTime: now,
                                     isTyped: typed, title: title)
            try visit.insert(db)
            return db.lastInsertedRowID
        }, completion: { _, result in
            switch result {
            case .success(let visitID):
                completion?(visitID)
            case .failure(let error):
                log.error("Failed to record history visit: \(error.localizedDescription)")
                completion?(nil)
            }
        })
    }

    /// Corrects the title of one recorded visit. A single-page app changes
    /// `document.title` after the navigation has finished, so the title stored
    /// with the visit is the previous page's (TASK-88).
    ///
    /// The correction targets the visit the tab itself recorded, by id — never
    /// "every visit of this URL" (TASK-91). `url` is a consistency check, not a
    /// defence against id reuse (`historyVisit.id` is `AUTOINCREMENT`, so a
    /// deleted row's id is never handed out again): an id that has since been
    /// deleted matches nothing, and an id that does not belong to `url` — a
    /// caller pairing stale state — writes nothing instead of renaming a
    /// stranger's visit.
    ///
    /// `historyURL.title` — the latest known title, which feeds FTS, the command
    /// palette and the extensions API — follows only if this visit is still the
    /// newest visit of the URL across *all* spaces. An old tab settling its
    /// title minutes later must not override what a newer visit called the page.
    ///
    /// This is a correction, not a visit: no `historyVisit` row is added, and
    /// `visitCount` / `lastVisitTime` are untouched. An unknown id is a no-op.
    /// `historySearch` is synchronized with `historyURL`, so the FTS index
    /// follows the URL-level title via its triggers.
    func updateTitle(visitID: Int64, url: String, title: String) {
        // Fire-and-forget like `recordVisit`, and serialized behind it on the
        // same writer queue, so a title correction can never overtake the visit
        // it corrects — including the insert that handed out `visitID`.
        dbQueue.asyncWrite({ db in
            try db.execute(sql: """
                UPDATE historyVisit SET title = ?
                WHERE id = ? AND urlID = (SELECT id FROM historyURL WHERE url = ?)
                """, arguments: [title, visitID, url])
            // Nothing was corrected — the id is unknown, or names a visit of
            // another URL — so the shared row must not move either.
            guard db.changesCount > 0 else { return }
            try db.execute(sql: """
                UPDATE historyURL SET title = ?
                WHERE url = ? AND title <> ?
                  AND ? = (SELECT v.id FROM historyVisit v
                           WHERE v.urlID = historyURL.id
                           ORDER BY v.visitTime DESC, v.id DESC LIMIT 1)
                """, arguments: [title, url, title, visitID])
        }, completion: { _, result in
            if case .failure(let error) = result {
                log.error("Failed to update history title: \(error.localizedDescription)")
            }
        })
    }

    // MARK: - Query building (shared)

    /// The `historySearch` MATCH expression for a query's tokens: each token
    /// prefix-matched, all OR'd, optionally confined to one column.
    ///
    /// Every token is **quoted** (TASK-94). FTS5 reserves `AND`, `OR` and `NOT`
    /// as query operators, so a bare `NOT* OR found*` is a syntax error — every
    /// history lookup threw, logged and returned nothing, and typing "not found"
    /// in the palette or the History page silently found nothing at all. Inside
    /// double quotes a token is always a string. (`NEAR` only parses as an
    /// operator before `(`, so it never failed, but it is quoted alike.) Tokens
    /// are alphanumeric by construction — the split that produces them drops
    /// everything else — so none can contain a quote and none needs escaping.
    private static func ftsPrefixQuery(_ tokens: [String], column: String? = nil) -> String {
        let terms = tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
        guard let column else { return terms }
        return "\(column) : (\(terms))"
    }

    /// The title half of a history search, over `titleExpression`: the prefilter
    /// SQLite can evaluate in C, and behind it `history_title_matches`. One
    /// helper because both the History page (`searchVisits`) and the palette
    /// (`searchHistory`) scan titles this way, and they must agree exactly.
    ///
    ///     (title LIKE '%tok%' [OR …] OR title GLOB '*[^ -~]*') AND history_title_matches(…)
    ///
    /// The prefilter is a strict superset of the matcher, so it only ever saves
    /// work; it is written to the left of the AND so short-circuit evaluation
    /// reaches the Swift function only for the few rows that could match. See
    /// `searchVisits` for why it cannot exclude a row the matcher would accept.
    /// The GLOB pattern is a constant — no user text — so it is spelled out
    /// rather than bound; a token is alphanumeric, so it can hold neither `%`
    /// nor `_` and its LIKE pattern needs no ESCAPE clause.
    ///
    /// Arguments are appended in statement order: one pattern per token, then
    /// the tokens as one string for the matcher. `titleExpression` is repeated,
    /// not aliased (a SELECT alias is not visible to the WHERE clause), so it
    /// must not itself bind anything.
    ///
    /// "Agree exactly" is about the prefilter and the matcher, not about the
    /// expression handed in: the two callers deliberately pass different ones.
    /// `searchVisits` keeps the unguarded `COALESCE(v.title, h.title)` — its
    /// scope is a *profile*, i.e. several space IDs, and the palette's guard is
    /// written argument-free as `o.spaceID <> v.spaceID`, which would read a
    /// sibling space of the same profile as foreign. Falling back to the
    /// URL-level title for a legacy visit is the TASK-91 decision for the
    /// History page and is not TASK-94's to change.
    private func titleMatchCondition(_ titleExpression: String, tokens: [String],
                                     into args: inout [DatabaseValueConvertible]) -> String {
        let likeTerms = tokens.map { _ in "\(titleExpression) LIKE ?" }
            .joined(separator: "\n                           OR ")
        for token in tokens {
            args.append("%\(token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))%")
        }
        args.append(tokens.joined(separator: " "))
        return """
            (\(likeTerms)
                           OR \(titleExpression) GLOB '*[^ -~]*')
                          AND history_title_matches(\(titleExpression), ?)
            """
    }

    // MARK: - Command palette (space-scoped)

    /// The title a palette suggestion displays: the title *this space's* own
    /// latest visit gave the URL (TASK-94).
    ///
    /// `historyURL.title` is one row per URL shared by every profile, overwritten
    /// by the newest visit anywhere, so a suggestion in the personal profile was
    /// labelled with whatever the work profile last called the page ("(3) Inbox -
    /// you@work"). This space's own latest *titled* visit answers instead —
    /// `IS NOT NULL AND <> ''`, so a visit recorded with no usable title does not
    /// hide an older one that has it.
    ///
    /// When this space has no titled visit of the URL at all — only visits from
    /// before per-visit titles existed (TASK-91) — the URL-level title stands in
    /// **only if no other space has visited the URL either**. Otherwise that
    /// title is, or may since have become, another profile's, which is the leak
    /// itself; the row is labelled with the empty string and
    /// `SuggestionProvider.displayTitle` shows the URL. Losing a legitimate
    /// legacy title on a shared URL is the cheap half of that trade.
    ///
    /// Known hole, not worth code: the guard reads the *present*. If another
    /// space's pre-TASK-91 visits are what gave `historyURL.title` its value
    /// and those visits are later deleted, nothing recomputes it —
    /// `reconcileStagedURLs` only revisits the title when a deleted visit
    /// carried one of its own — so the shared title outlives its source and
    /// this space adopts it as a fallback. Confined to title-less visits still
    /// inside the 90-day window.
    ///
    /// Written against `h.id` / `h.title`, with two bound `?` — the space ID
    /// twice — so each of the three lookups can name its already-narrowed rows
    /// `h` and drop this into the *outer* select (`labelledSelect`): the
    /// correlated subqueries then run only for the handful of rows that survived
    /// LIMIT, never for every candidate.
    private static let scopedTitleExpression = """
        COALESCE(
                       (SELECT v2.title FROM historyVisit v2
                        WHERE v2.urlID = h.id AND v2.spaceID = ?
                          AND v2.title IS NOT NULL AND v2.title <> ''
                        ORDER BY v2.visitTime DESC, v2.id DESC LIMIT 1),
                       CASE WHEN NOT EXISTS (SELECT 1 FROM historyVisit o
                                             WHERE o.urlID = h.id AND o.spaceID <> ?)
                            THEN h.title ELSE '' END)
        """

    /// The same rule as `scopedTitleExpression`, for the title a *visit* is
    /// matched on. Correlated to the enclosing `v`, so the scope comes from
    /// `v.spaceID` and this binds nothing — it is repeated several times inside
    /// `titleMatchCondition`, which requires an expression free of arguments.
    ///
    /// `COALESCE` evaluates left to right and stops, so the cross-space guard
    /// costs nothing for a visit that has a title of its own.
    private static let visitTitleExpression = """
        COALESCE(NULLIF(v.title, ''),
                                    CASE WHEN NOT EXISTS (
                                             SELECT 1 FROM historyVisit o
                                             WHERE o.urlID = h.id AND o.spaceID <> v.spaceID)
                                         THEN h.title ELSE '' END)
        """

    /// The `HistoryURL` columns as a space-scoped inner select must expose them.
    private static let historyURLProjection = """
        h.id AS id, h.url AS url, h.title AS title,
                               h.faviconURL AS faviconURL, h.visitCount AS visitCount,
                               h.lastVisitTime AS lastVisitTime
        """

    /// Wraps a space-scoped `inner` select in the outer select that labels its
    /// rows (TASK-94). `inner` exposes `historyURLProjection`, is aliased `h`, and
    /// has already applied its own WHERE / GROUP BY / ORDER BY / LIMIT — so the
    /// label's correlated subqueries see only the rows that survived.
    ///
    /// `order` restates the inner ORDER BY over the carried-out columns: an outer
    /// select over a subquery inherits no order. Empty for a single-row lookup.
    ///
    /// The label's two binds lead the statement, so every caller's arguments
    /// start with `labelArguments(spaceID)`; this is the one place that knows it.
    private static func labelledSelect(inner: String, orderedBy order: String) -> String {
        """
        SELECT h.id AS id, h.url AS url,
               \(scopedTitleExpression) AS title,
               h.faviconURL AS faviconURL, h.visitCount AS visitCount,
               h.lastVisitTime AS lastVisitTime
        FROM (
        \(inner)
        ) h
        \(order.isEmpty ? "" : "ORDER BY \(order)")
        """
    }

    /// What `scopedTitleExpression` binds: the space ID, twice.
    private static func labelArguments(_ spaceID: String) -> [DatabaseValueConvertible] {
        [spaceID, spaceID]
    }

    /// The most recently visited URLs of one space, newest first.
    ///
    /// The inner select picks the rows (unchanged: one per URL, ordered by the
    /// space's own latest visit); the outer one labels them (TASK-94) — with an
    /// `id` tiebreak in both, so which rows the LIMIT keeps and the order they
    /// come back in are the same decision.
    func recentHistory(spaceID: String, limit: Int = 12) -> [HistoryURL] {
        let sql = Self.labelledSelect(inner: """
            SELECT \(Self.historyURLProjection),
                               MAX(v.visitTime) AS inScopeVisitTime
                        FROM historyURL h
                        JOIN historyVisit v ON v.urlID = h.id
                        WHERE v.spaceID = ?
                        GROUP BY h.url
                        ORDER BY inScopeVisitTime DESC, id DESC
                        LIMIT ?
            """, orderedBy: "h.inScopeVisitTime DESC, h.id DESC")
        var args: [DatabaseValueConvertible] = Self.labelArguments(spaceID)
        args.append(spaceID)
        args.append(limit)
        do {
            return try dbQueue.read { db in
                try HistoryURL.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
        } catch {
            log.error("Failed to fetch recent history: \(error.localizedDescription)")
            return []
        }
    }

    /// History suggestions for the command palette, scoped to one space.
    ///
    /// Like `searchVisits`, a title from another profile must neither label a
    /// suggestion nor produce one (TASK-94) — but this runs synchronously on the
    /// main thread on every keystroke, so the title half cannot be a scan of the
    /// scope's visits the way the History page's is. The shape is therefore:
    ///
    /// - `historySearch` stays the candidate generator, with today's tokenization
    ///   and today's ordering. It is one row per URL and its `title` is the
    ///   shared, latest-known one.
    /// - A candidate qualifies only if the space visited it, and then only if it
    ///   matches in the FTS `url` column — a URL is the same text whoever visited
    ///   it — or some *in-scope* visit's own title matches, under the same
    ///   cross-space rule the label uses (`visitTitleExpression`) and behind the
    ///   same prefilter the History page scans with (`titleMatchCondition`). The
    ///   URL test is written first, so the matcher only ever runs over the visits
    ///   of candidates that did not already match by URL.
    ///
    /// **Accepted limitation**: FTS is still the gate, so in the palette a title
    /// only this space ever gave a page is findable only while the shared
    /// URL-level title also contains the word. Query "inbox" finds the personal
    /// visit of a page the shared row calls "(3) Inbox - you@work" and labels it
    /// "Inbox"; query "work" finds nothing there — but a word that appears *only*
    /// in this space's own older title, and nowhere in the shared one, produces
    /// no candidate to test. Lifting that would mean scanning the scope's visits
    /// on every keystroke: TASK-93 measured 18–40 ms per 50k visits, and 220 ms
    /// for non-ASCII titles — fine off-main for the History page, not inside a
    /// keystroke's budget. The History page remains the place to find an old
    /// title.
    ///
    /// **Accepted, and different from `searchVisits`**: a row here is a URL,
    /// not a visit, so the visit that earned the match and the visit that
    /// supplies the label need not be the same one — "inbox" can match this
    /// space's older visit while the row is labelled by its newer one. Both are
    /// this space's own, so nothing crosses a profile; it is only the
    /// searchVisits guarantee ("a row that matched on a title displays a title
    /// that matched") that a one-row-per-URL list cannot keep.
    ///
    /// Not changed, and deliberately: `rank`, `h.visitCount` and `h.faviconURL`
    /// are cross-space values. The first two order the results and nothing else.
    /// `faviconURL` *is* displayed — one icon per URL, whoever fetched it last —
    /// which is a separate question from the title and not TASK-94's.
    func searchHistory(query: String, spaceID: String, limit: Int = 10) -> [HistoryURL] {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        // Arguments in statement order: the label's two, the FTS candidate
        // query, the scope test, the url-column query, the title test's space ID,
        // then whatever `titleMatchCondition` binds, then the limit.
        var args: [DatabaseValueConvertible] = Self.labelArguments(spaceID)
        args.append(Self.ftsPrefixQuery(tokens))
        args.append(spaceID)
        args.append(Self.ftsPrefixQuery(tokens, column: "url"))
        args.append(spaceID)
        let titleCondition = titleMatchCondition(Self.visitTitleExpression, tokens: tokens,
                                                 into: &args)
        args.append(limit)

        let sql = Self.labelledSelect(inner: """
            SELECT \(Self.historyURLProjection), s.rank AS rank
                        FROM historySearch s
                        JOIN historyURL h ON h.rowid = s.rowid
                        WHERE historySearch MATCH ?
                          AND EXISTS (
                              SELECT 1 FROM historyVisit v
                              WHERE v.urlID = h.id AND v.spaceID = ?
                          )
                          AND (
                              h.id IN (
                                  SELECT s2.rowid FROM historySearch s2
                                  WHERE historySearch MATCH ?
                              )
                              OR EXISTS (
                                  SELECT 1 FROM historyVisit v
                                  WHERE v.urlID = h.id AND v.spaceID = ?
                                    AND (\(titleCondition))
                              )
                          )
                        ORDER BY rank, -h.visitCount, id
                        LIMIT ?
            """, orderedBy: "h.rank, -h.visitCount, h.id")

        do {
            return try dbQueue.read { db in
                try HistoryURL.fetchAll(db, sql: sql, arguments: StatementArguments(args))
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
                // Quoted tokens, or a query holding "and"/"or"/"not" is an FTS5
                // syntax error and the extension sees no results (TASK-94).
                let ftsQuery = Self.ftsPrefixQuery(tokens)

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
    /// (from `TabStore`). Every field but `faviconURL` comes from the in-scope
    /// `historyVisit` rows — `historyURL.visitCount` and `lastVisitTime`
    /// aggregate across *all* profiles and must never leak into a profile-scoped
    /// view, neither as a value nor as a sort key. The title is the visit's own
    /// (TASK-91), falling back to the URL-level one only for visits recorded
    /// before per-visit titles existed.
    ///
    /// Pass the previous page's last entry as `cursor` to get the next page;
    /// see `HistoryCursor` for why this is keyset paging and not OFFSET.
    ///
    /// `from`/`until` narrow the listing to a time range, half-open
    /// `[from, until)` (TASK-92). Both are computed natively from the symbolic
    /// range the page named — see `HistoryTimeRange` — and are day-aligned, so
    /// every page of one listing sees the same window.
    func visits(spaceIDs: [String], from: Double? = nil, until: Double? = nil,
                before cursor: HistoryCursor? = nil, limit: Int) -> [HistoryVisitEntry] {
        guard !spaceIDs.isEmpty else { return [] }
        let limit = clampedPageSize(limit)
        let placeholders = databaseQuestionMarks(count: spaceIDs.count)

        var sql = """
            SELECT v.id AS visitID, h.url AS url, COALESCE(v.title, h.title) AS title,
                   h.faviconURL AS faviconURL, v.visitTime AS visitTime
            FROM historyVisit v
            JOIN historyURL h ON h.id = v.urlID
            WHERE v.spaceID IN (\(placeholders))
            """
        var args: [DatabaseValueConvertible] = spaceIDs
        sql += timeWindow("v.visitTime", from: from, until: until, into: &args)
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
    ///
    /// A **visit**, not a URL, has to earn the match (TASK-93), and the two
    /// halves of the query are answered differently:
    /// - URL text goes through `historySearch`, filtered to its `url` column.
    ///   A URL is the same text whoever visited it, so an FTS hit there
    ///   qualifies every visit of that URL without crossing anything.
    /// - Titles are matched against the visit's *own* title (falling back to
    ///   the URL-level one only for legacy title-less visits — which is what
    ///   they display) by `history_title_matches`, a scan, not an index.
    ///
    /// Titles stay out of the index because `historySearch` holds one row per
    /// URL: its `title` is the latest known one, shared by every profile, so
    /// matching on it let a query find a page through a title only *another*
    /// profile's visit ever gave it. Indexing per visit instead would mean a
    /// second FTS table over `historyVisit` — rejected as index bloat (TASK-91,
    /// decision D) — so the title half is a scan of the rows the other filters
    /// already leave: one profile's visits inside the window, reached through
    /// `historyVisit_spaceID_visitTime`. `expireOldVisits` keeps that to 90
    /// days of visits, which bounds but does not make it small — a heavy
    /// profile holds tens of thousands inside the window — so the scan is not
    /// run on the title itself but behind a prefilter SQLite can evaluate in C
    /// (`titleMatchCondition`, shared with the palette's `searchHistory`):
    ///
    ///     (title LIKE '%tok%' [OR …] OR title GLOB '*[^ -~]*') AND history_title_matches(…)
    ///
    /// which is a strict superset of the matcher, and therefore only ever saves
    /// work. For a title made of printable ASCII, folding *is* ASCII
    /// lowercasing and "some token starts with `tok`" implies "the string
    /// contains `tok`" — precisely what SQLite's default (ASCII
    /// case-insensitive) LIKE tests. A title where folding could do more than
    /// lowercase — diacritics, non-ASCII case, anything the matcher might
    /// reshape — necessarily holds a character outside ` `…`~`, and the GLOB
    /// term hands it to the matcher unconditionally. `history_title_matches`
    /// reproduces the FTS semantics it replaces (folding, alphanumeric tokens,
    /// prefix terms, OR) so the two halves of the query agree with each other.
    ///
    /// What this buys: a title a page *used* to have is searchable again — every
    /// visit matches under the title it was recorded with; a row that matched on
    /// a title always displays a title that matched; and no title from another
    /// profile can either produce a result here or hide one.
    ///
    /// `from`/`until` (TASK-92) narrow the window *inside* the inner select,
    /// next to the space filter, so `ROW_NUMBER` picks the latest **in-range,
    /// qualifying** visit — the visit the row stands for is one the user can see
    /// and one that actually matched — and a URL with no such visit drops out of
    /// the results entirely rather than appearing with an out-of-range time.
    func searchVisits(query: String, spaceIDs: [String], from: Double? = nil, until: Double? = nil,
                      before cursor: HistoryCursor? = nil, limit: Int) -> [HistoryVisitEntry] {
        guard !spaceIDs.isEmpty else { return [] }
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        // The FTS half, confined to the `url` column by a column filter;
        // `historySearch` is synchronized with `historyURL`, so its rowid is
        // `historyURL.id`.
        let urlQuery = Self.ftsPrefixQuery(tokens, column: "url")
        let limit = clampedPageSize(limit)
        let placeholders = databaseQuestionMarks(count: spaceIDs.count)
        // The displayed title, repeated rather than aliased: a SELECT alias is
        // not visible to the WHERE clause that has to filter on it.
        let titleExpression = "COALESCE(v.title, h.title)"

        // The window's arguments sit between the space IDs and the query terms,
        // which is where they sit in the statement below: FTS query, then one
        // pattern per token, then the tokens for the matcher.
        var args: [DatabaseValueConvertible] = spaceIDs
        let window = timeWindow("v.visitTime", from: from, until: until, into: &args)
        args.append(urlQuery)
        let titleCondition = titleMatchCondition(titleExpression, tokens: tokens, into: &args)

        // `historyURL` is joined inside the inner select, not outside it: the
        // title test needs the URL-level title for legacy title-less visits,
        // and it has to run before `ROW_NUMBER` picks a representative.
        var sql = """
            SELECT l.visitID AS visitID, l.url AS url, COALESCE(l.visitTitle, l.urlTitle) AS title,
                   l.faviconURL AS faviconURL, l.visitTime AS visitTime
            FROM (
                SELECT v.id AS visitID, v.visitTime AS visitTime, v.title AS visitTitle,
                       h.url AS url, h.title AS urlTitle, h.faviconURL AS faviconURL,
                       ROW_NUMBER() OVER (
                           PARTITION BY v.urlID ORDER BY v.visitTime DESC, v.id DESC
                       ) AS rn
                FROM historyVisit v
                JOIN historyURL h ON h.id = v.urlID
                WHERE v.spaceID IN (\(placeholders))\(window)
                  AND (
                      v.urlID IN (
                          SELECT s.rowid FROM historySearch s WHERE historySearch MATCH ?
                      )
                      OR (
                          \(titleCondition)
                      )
                  )
            ) l
            WHERE l.rn = 1
            """
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

    /// The `[from, until)` terms for a visit-time column, with their values
    /// appended to `args` — half-open, so a visit exactly on `from` is in the
    /// period and one exactly on `until` belongs to the next (TASK-92).
    ///
    /// One helper because three statements need the same pair and each binds it
    /// in a different place: the caller appends to `args` in statement order,
    /// and this never reorders what is already there.
    private func timeWindow(_ column: String, from: Double?, until: Double?,
                            into args: inout [DatabaseValueConvertible]) -> String {
        var sql = ""
        if let from {
            sql += " AND \(column) >= ?"
            args.append(from)
        }
        if let until {
            sql += " AND \(column) < ?"
            args.append(until)
        }
        return sql
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
    ///
    /// Only in-scope visits ever produced the match; since TASK-94 the title the
    /// top hit displays is in-scope too — the inner select finds the row, the
    /// outer one labels it (`scopedTitleExpression`). One row, so the outer
    /// select needs no order of its own.
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
        let sql = Self.labelledSelect(inner: """
            SELECT \(Self.historyURLProjection)
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
            """, orderedBy: "")
        // Appended one at a time: a single heterogeneous literal of strings and
        // computed Doubles is more than the type checker will sit through.
        var args: [DatabaseValueConvertible] = Self.labelArguments(spaceID)
        args.append(spaceID)
        args.append(contentsOf: patterns)
        for days in [90.0, 4.0, 14.0, 31.0, 90.0] {
            args.append(now - days * day)
        }
        do {
            return try dbQueue.read { db in
                try HistoryURL.fetchOne(db, sql: sql, arguments: StatementArguments(args))
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
    ///
    /// `from`/`until` narrow the `allVisitsOfURL` fan-out to the half-open range
    /// `[from, until)` (TASK-92): a row deleted while the page is filtered to a
    /// period stands for the URL's visits *in that period*, and the ones outside
    /// it — which the user was not looking at — stay. Without `allVisitsOfURL`
    /// they are ignored; the named ids are always deleted, whatever the range,
    /// so the row the user clicked cannot survive its own deletion.
    func deleteVisits(ids: [Int64], spaceIDs: [String], allVisitsOfURL: Bool = false,
                      from: Double? = nil, until: Double? = nil,
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
                                              spaceIDs: spaceIDs, from: from, until: until)
                // A second pass for the named ids alone, and only when a window
                // narrowed the first one. Normally it finds nothing: the window
                // is the one the row was rendered under, so the pass above has
                // already taken the named visits with it. It is the defence for
                // the case where that is not true — a window the caller had
                // when it read the row but which no longer contains it, or one
                // a hand-written message simply got wrong. Without it the id
                // the caller named would be left behind and its row would come
                // back on the next refresh. Anything the pass above took is
                // already gone, so nothing can be staged — or counted — twice.
                if from != nil || until != nil {
                    try self.stageAndDeleteVisits(db, driving: "id", values: visitIDs, spaceIDs: spaceIDs)
                }
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
        // `hadTitle` is 1 when at least one of the deleted visits carried a
        // title of its own: only then may the URL's latest known title have come
        // from a visit this delete removed, and only then is it repaired below
        // (TASK-91).
        try db.execute(sql: """
            CREATE TEMP TABLE \(Self.stageTable) (
                urlID INTEGER PRIMARY KEY, n INTEGER NOT NULL, hadTitle INTEGER NOT NULL
            )
            """)
        defer { try? db.execute(sql: "DROP TABLE IF EXISTS temp.\(Self.stageTable)") }
        try delete(db)
        return try reconcileStagedURLs(db)
    }

    /// Stages and deletes the in-scope visits named by `values` of the `driving`
    /// column — `id` (one visit each) or `urlID` (every in-scope visit of those
    /// URLs). Both are this file's own literals; every value is bound.
    ///
    /// `from`/`until` narrow the rows to the half-open range `[from, until)`
    /// (TASK-92); they are bound like everything else.
    private func stageAndDeleteVisits(_ db: Database, driving column: String, values: [Int64],
                                      spaceIDs: [String], from: Double? = nil,
                                      until: Double? = nil) throws {
        for chunk in chunked(values) {
            var args: [DatabaseValueConvertible] = chunk
            args.append(contentsOf: spaceIDs)
            let window = timeWindow("visitTime", from: from, until: until, into: &args)
            // A URL can own visits in more than one chunk, which is what the
            // staging table's `n = n + excluded.n` is for.
            try stageAndDeleteVisits(db, where: """
                \(column) IN (\(databaseQuestionMarks(count: chunk.count)))
                  AND \(pinnedSpaceScope(count: spaceIDs.count))\(window)
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
            INSERT INTO \(Self.stageTable) (urlID, n, hadTitle)
            SELECT urlID, COUNT(*), MAX(title IS NOT NULL) FROM historyVisit
            WHERE \(condition) GROUP BY urlID
            ON CONFLICT(urlID) DO UPDATE SET
                n = n + excluded.n,
                hadTitle = MAX(hadTitle, excluded.hadTitle)
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
    /// - `title` — the latest known title — is repaired only when the delete
    ///   took a visit that carried a title (`hadTitle`), since only such a visit
    ///   can be where the URL's title came from. It becomes the title of the
    ///   newest *remaining* visit that has one, across all spaces, and empty
    ///   when no remaining visit has one: the deleted page's title must not go
    ///   on naming the URL in search and suggestions (TASK-91). Deleting a visit
    ///   recorded before per-visit titles existed leaves the title alone —
    ///   blanking a legacy URL's only title would lose it for nothing.
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
                                 (SELECT COUNT(*) FROM historyVisit v WHERE v.urlID = historyURL.id)),
                title = CASE
                    WHEN (SELECT s.hadTitle FROM \(Self.stageTable) s WHERE s.urlID = historyURL.id) = 1
                    THEN COALESCE((SELECT v.title FROM historyVisit v
                                   WHERE v.urlID = historyURL.id AND v.title IS NOT NULL
                                   ORDER BY v.visitTime DESC, v.id DESC LIMIT 1),
                                  '')
                    ELSE title END
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
