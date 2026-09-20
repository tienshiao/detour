import XCTest
import GRDB
import WebKit
@testable import Detour

/// Deleting from the History page (TASK-87), against real `WKWebView`s.
///
/// Three things are under test here, and `HistoryDatabaseTests` covers none of
/// them: that the destructive bridge methods enforce the sending tab's profile
/// scope end to end (a forged id from another profile deletes nothing), that
/// they are as unreachable from web content as `history.query` is, and that the
/// page itself removes exactly the rows it deleted without reloading.
///
/// Tabs are built the way production builds them — `TabStore.addTab` with a
/// space's configuration, then `BrowserTab.loadInternalPage` — so the scheme
/// handler, the user script and the tab's own navigation delegate are all in
/// force. The bridge reads an in-memory database through
/// `HistoryPageBridge.database` and asks its question through
/// `HistoryPageBridge.confirmClear`; nothing here touches the real history and
/// no NSAlert is ever presented.
@MainActor
final class HistoryDeletionIntegrationTests: XCTestCase {

    private let webURL = URL(string: "https://example.invalid/page")!

    private var sharedProfiles: [Profile] = []
    private var sharedSpaceIDs: [UUID] = []
    private var createdTabs: [BrowserTab] = []
    private var defaultFaviconFetch: ((URL, @escaping (Data?) -> Void) -> Void)!
    private var defaultConfirmClear: ((BrowserTab, HistoryPageBridge.ClearRange, @escaping (Bool) -> Void) -> Void)!

    /// What the last `history.clear` asked the user, recorded by the seam below.
    private var confirmedRanges: [HistoryPageBridge.ClearRange] = []

    override func setUp() {
        super.setUp()
        defaultFaviconFetch = FaviconPNGLoader.shared.fetch
        FaviconPNGLoader.shared.resetForTesting()
        FaviconPNGLoader.shared.fetch = { _, completion in completion(nil) }
        defaultConfirmClear = HistoryPageBridge.confirmClear
    }

    override func tearDown() {
        HistoryPageBridge.database = .shared
        HistoryPageBridge.confirmClear = defaultConfirmClear
        FaviconPNGLoader.shared.fetch = defaultFaviconFetch
        FaviconPNGLoader.shared.resetForTesting()
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        for id in sharedSpaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        sharedSpaceIDs.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        for profile in sharedProfiles {
            for favorite in profile.favorites { favorite.tab?.teardown() }
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        sharedProfiles.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A space on a profile of its own in the shared store — the bridge resolves
    /// the sending web view through `TabStore.shared`, so the store has to be
    /// that one.
    private func makeSpace(_ name: String) -> Space {
        let profile = TabStore.shared.addProfile(name: "Delete \(name)")
        sharedProfiles.append(profile)
        let space = TabStore.shared.addSpace(name: "Delete \(name)", emoji: "🕘",
                                             colorHex: "007AFF", profileID: profile.id)
        sharedSpaceIDs.append(space.id)
        TabStore.shared.undoManager.removeAllActions()
        return space
    }

    private func makeIncognitoSpace() -> Space {
        let space = TabStore.shared.addIncognitoSpace()
        sharedSpaceIDs.append(space.id)
        return space
    }

    private func makeTab(in space: Space) -> BrowserTab {
        let tab = TabStore.shared.addTab(in: space)
        tab.webView?.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        createdTabs.append(tab)
        return tab
    }

    private func makeDatabase() throws -> HistoryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
    }

    /// Seeds one visit at a caller-chosen time; `recordVisit` stamps `Date()`
    /// and writes asynchronously, and these tests need deterministic ordering.
    @discardableResult
    private func seedVisit(_ db: HistoryDatabase, url: String, title: String,
                           spaceID: UUID, visitTime: Double) throws -> Int64 {
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
            try conn.execute(sql: "INSERT INTO historyVisit (urlID, spaceID, visitTime) VALUES (?, ?, ?)",
                             arguments: [urlID, spaceID.uuidString, visitTime])
            return conn.lastInsertedRowID
        }
    }

    /// Answers `confirmed` to every clear and records the range it was asked
    /// about, in place of the NSAlert sheet production puts on the window.
    private func stubConfirmClear(_ confirmed: Bool) {
        confirmedRanges.removeAll()
        HistoryPageBridge.confirmClear = { [weak self] _, range, completion in
            self?.confirmedRanges.append(range)
            completion(confirmed)
        }
    }

    private func visitTimes(_ db: HistoryDatabase, _ space: Space) -> [Double] {
        db.visits(spaceIDs: [space.id.uuidString], limit: 100).map(\.visitTime)
    }

