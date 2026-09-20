import XCTest
import GRDB
@testable import Detour

/// The per-(URL, space) title index and the searches that gate on it (TASK-96).
///
/// `historyTitle` is one row per distinct non-empty title a space gave a URL,
/// `n` counting the visits that currently carry it, and `historyTitleSearch` is
/// an external-content FTS5 index over those rows. Nothing in Swift maintains
/// them — SQL triggers on `historyVisit` do — so what these tests are really
/// about is that every write path in the file goes through those triggers and
/// leaves the table, the refcounts and the FTS index agreeing with the visits.
final class HistoryTitleIndexTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDatabase() throws -> HistoryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
    }

    /// The same raw upsert `HistoryDatabaseTests.seedVisit` uses: a visit with a
    /// caller-chosen time, and a `visitTitle` of nil for a visit as the database
    /// held them before per-visit titles existed (TASK-91).
    @discardableResult
    private func seedVisit(_ db: HistoryDatabase, url: String, title: String = "Page",
                           visitTitle: String? = nil, spaceID: String,
                           visitTime: Double) throws -> Int64 {
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
                INSERT INTO historyVisit (urlID, spaceID, visitTime, title) VALUES (?, ?, ?, ?)
                """, arguments: [urlID, spaceID, visitTime, visitTitle])
            return conn.lastInsertedRowID
        }
    }

    private func recordVisitAwaitingID(_ db: HistoryDatabase, url: String, title: String,
                                       spaceID: String) -> Int64? {
        var visitID: Int64?
        let done = expectation(description: "record visit")
        db.recordVisit(url: url, title: title, faviconURL: nil, spaceID: spaceID) { id in
            visitID = id
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return visitID
    }

    private func awaitDeletion(_ perform: (@escaping (Result<HistoryDeletionResult, Error>) -> Void) -> Void) {
        let done = expectation(description: "history delete")
        perform { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    // MARK: - Reading the index back

    /// `(urlID, spaceID, title, n)` for every row, in a stable order.
    private func indexRows(_ db: HistoryDatabase) throws -> [String] {
        try db.dbQueue.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT urlID, spaceID, title, n FROM historyTitle
                ORDER BY urlID, spaceID, title
                """).map { "\($0["urlID"] as Int64)|\($0["spaceID"] as String)|\($0["title"] as String)|\($0["n"] as Int)" }
        }
    }

    /// The titles the FTS index answers `query` with, through the same
    /// quoted-prefix expression every lookup in `HistoryDatabase` builds — over
    /// *folded* tokens, because `historyTitleSearch` indexes folded text.
    private func ftsTitles(_ db: HistoryDatabase, _ query: String,
                           spaceID: String? = nil) throws -> Set<String> {
        let tokens = HistoryDatabase.folded(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
        var sql = """
            SELECT t.title FROM historyTitleSearch ts JOIN historyTitle t ON t.id = ts.rowid
            WHERE historyTitleSearch MATCH ?
            """
        var args: [DatabaseValueConvertible] = [match]
        if let spaceID {
            sql += " AND t.spaceID = ?"
            args.append(spaceID)
        }
        return try db.dbQueue.read { conn in
            Set(try String.fetchAll(conn, sql: sql, arguments: StatementArguments(args)))
        }
    }

    /// Everything that can be checked about the index without knowing what the
    /// test did: the refcounts are what a fresh `GROUP BY` over the visits would
    /// produce, nothing is stuck at or below zero, the FTS index agrees with its
    /// content table, and no FTS entry outlives the row it indexed.
    ///
    /// The third check is FTS5's own `integrity-check`, and it has to be the
    /// `rank = 1` form: the bare command validates only the index's internal
    /// structure and passes happily over an external-content table whose content
    /// has drifted (checked against SQLite 3.51 on this machine). The fourth
    /// reads the index's rowids out of `fts5vocab`, which is the only way to see
    /// entries the content table no longer has a row for — the failure a
    /// hand-written delete trigger is most likely to produce.
    private func assertIndexIsConsistent(_ db: HistoryDatabase,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        try db.dbQueue.write { conn in
            let recomputed = try Row.fetchAll(conn, sql: """
                SELECT urlID, spaceID, title, COUNT(*) AS n FROM historyVisit
                WHERE title IS NOT NULL AND title <> ''
                GROUP BY urlID, spaceID, title ORDER BY urlID, spaceID, title
                """).map { "\($0["urlID"] as Int64)|\($0["spaceID"] as String)|\($0["title"] as String)|\($0["n"] as Int)" }
            let stored = try Row.fetchAll(conn, sql: """
                SELECT urlID, spaceID, title, n FROM historyTitle ORDER BY urlID, spaceID, title
                """).map { "\($0["urlID"] as Int64)|\($0["spaceID"] as String)|\($0["title"] as String)|\($0["n"] as Int)" }
            XCTAssertEqual(stored, recomputed, "refcounts drifted from the visits",
                           file: file, line: line)
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyTitle WHERE n <= 0"),
                           0, "a row survived at n <= 0", file: file, line: line)

            do {
                try conn.execute(sql: """
                    INSERT INTO historyTitleSearch(historyTitleSearch, rank)
                    VALUES ('integrity-check', 1)
                    """)
            } catch {
                XCTFail("FTS integrity-check failed: \(error)", file: file, line: line)
            }

            try conn.execute(sql: "DROP TABLE IF EXISTS temp.historyTitleVocab")
            try conn.execute(sql: """
                CREATE VIRTUAL TABLE temp.historyTitleVocab
                USING fts5vocab('main', 'historyTitleSearch', 'instance')
                """)
            let indexed = Set(try Int64.fetchAll(conn, sql: "SELECT DISTINCT doc FROM temp.historyTitleVocab"))
            let present = Set(try Int64.fetchAll(conn, sql: "SELECT id FROM historyTitle"))
            XCTAssertEqual(indexed, present,
                           "the FTS index and the title table name different rows",
                           file: file, line: line)
            try conn.execute(sql: "DROP TABLE IF EXISTS temp.historyTitleVocab")
        }
    }

    // MARK: - The migration (AC #1)

    /// Raw SQL, deliberately: the point is that the same statements produce the
    /// same index whether the triggers ran as they landed (a database that was
    /// always on h5) or the migration built it afterwards from what was already
    /// there. Both databases get titled, empty-titled and title-less visits, two
    /// spaces, a title two visits share, and a URL one space retitled.
    private func seedTheSameHistory(_ conn: Database) throws {
        try conn.execute(sql: """
            INSERT INTO historyURL (url, title, visitCount, lastVisitTime) VALUES
                ('https://mail.example/', 'Dashboard', 5, 5000),
                ('https://news.example/', 'Evening Edition', 3, 3000),
                ('https://old.example/', 'Legacy Only', 1, 1000);
            INSERT INTO historyVisit (urlID, spaceID, visitTime, title) VALUES
                (1, 'personal', 1000, 'Budget 2026'),
                (1, 'personal', 1100, 'Budget 2026'),
                (1, 'personal', 1200, ''),
                (1, 'personal', 1300, NULL),
                (1, 'work',     5000, 'Dashboard'),
                (2, 'personal', 2000, 'Morning Edition'),
                (2, 'personal', 3000, 'Evening Edition'),
                (2, 'work',     2500, 'Morning Edition'),
                (3, 'personal', 1000, NULL);
            """)
    }

    func testTheMigrationBuildsTheIndexExistingHistoryWouldHaveProduced() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true

        // The database as the version before the title index left it. The
        // functions go on first: driving `migrator` past h5 on a bare queue
        // needs `history_fold`, which the backfill calls.
        let queue = try DatabaseQueue(configuration: config)
        queue.writeWithoutTransaction { HistoryDatabase.registerFunctions(on: $0) }
        try HistoryDatabase.migrator.migrate(queue, upTo: "h4")
        try queue.write { try seedTheSameHistory($0) }
        let migrated = try HistoryDatabase(dbQueue: queue)

        // The same rows written to a database that already had the triggers.
        let fresh = try makeDatabase()
        try fresh.dbQueue.write { try seedTheSameHistory($0) }

        XCTAssertEqual(try indexRows(migrated), [
            "1|personal|Budget 2026|2",
            "1|work|Dashboard|1",
            "2|personal|Evening Edition|1",
            "2|personal|Morning Edition|1",
            "2|work|Morning Edition|1",
        ], "one row per distinct non-empty title a space gave a URL; '' and NULL do not count")
        XCTAssertEqual(try indexRows(fresh), try indexRows(migrated),
                       "the backfill and the triggers agree")
        try assertIndexIsConsistent(migrated)
        try assertIndexIsConsistent(fresh)

        // And the searches built on it answer identically.
        for query in ["budget", "dashboard", "morning", "evening", "legacy", "mail", "news"] {
            for space in ["personal", "work"] {
                XCTAssertEqual(migrated.searchHistory(query: query, spaceID: space).map(\.url),
                               fresh.searchHistory(query: query, spaceID: space).map(\.url),
                               "searchHistory(\(query), \(space))")
            }
            XCTAssertEqual(migrated.searchVisits(query: query, spaceIDs: ["personal"], limit: 50).map(\.visitID),
                           fresh.searchVisits(query: query, spaceIDs: ["personal"], limit: 50).map(\.visitID),
                           "searchVisits(\(query))")
        }
        XCTAssertEqual(migrated.searchHistory(query: "budget", spaceID: "personal").map(\.title),
                       ["Budget 2026"],
                       "and the migrated database can find a title only that space ever gave the URL")
    }

    // MARK: - Trigger lifecycle (AC #4)

    func testRepeatedVisitsUnderOneTitleShareOneRow() throws {
        let db = try makeDatabase()
        for _ in 0 ..< 4 {
            _ = recordVisitAwaitingID(db, url: "https://news.example/", title: "Morning Edition",
                                      spaceID: "A")
        }

        XCTAssertEqual(try indexRows(db), ["1|A|Morning Edition|4"],
                       "four visits, one indexed title")
        try assertIndexIsConsistent(db)
    }

    /// A single-page app settling its title (TASK-88) is a `historyVisit` UPDATE,
    /// which has to move the count from one row to the other — and take the FTS
    /// entry with it in both directions.
    func testARetitleMovesTheCountAndTheIndexFollowsBothWays() throws {
        let db = try makeDatabase()
        let first = try XCTUnwrap(recordVisitAwaitingID(db, url: "https://app.example/",
                                                        title: "Loading", spaceID: "A"))
        _ = recordVisitAwaitingID(db, url: "https://app.example/", title: "Loading", spaceID: "A")

        XCTAssertEqual(try indexRows(db), ["1|A|Loading|2"])

        db.updateTitle(visitID: first, url: "https://app.example/", title: "Quarterly figures")

        XCTAssertEqual(try indexRows(db), ["1|A|Loading|1", "1|A|Quarterly figures|1"],
                       "the count moved, and the old row survives because a visit still holds it")
        XCTAssertEqual(try ftsTitles(db, "quarterly"), ["Quarterly figures"])
        try assertIndexIsConsistent(db)

        // The last visit under the old title leaves: the row and its FTS entry go.
        let second = try db.dbQueue.read { conn in
            try Int64.fetchOne(conn, sql: "SELECT id FROM historyVisit WHERE title = 'Loading'")!
        }
        db.updateTitle(visitID: second, url: "https://app.example/", title: "Quarterly figures")

        XCTAssertEqual(try indexRows(db), ["1|A|Quarterly figures|2"])
        XCTAssertTrue(try ftsTitles(db, "loading").isEmpty,
                      "the word nothing is called any more stops matching")
        try assertIndexIsConsistent(db)
    }

    /// A legacy visit gaining a title has no old row to decrement, and a visit
    /// moved to another space is a different index row. Both are the `UPDATE`
    /// triggers' edge cases.
    func testATitlelessVisitGainingATitleAndAVisitChangingSpace() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://old.example/", title: "Legacy", spaceID: "A", visitTime: 1000)
        XCTAssertTrue(try indexRows(db).isEmpty, "a title-less visit is not indexed")

        try db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE historyVisit SET title = 'Named at last' WHERE id = 1")
        }
        XCTAssertEqual(try indexRows(db), ["1|A|Named at last|1"])
        try assertIndexIsConsistent(db)

        try db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE historyVisit SET spaceID = 'B' WHERE id = 1")
        }
        XCTAssertEqual(try indexRows(db), ["1|B|Named at last|1"],
                       "the title followed the visit into the other space")
        try assertIndexIsConsistent(db)

        try db.dbQueue.write { conn in
            try conn.execute(sql: "UPDATE historyVisit SET title = NULL WHERE id = 1")
        }
        XCTAssertTrue(try indexRows(db).isEmpty)
        XCTAssertTrue(try ftsTitles(db, "named").isEmpty)
        try assertIndexIsConsistent(db)
    }

    /// Every delete path in the file, each against a freshly seeded corpus: what
    /// they have in common is that none of them knows the title index exists.
    func testEveryDeletePathLeavesTheIndexConsistent() throws {
        // (what to do, what should be left)
        let cases: [(name: String, run: (HistoryDatabase, [Int64]) -> Void)] = [
            ("one visit by id", { db, ids in
                self.awaitDeletion { db.deleteVisits(ids: [ids[0]], spaceIDs: ["A"], completion: $0) }
            }),
            ("all in-scope visits of a URL", { db, ids in
                self.awaitDeletion {
                    db.deleteVisits(ids: [ids[0]], spaceIDs: ["A"], allVisitsOfURL: true, completion: $0)
                }
            }),
            ("all visits of a URL inside a window", { db, ids in
                self.awaitDeletion {
                    db.deleteVisits(ids: [ids[0]], spaceIDs: ["A"], allVisitsOfURL: true,
                                    from: 900, until: 1150, completion: $0)
                }
            }),
            ("clear since", { db, _ in
                self.awaitDeletion { db.deleteVisits(spaceIDs: ["A"], since: 1100, completion: $0) }
            }),
            ("clear all of a profile", { db, _ in
                self.awaitDeletion { db.deleteVisits(spaceIDs: ["A"], since: nil, completion: $0) }
            }),
            ("sweep of spaces that no longer exist", { db, _ in
                self.awaitDeletion { db.deleteVisits(notInSpaceIDs: ["A"], completion: $0) }
            }),
            ("the 90-day expiry", { db, _ in db.expireOldVisits(olderThan: 0) }),
            ("the last visit of a URL, taking the historyURL row", { db, ids in
                self.awaitDeletion { db.deleteVisits(ids: ids, spaceIDs: ["A", "B"], completion: $0) }
            }),
            ("a raw historyURL delete, through the FK cascade", { db, _ in
                try? db.dbQueue.write { conn in
                    try conn.execute(sql: "DELETE FROM historyURL WHERE url = 'https://news.example/'")
                }
            }),
        ]

        for (name, run) in cases {
            let db = try makeDatabase()
            var ids: [Int64] = []
            // Two URLs, two spaces, a shared title, a repeated title and a
            // title-less visit — so a delete can empty a row, halve one, or miss.
            ids.append(try seedVisit(db, url: "https://news.example/", title: "Morning Edition",
                                     visitTitle: "Morning Edition", spaceID: "A", visitTime: 1000))
            ids.append(try seedVisit(db, url: "https://news.example/", title: "Morning Edition",
                                     visitTitle: "Morning Edition", spaceID: "A", visitTime: 1100))
            ids.append(try seedVisit(db, url: "https://news.example/", title: "Evening Edition",
                                     visitTitle: "Evening Edition", spaceID: "A", visitTime: 1200))
            ids.append(try seedVisit(db, url: "https://news.example/", title: "Night Edition",
                                     visitTitle: "Night Edition", spaceID: "B", visitTime: 1300))
            ids.append(try seedVisit(db, url: "https://mail.example/", title: "Inbox",
                                     spaceID: "A", visitTime: 1400))
            ids.append(try seedVisit(db, url: "https://mail.example/", title: "Inbox",
                                     visitTitle: "Inbox", spaceID: "A", visitTime: 1500))

            run(db, ids)

            try assertIndexIsConsistent(db, line: #line)
            XCTAssertTrue(try indexRows(db).allSatisfy { !$0.hasSuffix("|0") }, name)
        }
    }

    /// The expiry and the launch sweep delete through paths that never name a
    /// single visit; this pins what they actually leave behind rather than only
    /// that it is self-consistent.
    func testTheSweepAndTheExpiryTakeTheirTitlesWithThem() throws {
        let db = try makeDatabase()
        let now = Date().timeIntervalSince1970
        try seedVisit(db, url: "https://gone.example/", title: "Deleted space page",
                      visitTitle: "Deleted space page", spaceID: "ghost", visitTime: now - 100)
        try seedVisit(db, url: "https://here.example/", title: "Still here",
                      visitTitle: "Still here", spaceID: "A", visitTime: now - 100)

        awaitDeletion { db.deleteVisits(notInSpaceIDs: ["A"], completion: $0) }

        XCTAssertEqual(try indexRows(db), ["2|A|Still here|1"])
        XCTAssertTrue(try ftsTitles(db, "deleted").isEmpty)
        try assertIndexIsConsistent(db)

        db.expireOldVisits(olderThan: 0)

        XCTAssertTrue(try indexRows(db).isEmpty, "every visit expired, so every title went")
        XCTAssertTrue(try ftsTitles(db, "still").isEmpty)
        try assertIndexIsConsistent(db)
    }

    // MARK: - Isolation (AC #2 and #3)

    /// The reported case. Personal saw "Budget 2026"; work later retitled the
    /// shared `historyURL` row "Dashboard", so the word survives only in
    /// personal's own visit title.
    private func seedRetitledAcrossProfiles(_ db: HistoryDatabase) throws {
        try seedVisit(db, url: "https://ledger.example/", title: "Budget 2026",
                      visitTitle: "Budget 2026", spaceID: "personal", visitTime: 1000)
        try seedVisit(db, url: "https://ledger.example/", title: "Dashboard",
                      visitTitle: "Dashboard", spaceID: "work", visitTime: 2000)
    }

    func testTheOwnTitleIsFoundInItsOwnSpaceAndNowhereElse() throws {
        let db = try makeDatabase()
        try seedRetitledAcrossProfiles(db)

        XCTAssertEqual(db.searchHistory(query: "budget", spaceID: "personal").map(\.title),
                       ["Budget 2026"],
                       "the palette finds it through personal's own title, and labels it with that")
        XCTAssertTrue(db.searchHistory(query: "budget", spaceID: "work").isEmpty,
                      "work never saw a page called that")
        XCTAssertEqual(db.searchHistory(query: "dashboard", spaceID: "work").map(\.title),
                       ["Dashboard"])
        XCTAssertTrue(db.searchHistory(query: "dashboard", spaceID: "personal").isEmpty,
                      "and the shared title stays the other profile's")
    }

    func testTheHistoryPageSeesTheSameSplitAtProfileScope() throws {
        let db = try makeDatabase()
        try seedRetitledAcrossProfiles(db)
        // A sibling space of the personal profile, to prove the gate is scoped
        // to the whole profile and not to the space the visit belongs to.
        try seedVisit(db, url: "https://other.example/", title: "Unrelated",
                      visitTitle: "Unrelated", spaceID: "personal2", visitTime: 1500)

        XCTAssertEqual(db.searchVisits(query: "budget", spaceIDs: ["personal", "personal2"],
                                       limit: 10).map(\.title),
                       ["Budget 2026"])
        XCTAssertTrue(db.searchVisits(query: "budget", spaceIDs: ["work"], limit: 10).isEmpty)
        XCTAssertEqual(db.searchVisits(query: "dashboard", spaceIDs: ["work"], limit: 10).map(\.title),
                       ["Dashboard"])
        XCTAssertTrue(db.searchVisits(query: "dashboard", spaceIDs: ["personal", "personal2"],
                                      limit: 10).isEmpty,
                      "the gate may offer the URL through the shared title; the matcher still refuses it")
    }

    /// A title-less visit (TASK-91) has no index row of its own, so it can only
    /// be reached through the shared URL-level title — and only while no other
    /// space has visited the URL (TASK-94). Both halves, so the legacy arm of
    /// the candidate union is pinned in the positive *and* the negative.
    func testALegacyVisitIsStillReachableAndStillGuarded() throws {
        let alone = try makeDatabase()
        try seedVisit(alone, url: "https://old.example/", title: "Legacy fallback title",
                      spaceID: "A", visitTime: 1000)
        XCTAssertEqual(alone.searchHistory(query: "fallback", spaceID: "A").map(\.title),
                       ["Legacy fallback title"],
                       "nobody else has visited it, so the shared title is this space's own")

        let shared = try makeDatabase()
        try seedVisit(shared, url: "https://old.example/", title: "Legacy fallback title",
                      spaceID: "A", visitTime: 1000)
        try seedVisit(shared, url: "https://old.example/", title: "Work quarterly numbers",
                      visitTitle: "Work quarterly numbers", spaceID: "B", visitTime: 2000)
        XCTAssertTrue(shared.searchHistory(query: "quarterly", spaceID: "A").isEmpty,
                      "another space has visited it, so the shared title is no longer A's to use")
        XCTAssertTrue(shared.searchHistory(query: "fallback", spaceID: "A").isEmpty,
                      "and the same guard withdraws the old shared title from A")
    }

    // MARK: - Folded titles end to end

    /// The user-visible half of the folded index: a page whose title spells a
    /// word with `ß`, `ö` or a ligature is found by the ASCII spelling, in both
    /// searches, from either direction. Before the titles were folded, the
    /// candidate gate dropped every one of the `strasse`/`file` queries —
    /// `unicode61` had indexed `straße` and `ﬁle` unchanged.
    func testAFoldedSpellingFindsTheTitleInBothSearches() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://karte.example/", title: "Straße nach Köln",
                      visitTitle: "Straße nach Köln", spaceID: "A", visitTime: 1000)
        try seedVisit(db, url: "https://docs.example/", title: "ﬁle ligature guide",
                      visitTitle: "ﬁle ligature guide", spaceID: "A", visitTime: 2000)

        for query in ["strasse", "straße", "STRASSE", "STRASSE nach", "koln", "köln", "KÖLN"] {
            XCTAssertEqual(db.searchVisits(query: query, spaceIDs: ["A"], limit: 10).map(\.title),
                           ["Straße nach Köln"], "searchVisits(\(query.debugDescription))")
            XCTAssertEqual(db.searchHistory(query: query, spaceID: "A").map(\.title),
                           ["Straße nach Köln"], "searchHistory(\(query.debugDescription))")
        }
        for query in ["file", "ﬁle", "FILE", "ligature"] {
            XCTAssertEqual(db.searchVisits(query: query, spaceIDs: ["A"], limit: 10).map(\.title),
                           ["ﬁle ligature guide"], "searchVisits(\(query.debugDescription))")
            XCTAssertEqual(db.searchHistory(query: query, spaceID: "A").map(\.title),
                           ["ﬁle ligature guide"], "searchHistory(\(query.debugDescription))")
        }
        // The raw title is still the row's identity and still what is displayed.
        XCTAssertEqual(try indexRows(db), ["1|A|Straße nach Köln|1", "2|A|ﬁle ligature guide|1"])
        try assertIndexIsConsistent(db)
    }

    /// The exception, pinned rather than left to be rediscovered: a visit from
    /// before per-visit titles has no `historyTitle` row, so it reaches the gate
    /// only through `historySearch`, which indexes the raw URL-level title. The
    /// ASCII spelling therefore does not find it — the behaviour that arm has
    /// always had — while the title's own spelling still does.
    func testALegacyVisitKeepsTheUnfoldedBehaviourOfTheSharedIndex() throws {
        let db = try makeDatabase()
        try seedVisit(db, url: "https://karte.example/", title: "Straße nach Köln",
                      spaceID: "A", visitTime: 1000)

        XCTAssertEqual(db.searchVisits(query: "straße", spaceIDs: ["A"], limit: 10).map(\.title),
                       ["Straße nach Köln"], "its own spelling reaches historySearch")
        XCTAssertTrue(db.searchVisits(query: "strasse", spaceIDs: ["A"], limit: 10).isEmpty,
                      "the shared URL-level index is not folded, and TASK-96 did not change it")
        XCTAssertEqual(db.searchVisits(query: "köln", spaceIDs: ["A"], limit: 10).map(\.title),
                       ["Straße nach Köln"],
                       "a plain diacritic still folds — unicode61 does that much on its own")
    }

    // MARK: - The gate against the matcher (AC, risk 4)

    /// Titles chosen to make FTS5's `unicode61` and `titleMatches` disagree if
    /// they are going to: Latin-1 and Latin Extended diacritics, a sharp s, a
    /// slashed o, Cyrillic, a CJK run, emoji beside words, digits, punctuation
    /// that only one side might treat as a separator, an apostrophe, full-width
    /// letters and a Turkish dotless i.
    private static let awkwardTitles = [
        "Résumé builder", "ÅNGSTRÖM units", "Straße nach Köln", "Øresund bridge",
        "łódź harbour", "Привет мир", "Москва новости", "東京 tokyo station",
        "emoji 🎉 party time", "digits 12345 here", "foo_bar baz", "C++ reference",
        "node.js guide", "don't panic", "ＦＵＬＬＷＩＤＴＨ letters", "ırmak dotless",
        "naïve café", "über Straße", "ǅungla digraph", "ﬁle ligature",
        "İstanbul dotted", "ß alone", "Ｔｏｋｙｏ wide", "ĳsselmeer dutch",
    ]

    /// Every `title|query` pair where `titleMatches` accepts but the FTS index
    /// does not hit — and there are none, which is the point of the assertion.
    ///
    /// It was not always empty. While `historyTitleSearch` indexed the raw
    /// title, thirteen pairs diverged, all of one cause: Foundation's
    /// `.diacriticInsensitive` folding **expands** a few characters into several
    /// ASCII ones (`ß` → `ss`, the `ﬁ` ligature → `fi`) where FTS5's `unicode61`
    /// maps one codepoint to at most one other and leaves them alone — so the
    /// matcher looked for the token `strasse` while the index held `straße`, and
    /// every query past the point the two spellings part (`stras…`, `s` of `ß`,
    /// `f…` of `ﬁ`) hit one side only. The index is built over
    /// `history_fold(title)` now and this query's terms are folded by the same
    /// function, so the two cannot part at all.
    ///
    /// Asserted as an exact set, so a regression in either direction — a new
    /// divergence, or this list going stale — fails here.
    private static let knownDivergences: Set<String> = []

    func testTheGateNeverHidesWhatTheMatcherAcceptsExceptWhereRecorded() throws {
        let db = try makeDatabase()
        for (index, title) in Self.awkwardTitles.enumerated() {
            try seedVisit(db, url: "https://t\(index).invalid/", title: title, visitTitle: title,
                          spaceID: "A", visitTime: Double(index + 1))
        }

        // Prefixes of every token of every title, on both sides of folding, plus
        // a few words that should reach across a fold.
        var queries: Set<String> = ["strasse", "resume", "angstrom", "oresund", "lodz",
                                    "privet", "tokyo", "party", "ist", "istanbul", "ij",
                                    "dz", "fi", "file", "ss", "naive", "cafe", "uber",
                                    "irmak", "dont", "panic", "node", "js", "foo", "bar"]
        for title in Self.awkwardTitles {
            for raw in title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            where !raw.isEmpty {
                let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                         locale: nil)
                for text in [raw, folded] {
                    for length in 1 ... text.count {
                        queries.insert(String(text.prefix(length)))
                    }
                }
            }
        }

        var found: Set<String> = []
        for query in queries.sorted() {
            let hits = try ftsTitles(db, query, spaceID: "A")
            for title in Self.awkwardTitles
            where HistoryDatabase.titleMatches(title, query: query) && !hits.contains(title) {
                found.insert("\(title)|\(query)")
            }
        }

        XCTAssertEqual(found, Self.knownDivergences, """
            the FTS gate and history_title_matches disagree on a pair that is not \
            recorded. Unexpected: \(found.subtracting(Self.knownDivergences).sorted()); \
            no longer diverging: \(Self.knownDivergences.subtracting(found).sorted())
            """)

        // And they really do reach the History page through the gate, which is
        // what the divergence list is about in the first place.
        for query in ["resume", "angstrom", "privet", "tokyo", "party", "naive", "cafe",
                      "node", "foo", "panic", "oresund", "lodz", "irmak",
                      "strasse", "straße", "file", "ﬁle", "koln", "köln"] {
            let fromSQL = Set(db.searchVisits(query: query, spaceIDs: ["A"], limit: 100).map(\.title))
            let fromMatcher = Set(Self.awkwardTitles.filter {
                HistoryDatabase.titleMatches($0, query: query)
            })
            XCTAssertEqual(fromSQL, fromMatcher, "searchVisits(\(query.debugDescription))")
        }
    }
}
