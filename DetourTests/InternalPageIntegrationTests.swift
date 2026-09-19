import XCTest
import GRDB
import WebKit
@testable import Detour

/// The internal-page defences, against real `WKWebView`s (TASK-86).
///
/// `InternalPageTests` pins the pure rules; this suite checks that the wiring
/// around them holds when a page actually loads: that an armed tab gets the
/// History page and the page world cannot see the bridge, that web content can
/// neither navigate to nor embed `detour://history/` nor call the bridge from
/// the private content world, that a hostile title stays text, and that what a
/// tab's page may read is its own profile's history and nothing else.
///
/// Tabs are built the way production builds them — `TabStore.addTab` with a
/// space's configuration, then `BrowserTab.loadInternalPage` — so the scheme
/// handler, the user script and the tab's own navigation delegate are all
/// installed and in force. The bridge reads an in-memory database through
/// `HistoryPageBridge.database`; nothing here touches the real history.
///
/// The extension case of AC #6 is covered at the unit level:
/// `InternalPageTests.testBridgeRejectsEveryOtherSender` rejects a
/// `webkit-extension://` origin, and an extension content script runs in its own
/// content world, which the handler is not registered in at all. Case (c) below
/// is the stronger statement — even code already running in the *right* world is
/// refused when the document it runs in is not the page.
@MainActor
final class InternalPageIntegrationTests: XCTestCase {

    private let historyURL = URL(string: "detour://history/")!
    private let webURL = URL(string: "https://example.invalid/page")!

    private var sharedProfiles: [Profile] = []
    private var sharedSpaceIDs: [UUID] = []
    private var createdTabs: [BrowserTab] = []
    private var defaultFaviconFetch: ((URL, @escaping (Data?) -> Void) -> Void)!

    override func setUp() {
        super.setUp()
        // The page asks for a favicon per rendered row; keep that off the
        // network and out of the shared cache.
        defaultFaviconFetch = FaviconPNGLoader.shared.fetch
        FaviconPNGLoader.shared.resetForTesting()
        FaviconPNGLoader.shared.fetch = { _, completion in completion(nil) }
    }

    override func tearDown() {
        HistoryPageBridge.database = .shared
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
        let profile = TabStore.shared.addProfile(name: "Internal \(name)")
        sharedProfiles.append(profile)
        let space = TabStore.shared.addSpace(name: "Internal \(name)", emoji: "🕘",
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

    /// A tab with a web view big enough to lay the page out.
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

    /// Seeds one visit at a caller-chosen time. `recordVisit` stamps `Date()`
    /// and writes asynchronously; the page's ordering has to be deterministic.
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

    // MARK: - Driving the page

    /// Waits until the History page has loaded *and* its user script has drawn
    /// something — a row, or one of the empty states. The tab's own navigation
    /// delegate stays installed throughout (a `NavigationWaiter` would replace
    /// it, and with it the policy under test), so this polls instead.
    private func waitForHistoryPage(_ tab: BrowserTab) async throws {
        try await waitUntil("the History page to render") {
            guard let webView = tab.webView, !webView.isLoading,
                  InternalPage(url: webView.url ?? URL(string: "about:blank")!) == .history else { return false }
            let drawn = try? await webView.callAsyncJavaScript(
                "return document.querySelectorAll('.row, .empty-title').length;",
                contentWorld: .page) as? Int
            return (drawn ?? 0) > 0
        }
    }

    /// Runs `js` in the page world and decodes the JSON string it returns.
    private func pageJSON(_ webView: WKWebView, _ js: String) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript(js, contentWorld: .page)
        let text = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func rowTitles(_ webView: WKWebView) async throws -> [String] {
        let result = try await pageJSON(webView, """
            return JSON.stringify({
                titles: Array.from(document.querySelectorAll('.row .title')).map((el) => el.textContent),
            });
            """)
        return try XCTUnwrap(result["titles"] as? [String])
    }

    /// Posts one bridge message from `world` and reports how the promise settled.
    private func callBridge(_ webView: WKWebView, in world: WKContentWorld,
                            method: String = "history.query") async throws -> (result: Any?, error: String?) {
        let js = """
            try {
                const value = await window.webkit.messageHandlers.detourInternal.postMessage({
                    method: method, params: {},
                });
                return JSON.stringify({ result: value === undefined ? null : value });
            } catch (error) {
                return JSON.stringify({ error: String(error && error.message ? error.message : error) });
            }
            """
        let raw = try await webView.callAsyncJavaScript(js, arguments: ["method": method], contentWorld: world)
        let text = try XCTUnwrap(raw as? String, "expected a JSON string")
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return (dict["result"], dict["error"] as? String)
    }

    /// Loads a web page into `tab`'s web view, keeping the tab's delegate.
    private func loadWebPage(_ tab: BrowserTab, html: String) async throws {
        let webView = try XCTUnwrap(tab.webView)
        try await loadHTMLStringAndWait(webView, html: html, baseURL: webURL)
    }

    // MARK: - The page loads

    func testArmedTabLoadsTheHistoryPage() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Loads")
        try seedVisit(db, url: "https://swift.org/", title: "Swift",
                      spaceID: space.id, visitTime: Date().timeIntervalSince1970 - 60)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)

        let webView = try XCTUnwrap(tab.webView)
        let title = try await webView.callAsyncJavaScript("return document.title;", contentWorld: .page) as? String
        XCTAssertEqual(title, "History")
        XCTAssertEqual(tab.title, "History", "the sidebar shows the page's name, not detour://history/")
        XCTAssertEqual(tab.displayHost, "History", "and so does the faux address bar")
        let titles = try await rowTitles(webView)
        XCTAssertEqual(titles, ["Swift"], "the world script rendered the visit")
        // Single-use: a tab left armed while History shows would admit a
        // redirect back to detour:// from the first entry the user clicks.
        XCTAssertNil(tab.armedInternalPage, "the load spent the arming")
    }