    private func visitRowCount(_ db: HistoryDatabase) throws -> Int {
        try db.dbQueue.read { conn in try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyVisit") ?? 0 }
    }

    private func urlRowExists(_ db: HistoryDatabase, _ url: String) throws -> Bool {
        try db.dbQueue.read { conn in
            try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM historyURL WHERE url = ?)",
                              arguments: [url]) ?? false
        }
    }

    // MARK: - Driving the page

    private func waitForHistoryPage(_ tab: BrowserTab) async throws {
        try await waitUntil("the History page to render") {
            guard let webView = tab.webView, !webView.isLoading,
                  InternalPage(url: webView.url ?? URL(string: "about:blank")!) == .history else { return false }
            let drawn = try? await webView.callAsyncJavaScript(
                "return document.querySelectorAll('.row, .empty-title').length;", contentWorld: .page) as? Int
            return (drawn ?? 0) > 0
        }
    }

    /// Posts one bridge message from `world` and reports how the promise settled.
    /// `params` travels as an argument rather than being spliced into the source,
    /// so a test can send exactly the shape it means to.
    private func callBridge(_ webView: WKWebView, in world: WKContentWorld, method: String,
                            params: [String: Any] = [:]) async throws -> (result: [String: Any]?, error: String?) {
        let js = """
            try {
                const value = await window.webkit.messageHandlers.detourInternal.postMessage({
                    method: method, params: params,
                });
                return JSON.stringify({ result: value === undefined ? null : value });
            } catch (error) {
                return JSON.stringify({ error: String(error && error.message ? error.message : error) });
            }
            """
        let raw = try await webView.callAsyncJavaScript(js, arguments: ["method": method, "params": params],
                                                        contentWorld: world)
        let text = try XCTUnwrap(raw as? String, "expected a JSON string")
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return (dict["result"] as? [String: Any], dict["error"] as? String)
    }

    /// Runs `js` in the page's own content world, the way the page's script sees
    /// the document — clicks and key events dispatched here reach the listeners
    /// the user script registered.
    @discardableResult
    private func runInPage(_ webView: WKWebView, _ js: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(js, contentWorld: InternalPageBridge.contentWorld)
    }

    /// Everything the assertions below look at, in one round trip.
    private struct PageState {
        var ids: [Int64] = []
        var titles: [String] = []
        var days: [String] = []
        var emptyTitle: String?
        var selection: String?
        var notice: String?
        var clearHidden = true
        var rangeHidden = true
        var rangeValue = ""
        var dayHidden = true
        var dayValue = ""
        var dayMin: String?
        var dayMax: String?
        var search = ""
    }

    private func pageState(_ webView: WKWebView) async throws -> PageState {
        let raw = try await runInPage(webView, """
            const empty = document.getElementById('empty');
            const selection = document.getElementById('selection');
            const notice = document.getElementById('notice');
            const title = document.querySelector('.empty-title');
            return JSON.stringify({
                ids: Array.from(document.querySelectorAll('.item')).map((el) => Number(el.dataset.id)),
                titles: Array.from(document.querySelectorAll('.row .title')).map((el) => el.textContent),
                days: Array.from(document.querySelectorAll('.day')).map((el) => el.textContent),
                emptyTitle: empty.hidden || !title ? null : title.textContent,
                selection: getComputedStyle(selection).display === 'none'
                    ? null : document.getElementById('selection-count').textContent,
                notice: notice.hidden ? null : notice.textContent,
                clearHidden: document.getElementById('clear').hidden,
                rangeHidden: document.getElementById('range').hidden,
                rangeValue: document.getElementById('range').value,
                dayHidden: document.getElementById('day').hidden,
                dayValue: document.getElementById('day').value,
                dayMin: document.getElementById('day').getAttribute('min'),
                dayMax: document.getElementById('day').getAttribute('max'),
                search: location.search,
            });
            """)
        let text = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        var state = PageState()
        state.ids = (dict["ids"] as? [NSNumber])?.map(\.int64Value) ?? []
        state.titles = dict["titles"] as? [String] ?? []
        state.days = dict["days"] as? [String] ?? []
        state.emptyTitle = dict["emptyTitle"] as? String
        state.selection = dict["selection"] as? String
        state.notice = dict["notice"] as? String
        state.clearHidden = dict["clearHidden"] as? Bool ?? true
        state.rangeHidden = dict["rangeHidden"] as? Bool ?? true
        state.rangeValue = dict["rangeValue"] as? String ?? ""
        state.dayHidden = dict["dayHidden"] as? Bool ?? true
        state.dayValue = dict["dayValue"] as? String ?? ""
        state.dayMin = dict["dayMin"] as? String
        state.dayMax = dict["dayMax"] as? String
        state.search = dict["search"] as? String ?? ""
        return state
    }

    /// Makes every `historyVisit` delete fail, or — with `url` — only the ones
    /// belonging to that URL, so a test can watch a write fail without a corrupt
    /// database. `RAISE(ABORT)` rolls the whole delete back, which is exactly
    /// what a real write error does.
    private func blockVisitDeletes(_ db: HistoryDatabase, forURL url: String? = nil) throws {
        // SQLite allows no bound parameters inside a trigger program, and the
        // URLs these tests use are literals of their own.
        let when = url.map { "WHEN OLD.urlID = (SELECT id FROM historyURL WHERE url = '\($0)')" } ?? ""
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                CREATE TRIGGER refuseVisitDelete BEFORE DELETE ON historyVisit \(when)
                BEGIN SELECT RAISE(ABORT, 'refused'); END
                """)
        }
    }

    private func waitForRows(_ webView: WKWebView, _ count: Int, _ what: String = "",
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("the list to hold \(count) row(s)\(what.isEmpty ? "" : " — \(what)")",
                            file: file, line: line) {
            try await self.pageState(webView).ids.count == count
        }
    }

    private func loadWebPage(_ tab: BrowserTab, html: String) async throws {
        let webView = try XCTUnwrap(tab.webView)
        try await loadHTMLStringAndWait(webView, html: html, baseURL: webURL)
    }

    // MARK: - The scope the bridge enforces (AC #4)

    /// The happy path through the real bridge: the page names one of its own
    /// visits and the row is gone.
    func testDeletingAVisitFromThePageRemovesTheRow() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("One Visit")
        let now = Date().timeIntervalSince1970
        let target = try seedVisit(db, url: "https://swift.org/", title: "Swift",
                                   spaceID: space.id, visitTime: now - 60)
        try seedVisit(db, url: "https://apple.com/", title: "Apple", spaceID: space.id, visitTime: now - 120)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.delete", params: ["ids": [target]])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.result?["cleared"] as? Bool, true)
        XCTAssertEqual((outcome.result?["deleted"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(visitTimes(db, space), [now - 120], "only the named visit went")
        XCTAssertFalse(try urlRowExists(db, "https://swift.org/"), "its last visit anywhere: the URL goes too")
    }

    /// AC #4, through the bridge rather than the SQL: a visit id belonging to
    /// another profile deletes nothing, with or without the `allVisitsOfURL`
    /// fan-out — and the page's own visits of that URL are not collateral for a
    /// forged pointer either.
    func testACrossProfileForgedVisitIDDeletesNothing() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let mine = makeSpace("Forged Mine")
        let theirs = makeSpace("Forged Theirs")
        let now = Date().timeIntervalSince1970
        let shared = "https://shared.example/"
        let mineOld = try seedVisit(db, url: shared, title: "Shared", spaceID: mine.id, visitTime: now - 3600)
        try seedVisit(db, url: shared, title: "Shared", spaceID: mine.id, visitTime: now - 1800)
        let theirsVisit = try seedVisit(db, url: shared, title: "Shared", spaceID: theirs.id, visitTime: now - 60)

        let tab = makeTab(in: mine)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        // (a) The other profile's id, named plainly.
        var outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.delete", params: ["ids": [theirsVisit]])
        XCTAssertEqual(outcome.result?["cleared"] as? Bool, true)
        XCTAssertEqual((outcome.result?["deleted"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(visitTimes(db, theirs), [now - 60], "their visit is still there")
        XCTAssertEqual(visitTimes(db, mine).count, 2)

        // (b) The same id used as a pointer to a URL both profiles visited: the
        // URL set is derived only from in-scope ids, so nothing goes — not even
        // the caller's own visits of that URL.
        outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld, method: "history.delete",
                                       params: ["ids": [theirsVisit], "allVisitsOfURL": true])
        XCTAssertEqual((outcome.result?["deleted"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(try visitRowCount(db), 3, "every visit survives a forged id")

        // (c) The page's own id, with the fan-out: all of its visits of that URL
        // go, the other profile's stays, and the shared row survives with it.
        outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld, method: "history.delete",
                                       params: ["ids": [mineOld], "allVisitsOfURL": true])
        XCTAssertEqual((outcome.result?["deleted"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(visitTimes(db, mine), [], "both of this profile's visits went")
        XCTAssertEqual(visitTimes(db, theirs), [now - 60], "the other profile's did not")
        XCTAssertTrue(try urlRowExists(db, shared), "a visit remains somewhere, so the URL row stays")
    }

    // MARK: - Clearing (AC #3)

    /// The confirmation is native and its answer is the only thing that can
    /// start a clear: "no" deletes nothing and says so.
    func testClearDeletesNothingWhenTheUserCancels() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        stubConfirmClear(false)
        let space = makeSpace("Clear Cancel")
        try seedVisit(db, url: "https://swift.org/", title: "Swift", spaceID: space.id,
                      visitTime: Date().timeIntervalSince1970 - 60)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.clear", params: ["range": "all"])
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.result?["cleared"] as? Bool, false)
        XCTAssertEqual((outcome.result?["deleted"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(confirmedRanges, [.all], "the sheet was asked about the range the page named")
        XCTAssertEqual(visitTimes(db, space).count, 1)
    }

    /// And "yes" clears the sending profile only.
    func testClearAllRemovesOnlyTheSendingProfilesVisits() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        stubConfirmClear(true)
        let mine = makeSpace("Clear Mine")
        let theirs = makeSpace("Clear Theirs")
        let now = Date().timeIntervalSince1970
        try seedVisit(db, url: "https://a.example/", title: "A", spaceID: mine.id, visitTime: now - 60)
        try seedVisit(db, url: "https://b.example/", title: "B", spaceID: mine.id, visitTime: now - 7200)
        try seedVisit(db, url: "https://a.example/", title: "A", spaceID: theirs.id, visitTime: now - 30)

        let tab = makeTab(in: mine)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.clear", params: ["range": "all"])
        XCTAssertEqual(outcome.result?["cleared"] as? Bool, true)
        XCTAssertEqual((outcome.result?["deleted"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(confirmedRanges, [.all])
        XCTAssertEqual(visitTimes(db, mine), [])
        XCTAssertEqual(visitTimes(db, theirs), [now - 30], "the other profile is untouched")
        XCTAssertFalse(try urlRowExists(db, "https://b.example/"), "nobody else had visited it")
        XCTAssertTrue(try urlRowExists(db, "https://a.example/"), "the other profile still has")
    }

    /// The sheet blocks its own window, not the app: spaces can come and go
    /// while it is up. What gets cleared is the profile's scope as it is when
    /// the user answers, not as it was when the question was asked (TASK-87).
    func testAClearUsesTheScopeTheTabHasWhenTheUserAnswers() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let mine = makeSpace("Clear Scope")
        let now = Date().timeIntervalSince1970
        try seedVisit(db, url: "https://old.example/", title: "Old", spaceID: mine.id, visitTime: now - 60)

        var latecomer: Space?
        HistoryPageBridge.confirmClear = { [weak self] _, range, completion in
            self?.confirmedRanges.append(range)
            // A second space joins the profile while the question is on screen.
            let space = TabStore.shared.addSpace(name: "Clear Scope Late", emoji: "🕘",
                                                 colorHex: "007AFF", profileID: mine.profileID)
            self?.sharedSpaceIDs.append(space.id)
            TabStore.shared.undoManager.removeAllActions()
            try? self?.seedVisit(db, url: "https://new.example/", title: "New",
                                 spaceID: space.id, visitTime: now - 30)
            latecomer = space
            completion(true)
        }
        confirmedRanges.removeAll()

        let tab = makeTab(in: mine)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.clear", params: ["range": "all"])
        XCTAssertEqual(outcome.result?["cleared"] as? Bool, true)
        XCTAssertEqual((outcome.result?["deleted"] as? NSNumber)?.intValue, 2,
                       "the space that joined the profile is in scope too")
        XCTAssertEqual(visitTimes(db, mine), [])
        XCTAssertEqual(visitTimes(db, try XCTUnwrap(latecomer)), [])
    }

    /// The cutoffs the ranges compute. The page never sends a time, so this is
    /// the whole of what "last hour" and "today" mean.
    func testClearRangeCutoffs() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 19
        components.hour = 14
        components.minute = 30
        let now = try XCTUnwrap(calendar.date(from: components))
        var midnight = components
        midnight.hour = 0
        midnight.minute = 0
        let startOfDay = try XCTUnwrap(calendar.date(from: midnight))

        XCTAssertEqual(HistoryPageBridge.ClearRange.hour.cutoff(now: now, calendar: calendar),
                       now.timeIntervalSince1970 - 3600)
        XCTAssertEqual(HistoryPageBridge.ClearRange.today.cutoff(now: now, calendar: calendar),
                       startOfDay.timeIntervalSince1970, "the start of the *local* day")
        XCTAssertNil(HistoryPageBridge.ClearRange.all.cutoff(now: now, calendar: calendar),
                     "no cutoff at all, not an ancient one")
    }

    // MARK: - The destructive methods are as unreachable as the rest (AC #7)

    /// Code in the bridge's own content world, running in a *web* document, is
    /// refused — the destructive methods are not a second door into the bridge.
    func testDeleteAndClearAreRefusedFromAWebPage() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        stubConfirmClear(true)
        let space = makeSpace("Web Document")
        try seedVisit(db, url: "https://swift.org/", title: "Swift", spaceID: space.id,
                      visitTime: Date().timeIntervalSince1970 - 60)

        let tab = makeTab(in: space)
        try await loadWebPage(tab, html: "<html><body>web</body></html>")
        let webView = try XCTUnwrap(tab.webView)

        for method in ["history.delete", "history.clear"] {
            let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld, method: method,
                                               params: ["ids": [1], "range": "all"])
            XCTAssertNil(outcome.result, "\(method) answered a web document")
            XCTAssertEqual(outcome.error, "forbidden", "\(method) was not refused")
        }
        XCTAssertEqual(confirmedRanges, [], "no question was even asked")
        XCTAssertEqual(visitTimes(db, space).count, 1)
    }

    /// And the page world — where anything injected into the document would run
    /// — cannot see the handler at all, so it has nothing to call.
    func testThePageWorldCannotReachTheDestructiveMethods() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Page World Delete")
        try seedVisit(db, url: "https://swift.org/", title: "Swift", spaceID: space.id,
                      visitTime: Date().timeIntervalSince1970 - 60)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let handler = try await webView.callAsyncJavaScript("""
            return typeof window.webkit === 'undefined'
                ? 'no webkit'
                : typeof (window.webkit.messageHandlers || {}).detourInternal;
            """, contentWorld: .page) as? String
        XCTAssertTrue(handler == "no webkit" || handler == "undefined",
                      "the page world must not reach the bridge, but saw \(handler ?? "nil")")
        XCTAssertEqual(visitTimes(db, space).count, 1)
    }

    /// Params the page would never send: the bridge answers "malformed" rather
    /// than guessing what was meant.
    func testMalformedDeleteAndClearParamsAreRejected() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        stubConfirmClear(true)
        let space = makeSpace("Malformed")
        let visit = try seedVisit(db, url: "https://swift.org/", title: "Swift", spaceID: space.id,
                                  visitTime: Date().timeIntervalSince1970 - 60)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let tooMany = (1...(HistoryPageBridge.maxDeleteCount + 1)).map(Int64.init)
        let cases: [(String, [String: Any])] = [
            ("history.delete", [:]),
            ("history.delete", ["ids": [Int64]()]),
            ("history.delete", ["ids": tooMany]),
            ("history.delete", ["ids": ["\(visit)"]]),
            ("history.delete", ["ids": [visit, "nope"]]),
            ("history.clear", [:]),
            ("history.clear", ["range": "week"]),
            ("history.clear", ["range": 7]),
        ]
        for (method, params) in cases {
            let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                               method: method, params: params)
            XCTAssertNil(outcome.result, "\(method) \(params) was answered")
            XCTAssertEqual(outcome.error, "malformed", "\(method) \(params)")
        }
        XCTAssertEqual(confirmedRanges, [], "an unknown range never reaches the sheet")
        XCTAssertEqual(visitTimes(db, space).count, 1, "and nothing was deleted")
    }

    /// An incognito tab has no scope to delete in — and must not fall through to
    /// another profile's history.
    func testDeleteAndClearAreUnavailableInIncognito() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        stubConfirmClear(true)
        let other = makeSpace("Incognito Neighbour")
        try seedVisit(db, url: "https://swift.org/", title: "Swift", spaceID: other.id,
                      visitTime: Date().timeIntervalSince1970 - 60)

        let tab = makeTab(in: makeIncognitoSpace())
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        var outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.delete", params: ["ids": [1]])
        XCTAssertEqual(outcome.error, "unavailable")
        outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                       method: "history.clear", params: ["range": "all"])
        XCTAssertEqual(outcome.error, "unavailable")
        XCTAssertEqual(confirmedRanges, [])
        XCTAssertEqual(visitTimes(db, other).count, 1)

        // The page hides what it cannot do.
        let chrome = try await pageState(webView)
        XCTAssertTrue(chrome.clearHidden, "no Clear History control in a private space")
        XCTAssertTrue(chrome.rangeHidden, "and nothing to filter by period either (TASK-92)")
    }

    // MARK: - The page (AC #1, #2)

    /// A day with several visits and a day with one, so deleting the lone row
    /// has to take its heading with it.
    private struct PageFixture {
        let db: HistoryDatabase
        let space: Space
        let tab: BrowserTab
        let webView: WKWebView
        /// The only row under the "Yesterday" heading, and so the only one whose
        /// deletion must take a heading with it.
        let yesterdayID: Int64
    }

    private func makePageFixture(_ name: String) async throws -> PageFixture {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace(name)
        // Anchored to the local day rather than to "now", so the grouping is the
        // same whatever time of day the suite runs at.
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let yesterday = try seedVisit(db, url: "https://yesterday.example/", title: "Yesterday Page",
                                      spaceID: space.id, visitTime: startOfDay - 43200)
        for index in 1...3 {
            try seedVisit(db, url: "https://today.example/\(index)", title: "Today \(index)",
                          spaceID: space.id, visitTime: startOfDay + Double(index) * 3600)
        }
        // A URL with a history of its own, for the search-mode case: one row on
        // screen, three visits behind it.
        for index in 1...3 {
            try seedVisit(db, url: "https://zulu.example/", title: "Zulu Page",
                          spaceID: space.id, visitTime: startOfDay + 600 + Double(index))
        }

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)
        try await waitForRows(webView, 7)
        return PageFixture(db: db, space: space, tab: tab, webView: webView, yesterdayID: yesterday)
    }

    /// AC #1: the row's own delete button removes that row and nothing else,
    /// without a reload — and the day heading it was the last row of goes too.
    func testTheRowDeleteButtonRemovesJustThatRow() async throws {
        let f = try await makePageFixture("Row Button")
        let before = try await pageState(f.webView)
        XCTAssertEqual(before.days.count, 2, "Today and Yesterday")

        // The last row on screen is the only one under "Yesterday".
        try await runInPage(f.webView, """
            const items = document.querySelectorAll('.item');
            items[items.length - 1].querySelector('.delete').click();
            return true;
            """)
        try await waitForRows(f.webView, 6)

        let state = try await pageState(f.webView)
        XCTAssertFalse(state.ids.contains(f.yesterdayID), "the deleted row is gone from the DOM")
        XCTAssertEqual(state.days.count, 1, "the heading left with no rows went with them")
        XCTAssertFalse(state.titles.contains("Yesterday Page"))
        XCTAssertEqual(state.titles.count, 6, "every other row stayed")
        XCTAssertEqual(visitTimes(f.db, f.space).count, 6, "and the visit is gone from the database")
        XCTAssertFalse(try urlRowExists(f.db, "https://yesterday.example/"))
    }

    /// AC #2: two rows picked with their checkboxes and removed with the Delete
    /// key. The search field is blurred first, the way clicking a row's checkbox
    /// blurs it — the key belongs to the list only when nothing is being typed.
    func testSelectingTwoRowsAndPressingDeleteRemovesBoth() async throws {
        let f = try await makePageFixture("Key Delete")

        let selected = try await runInPage(f.webView, """
            document.getElementById('search').blur();
            const items = document.querySelectorAll('.item');
            items[0].querySelector('.pick').click();
            items[1].querySelector('.pick').click();
            return document.getElementById('selection-count').textContent;
            """) as? String
        XCTAssertEqual(selected, "2 selected", "the selection bar counts them")

        let doomed = Array(try await pageState(f.webView).ids.prefix(2))
        try await runInPage(f.webView, """
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete', bubbles: true }));
            return true;
            """)
        try await waitForRows(f.webView, 5)

        let state = try await pageState(f.webView)
        XCTAssertEqual(Set(state.ids).intersection(doomed), [], "neither row survived")
        XCTAssertNil(state.selection, "the selection bar is gone with the selection")
        XCTAssertEqual(visitTimes(f.db, f.space).count, 5)
    }

    /// Shift+click takes the range between the last row toggled by hand and this
    /// one, and Escape puts the selection back.
    func testShiftClickSelectsARangeAndEscapeClearsIt() async throws {
        let f = try await makePageFixture("Shift Range")

        let count = try await runInPage(f.webView, """
            document.getElementById('search').blur();
            const items = document.querySelectorAll('.item');
            items[0].querySelector('.pick').click();
            items[3].querySelector('.pick').dispatchEvent(new MouseEvent('click', { shiftKey: true, bubbles: true }));
            return document.querySelectorAll('.item.selected').length;
            """) as? Int
        XCTAssertEqual(count, 4, "the range, not just the two ends")

        let after = try await runInPage(f.webView, """
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            return document.querySelectorAll('.item.selected').length;
            """) as? Int
        XCTAssertEqual(after, 0)
        let cleared = try await pageState(f.webView)
        XCTAssertNil(cleared.selection)
        XCTAssertEqual(visitTimes(f.db, f.space).count, 7, "selecting deletes nothing")
    }

    /// In search mode a row stands for a URL, so deleting it takes every visit
    /// of that URL in scope — the page sends `allVisitsOfURL`.
    func testDeletingASearchResultRemovesEveryVisitOfThatURL() async throws {
        let f = try await makePageFixture("Search Delete")

        try await runInPage(f.webView, """
            const search = document.getElementById('search');
            search.value = 'zulu';
            search.dispatchEvent(new Event('input'));
            return true;
            """)
        try await waitForRows(f.webView, 1)
        let searching = try await pageState(f.webView)
        XCTAssertEqual(searching.titles, ["Zulu Page"], "one row per URL, whatever its visit count")

        try await runInPage(f.webView, """
            document.querySelector('.item .delete').click();
            return true;
            """)
        try await waitForRows(f.webView, 0)

        let state = try await pageState(f.webView)
        XCTAssertEqual(state.emptyTitle, "No results for “zulu”")
        XCTAssertEqual(visitTimes(f.db, f.space).count, 4, "all three visits of that URL went")
        XCTAssertFalse(try urlRowExists(f.db, "https://zulu.example/"))
    }

    /// A write that fails must not look like a delete: the rows stay, the page
    /// says so, and the list it rebuilds afterwards still holds them (TASK-87).
    func testAFailedDeleteKeepsTheRowsAndSaysSo() async throws {
        let f = try await makePageFixture("Failed Delete")
        let before = try await pageState(f.webView).ids
        try blockVisitDeletes(f.db)

        try await runInPage(f.webView, """
            document.querySelector('.item .delete').click();
            return true;
            """)
        try await waitUntil("the page to report the failure") {
            try await self.pageState(f.webView).notice != nil
        }

        let state = try await pageState(f.webView)
        XCTAssertEqual(state.notice, "Those entries could not be deleted.")
        XCTAssertEqual(state.ids, before, "every row is still on screen")
        XCTAssertNil(state.emptyTitle)
        XCTAssertEqual(visitTimes(f.db, f.space).count, 7, "and still in the database")
    }

    /// A selection whose rows were rendered in different modes is sent as one
    /// request per mode: the URL-mode row takes every in-scope visit of its URL
    /// (and every row showing one of them), the list-mode row takes one visit.
    func testAMixedSelectionAsksForWhatEachRowShows() async throws {
        let f = try await makePageFixture("Mixed Modes")

        // The page only produces a mixed list transiently — a reply for the
        // previous query rendering under a newer one — so the row is re-marked
        // here rather than raced into place.
        let selected = try await runInPage(f.webView, """
            document.getElementById('search').blur();
            const items = Array.from(document.querySelectorAll('.item'));
            const zulu = items.find((el) => el.dataset.url === 'https://zulu.example/');
            zulu.dataset.mode = 'url';
            zulu.querySelector('.pick').click();
            items.find((el) => el.dataset.url === 'https://today.example/1').querySelector('.pick').click();
            return document.getElementById('selection-count').textContent;
            """) as? String
        XCTAssertEqual(selected, "2 selected")

        try await runInPage(f.webView, """
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete', bubbles: true }));
            return true;
            """)
        // Three visits of the URL-mode row plus the one visit of the other.
        try await waitUntil("both requests to land") { self.visitTimes(f.db, f.space).count == 3 }
        try await waitForRows(f.webView, 3)

        XCTAssertFalse(try urlRowExists(f.db, "https://zulu.example/"), "all three of its visits went")
        XCTAssertFalse(try urlRowExists(f.db, "https://today.example/1"), "and exactly one of the other's")
        let state = try await pageState(f.webView)
        XCTAssertEqual(state.ids.count, 3, "the URL's other rows went with it, without a reload")
        XCTAssertNil(state.notice)
    }

    /// A request that fails partway: what the earlier ones committed is off
    /// screen already, the rest is still there, and the list is rebuilt from the
    /// database rather than left to the next refresh — which would see the same
    /// top row and change nothing.
    func testAFailedRequestLeavesTheCommittedDeletionsGone() async throws {
        let f = try await makePageFixture("Partial Failure")
        try blockVisitDeletes(f.db, forURL: "https://zulu.example/")

        try await runInPage(f.webView, """
            document.getElementById('search').blur();
            const items = Array.from(document.querySelectorAll('.item'));
            items.find((el) => el.dataset.url === 'https://today.example/1').querySelector('.pick').click();
            const zulu = items.find((el) => el.dataset.url === 'https://zulu.example/');
            zulu.dataset.mode = 'url';
            zulu.querySelector('.pick').click();
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete', bubbles: true }));
            return true;
            """)
        try await waitUntil("the page to report the failure") {
            try await self.pageState(f.webView).notice != nil
        }
        try await waitForRows(f.webView, 6)

        XCTAssertFalse(try urlRowExists(f.db, "https://today.example/1"),
                       "the request before the failure committed")
        XCTAssertEqual(visitTimes(f.db, f.space).count, 6, "and the refused one changed nothing")
        let state = try await pageState(f.webView)
        XCTAssertFalse(state.titles.contains("Today 1"), "a committed deletion does not come back")
        XCTAssertEqual(state.titles.filter { $0 == "Zulu Page" }.count, 3,
                       "the rows the database still has are back from it")
    }

    /// Deleting every row that is loaded is not an empty history: the next page
    /// is already on its way, and "No history yet" would be a lie (TASK-87).
    func testDeletingEveryLoadedRowNeverClaimsTheHistoryIsEmpty() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Long History")
        let start = Date().timeIntervalSince1970 - 7200
        for index in 1...150 {
            try seedVisit(db, url: "https://page.example/\(index)", title: "Page \(index)",
                          spaceID: space.id, visitTime: start + Double(index))
        }

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)
        try await waitForRows(webView, 100, "one page of a history that has more")

        // Watch for an empty state at any point, not just once the dust settles.
        try await runInPage(webView, """
            window.emptyShown = 0;
            const empty = document.getElementById('empty');
            new MutationObserver(() => { if (!empty.hidden) window.emptyShown += 1; })
                .observe(empty, { attributes: true, attributeFilter: ['hidden'] });
            return true;
            """)
        let chosen = try await runInPage(webView, """
            document.getElementById('search').blur();
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }));
            const count = document.querySelectorAll('.item.selected').length;
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete', bubbles: true }));
            return count;
            """) as? Int
        XCTAssertEqual(chosen, 100, "Cmd+A takes the loaded rows")

        try await waitForRows(webView, 50, "the next page, pulled in by the delete")
        let state = try await pageState(webView)
        XCTAssertNil(state.emptyTitle)
        XCTAssertEqual(try visitRowCount(db), 50)
        let flashes = try await runInPage(webView, "return window.emptyShown;") as? Int
        XCTAssertEqual(flashes, 0, "“No history yet” never appeared")
    }

    /// The mode a row is deleted in is the one it was RENDERED in, not the one
    /// the search field has moved on to: while a search is in flight the page's
    /// query already says "search" and the rows on screen are still the list's
    /// per-visit ones. Deleting one of them must take that visit, not the URL's
    /// whole history (TASK-87).
    func testARowDeletedWhileASearchIsPendingTakesOnlyThatVisit() async throws {
        let f = try await makePageFixture("Pending Search")

        // The database is one connection, so holding a write holds the search
        // the page is about to issue: the reply cannot land — and cannot
        // re-render the list — until this test lets it.
        let released = expectation(description: "the writer queue is given back")
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // Whatever happens below, the queue is given back: a wait that fails
        // here would otherwise leave the database — and teardown — blocked.
        defer { release.signal() }
        DispatchQueue.global().async {
            try? f.db.dbQueue.write { _ in
                holding.signal()
                release.wait()
            }
            released.fulfill()
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 10), .success, "the write never started")

        try await runInPage(f.webView, """
            const search = document.getElementById('search');
            search.value = 'zulu';
            search.dispatchEvent(new Event('input'));
            return true;
            """)
        // The page writes the term into its URL immediately before issuing the
        // query, so this is it saying "the query is 'zulu' now".
        try await waitUntil("the search to be issued") {
            try await self.runInPage(f.webView, "return location.search;") as? String == "?q=zulu"
        }

        let mode = try await runInPage(f.webView, """
            const item = Array.from(document.querySelectorAll('.item'))
                .find((el) => el.dataset.url === 'https://zulu.example/');
            item.querySelector('.delete').click();
            return item.dataset.mode;
            """) as? String
        XCTAssertEqual(mode, "visit", "the rows on screen are still the list's")
        release.signal()
        await fulfillment(of: [released], timeout: 10)

        try await waitUntil("the delete to land") { self.visitTimes(f.db, f.space).count == 6 }
        XCTAssertTrue(try urlRowExists(f.db, "https://zulu.example/"),
                      "one visit went, not the three the search row would have taken")
    }

    /// AC #3 from the page's side: the menu's ranges reach the bridge, and a
    /// confirmed clear leaves the list showing the empty state.
    func testClearingFromTheMenuEmptiesTheList() async throws {
        let f = try await makePageFixture("Clear Menu")
        stubConfirmClear(true)
        let chrome = try await pageState(f.webView)
        XCTAssertFalse(chrome.clearHidden, "the control is there for a normal space")

        try await runInPage(f.webView, """
            document.querySelector('#clear .menu-item[data-range="all"]').click();
            return true;
            """)
        try await waitForRows(f.webView, 0)

        let state = try await pageState(f.webView)
        XCTAssertEqual(state.emptyTitle, "No history yet")
        XCTAssertEqual(confirmedRanges, [.all], "the range the user picked is the one asked about")
        XCTAssertEqual(visitTimes(f.db, f.space), [])
    }

    /// Cancelling changes nothing on screen — the page draws no confirmation of
    /// its own and has nothing to undo.
    func testCancellingAClearLeavesTheListAlone() async throws {
        let f = try await makePageFixture("Clear Cancelled")
        stubConfirmClear(false)
        let before = try await pageState(f.webView).ids

        try await runInPage(f.webView, """
            document.querySelector('#clear .menu-item[data-range="today"]').click();
            return true;
            """)
        try await waitUntil("the clear to be answered") { self.confirmedRanges == [.today] }
        // Give a list that was going to change time to change.
        try await Task.sleep(nanoseconds: 400_000_000)

        let after = try await pageState(f.webView)
        XCTAssertEqual(after.ids, before)
        XCTAssertEqual(visitTimes(f.db, f.space).count, 7)
    }

    // MARK: - The time filter (TASK-92)

    /// One `history.query`, refused loudly: the reply itself, for the tests that
    /// look at more of it than the entries.
    private func query(_ webView: WKWebView, _ params: [String: Any],
                       file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.query", params: params)
        XCTAssertNil(outcome.error, "the query was refused", file: file, line: line)
        return try XCTUnwrap(outcome.result, "no reply", file: file, line: line)
    }

    /// The URLs one `history.query` answered with, in the order it answered.
    private func queryURLs(_ webView: WKWebView, _ params: [String: Any],
                           file: StaticString = #filePath, line: UInt = #line) async throws -> [String] {
        let entries = try await query(webView, params, file: file, line: line)["entries"]
            as? [[String: Any]] ?? []
        return entries.compactMap { $0["url"] as? String }
    }

    /// A local day, as the page's date field and the `?day=` parameter spell it.
    private func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func todayText() -> String { dayText(Date()) }

    /// The window a row on screen was rendered under, as the page stamped it.
    /// Nil for a listing of all of history, which has no window.
    private func windowStamp(_ webView: WKWebView, at index: Int = 0) async throws -> [String: Any]? {
        let raw = try await runInPage(webView, """
            const item = document.querySelectorAll('.item')[\(index)];
            return item ? String(item.dataset.window || '') : '';
            """) as? String
        guard let raw, !raw.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
    }

    /// A preset is turned into bounds natively; the page gets the period's
    /// visits and nothing else, with or without a search.
    func testAQueryWithAPresetAnswersOnlyThePeriodsVisits() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Preset Query")
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfYesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: startOfToday))
        let longAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: startOfToday))
        try seedVisit(db, url: "https://today.example/", title: "Swift Today", spaceID: space.id,
                      visitTime: startOfToday.timeIntervalSince1970 + 60)
        try seedVisit(db, url: "https://yesterday.example/", title: "Swift Yesterday", spaceID: space.id,
                      visitTime: startOfYesterday.timeIntervalSince1970 + 60)
        try seedVisit(db, url: "https://old.example/", title: "Swift Old", spaceID: space.id,
                      visitTime: longAgo.timeIntervalSince1970 + 60)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let today = try await queryURLs(webView, ["range": ["preset": "today"]])
        XCTAssertEqual(today, ["https://today.example/"])
        let yesterday = try await queryURLs(webView, ["range": ["preset": "yesterday"]])
        XCTAssertEqual(yesterday, ["https://yesterday.example/"], "half-open: today is not in it")
        let week = try await queryURLs(webView, ["range": ["preset": "week"]])
        XCTAssertEqual(week, ["https://today.example/", "https://yesterday.example/"])
        let month = try await queryURLs(webView, ["range": ["preset": "month"]])
        XCTAssertEqual(month.count, 3)
        let everything = try await queryURLs(webView, [:])
        XCTAssertEqual(everything.count, 3, "no range is all of history")
        // A day the retention window could still hold, but nothing was recorded
        // in: an empty list, not an error.
        let emptyDay = try await queryURLs(webView, ["range": ["day": "1999-01-01"]])
        XCTAssertEqual(emptyDay, [], "a period with nothing in it is still a period")
        // Combined with a search: one row per URL, inside the period only.
        let searched = try await queryURLs(webView, ["search": "swift", "range": ["preset": "today"]])
        XCTAssertEqual(searched, ["https://today.example/"])
    }

    /// A `range` that is neither absent nor one of the two shapes is refused —
    /// never quietly widened to all of history.
    ///
    /// `history.delete` is not in this list any more: it takes the resolved
    /// `window` its rows were rendered under, never a period name (TASK-92), and
    /// a `range` it is sent anyway is simply a param it does not read.
    func testAMalformedRangeIsRejected() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Malformed Range")
        try seedVisit(db, url: "https://swift.org/", title: "Swift", spaceID: space.id,
                      visitTime: Date().timeIntervalSince1970 - 60)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let ranges: [Any] = [
            "today",
            ["preset": "decade"],
            ["preset": "day"],
            ["preset": "today", "day": "2026-01-01"],
            ["day": "2026-2-3"],
            ["day": "2026-02-30"],
            ["day": "2026-13-01"],
            ["day": 20260203],
            [String: Any](),
        ]
        for range in ranges {
            let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                               method: "history.query", params: ["range": range])
            XCTAssertNil(outcome.result, "history.query answered \(range)")
            XCTAssertEqual(outcome.error, "malformed", "history.query \(range)")
        }
        // Even next to a window it would otherwise read: a message that says
        // something unrecognizable is refused, not half-read.
        let both = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                        method: "history.query",
                                        params: ["range": ["preset": "decade"],
                                                 "window": ["from": 0, "until": NSNull()]])
        XCTAssertEqual(both.error, "malformed", "the window does not excuse the range")
        XCTAssertEqual(visitTimes(db, space).count, 1, "and nothing was deleted along the way")
    }

    /// The `window` the page echoes is validated as strictly as a range was:
    /// two keys, both there, `from` before `until`, on both methods.
    func testAMalformedWindowIsRejected() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Malformed Window")
        let visit = try seedVisit(db, url: "https://swift.org/", title: "Swift", spaceID: space.id,
                                  visitTime: Date().timeIntervalSince1970 - 60)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let windows: [Any] = [
            "today",
            100,
            ["from": 100],
            ["until": 200],
            ["from": 100, "until": 200, "extra": 1],
            ["from": 200, "until": 100],
            ["from": 200, "until": 200],
            ["from": "100", "until": "200"],
            ["from": NSNull(), "until": 200],
            [String: Any](),
            [100, 200],
        ]
        for window in windows {
            var outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                               method: "history.query", params: ["window": window])
            XCTAssertNil(outcome.result, "history.query answered \(window)")
            XCTAssertEqual(outcome.error, "malformed", "history.query \(window)")

            outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.delete",
                                           params: ["ids": [visit], "allVisitsOfURL": true,
                                                    "window": window])
            XCTAssertNil(outcome.result, "history.delete answered \(window)")
            XCTAssertEqual(outcome.error, "malformed", "history.delete \(window)")
        }
        // Refused whether or not the delete would have used it: a window it
        // cannot read is a message it cannot trust.
        let perVisit = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                            method: "history.delete",
                                            params: ["ids": [visit], "window": ["from": 200, "until": 100]])
        XCTAssertEqual(perVisit.error, "malformed")
        XCTAssertEqual(visitTimes(db, space).count, 1, "and nothing was deleted along the way")
    }

    /// The reply says which window it read under, so the page can ask for the
    /// rest of the same listing inside it. All of history has none: there is no
    /// period for a later page to stay inside.
    func testAQueryReplyCarriesTheWindowItRead() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Reply Window")
        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        try seedVisit(db, url: "https://today.example/", title: "Today", spaceID: space.id,
                      visitTime: startOfToday + 60)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let allTime = try await query(webView, [:])
        XCTAssertNil(allTime["window"], "all of history is not a window")

        let todayReply = try await query(webView, ["range": ["preset": "today"]])
        let today = try XCTUnwrap(todayReply["window"] as? [String: Any])
        XCTAssertEqual(today["from"] as? Double, startOfToday)
        XCTAssertTrue(today["until"] is NSNull, "today is still running, so it has no end")

        let yesterdayReply = try await query(webView, ["range": ["preset": "yesterday"]])
        let yesterday = try XCTUnwrap(yesterdayReply["window"] as? [String: Any])
        XCTAssertEqual(yesterday["until"] as? Double, startOfToday, "half-open, and closed")

        // And an echoed window is answered with itself: what the next page of
        // the listing will be asked for is what this one was read with.
        let echoedReply = try await query(webView, ["window": ["from": 10, "until": 20]])
        let echoed = try XCTUnwrap(echoedReply["window"] as? [String: Any])
        XCTAssertEqual(echoed["from"] as? Double, 10)
        XCTAssertEqual(echoed["until"] as? Double, 20)
    }

    /// AC #3, the midnight case: a listing pages inside the window it was
    /// rendered under. The window the page echoes is what the bounds are, and
    /// the symbolic range — which would resolve to something else entirely — is
    /// not consulted for them.
    func testAnEchoedWindowIsWhatALaterPageIsReadUnder() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Echoed Window")
        for time in [100.0, 200.0, 300.0, 400.0] {
            try seedVisit(db, url: "https://at\(Int(time)).example/", title: "Visit \(Int(time))",
                          spaceID: space.id, visitTime: time)
        }

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let window: [String: Any] = ["from": 50, "until": 350]
        let first = try await query(webView, ["window": window, "limit": 2])
        XCTAssertEqual((first["entries"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String },
                       ["https://at300.example/", "https://at200.example/"])
        let cursor = try XCTUnwrap(first["nextCursor"] as? [String: Any], "there is more to load")

        let second = try await query(webView, ["window": window, "limit": 2, "cursor": cursor])
        XCTAssertEqual((second["entries"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String },
                       ["https://at100.example/"], "inside the window, and the 400 visit is not in it")
        XCTAssertNil(second["nextCursor"], "that was the whole period")

        // The window wins over the range: "today" is nowhere near 1970, and the
        // entries are the window's.
        let both = try await query(webView, ["window": window, "range": ["preset": "today"], "limit": 10])
        XCTAssertEqual((both["entries"] as? [[String: Any]] ?? []).count, 3)
    }

    /// AC #5: deleting a search row while a period is showing takes that URL's
    /// visits inside the window the row was rendered under. The ones outside it
    /// are not what the row stood for, and they stay.
    func testDeletingAURLRowWithAWindowKeepsTheVisitsOutsideIt() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Ranged Delete")
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let longAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: startOfToday))
        let url = "https://zulu.example/"
        let today = try seedVisit(db, url: url, title: "Zulu", spaceID: space.id,
                                  visitTime: startOfToday.timeIntervalSince1970 + 60)
        try seedVisit(db, url: url, title: "Zulu", spaceID: space.id,
                      visitTime: startOfToday.timeIntervalSince1970 + 120)
        try seedVisit(db, url: url, title: "Zulu", spaceID: space.id,
                      visitTime: longAgo.timeIntervalSince1970 + 60)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.delete",
                                           params: ["ids": [today], "allVisitsOfURL": true,
                                                    "window": ["from": startOfToday.timeIntervalSince1970,
                                                               "until": NSNull()]])
        XCTAssertNil(outcome.error)
        XCTAssertEqual((outcome.result?["deleted"] as? NSNumber)?.intValue, 2, "today's two visits")
        XCTAssertEqual(visitTimes(db, space), [longAgo.timeIntervalSince1970 + 60],
                       "the visit from ten days ago was never on screen")
        XCTAssertTrue(try urlRowExists(db, url), "a visit remains, so the URL row stays")
    }

    /// The wire change itself: `history.delete` no longer knows what a `range`
    /// is. One sent anyway is an unread param — not an error, and above all not
    /// a narrowing the caller might think it asked for.
    func testDeleteIgnoresARangeParam() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Delete Range Param")
        let url = "https://zulu.example/"
        let long = try seedVisit(db, url: url, title: "Zulu", spaceID: space.id, visitTime: 100)
        try seedVisit(db, url: url, title: "Zulu", spaceID: space.id, visitTime: 200)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        // A range that would have refused the message, and one that would have
        // spared a visit: neither is read.
        let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld,
                                           method: "history.delete",
                                           params: ["ids": [long], "allVisitsOfURL": true,
                                                    "range": ["preset": "today"]])
        XCTAssertNil(outcome.error, "an unknown param is not a malformed message")
        XCTAssertEqual((outcome.result?["deleted"] as? NSNumber)?.intValue, 2,
                       "with no window, the fan-out is every in-scope visit of the URL")
        XCTAssertEqual(visitTimes(db, space), [])
    }

    /// AC #1 and #4 from the page's side: the control reloads the list into the
    /// period, the rows remember which period they were read under, and the URL
    /// carries it so a reload comes back to the same view.
    func testChoosingAPeriodFiltersTheListAndTheURL() async throws {
        let f = try await makePageFixture("Range Control")
        let before = try await pageState(f.webView)
        XCTAssertFalse(before.rangeHidden, "the control is there for a normal space")
        XCTAssertEqual(before.rangeValue, "", "and starts at All time")
        XCTAssertEqual(before.search, "")

        try await runInPage(f.webView, """
            const range = document.getElementById('range');
            range.value = 'yesterday';
            range.dispatchEvent(new Event('change'));
            return true;
            """)
        try await waitForRows(f.webView, 1, "only the one visit from yesterday")

        var state = try await pageState(f.webView)
        XCTAssertEqual(state.titles, ["Yesterday Page"])
        XCTAssertEqual(state.search, "?range=yesterday", "the period is in the page's URL")
        // The row remembers the *window* it was read under, not the name of the
        // period: by the time it is deleted, "yesterday" may mean another day
        // (TASK-92).
        let stamp = try await windowStamp(f.webView)
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let startOfYesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1,
                                                                   to: startOfToday))
        XCTAssertEqual(stamp?["from"] as? Double, startOfYesterday.timeIntervalSince1970)
        XCTAssertEqual(stamp?["until"] as? Double, startOfToday.timeIntervalSince1970)

        // A period nothing was recorded in names itself in the empty state.
        try await runInPage(f.webView, """
            const range = document.getElementById('range');
            range.value = 'day';
            range.dispatchEvent(new Event('change'));
            const day = document.getElementById('day');
            day.value = '2019-05-04';
            day.dispatchEvent(new Event('change'));
            return true;
            """)
        try await waitUntil("the empty state to name the day") {
            try await self.pageState(f.webView).emptyTitle?.hasPrefix("No history from ") == true
        }
        state = try await pageState(f.webView)
        XCTAssertEqual(state.search, "?day=2019-05-04")
        XCTAssertTrue(state.emptyTitle?.contains("2019") == true, "got \(state.emptyTitle ?? "nil")")

        // And back to all of it, with the URL emptied out again.
        try await runInPage(f.webView, """
            const range = document.getElementById('range');
            range.value = '';
            range.dispatchEvent(new Event('change'));
            return true;
            """)
        try await waitForRows(f.webView, 7)
        state = try await pageState(f.webView)
        XCTAssertEqual(state.search, "")
        XCTAssertEqual(visitTimes(f.db, f.space).count, 7, "filtering deletes nothing")
        let noWindow = try await windowStamp(f.webView)
        XCTAssertNil(noWindow, "all of history stamps no window")
    }

    /// "Specific day…" applies a day the moment it is chosen — the last day
    /// picked on this page, else today — so the control, the list and the URL
    /// are never three different answers. A field emptied afterwards goes back
    /// to the day on screen rather than stranding the list on a period nothing
    /// names.
    /// WebKit restores form values on a reload or a session restore after the
    /// page script has set the controls from the URL. The controls follow the
    /// page's state, not the other way round: a restored value that disagrees
    /// with the list is put right without a `change` (TASK-92).
    func testRestoredFormStateCannotPutTheRangeControlOutOfStepWithTheList() async throws {
        let f = try await makePageFixture("Restored Form State")

        try await runInPage(f.webView, """
            // What form-state restoration does: a value, and no event.
            document.getElementById('range').value = 'week';
            window.dispatchEvent(new Event('pageshow'));
            return true;
            """)
        let state = try await pageState(f.webView)
        XCTAssertEqual(state.rangeValue, "", "the list is on all time, so the control says so")
        XCTAssertTrue(state.dayHidden)
        XCTAssertEqual(state.search, "")
    }

    func testChoosingASpecificDayFiltersToADayAtOnce() async throws {
        let f = try await makePageFixture("Specific Day")
        let today = todayText()
        let startOfToday = Calendar.current.startOfDay(for: Date())

        try await runInPage(f.webView, """
            const range = document.getElementById('range');
            range.value = 'day';
            range.dispatchEvent(new Event('change'));
            return true;
            """)
        try await waitForRows(f.webView, 6, "today's visits, without yesterday's")

        var state = try await pageState(f.webView)
        XCTAssertEqual(state.dayValue, today, "the field names a day straight away")
        XCTAssertEqual(state.search, "?day=\(today)", "and the page's URL agrees with it")
        XCTAssertFalse(state.dayHidden)
        XCTAssertNil(state.dayMin, "no lower bound: the expiry only runs at launch, so older days exist")
        XCTAssertEqual(state.dayMax, today, "capped at today, set each time the field is revealed")

        let stamp = try await windowStamp(f.webView)
        XCTAssertEqual(stamp?["from"] as? Double, startOfToday.timeIntervalSince1970)
        XCTAssertEqual(stamp?["until"] as? Double,
                       try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: startOfToday))
                           .timeIntervalSince1970,
                       "the rows carry the day's own window")

        // Emptied and committed: nothing changes but the field, which is put
        // back to the day the list is actually showing.
        try await runInPage(f.webView, """
            const day = document.getElementById('day');
            day.value = '';
            day.dispatchEvent(new Event('input'));
            day.dispatchEvent(new Event('change'));
            return true;
            """)
        state = try await pageState(f.webView)
        XCTAssertEqual(state.dayValue, today, "the field was put back")
        XCTAssertEqual(state.ids.count, 6, "and the listing was left where it was")
        XCTAssertEqual(state.search, "?day=\(today)")

        // A day of the user's own, then away to another period and back: it is
        // that day the choice returns to, not today.
        let yesterday = dayText(try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1,
                                                                    to: startOfToday)))
        try await runInPage(f.webView, """
            const day = document.getElementById('day');
            day.value = '\(yesterday)';
            day.dispatchEvent(new Event('input'));
            return true;
            """)
        try await waitForRows(f.webView, 1, "the one visit from yesterday")

        try await runInPage(f.webView, """
            const range = document.getElementById('range');
            range.value = 'week';
            range.dispatchEvent(new Event('change'));
            return true;
            """)
        try await waitForRows(f.webView, 7, "the whole week")
        let weekState = try await pageState(f.webView)
        XCTAssertTrue(weekState.dayHidden, "and the field goes away with the choice")

        try await runInPage(f.webView, """
            const range = document.getElementById('range');
            range.value = 'day';
            range.dispatchEvent(new Event('change'));
            return true;
            """)
        try await waitForRows(f.webView, 1, "back to the day that was picked")
        state = try await pageState(f.webView)
        XCTAssertEqual(state.dayValue, yesterday)
        XCTAssertEqual(state.search, "?day=\(yesterday)")
    }

    /// AC #5 end to end, and the reason the row carries a window rather than a
    /// period: a URL row deleted while a day is showing takes that URL's visits
    /// *in that day* and leaves the ones the user could not see.
    func testDeletingASearchRowUnderADayLeavesTheOtherDaysVisits() async throws {
        let f = try await makePageFixture("Windowed Row Delete")
        let today = todayText()
        // One more visit of the search row's URL, on another day entirely.
        try seedVisit(f.db, url: "https://zulu.example/", title: "Zulu Page", spaceID: f.space.id,
                      visitTime: Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 - 86_400 * 3)

        try await runInPage(f.webView, """
            const range = document.getElementById('range');
            range.value = 'day';
            range.dispatchEvent(new Event('change'));
            const search = document.getElementById('search');
            search.value = 'zulu';
            search.dispatchEvent(new Event('input'));
            return true;
            """)
        try await waitForRows(f.webView, 1, "one row for the URL, inside today")

        try await runInPage(f.webView, """
            document.querySelector('.item .delete').click();
            return true;
            """)
        try await waitForRows(f.webView, 0)

        let afterState = try await pageState(f.webView)
        XCTAssertEqual(afterState.search, "?q=zulu&day=\(today)")
        let left = f.db.visits(spaceIDs: [f.space.id.uuidString], limit: 100)
            .filter { $0.url == "https://zulu.example/" }
        XCTAssertEqual(left.count, 1, "the visit from three days ago was not on screen and stays")
    }

    // MARK: - The selection shares the search row (TASK-95)

    /// A JSON object the page built, as a dictionary — for the measurements
    /// below that `pageState` has no business carrying.
    private func jsonFromPage(_ webView: WKWebView, _ js: String) async throws -> [String: Any] {
        let raw = try await runInPage(webView, js)
        let text = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Starts counting the `history.query` messages the page sends, and zeroes
    /// the count. Every read the page makes goes through `postMessage` on the
    /// bridge's handler, so wrapping that — from inside the page's own content
    /// world, where the script already lives — is the one place that sees them
    /// all; nothing is added to the page for this. A test that needs "no read
    /// happened" also asserts a read happening later, which is what proves the
    /// wrapper was in place rather than quietly missing.
    private func instrumentBridge(_ webView: WKWebView) async throws {
        try await runInPage(webView, """
            if (!window.bridgeLog) {
                window.bridgeLog = { sent: 0, settled: 0, deletes: 0 };
                const handler = window.webkit.messageHandlers.detourInternal;
                const proto = Object.getPrototypeOf(handler);
                const original = proto.postMessage;
                proto.postMessage = function (body) {
                    const method = body && body.method;
                    if (method === 'history.delete') window.bridgeLog.deletes += 1;
                    const answer = original.call(this, body);
                    if (method !== 'history.query') return answer;
                    window.bridgeLog.sent += 1;
                    // Counted where the reply arrives, so a test can wait for
                    // the page to have been *told* rather than for a guess at
                    // how long telling it takes. The page's own handler runs
                    // in the microtask after this one, which is still long
                    // before the next round trip from the test.
                    return answer.then(
                        (value) => { window.bridgeLog.settled += 1; return value; },
                        (error) => { window.bridgeLog.settled += 1; throw error; });
                };
            }
            window.bridgeLog.sent = 0;
            window.bridgeLog.settled = 0;
            window.bridgeLog.deletes = 0;
            return true;
            """)
    }

    /// What the page has asked the bridge for since the counters were zeroed.
    private struct BridgeLog: Equatable {
        var sent = 0
        var settled = 0
        var deletes = 0
    }

    private func bridgeLog(_ webView: WKWebView) async throws -> BridgeLog {
        let dict = try await jsonFromPage(webView, "return JSON.stringify(window.bridgeLog);")
        var log = BridgeLog()
        log.sent = (dict["sent"] as? NSNumber)?.intValue ?? -1
        log.settled = (dict["settled"] as? NSNumber)?.intValue ?? -1
        log.deletes = (dict["deletes"] as? NSNumber)?.intValue ?? -1
        return log
    }

    /// Waits for `count` reads to have been answered, so what is asserted
    /// afterwards is the page's state *after* the reply, not while it is in
    /// flight.
    private func waitForSettledQueries(_ webView: WKWebView, _ count: Int,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("\(count) history.query repl(y|ies) to land", file: file, line: line) {
            try await self.bridgeLog(webView).settled >= count
        }
    }

    /// Everything a selection must leave exactly as it found it: how tall the
    /// sticky header is, where the list sits under it, and where the page is
    /// scrolled to. The numbers themselves are nobody's business — only that
    /// they are the same in both states.
    private struct HeaderGeometry: Equatable {
        var headerHeight = 0.0
        var firstItemTop = 0.0
        var lastItemTop = 0.0
        var scrollY = 0.0
    }

    private func geometry(_ webView: WKWebView) async throws -> HeaderGeometry {
        let dict = try await jsonFromPage(webView, """
            const items = document.querySelectorAll('.item');
            const last = items.length ? items[items.length - 1] : null;
            return JSON.stringify({
                headerHeight: document.getElementById('bar').offsetHeight,
                firstItemTop: items.length ? items[0].getBoundingClientRect().top : 0,
                lastItemTop: last ? last.getBoundingClientRect().top : 0,
                scrollY: window.scrollY,
            });
            """)
        var geometry = HeaderGeometry()
        geometry.headerHeight = (dict["headerHeight"] as? NSNumber)?.doubleValue ?? -1
        geometry.firstItemTop = (dict["firstItemTop"] as? NSNumber)?.doubleValue ?? -1
        geometry.lastItemTop = (dict["lastItemTop"] as? NSNumber)?.doubleValue ?? -1
        geometry.scrollY = (dict["scrollY"] as? NSNumber)?.doubleValue ?? -1
        return geometry
    }

    private func assertUnmoved(_ actual: HeaderGeometry, _ expected: HeaderGeometry, _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.headerHeight, expected.headerHeight, accuracy: 0.01,
                       "the header changed height \(what)", file: file, line: line)
        XCTAssertEqual(actual.firstItemTop, expected.firstItemTop, accuracy: 0.01,
                       "the first row moved \(what)", file: file, line: line)
        XCTAssertEqual(actual.lastItemTop, expected.lastItemTop, accuracy: 0.01,
                       "the last row moved \(what)", file: file, line: line)
        XCTAssertEqual(actual.scrollY, expected.scrollY, accuracy: 0.01,
                       "the page scrolled \(what)", file: file, line: line)
    }

    /// AC: ticking the first row's checkbox moves nothing — not the header's
    /// height, not a row, not the scroll position — and neither does clearing
    /// the selection again (TASK-95).
    func testSelectingTheFirstRowMovesNothing() async throws {
        let f = try await makePageFixture("Selection Layout")
        let idle = try await geometry(f.webView)

        try await runInPage(f.webView, """
            document.getElementById('search').blur();
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            return true;
            """)
        var selection = try await pageState(f.webView).selection
        XCTAssertEqual(selection, "1 selected")
        try await assertUnmoved(geometry(f.webView), idle, "while a row is selected")

        try await runInPage(f.webView, """
            document.getElementById('selection-cancel').click();
            return true;
            """)
        selection = try await pageState(f.webView).selection
        XCTAssertNil(selection)
        try await assertUnmoved(geometry(f.webView), idle, "after the selection was cleared")
    }

    /// The same, with the list scrolled: the header is sticky, so a strip added
    /// to it would push every visible row down here too.
    func testSelectingARowMovesNothingWhenTheListIsScrolled() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Selection Scrolled")
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        // One page of a single day: enough rows to scroll, few enough that the
        // listing is finished and no paging can append while this test measures.
        for index in 1...40 {
            try seedVisit(db, url: "https://page.example/\(index)", title: "Page \(index)",
                          spaceID: space.id, visitTime: startOfDay + Double(index))
        }

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)
        try await waitForRows(webView, 40)

        // The preconditions this test rests on, named so a host view too small
        // to scroll fails as itself rather than as a mysterious equality.
        let room = try await jsonFromPage(webView, """
            window.scrollTo(0, 300);
            return JSON.stringify({
                overflow: document.documentElement.scrollHeight - window.innerHeight,
                scrollY: window.scrollY,
            });
            """)
        XCTAssertGreaterThan((room["overflow"] as? NSNumber)?.doubleValue ?? 0, 300,
                             "the page is not tall enough to scroll 300pt: nothing to test")
        XCTAssertEqual((room["scrollY"] as? NSNumber)?.doubleValue ?? -1, 300, accuracy: 0.01,
                       "the list never scrolled")

        let idle = try await geometry(webView)
        // A row that is actually on screen under the header, the way a pointer
        // would have found one.
        let picked = try await runInPage(webView, """
            document.getElementById('search').blur();
            const header = document.getElementById('bar').getBoundingClientRect().bottom;
            const item = Array.from(document.querySelectorAll('.item')).find((el) => {
                const rect = el.getBoundingClientRect();
                return rect.top > header && rect.bottom < window.innerHeight;
            });
            if (!item) return '';
            item.querySelector('.pick').click();
            return String(item.dataset.id);
            """) as? String
        XCTAssertFalse(try XCTUnwrap(picked, "the page answered nothing at all").isEmpty,
                       "no row was on screen under the header to pick")
        var selection = try await pageState(webView).selection
        XCTAssertEqual(selection, "1 selected")
        try await assertUnmoved(geometry(webView), idle, "while a row is selected, scrolled down")

        try await runInPage(webView, """
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            return true;
            """)
        selection = try await pageState(webView).selection
        XCTAssertNil(selection)
        try await assertUnmoved(geometry(webView), idle, "after Escape, scrolled down")
    }

    /// The row's own controls leave the row entirely while a selection is on —
    /// the fixed-height row is what keeps the header still, so `display: none`
    /// is safe here, and it takes them out of hit-testing, the tab order and
    /// the accessibility tree. They come back with the search term, the period
    /// and the page's URL untouched.
    func testTheSearchRowsControlsLeaveTheRowAndComeBackUnchanged() async throws {
        let f = try await makePageFixture("Selection Controls")

        try await runInPage(f.webView, """
            const range = document.getElementById('range');
            range.value = 'week';
            range.dispatchEvent(new Event('change'));
            const search = document.getElementById('search');
            search.value = 'today';
            search.dispatchEvent(new Event('input'));
            return true;
            """)
        try await waitForRows(f.webView, 3, "the three pages titled Today")
        let before = try await pageState(f.webView)
        XCTAssertEqual(before.rangeValue, "week")
        XCTAssertEqual(before.search, "?q=today&range=week")

        try await runInPage(f.webView, """
            document.getElementById('search').blur();
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            return true;
            """)
        let selecting = try await jsonFromPage(f.webView, """
            const display = (id) => getComputedStyle(document.getElementById(id)).display;
            return JSON.stringify({
                search: display('search'),
                range: display('range'),
                clear: display('clear'),
                day: display('day'),
                title: getComputedStyle(document.querySelector('h1')).display,
                selection: display('selection'),
                count: document.getElementById('selection-count').textContent,
                searchValue: document.getElementById('search').value,
            });
            """)
        XCTAssertEqual(selecting["search"] as? String, "none")
        XCTAssertEqual(selecting["range"] as? String, "none",
                       "the class rule has to out-rank the .picker styling")
        XCTAssertEqual(selecting["clear"] as? String, "none",
                       "and the .menu styling")
        XCTAssertEqual(selecting["day"] as? String, "none")
        XCTAssertNotEqual(selecting["title"] as? String, "none", "the page's own title stays")
        XCTAssertNotEqual(selecting["selection"] as? String, "none")
        XCTAssertEqual(selecting["count"] as? String, "1 selected")
        XCTAssertEqual(selecting["searchValue"] as? String, "today", "hidden, not emptied")

        try await runInPage(f.webView, """
            document.getElementById('selection-cancel').click();
            return true;
            """)
        let after = try await jsonFromPage(f.webView, """
            const display = (id) => getComputedStyle(document.getElementById(id)).display;
            return JSON.stringify({
                search: display('search'),
                range: display('range'),
                clear: display('clear'),
                day: display('day'),
                selection: display('selection'),
                searchValue: document.getElementById('search').value,
            });
            """)
        XCTAssertNotEqual(after["search"] as? String, "none")
        XCTAssertNotEqual(after["range"] as? String, "none")
        XCTAssertNotEqual(after["clear"] as? String, "none")
        XCTAssertEqual(after["day"] as? String, "none",
                       "the date field belongs to a choice nobody made: still hidden by its own attribute")
        XCTAssertEqual(after["selection"] as? String, "none")
        XCTAssertEqual(after["searchValue"] as? String, "today")
        let state = try await pageState(f.webView)
        XCTAssertEqual(state.rangeValue, "week", "the period came back as it was")
        XCTAssertEqual(state.search, "?q=today&range=week", "and so did the page's URL")
        XCTAssertEqual(state.ids.count, 3, "the listing itself never changed")
    }

    /// A Clear History menu left open would hang over a list the selection is
    /// about to change, and come back open afterwards: entering the selection
    /// closes it, and it stays closed.
    func testStartingASelectionClosesTheClearHistoryMenu() async throws {
        let f = try await makePageFixture("Selection Closes Menu")

        let opened = try await jsonFromPage(f.webView, """
            document.getElementById('search').blur();
            const clear = document.getElementById('clear');
            clear.open = true;
            const wasOpen = clear.open;
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            return JSON.stringify({ wasOpen: wasOpen, open: clear.open });
            """)
        XCTAssertEqual(opened["wasOpen"] as? Bool, true, "the menu was open to begin with")
        XCTAssertEqual(opened["open"] as? Bool, false, "and the selection closed it")

        let afterEscape = try await jsonFromPage(f.webView, """
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            return JSON.stringify({
                open: document.getElementById('clear').open,
                selected: document.querySelectorAll('.item.selected').length,
            });
            """)
        XCTAssertEqual(afterEscape["open"] as? Bool, false, "it did not come back open")
        XCTAssertEqual((afterEscape["selected"] as? NSNumber)?.intValue, 0,
                       "Escape cleared the selection, not the menu")
    }

    /// A control that has just left the row may not keep the caret — it would
    /// be typed into unseen. Focus goes back to the document while the
    /// selection is on, and the field gets it back when the selection ends.
    func testASelectionNeverLeavesFocusInAControlThatLeftTheRow() async throws {
        let f = try await makePageFixture("Selection Focus")

        let selecting = try await jsonFromPage(f.webView, """
            const search = document.getElementById('search');
            search.focus();
            const before = document.activeElement.id;
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            const active = document.activeElement;
            return JSON.stringify({
                before: before,
                after: active.id || active.tagName,
                activeDisplay: getComputedStyle(active).display,
                searchDisplay: getComputedStyle(search).display,
            });
            """)
        XCTAssertEqual(selecting["before"] as? String, "search", "the field had focus to begin with")
        XCTAssertEqual(selecting["searchDisplay"] as? String, "none")
        XCTAssertNotEqual(selecting["after"] as? String, "search", "focus stayed in the hidden field")
        XCTAssertNotEqual(selecting["activeDisplay"] as? String, "none",
                          "focus is on something that is rendered")

        let afterEscape = try await jsonFromPage(f.webView, """
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            const active = document.activeElement;
            return JSON.stringify({
                active: active.id || active.tagName,
                searchDisplay: getComputedStyle(document.getElementById('search')).display,
            });
            """)
        XCTAssertNotEqual(afterEscape["searchDisplay"] as? String, "none", "the field is back")
        XCTAssertEqual(afterEscape["active"] as? String, "search",
                       "and Escape hands the caret back to it")
    }

    /// The flow the restore is for: type a query, tick a row, change your mind,
    /// carry on typing. Cancel gives the field its focus and its text back —
    /// and runs the search it was owed.
    func testCancellingASelectionGivesTheSearchFieldItsFocusBack() async throws {
        let f = try await makePageFixture("Focus Restore")

        try await runInPage(f.webView, """
            const search = document.getElementById('search');
            search.focus();
            search.value = 'zulu';
            search.dispatchEvent(new Event('input'));
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            return true;
            """)
        let restored = try await jsonFromPage(f.webView, """
            document.getElementById('selection-cancel').click();
            const active = document.activeElement;
            return JSON.stringify({
                active: active.id || active.tagName,
                value: document.getElementById('search').value,
            });
            """)
        XCTAssertEqual(restored["active"] as? String, "search")
        XCTAssertEqual(restored["value"] as? String, "zulu", "with what was typed still in it")
        try await waitForRows(f.webView, 1, "and the search the selection held back")
    }

    /// Focus is given back, never taken: a user who put the caret somewhere
    /// else during the selection keeps it there.
    func testASelectionDoesNotTakeFocusBackFromWhereTheUserPutIt() async throws {
        let f = try await makePageFixture("Focus Not Stolen")

        let result = try await jsonFromPage(f.webView, """
            const search = document.getElementById('search');
            search.focus();
            const items = document.querySelectorAll('.item');
            items[0].querySelector('.pick').click();
            // The user goes somewhere else while the selection is on.
            items[1].querySelector('.pick').focus();
            const before = document.activeElement.className;
            document.getElementById('selection-cancel').click();
            const active = document.activeElement;
            return JSON.stringify({
                before: before,
                after: active.id || active.className || active.tagName,
            });
            """)
        XCTAssertEqual(result["before"] as? String, "pick", "the user moved the caret themselves")
        XCTAssertEqual(result["after"] as? String, "pick", "and it was not taken back off them")
    }

    /// A search typed a moment before a row is ticked must not land in the
    /// middle of the selection: re-rendering the list would throw the tick away
    /// and flash the header. The debounce is held, and run when the selection
    /// ends (TASK-95).
    func testASearchTypedBeforeASelectionWaitsForItToEnd() async throws {
        let f = try await makePageFixture("Pending Search Selection")
        try await instrumentBridge(f.webView)

        let typed = try await jsonFromPage(f.webView, """
            const search = document.getElementById('search');
            search.focus();
            search.value = 'zulu';
            search.dispatchEvent(new Event('input'));
            // The same turn, so the 150 ms debounce cannot have fired: the user
            // ticks a row while the search is still owed.
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            window.firstItem = document.querySelectorAll('.item')[0];
            return JSON.stringify({
                selecting: document.getElementById('bar').classList.contains('selecting'),
                count: document.getElementById('selection-count').textContent,
            });
            """)
        XCTAssertEqual(typed["selecting"] as? Bool, true)
        XCTAssertEqual(typed["count"] as? String, "1 selected")
        let before = try await pageState(f.webView).ids

        // Well past the debounce: nothing may have happened.
        try await Task.sleep(nanoseconds: 600_000_000)
        let waited = try await jsonFromPage(f.webView, """
            return JSON.stringify({
                selecting: document.getElementById('bar').classList.contains('selecting'),
                count: document.getElementById('selection-count').textContent,
                selected: document.querySelectorAll('.item.selected').length,
                sameFirstRow: document.querySelectorAll('.item')[0] === window.firstItem,
                search: location.search,
            });
            """)
        XCTAssertEqual(waited["selecting"] as? Bool, true, "the header left selection mode")
        XCTAssertEqual(waited["count"] as? String, "1 selected")
        XCTAssertEqual((waited["selected"] as? NSNumber)?.intValue, 1, "the tick survived")
        XCTAssertEqual(waited["sameFirstRow"] as? Bool, true, "the rows were re-rendered under it")
        XCTAssertEqual(waited["search"] as? String, "", "and the search had not run")
        let during = try await pageState(f.webView).ids
        XCTAssertEqual(during, before, "the listing is still the one the row was ticked in")
        // Not "nothing visibly changed" — nothing was even asked.
        var reads = try await bridgeLog(f.webView)
        XCTAssertEqual(reads.sent, 0, "the page read the history while a selection was up")

        try await runInPage(f.webView, """
            document.getElementById('selection-cancel').click();
            return true;
            """)
        try await waitForRows(f.webView, 1, "the owed search, run once the selection ended")
        let after = try await pageState(f.webView)
        XCTAssertEqual(after.titles, ["Zulu Page"])
        XCTAssertEqual(after.search, "?q=zulu", "through the ordinary path, URL and all")
        // And the counter did move, so the zero above was a real observation.
        reads = try await bridgeLog(f.webView)
        XCTAssertEqual(reads.sent, 1, "the owed search is one read, and the counter saw it")
    }

    /// A narrow window is where an overlay would have put the count on top of
    /// the title. In the row itself the count is just another flex child: it
    /// ellipsizes, and the buttons stay inside the row.
    func testTheSelectionFitsANarrowWindowWithoutOverlappingTheTitle() async throws {
        let f = try await makePageFixture("Narrow Selection")
        // The same way `makeTab` sizes it — the view is in no hierarchy, so
        // nothing lays it back out; if that ever changes this fails as a
        // precondition rather than as a wait that never ends.
        f.webView.frame = NSRect(x: 0, y: 0, width: 360, height: 700)
        try await waitUntil("the web view to lay out at 360pt", timeout: 3) {
            (try await self.runInPage(f.webView, "return window.innerWidth;") as? NSNumber)?
                .intValue == 360
        }
        let width = try await runInPage(f.webView, "return window.innerWidth;") as? NSNumber
        XCTAssertEqual(width?.intValue, 360,
                       "the web view did not keep the narrow frame this test needs")

        let boxes = try await jsonFromPage(f.webView, """
            document.getElementById('search').blur();
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }));
            const box = (el) => {
                const rect = el.getBoundingClientRect();
                return { left: rect.left, right: rect.right };
            };
            const count = document.getElementById('selection-count');
            return JSON.stringify({
                title: box(document.querySelector('h1')),
                count: box(count),
                remove: box(document.getElementById('selection-delete')),
                cancel: box(document.getElementById('selection-cancel')),
                row: box(document.getElementById('bar-main')),
                text: count.textContent,
            });
            """)
        XCTAssertEqual(boxes["text"] as? String, "7 selected")
        let edge = { (name: String, side: String) -> Double in
            ((boxes[name] as? [String: Any])?[side] as? NSNumber)?.doubleValue ?? .nan
        }
        XCTAssertGreaterThanOrEqual(edge("count", "left"), edge("title", "right"),
                                    "the count is on top of the title")
        XCTAssertLessThanOrEqual(edge("count", "right"), edge("remove", "left") + 0.5,
                                 "the count runs into the buttons")
        // The row's padding, read off the title rather than taken from the CSS.
        let padding = edge("title", "left") - edge("row", "left")
        XCTAssertGreaterThanOrEqual(edge("remove", "left"), edge("row", "left") + padding - 0.5)
        XCTAssertLessThanOrEqual(edge("cancel", "right"), edge("row", "right") - padding + 0.5,
                                 "a button hangs off the end of the row")
    }

    /// Incognito hides the period and Clear History controls altogether, which
    /// is the row the swap has to work in as well. A private space records
    /// nothing, so there is no row to tick: the header's two states are driven
    /// here by the one class `updateSelectionBar` toggles.
    func testTheIncognitoHeaderKeepsItsHeightInBothStates() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let tab = makeTab(in: makeIncognitoSpace())
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let chrome = try await pageState(webView)
        XCTAssertTrue(chrome.clearHidden)
        XCTAssertTrue(chrome.rangeHidden)

        let measured = try await jsonFromPage(webView, """
            const bar = document.getElementById('bar');
            const empty = document.getElementById('empty');
            const measure = () => [bar.offsetHeight, empty.getBoundingClientRect().top];
            const idle = measure();
            bar.classList.add('selecting');
            const selecting = measure();
            const selectionDisplay = getComputedStyle(document.getElementById('selection')).display;
            bar.classList.remove('selecting');
            return JSON.stringify({
                idle: idle, selecting: selecting, back: measure(),
                selectionDisplay: selectionDisplay,
            });
            """)
        let idle = (measured["idle"] as? [NSNumber])?.map(\.doubleValue) ?? []
        XCTAssertEqual(idle.count, 2)
        XCTAssertEqual((measured["selecting"] as? [NSNumber])?.map(\.doubleValue), idle,
                       "the private header grew, or the empty state moved")
        XCTAssertEqual((measured["back"] as? [NSNumber])?.map(\.doubleValue), idle)
        XCTAssertNotEqual(measured["selectionDisplay"] as? String, "none",
                          "the controls show even with nothing else in the row")
    }

    /// The reply to a read that was already in flight when the selection
    /// started is a replacement too, and waits its turn: dropped where it
    /// lands, re-asked when the selection ends (TASK-95).
    func testAReplyInFlightWhenTheSelectionStartsIsDroppedAndReAsked() async throws {
        let f = try await makePageFixture("Deferred Reply")
        try await instrumentBridge(f.webView)

        // The database is one connection, so holding a write holds the search
        // the page is about to issue: its reply cannot land until this test
        // lets it, which is when the selection is already up.
        let released = expectation(description: "the writer queue is given back")
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // Whatever happens below — a failed wait, a thrown assertion — the
        // queue is given back, or the database (and teardown with it) hangs.
        defer { release.signal() }
        DispatchQueue.global().async {
            try? f.db.dbQueue.write { _ in
                holding.signal()
                release.wait()
            }
            released.fulfill()
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 10), .success, "the write never started")

        try await runInPage(f.webView, """
            const search = document.getElementById('search');
            search.value = 'zulu';
            search.dispatchEvent(new Event('input'));
            return true;
            """)
        // The page writes its URL as it issues the query, so this is the
        // request being on its way.
        try await waitUntil("the search to be issued") {
            try await self.runInPage(f.webView, "return location.search;") as? String == "?q=zulu"
        }

        // The reply really is still held: the list is the unfiltered one the
        // page started with, not the single row 'zulu' answers.
        let before = try await pageState(f.webView).ids
        XCTAssertEqual(before.count, 7, "the search was answered before the row was ticked")
        var log = try await bridgeLog(f.webView)
        XCTAssertEqual(log.settled, 0, "the reply had already landed: nothing was deferred")

        try await runInPage(f.webView, """
            document.getElementById('search').blur();
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            window.firstItem = document.querySelectorAll('.item')[0];
            return true;
            """)
        release.signal()
        await fulfillment(of: [released], timeout: 10)
        // The held reply has now been answered — and dropped.
        try await waitForSettledQueries(f.webView, 1)

        let during = try await jsonFromPage(f.webView, """
            return JSON.stringify({
                selecting: document.getElementById('bar').classList.contains('selecting'),
                selected: document.querySelectorAll('.item.selected').length,
                sameFirstRow: document.querySelectorAll('.item')[0] === window.firstItem,
            });
            """)
        XCTAssertEqual(during["selecting"] as? Bool, true, "the header left selection mode")
        XCTAssertEqual((during["selected"] as? NSNumber)?.intValue, 1, "the tick was thrown away")
        XCTAssertEqual(during["sameFirstRow"] as? Bool, true, "the list was replaced under it")
        let stillThere = try await pageState(f.webView).ids
        XCTAssertEqual(stillThere, before, "the rows the tick belongs to are still the ones on screen")

        try await runInPage(f.webView, """
            document.getElementById('selection-cancel').click();
            return true;
            """)
        try await waitForRows(f.webView, 1, "the search, asked again once the selection ended")
        let after = try await pageState(f.webView)
        XCTAssertEqual(after.titles, ["Zulu Page"])
        XCTAssertEqual(after.search, "?q=zulu")
        log = try await bridgeLog(f.webView)
        XCTAssertEqual(log.sent, 2, "the search, and the one that replaced the dropped reply")
        XCTAssertEqual(log.settled, 2)
    }

    /// A refresh — the tab coming back into view, the window taking focus — is
    /// deferred too, and it is still a *refresh* when it runs: it finds the
    /// same top row and leaves the list, and the rows paged in below it, alone.
    func testARefreshWhileSelectingIsDeferredAndStillARefresh() async throws {
        let f = try await makePageFixture("Deferred Refresh")
        try await instrumentBridge(f.webView)

        try await runInPage(f.webView, """
            document.getElementById('search').blur();
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            window.firstItem = document.querySelectorAll('.item')[0];
            // What the window taking focus does.
            window.dispatchEvent(new Event('focus'));
            return true;
            """)
        try await Task.sleep(nanoseconds: 400_000_000)

        let during = try await jsonFromPage(f.webView, """
            return JSON.stringify({
                selecting: document.getElementById('bar').classList.contains('selecting'),
                selected: document.querySelectorAll('.item.selected').length,
                sameFirstRow: document.querySelectorAll('.item')[0] === window.firstItem,
            });
            """)
        XCTAssertEqual(during["selecting"] as? Bool, true)
        XCTAssertEqual((during["selected"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(during["sameFirstRow"] as? Bool, true)
        var log = try await bridgeLog(f.webView)
        XCTAssertEqual(log.sent, 0, "the refresh read the history anyway")

        try await runInPage(f.webView, """
            document.getElementById('selection-cancel').click();
            return true;
            """)
        // Waited for the *reply*, not for the request: what the page does with
        // a refresh is only knowable once it has been answered.
        try await waitForSettledQueries(f.webView, 1)
        let after = try await jsonFromPage(f.webView, """
            return JSON.stringify({
                sameFirstRow: document.querySelectorAll('.item')[0] === window.firstItem,
                rows: document.querySelectorAll('.item').length,
                search: location.search,
            });
            """)
        XCTAssertEqual(after["sameFirstRow"] as? Bool, true,
                       "a refresh that found nothing new still re-rendered the list")
        XCTAssertEqual((after["rows"] as? NSNumber)?.intValue, 7)
        XCTAssertEqual(after["search"] as? String, "")
        log = try await bridgeLog(f.webView)
        XCTAssertEqual(log.sent, 1, "one read, and it was the deferred refresh")
    }

    /// Only *replacing* the list is deferred. Cmd+A and then scrolling for
    /// more is a real flow, so a load-more page still appends — under the
    /// selection, which keeps every row it had.
    func testLoadMoreStillAppendsWhileSelecting() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Append While Selecting")
        let start = Date().timeIntervalSince1970 - 7200
        for index in 1...150 {
            try seedVisit(db, url: "https://page.example/\(index)", title: "Page \(index)",
                          spaceID: space.id, visitTime: start + Double(index))
        }

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)
        try await waitForRows(webView, 100, "one page of a history that has more")

        let chosen = try await runInPage(webView, """
            document.getElementById('search').blur();
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }));
            window.scrollTo(0, document.documentElement.scrollHeight);
            return document.querySelectorAll('.item.selected').length;
            """) as? NSNumber
        XCTAssertEqual(chosen?.intValue, 100, "Cmd+A took the loaded rows")

        try await waitForRows(webView, 150, "the next page, appended under the selection")
        let after = try await jsonFromPage(webView, """
            return JSON.stringify({
                selecting: document.getElementById('bar').classList.contains('selecting'),
                selected: document.querySelectorAll('.item.selected').length,
                count: document.getElementById('selection-count').textContent,
            });
            """)
        XCTAssertEqual(after["selecting"] as? Bool, true, "appending ended the selection")
        XCTAssertEqual((after["selected"] as? NSNumber)?.intValue, 100,
                       "the rows that were ticked are still ticked")
        XCTAssertEqual(after["count"] as? String, "100 selected",
                       "and the new rows were not ticked for the user")
    }

    /// A delete that fails: the selection ends — the header may not go on
    /// offering Delete for rows it could not delete — and the list is rebuilt
    /// from the database exactly once.
    func testAFailedDeleteClearsTheSelectionAndRebuildsTheListOnce() async throws {
        let f = try await makePageFixture("Failed Delete Selection")
        try blockVisitDeletes(f.db)
        try await instrumentBridge(f.webView)

        try await runInPage(f.webView, """
            document.getElementById('search').blur();
            const items = document.querySelectorAll('.item');
            items[0].querySelector('.pick').click();
            items[1].querySelector('.pick').click();
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete', bubbles: true }));
            return true;
            """)
        try await waitUntil("the page to report the failure") {
            try await self.pageState(f.webView).notice != nil
        }
        // The recovery's own read, answered — not "the rows are still seven",
        // which they were the whole time.
        try await waitForSettledQueries(f.webView, 1)

        let state = try await pageState(f.webView)
        XCTAssertEqual(state.ids.count, 7, "the rows the database still has came back")
        XCTAssertEqual(state.notice, "Those entries could not be deleted.")
        XCTAssertNil(state.selection, "the header still offers Delete for rows it could not delete")
        let after = try await jsonFromPage(f.webView, """
            return JSON.stringify({
                selecting: document.getElementById('bar').classList.contains('selecting'),
                selected: document.querySelectorAll('.item.selected').length,
                searchDisplay: getComputedStyle(document.getElementById('search')).display,
            });
            """)
        XCTAssertEqual(after["selecting"] as? Bool, false, "the header was left in selection mode")
        XCTAssertEqual((after["selected"] as? NSNumber)?.intValue, 0)
        XCTAssertNotEqual(after["searchDisplay"] as? String, "none", "with the search field hidden")
        // Give a second reload the time it would need to show up.
        try await Task.sleep(nanoseconds: 400_000_000)
        let log = try await bridgeLog(f.webView)
        XCTAssertEqual(log.sent, 1, "the recovery read the history more than once")
        XCTAssertEqual(log.deletes, 1, "and it asked to delete more than once")
        XCTAssertEqual(visitTimes(f.db, f.space).count, 7)
    }

    /// The caret comes back when the delete *failed*: nothing was removed, the
    /// key that asked is long since up, and the user is where they were.
    func testAFailedDeleteGivesTheSearchFieldItsFocusBack() async throws {
        let f = try await makePageFixture("Failed Delete Focus")
        try blockVisitDeletes(f.db)
        try await instrumentBridge(f.webView)

        try await runInPage(f.webView, """
            document.getElementById('search').focus();
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            document.getElementById('selection-delete').click();
            return true;
            """)
        try await waitForSettledQueries(f.webView, 1)

        let after = try await jsonFromPage(f.webView, """
            const active = document.activeElement;
            return JSON.stringify({
                active: active.id || active.tagName,
                selecting: document.getElementById('bar').classList.contains('selecting'),
            });
            """)
        XCTAssertEqual(after["selecting"] as? Bool, false)
        XCTAssertEqual(after["active"] as? String, "search",
                       "nothing was deleted, so nothing justified keeping the caret away")
    }

    /// A delete started from the keyboard never hands the caret back — not
    /// even when it fails and the row's controls come straight back. The key
    /// that asked may still be down, and a repeat arriving once the field has
    /// the caret is typed into it: the repeat guard never sees those, because
    /// a focused text field returns before it (TASK-95).
    func testAFailedKeyboardDeleteDoesNotHandTheCaretBack() async throws {
        let f = try await makePageFixture("Failed Keyboard Delete Focus")
        try blockVisitDeletes(f.db)
        try await instrumentBridge(f.webView)

        try await runInPage(f.webView, """
            const search = document.getElementById('search');
            search.value = 'foo';
            search.focus();
            // Ticked with the pointer, so the field is where the caret is owed.
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Backspace', bubbles: true }));
            return true;
            """)
        try await waitForSettledQueries(f.webView, 1)

        let after = try await jsonFromPage(f.webView, """
            const active = document.activeElement;
            return JSON.stringify({
                active: active.id || active.tagName,
                selecting: document.getElementById('bar').classList.contains('selecting'),
            });
            """)
        XCTAssertEqual(after["selecting"] as? Bool, false, "the failure left the header selecting")
        XCTAssertNotEqual(after["active"] as? String, "search",
                          "the caret went back under a key that may still be down")
    }

    /// A secondary press opens a menu and fires no `click`, so nothing
    /// collects the candidate it would otherwise have left — and a keyboard
    /// selection made later must not inherit it.
    func testARightClickLeavesNoFocusCandidateBehind() async throws {
        let f = try await makePageFixture("Right Click Candidate")

        let result = try await jsonFromPage(f.webView, """
            const search = document.getElementById('search');
            const item = document.querySelectorAll('.item')[0];
            search.focus();
            item.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 2 }));
            item.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));
            search.blur();
            // Later, from the keyboard, with the caret nowhere.
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }));
            const selected = document.querySelectorAll('.item.selected').length;
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            const active = document.activeElement;
            return JSON.stringify({ selected: selected, active: active.id || active.tagName });
            """)
        XCTAssertEqual((result["selected"] as? NSNumber)?.intValue, 7, "Cmd+A took the loaded rows")
        XCTAssertNotEqual(result["active"] as? String, "search",
                          "a right-click left a candidate for a later selection to pick up")
    }

    /// And so does a press released where no `click` follows: the release
    /// itself clears the candidate, after the click it was waiting for did
    /// not come.
    func testAPressThatFiresNoClickLeavesNoFocusCandidateBehind() async throws {
        let f = try await makePageFixture("Abandoned Press Candidate")

        try await runInPage(f.webView, """
            const search = document.getElementById('search');
            const item = document.querySelectorAll('.item')[0];
            search.focus();
            item.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
            search.blur();
            item.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
            return true;
            """)
        // The release arms a timer that runs after the click would have.
        try await Task.sleep(nanoseconds: 100_000_000)

        let result = try await jsonFromPage(f.webView, """
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }));
            const selected = document.querySelectorAll('.item.selected').length;
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
            const active = document.activeElement;
            return JSON.stringify({ selected: selected, active: active.id || active.tagName });
            """)
        XCTAssertEqual((result["selected"] as? NSNumber)?.intValue, 7, "Cmd+A took the loaded rows")
        XCTAssertNotEqual(result["active"] as? String, "search",
                          "a press that fired no click left its candidate behind")
    }

    /// A row's own × while other rows are ticked deletes that row only: the
    /// selection stands, and the caret it is holding is still owed back.
    func testDeletingAnUnselectedRowLeavesTheSelectionAndItsFocusAlone() async throws {
        let f = try await makePageFixture("Row Button During Selection")

        try await runInPage(f.webView, """
            const search = document.getElementById('search');
            search.focus();
            const items = document.querySelectorAll('.item');
            items[0].querySelector('.pick').click();
            // A different row, which nobody ticked.
            items[1].querySelector('.delete').click();
            return true;
            """)
        try await waitForRows(f.webView, 6)

        let during = try await jsonFromPage(f.webView, """
            return JSON.stringify({
                selecting: document.getElementById('bar').classList.contains('selecting'),
                selected: document.querySelectorAll('.item.selected').length,
            });
            """)
        XCTAssertEqual(during["selecting"] as? Bool, true, "the selection went with another row")
        XCTAssertEqual((during["selected"] as? NSNumber)?.intValue, 1)

        let after = try await jsonFromPage(f.webView, """
            document.getElementById('selection-cancel').click();
            const active = document.activeElement;
            return JSON.stringify({ active: active.id || active.tagName });
            """)
        XCTAssertEqual(after["active"] as? String, "search",
                       "the caret was forgotten by a delete that did not end the selection")
        XCTAssertEqual(visitTimes(f.db, f.space).count, 6)
    }

    /// Clearing the history while something else is owed is still one read:
    /// ending the selection runs it, and the caller does not run a second.
    func testClearingWithAReloadOwedReadsTheHistoryOnce() async throws {
        let f = try await makePageFixture("Clear With Owed Reload")
        stubConfirmClear(true)
        try await instrumentBridge(f.webView)

        try await runInPage(f.webView, """
            document.getElementById('search').blur();
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            // Something to owe: a refresh, held back by the selection.
            window.dispatchEvent(new Event('focus'));
            // The menu is off the row while a selection is up, so this is the
            // reply arriving for a clear the user started before ticking.
            document.querySelector('#clear .menu-item[data-range="all"]').click();
            return true;
            """)
        try await waitForRows(f.webView, 0, "the list the clear emptied")

        let state = try await pageState(f.webView)
        XCTAssertEqual(state.emptyTitle, "No history yet")
        XCTAssertNil(state.selection)
        XCTAssertEqual(confirmedRanges, [.all])
        // Give a second read the time it would need to show up.
        try await Task.sleep(nanoseconds: 400_000_000)
        let log = try await bridgeLog(f.webView)
        XCTAssertEqual(log.sent, 1, "the clear's reload and the owed one were both run")
    }

    /// Holding Delete down deletes once. The repeats arrive while the request
    /// is in flight and after the rows are gone; neither may do anything —
    /// least of all reach the search field the selection gives back.
    func testHoldingDeleteDeletesOnceAndTheRepeatsGoNowhere() async throws {
        let f = try await makePageFixture("Key Repeat")
        try await instrumentBridge(f.webView)

        let held = try await jsonFromPage(f.webView, """
            document.getElementById('search').blur();
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            const repeatKey = () => document.dispatchEvent(
                new KeyboardEvent('keydown', { key: 'Backspace', repeat: true, bubbles: true }));
            repeatKey();
            repeatKey();
            return JSON.stringify({
                rows: document.querySelectorAll('.item').length,
                selected: document.querySelectorAll('.item.selected').length,
            });
            """)
        XCTAssertEqual((held["rows"] as? NSNumber)?.intValue, 7, "a repeat deleted a row")
        XCTAssertEqual((held["selected"] as? NSNumber)?.intValue, 1, "and the tick is still there")
        XCTAssertEqual(visitTimes(f.db, f.space).count, 7, "nothing reached the database")
        var log = try await bridgeLog(f.webView)
        XCTAssertEqual(log, BridgeLog(sent: 0, settled: 0, deletes: 0),
                       "a repeat asked the bridge for something")

        // The press itself does delete.
        try await runInPage(f.webView, """
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Backspace', bubbles: true }));
            return true;
            """)
        try await waitForRows(f.webView, 6)

        // And the repeats that follow the press land on nothing: the field is
        // back, but it does not have the caret.
        try await runInPage(f.webView, """
            for (let i = 0; i < 3; i += 1) {
                document.dispatchEvent(
                    new KeyboardEvent('keydown', { key: 'Backspace', repeat: true, bubbles: true }));
            }
            return true;
            """)
        try await Task.sleep(nanoseconds: 300_000_000)
        let after = try await jsonFromPage(f.webView, """
            const active = document.activeElement;
            return JSON.stringify({
                rows: document.querySelectorAll('.item').length,
                active: active.id || active.tagName,
            });
            """)
        XCTAssertEqual((after["rows"] as? NSNumber)?.intValue, 6, "the repeats deleted more rows")
        // Where the caret is, not what a synthetic key would have typed into
        // it — a dispatched KeyboardEvent performs no editing, so asserting an
        // untouched value would prove nothing. This is the thing that keeps
        // the repeats away from the field.
        XCTAssertNotEqual(after["active"] as? String, "search",
                          "the caret went back into the field the repeats are aimed at")
        log = try await bridgeLog(f.webView)
        XCTAssertEqual(log.deletes, 1, "one press, one delete")
        XCTAssertEqual(log.sent, 0, "and the repeats sent the page off to read the history")
        XCTAssertEqual(visitTimes(f.db, f.space).count, 6, "exactly one delete reached the database")
    }

    /// A selection that ends because its rows were deleted hands focus to
    /// nobody — the key that deleted them may still be down.
    func testASelectionEndedByADeleteDoesNotHandFocusBack() async throws {
        let f = try await makePageFixture("Focus After Delete")

        try await runInPage(f.webView, """
            const search = document.getElementById('search');
            search.focus();
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            document.getElementById('selection-delete').click();
            return true;
            """)
        try await waitForRows(f.webView, 6)

        let after = try await jsonFromPage(f.webView, """
            const active = document.activeElement;
            return JSON.stringify({
                active: active.id || active.tagName,
                searchDisplay: getComputedStyle(document.getElementById('search')).display,
            });
            """)
        XCTAssertNotEqual(after["active"] as? String, "search",
                          "the field took the caret back after a delete")
        XCTAssertNotEqual(after["searchDisplay"] as? String, "none", "though it is on screen again")
    }

    /// A real press moves focus itself, before the click that starts the
    /// selection: WebKit blurs the search field on mousedown over a row. The
    /// page notes where the caret was as the press begins, so Cancel can still
    /// give it back (TASK-95) — `pick.click()` alone never exercises this,
    /// because a synthetic click does no focus handling at all.
    func testAPressThatBlursTheFieldStillHandsTheCaretBack() async throws {
        let f = try await makePageFixture("Pointer Focus")

        let result = try await jsonFromPage(f.webView, """
            const search = document.getElementById('search');
            const pick = document.querySelectorAll('.item')[0].querySelector('.pick');
            search.focus();
            // The sequence a real click produces, in order: the press, the
            // focus change the press performs by itself, then the release and
            // the click the page listens for.
            pick.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
            search.blur();
            const afterPress = document.activeElement.id || document.activeElement.tagName;
            pick.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
            pick.click();
            const whileSelecting = document.activeElement.id || document.activeElement.tagName;
            document.getElementById('selection-cancel').click();
            const active = document.activeElement;
            return JSON.stringify({
                afterPress: afterPress,
                whileSelecting: whileSelecting,
                selected: document.querySelectorAll('.item.selected').length,
                active: active.id || active.tagName,
            });
            """)
        XCTAssertNotEqual(result["afterPress"] as? String, "search",
                          "the press left the caret in the field: this test proves nothing")
        XCTAssertNotEqual(result["whileSelecting"] as? String, "search")
        XCTAssertEqual((result["selected"] as? NSNumber)?.intValue, 0, "Cancel left the row ticked")
        XCTAssertEqual(result["active"] as? String, "search",
                       "the caret the press took was never noted, so Cancel had nothing to give back")
    }

    /// And the candidate belongs to that press alone: a press that started no
    /// selection must not hand its caret to a keyboard selection made later,
    /// with the focus somewhere else entirely.
    func testAPressThatStartedNoSelectionLeavesNothingBehind() async throws {
        let f = try await makePageFixture("Stale Focus Candidate")

        let result = try await jsonFromPage(f.webView, """
            const search = document.getElementById('search');
            const items = document.querySelectorAll('.item');
            // A press on a row that ticks nothing: the row's link, with the
            // field focused and WebKit blurring it as the press lands.
            search.focus();
            items[0].dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
            search.blur();
            items[0].dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
            items[0].dispatchEvent(new MouseEvent('click', { bubbles: true }));
            // Later, and from the keyboard, with the caret elsewhere.
            items[1].querySelector('.pick').focus();
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }));
            const selected = document.querySelectorAll('.item.selected').length;
            document.getElementById('selection-cancel').click();
            const active = document.activeElement;
            return JSON.stringify({
                selected: selected,
                active: active.id || active.className || active.tagName,
            });
            """)
        XCTAssertEqual((result["selected"] as? NSNumber)?.intValue, 7, "Cmd+A took the loaded rows")
        XCTAssertNotEqual(result["active"] as? String, "search",
                          "a candidate from an earlier press was handed to a later selection")
    }

    /// Cancel reached with the keyboard: focus is on the button that is about
    /// to stop being rendered, which counts as nowhere — the field gets it
    /// back (Full Keyboard Access).
    func testCancellingFromTheKeyboardStillGivesTheFieldItsFocusBack() async throws {
        let f = try await makePageFixture("Focus From Cancel")

        let result = try await jsonFromPage(f.webView, """
            const search = document.getElementById('search');
            search.focus();
            document.querySelectorAll('.item')[0].querySelector('.pick').click();
            const cancel = document.getElementById('selection-cancel');
            cancel.focus();
            const held = document.activeElement.id;
            cancel.click();
            const active = document.activeElement;
            return JSON.stringify({ held: held, active: active.id || active.tagName });
            """)
        XCTAssertEqual(result["held"] as? String, "selection-cancel",
                       "the button never took focus: this test proves nothing")
        XCTAssertEqual(result["active"] as? String, "search")
    }

    // MARK: - What the store forgets afterwards (AC #6)

    /// The 30 s dedup would otherwise swallow the revisit: the user deletes a
    /// page and goes straight back to it, and nothing is recorded.
    ///
    /// The store here is a private one, so the assertions are about the database
    /// the recorder actually writes to. `HistoryPageBridge.finish` calls
    /// `TabStore.shared.historyDidDelete`, which this store is not; the delete
    /// and the notification are therefore driven by hand, in the order the
    /// bridge drives them. What is under test is the invalidation itself.
    func testRevisitingRightAfterADeleteIsRecordedAgain() async throws {
        let historyDB = try makeDatabase()
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB)
        let profile = store.addProfile(name: "Dedup")
        let space = store.addSpace(name: "Dedup", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        let tab = store.addTab(in: space)
        createdTabs.append(tab)
        let url = URL(string: "https://revisit.example/")!
        tab.url = url

        store.recordHistoryVisit(tab: tab, spaceID: space.id)
        try await waitUntil("the first visit to be recorded") {
            historyDB.visits(spaceIDs: [space.id.uuidString], limit: 10).count == 1
        }
        XCTAssertEqual(tab.lastRecordedHistoryURL, url)
        let visitID = historyDB.visits(spaceIDs: [space.id.uuidString], limit: 10)[0].visitID

        // What the bridge does: stamp the request, delete, then tell the store
        // what went.
        let requestedAt = Date()
        let deleted = expectation(description: "delete")
        historyDB.deleteVisits(ids: [visitID], spaceIDs: [space.id.uuidString]) { result in
            DispatchQueue.main.async {
                guard case .success(let deletion) = result else { return XCTFail("the delete failed") }
                store.historyDidDelete(deletion, spaceIDs: [space.id.uuidString], requestedAt: requestedAt)
                deleted.fulfill()
            }
        }
        await fulfillment(of: [deleted], timeout: 10)
        XCTAssertEqual(historyDB.visits(spaceIDs: [space.id.uuidString], limit: 10), [])
        XCTAssertNil(tab.lastRecordedHistoryURL, "a tab still on the URL has nothing left to correct")
        XCTAssertNil(tab.lastRecordedHistoryAt)

        // Straight back to it, well inside the 30 s window.
        store.recordHistoryVisit(tab: tab, spaceID: space.id)
        try await waitUntil("the revisit to be recorded") {
            historyDB.visits(spaceIDs: [space.id.uuidString], limit: 10).count == 1
        }
        XCTAssertEqual(tab.lastRecordedHistoryURL, url, "and the correction window is open again")
    }

    /// The delete runs on another queue, so a visit can be recorded while it is
    /// in flight — legitimately *after* the user chose what to delete. What that
    /// visit left in memory describes a row the delete never saw, and clearing
    /// it would cost the user the next revisit and the next title correction.
    func testStateFromAVisitRecordedAfterTheRequestSurvivesTheDelete() async throws {
        let historyDB = try makeDatabase()
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB)
        let profile = store.addProfile(name: "Late Visit")
        let space = store.addSpace(name: "Late Visit", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        let tab = store.addTab(in: space)
        createdTabs.append(tab)
        let url = URL(string: "https://late.example/")!
        tab.url = url

        // The delete was asked for first; the visit was recorded after it.
        let requestedAt = Date()
        try await Task.sleep(nanoseconds: 20_000_000)
        store.recordHistoryVisit(tab: tab, spaceID: space.id)
        try await waitUntil("the visit to be recorded") {
            historyDB.visits(spaceIDs: [space.id.uuidString], limit: 10).count == 1
        }

        store.historyDidDelete(HistoryDeletionResult(deletedVisitCount: 1,
                                                     affectedURLs: [url.absoluteString],
                                                     removedURLs: [url.absoluteString]),
                               spaceIDs: [space.id.uuidString], requestedAt: requestedAt)

        XCTAssertEqual(tab.lastRecordedHistoryURL, url, "the row this tab recorded is a newer one")
        XCTAssertNotNil(tab.lastRecordedHistoryAt)
        // The dedup marker is newer than the request too, so the visit it stands
        // for is not recorded a second time. (The write would be enqueued before
        // this read, which is serialized behind it.)
        store.recordHistoryVisit(tab: tab, spaceID: space.id)
        XCTAssertEqual(historyDB.visits(spaceIDs: [space.id.uuidString], limit: 10).count, 1)
    }

    /// A URL that only *lost* visits still has its `historyURL` row, so a tab
    /// sitting on it keeps the window in which its settled title corrects that
    /// row (TASK-88) — only a URL that went entirely clears it.
    func testATabOnAnAffectedButNotRemovedURLKeepsItsCorrectionState() async throws {
        let historyDB = try makeDatabase()
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB)
        let profile = store.addProfile(name: "Affected")
        let space = store.addSpace(name: "Affected", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        let tab = store.addTab(in: space)
        createdTabs.append(tab)
        let url = URL(string: "https://affected.example/")!
        tab.url = url

        store.recordHistoryVisit(tab: tab, spaceID: space.id)
        try await waitUntil("the visit to be recorded") {
            historyDB.visits(spaceIDs: [space.id.uuidString], limit: 10).count == 1
        }

        // An older visit of the same URL was deleted: the row stays.
        store.historyDidDelete(HistoryDeletionResult(deletedVisitCount: 1,
                                                     affectedURLs: [url.absoluteString],
                                                     removedURLs: []),
                               spaceIDs: [space.id.uuidString], requestedAt: Date())

        XCTAssertEqual(tab.lastRecordedHistoryURL, url, "its row is still there to correct")
        XCTAssertNotNil(tab.lastRecordedHistoryAt)
        // The dedup marker predates the request, so it goes: a revisit now is a
        // new row rather than a silence.
        store.recordHistoryVisit(tab: tab, spaceID: space.id)
        try await waitUntil("the revisit to be recorded") {
            historyDB.visits(spaceIDs: [space.id.uuidString], limit: 10).count == 2
        }
    }

    // MARK: - The launch sweep (AC #8)

    /// A space that no longer exists keeps visits no profile can see; the sweep
    /// at launch is where they go.
    func testTheLaunchSweepRemovesVisitsOfDeletedSpaces() throws {
        let historyDB = try makeDatabase()
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB)
        let profile = store.addProfile(name: "Sweep")
        let living = store.addSpace(name: "Sweep", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        let gone = UUID()
        try seedVisit(historyDB, url: "https://kept.example/", title: "Kept",
                      spaceID: living.id, visitTime: 200)
        try seedVisit(historyDB, url: "https://orphan.example/", title: "Orphan",
                      spaceID: gone, visitTime: 100)

        store.sweepHistoryOfDeletedSpaces()

        // The sweep is an async write on GRDB's writer queue and a read is
        // serialized behind it, so this observes the finished sweep.
        XCTAssertEqual(try visitRowCount(historyDB), 1)
        XCTAssertEqual(historyDB.visits(spaceIDs: [living.id.uuidString], limit: 10).map(\.url),
                       ["https://kept.example/"])
        XCTAssertFalse(try urlRowExists(historyDB, "https://orphan.example/"),
                       "its last visit anywhere went, so the URL did too")
    }

    /// The sweep runs seconds after launch, and Undo Delete Space lives for the
    /// whole session: a space deleted in between is still undoable, so its
    /// visits must survive the sweep — otherwise the undo brings the space back
    /// without its history.
    func testTheLaunchSweepKeepsTheHistoryOfASpaceDeletedThisSession() throws {
        let historyDB = try makeDatabase()
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB)
        let profile = store.addProfile(name: "Sweep Undo")
        let living = store.addSpace(name: "Sweep Undo", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        let doomed = store.addSpace(name: "Sweep Doomed", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        try seedVisit(historyDB, url: "https://kept.example/", title: "Kept",
                      spaceID: living.id, visitTime: 200)
        try seedVisit(historyDB, url: "https://undoable.example/", title: "Undoable",
                      spaceID: doomed.id, visitTime: 100)
        try seedVisit(historyDB, url: "https://orphan.example/", title: "Orphan",
                      spaceID: UUID(), visitTime: 50)

        store.deleteSpace(id: doomed.id)
        store.sweepHistoryOfDeletedSpaces()

        XCTAssertEqual(try visitRowCount(historyDB), 2, "only the space from an earlier run went")
        XCTAssertEqual(historyDB.visits(spaceIDs: [doomed.id.uuidString], limit: 10).map(\.url),
                       ["https://undoable.example/"], "Cmd+Z would restore the space to its history")
        XCTAssertFalse(try urlRowExists(historyDB, "https://orphan.example/"))
    }

    /// The guard that matters more than the sweep: a session database that was
    /// reset or failed to restore comes up with spaces no visit belongs to, and
    /// every visit would look orphaned. Nothing is swept until one surviving
    /// space proves the two files belong together.
    func testTheLaunchSweepRemovesNothingWhenNoSurvivingSpaceHasVisits() throws {
        let historyDB = try makeDatabase()
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB)
        let profile = store.addProfile(name: "Sweep Guard")
        _ = store.addSpace(name: "Sweep Guard", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        try seedVisit(historyDB, url: "https://a.example/", title: "A", spaceID: UUID(), visitTime: 100)
        try seedVisit(historyDB, url: "https://b.example/", title: "B", spaceID: UUID(), visitTime: 200)

        store.sweepHistoryOfDeletedSpaces()

        XCTAssertEqual(try visitRowCount(historyDB), 2, "the whole history would have gone")
    }
}