    /// AC #9: an incognito space's page explains itself instead of falling
    /// through to another profile's history.
    func testIncognitoTabSeesAnExplanationAndNoEntries() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let other = makeSpace("Incognito Other")
        try seedVisit(db, url: "https://swift.org/", title: "Swift",
                      spaceID: other.id, visitTime: Date().timeIntervalSince1970 - 60)

        let tab = makeTab(in: makeIncognitoSpace())
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)

        let webView = try XCTUnwrap(tab.webView)
        let titles = try await rowTitles(webView)
        XCTAssertEqual(titles, [])
        let empty = try await webView.callAsyncJavaScript(
            "return document.querySelector('.empty-title').textContent;", contentWorld: .page) as? String
        XCTAssertEqual(empty, "Private browsing keeps no history")
    }

    /// AC #3, end to end: two profiles that have visited the same URL at
    /// different times. The page shows its own profile's visit and its own
    /// visit time — never the `historyURL` aggregate, and never the other
    /// profile's visit.
    func testAPageSeesOnlyItsOwnProfilesVisits() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let mine = makeSpace("Scope Mine")
        let theirs = makeSpace("Scope Theirs")
        let now = Date().timeIntervalSince1970
        try seedVisit(db, url: "https://shared.example/", title: "Mine", spaceID: mine.id, visitTime: now - 3600)
        // Later, and under a different title, so leaking it would be obvious.
        try seedVisit(db, url: "https://shared.example/", title: "Theirs", spaceID: theirs.id, visitTime: now - 60)
        try seedVisit(db, url: "https://only-theirs.example/", title: "Only Theirs",
                      spaceID: theirs.id, visitTime: now - 30)

        let tab = makeTab(in: mine)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let result = try await pageJSON(webView, """
            return JSON.stringify({
                hosts: Array.from(document.querySelectorAll('.row .where')).map((el) => el.textContent),
                times: Array.from(document.querySelectorAll('.row .when')).map((el) => el.textContent),
            });
            """)
        XCTAssertEqual(result["hosts"] as? [String], ["shared.example"],
                       "only the in-scope visit, and nothing from the other profile")

        // The bridge is the source of the times the page renders; check the
        // value itself rather than a localized string.
        let scope = try XCTUnwrap(HistoryPageBridge.scope(for: tab))
        let entries = db.visits(spaceIDs: scope, limit: 10)
        XCTAssertEqual(entries.map(\.visitTime), [now - 3600],
                       "the in-scope visit time, not historyURL.lastVisitTime")
    }

    // MARK: - Hostile data (AC #7)

    func testAHostileTitleIsRenderedAsText() async throws {
        let db = try makeDatabase()
        HistoryPageBridge.database = db
        let space = makeSpace("Hostile")
        let hostileTitle = "<img src=x onerror=\"document.title='pwned'\"><script>document.title='pwned'</script>"
        // A URL that is not a link either: it must render as plain text, with
        // no href and no favicon request.
        try seedVisit(db, url: "javascript:document.title='pwned'", title: hostileTitle,
                      spaceID: space.id, visitTime: Date().timeIntervalSince1970 - 60)
        try seedVisit(db, url: "https://ok.example/\"><script>document.title='pwned'</script>",
                      title: "", spaceID: space.id, visitTime: Date().timeIntervalSince1970 - 120)

        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)
        let webView = try XCTUnwrap(tab.webView)

        let result = try await pageJSON(webView, """
            return JSON.stringify({
                title: document.title,
                injectedImages: document.querySelectorAll('img[src="x"]').length,
                scripts: document.querySelectorAll('script').length,
                titles: Array.from(document.querySelectorAll('.row .title')).map((el) => el.textContent),
                anchors: Array.from(document.querySelectorAll('.row')).map((el) => el.tagName),
                hrefs: Array.from(document.querySelectorAll('.row[href]')).map((el) => el.getAttribute('href')),
            });
            """)

        XCTAssertEqual(result["title"] as? String, "History", "nothing in the data ran")
        XCTAssertEqual(result["injectedImages"] as? Int, 0)
        XCTAssertEqual(result["scripts"] as? Int, 0)
        XCTAssertEqual(result["titles"] as? [String], [hostileTitle, "https://ok.example/\"><script>document.title='pwned'</script>"],
                       "the markup shows verbatim, as text")
        XCTAssertEqual(result["anchors"] as? [String], ["DIV", "A"],
                       "a javascript: entry is not an anchor; an https one is")
        XCTAssertEqual(result["hrefs"] as? [String], ["https://ok.example/%22%3E%3Cscript%3Edocument.title='pwned'%3C/script%3E"],
                       "and the one href is the URL as WebKit parses it")
    }

    // MARK: - The bridge is out of reach (AC #6)

    func testPageWorldCannotSeeTheBridge() async throws {
        HistoryPageBridge.database = try makeDatabase()
        let tab = makeTab(in: makeSpace("Page World"))
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
    }

    /// (a) A web page cannot send its own tab to the internal page.
    func testAWebPageCannotNavigateToTheInternalPage() async throws {
        let tab = makeTab(in: makeSpace("Navigate"))
        try await loadWebPage(tab, html: "<html><body><a id='link' href='detour://history/'>go</a></body></html>")
        let webView = try XCTUnwrap(tab.webView)

        _ = try? await webView.callAsyncJavaScript(
            "location.href = 'detour://history/'; document.getElementById('link').click(); return null;",
            contentWorld: .page)
        // Give a navigation that was going to happen time to happen.
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(webView.url, webURL, "the web view stayed on the web page")
        XCTAssertNil(tab.armedInternalPage)
        let title = try await webView.callAsyncJavaScript("return document.title;", contentWorld: .page) as? String
        XCTAssertNotEqual(title, "History")
    }

    /// (b) Nor embed it: the subframe navigation is cancelled, and the scheme
    /// handler would refuse to serve a web page's main document anyway.
    func testAWebPageCannotEmbedTheInternalPage() async throws {
        let tab = makeTab(in: makeSpace("Iframe"))
        try await loadWebPage(tab, html: """
            <html><body><iframe id="frame" src="detour://history/"></iframe></body></html>
            """)
        let webView = try XCTUnwrap(tab.webView)
        try await Task.sleep(nanoseconds: 700_000_000)

        let result = try await pageJSON(webView, """
            const frame = document.getElementById('frame');
            try {
                const doc = frame.contentDocument;
                return JSON.stringify({
                    reachable: true,
                    hasHistoryDOM: !!(doc && doc.querySelector('#entries')),
                    frameTitle: doc ? doc.title : null,
                });
            } catch (error) {
                return JSON.stringify({ reachable: false, hasHistoryDOM: false, frameTitle: null });
            }
            """)
        XCTAssertEqual(result["hasHistoryDOM"] as? Bool, false, "the frame never got the page")
        XCTAssertNotEqual(result["frameTitle"] as? String, "History")
        // The handler's own check, which stands even if a frame ever got this far.
        var request = URLRequest(url: historyURL)
        request.mainDocumentURL = webURL
        XCTAssertNil(InternalPageSchemeHandler.page(serving: request))
    }

    /// (c) The key one: code already running in the bridge's own content world
    /// is still refused while the document it runs in is a web page. Being in
    /// the right world is exposure control; the sender check is the guarantee.
    func testTheBridgeRefusesTheRightWorldOnAWebPage() async throws {
        HistoryPageBridge.database = try makeDatabase()
        let tab = makeTab(in: makeSpace("Wrong Document"))
        try await loadWebPage(tab, html: "<html><body>web</body></html>")
        let webView = try XCTUnwrap(tab.webView)

        let outcome = try await callBridge(webView, in: InternalPageBridge.contentWorld)
        XCTAssertNil(outcome.result)
        XCTAssertEqual(outcome.error, "forbidden")
    }

    /// (d) And `load(_:)` — the entry point extensions, links and other apps
    /// all share — refuses the scheme outright.
    func testLoadRefusesTheInternalSchemeOnAnUnarmedTab() async throws {
        let tab = makeTab(in: makeSpace("Unarmed"))
        try await loadWebPage(tab, html: "<html><head><title>Web</title></head><body>web</body></html>")
        let webView = try XCTUnwrap(tab.webView)

        tab.load(historyURL)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(tab.armedInternalPage)
        XCTAssertEqual(tab.url, webURL, "the tab's URL is untouched")
        XCTAssertEqual(webView.url, webURL)
    }

    // MARK: - Lifecycle (AC #8)

    /// Sleep and wake: `wake()` re-arms from the persisted URL, so the page
    /// comes back rather than being cancelled by the policy.
    func testAHistoryTabSurvivesSleepAndWake() async throws {
        HistoryPageBridge.database = try makeDatabase()
        let space = makeSpace("Wake")
        let tab = makeTab(in: space)
        tab.loadInternalPage(.history)
        try await waitForHistoryPage(tab)

        tab.sleep()
        XCTAssertNil(tab.webView)
        XCTAssertEqual(tab.url, historyURL, "which is what the session database persists")

        tab.wake()
        tab.webView?.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        XCTAssertNil(tab.armedInternalPage, "a restored session entry is admitted as a revisit, not by arming")
        try await waitForHistoryPage(tab)
        XCTAssertEqual(tab.title, "History")
    }

    /// Relaunch: a session restore rebuilds the tab asleep from its persisted
    /// URL and wakes it when the window shows it. Its name and icon are there
    /// before the web view is.
    func testARestoredHistoryTabLoadsOnWake() async throws {
        HistoryPageBridge.database = try makeDatabase()
        let space = makeSpace("Restore")
        let restored = BrowserTab(id: UUID(), title: "History", url: historyURL, faviconURL: nil,
                                  cachedInteractionState: nil, spaceID: space.id)
        createdTabs.append(restored)
        XCTAssertEqual(restored.title, "History")
        XCTAssertNotNil(restored.favicon, "a sleeping internal page still shows its symbol")

        space.tabs.append(restored)
        restored.wake()
        restored.webView?.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        XCTAssertEqual(restored.armedInternalPage, .history, "no session to restore: the wake's plain load is armed")
        try await waitForHistoryPage(restored)
        XCTAssertEqual(restored.webView?.url, historyURL)
        XCTAssertNil(restored.armedInternalPage)
    }

    /// AC #8: visiting the page never puts it in the history. A private store,
    /// so the assertion is about the database the recorder actually writes to.
    func testTheHistoryPageIsNeverRecordedAsAVisit() throws {
        let historyDB = try makeDatabase()
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB)
        let profile = store.addProfile(name: "Not Recorded")
        let space = store.addSpace(name: "Not Recorded", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        let tab = store.addTab(in: space)
        createdTabs.append(tab)
        tab.loadInternalPage(.history)

        store.recordHistoryVisit(tab: tab, spaceID: space.id)
        // `recordVisit` writes asynchronously but serialized on the writer
        // queue, so a read now observes anything it did write.
        XCTAssertEqual(historyDB.visits(spaceIDs: [space.id.uuidString], limit: 10), [],
                       "detour:// is not http(s), so nothing was recorded")
    }
}
