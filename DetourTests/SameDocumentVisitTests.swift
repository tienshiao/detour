import XCTest
import Combine
import GRDB
import WebKit
@testable import Detour

/// In-page navigations becoming history visits (TASK-91, decision G).
///
/// `history.pushState` and popstate traversals never toggle `isLoading`, so the
/// recorder — which runs when a load ends — never saw a single-page app's page
/// views: they reached the history only when an unrelated resource load happened
/// to toggle it, with whatever URL and title existed at that moment. A tab URL
/// that changes while nothing is loading is now a visit of its own, recorded
/// once it has settled and through the *same* recorder, so every exclusion and
/// the 30 s dedup are shared rather than reimplemented.
///
/// `replaceState` must not do the same: query-string churn (the History page's
/// own `?q=`, a filter, a scroll position) would flood the history. The two are
/// told apart by back/forward *item identity* — verified against a real
/// `WKWebView` below.
///
/// The pages here come from a loopback HTTP server rather than
/// `loadHTMLString`: WebKit gives a `loadHTMLString` document no back/forward
/// entry at all (`currentItem` is nil), so item identity is unobservable in that
/// setup — and the recorder's http(s)-only rule wants real http URLs anyway.
@MainActor
final class SameDocumentVisitTests: XCTestCase {

    private var createdTabs: [BrowserTab] = []
    private var servers: [LoopbackHTTPServer] = []
    private var navigationProbes: [NavigationProbe] = []

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        navigationProbes.removeAll()
        super.tearDown()
    }

    // MARK: - The pure policy

    private func outcome(tabURL: URL? = URL(string: "https://spa.invalid/home")!,
                         lastRecordedHistoryURL: URL? = URL(string: "https://spa.invalid/watch")!,
                         currentItem: ObjectIdentifier? = ObjectIdentifier(Sentinel.b),
                         lastRecordedItem: ObjectIdentifier? = ObjectIdentifier(Sentinel.a))
        -> SameDocumentVisitPolicy.Outcome {
        SameDocumentVisitPolicy.outcome(
            tabURL: tabURL, lastRecordedHistoryURL: lastRecordedHistoryURL,
            currentItem: currentItem, lastRecordedItem: lastRecordedItem)
    }

    /// Stand-ins for two back/forward entries: the policy only ever compares
    /// identities, and `WKBackForwardListItem` cannot be made by hand.
    private final class Sentinel {
        static let a = Sentinel()
        static let b = Sentinel()
    }

    func testPolicyRecordsAPushStateOntoANewEntry() {
        XCTAssertEqual(outcome(), .record)
    }

    /// The tab is already on the URL it recorded — a redraw, not a page view.
    func testPolicyRefusesTheURLTheTabAlreadyRecorded() {
        let url = URL(string: "https://spa.invalid/watch")!
        XCTAssertEqual(outcome(tabURL: url, lastRecordedHistoryURL: url), .skip)
        XCTAssertEqual(outcome(tabURL: nil), .skip)
    }

    /// `replaceState` rewrites the current entry's URL in place, so the entry is
    /// the same object: query-string churn is never a visit.
    func testPolicyRefusesAReplaceStateOnTheSameEntry() {
        let same = ObjectIdentifier(Sentinel.a)
        XCTAssertEqual(outcome(currentItem: same, lastRecordedItem: same), .skip)
    }

    /// No entry at all (a `loadHTMLString` document): a pushState cannot be told
    /// from a replaceState, so nothing is recorded — and there is no entry worth
    /// adopting as a baseline either.
    func testPolicyRefusesWhenTheDocumentHasNoBackForwardEntry() {
        XCTAssertEqual(outcome(currentItem: nil), .skip)
        XCTAssertEqual(outcome(currentItem: nil, lastRecordedItem: nil), .skip)
    }

    /// Nothing has been recorded for the document the tab is showing — a fresh
    /// tab, a favourite or peek tab promoted into a space, or an entry that has
    /// gone (the reference is weak). Recording here would turn the next
    /// `replaceState` into a visit, so the entry becomes the baseline instead
    /// and the *next* different one records (TASK-91).
    func testPolicyAdoptsABaselineWhenNothingWasRecordedForThisDocument() {
        XCTAssertEqual(outcome(lastRecordedItem: nil), .adoptBaseline)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: TabStore
        let historyDB: HistoryDatabase
        let space: Space
        let base: URL
        let server: LoopbackHTTPServer
    }

    private let spaPage = """
        <html><head><title>a video - SPA</title></head><body>video</body></html>
        """

    /// A page that has committed but cannot finish loading: the blocking script
    /// is served by a `pending` route, so parsing stops before the `<title>` and
    /// the document has no title of its own until the route is released.
    private let stalledPage = """
        <html><head><script src="/hang"></script><title>Slow Page</title></head>\
        <body>slow</body></html>
        """

    /// A store writing to in-memory databases, plus a loopback HTTP server: only
    /// a real http document has the back/forward entries this feature reads.
    ///
    /// - Parameters:
    ///   - debounce: how long the URL (and the title) must hold still. Short by
    ///     default so a test need not wait production's real second; a test that
    ///     has to act *within* the window passes a longer one.
    ///   - routes / pending / stalled: extra routes for the loopback server —
    ///     `pending` has committed but cannot finish, `stalled` has not answered
    ///     at all (see `LoopbackHTTPServer`).
    private func makeFixture(incognito: Bool = false,
                             debounce: TimeInterval = 0.2,
                             routes: [String: String] = [:],
                             pending: [String: String] = [:],
                             stalled: [String: String] = [:]) async throws -> Fixture {
        let server = try LoopbackHTTPServer(routes: routes.merging(["/": spaPage]) { given, _ in given },
                                            pending: pending, stalled: stalled)
        let port = try await server.start()
        servers.append(server)

        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB,
                             historySettleDebounce: debounce)
        let space: Space
        if incognito {
            space = store.addIncognitoSpace()
        } else {
            let profile = store.addProfile(name: "SPA")
            space = store.addSpace(name: "SPA", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        }
        return Fixture(store: store, historyDB: historyDB, space: space,
                       base: URL(string: "http://127.0.0.1:\(port)/")!, server: server)
    }

    private func makeTab(in f: Fixture) -> BrowserTab {
        let tab = f.store.addTab(in: f.space)
        createdTabs.append(tab)
        return tab
    }

    /// Spins the main run loop — the debounce is scheduled on it, and so is
    /// everything WebKit reports back.
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Every visit of the profile, newest first — each carrying its own title
    /// (TASK-91), which is what the History page shows.
    private func recorded(_ f: Fixture) -> [HistoryVisitEntry] {
        f.historyDB.visits(spaceIDs: [f.space.id.uuidString], limit: 50)
    }

    private func js(_ webView: WKWebView, _ source: String) async throws {
        _ = try await webView.callAsyncJavaScript("\(source); return true;", contentWorld: .page)
    }

    /// Loads the SPA page and waits until its visit has been recorded with the
    /// page's own title — the visit is filed the instant loading ends, which can
    /// be a beat before WebKit reports the title, and the TASK-88 correction is
    /// what settles it.
    private func loadSPAPage(_ f: Fixture, _ tab: BrowserTab) async throws -> WKWebView {
        let webView = try XCTUnwrap(tab.webView)
        try await loadAndWait(webView, URLRequest(url: f.base))
        try await waitUntil("the first visit to be recorded with the page's own title") {
            self.pump(0.05)
            return self.recorded(f).first.map { $0.url == f.base.absoluteString
                && $0.title == "a video - SPA" } ?? false
        }
        XCTAssertNotNil(webView.backForwardList.currentItem,
                        "precondition: a real http document has a back/forward entry")
        return webView
    }

    // MARK: - pushState

    /// AC #7: the in-page navigation is a visit of its own, carrying the title
    /// the site settles on — and the page it left keeps the title it had.
    func testAPushStateRecordsAVisitWithTheSettledTitle() async throws {
        let f = try await makeFixture()
        let tab = makeTab(in: f)
        let webView = try await loadSPAPage(f, tab)
        let pushed = f.base.absoluteString + "home"

        try await js(webView, "history.pushState({}, '', '/home'); document.title = 'SPA Home'")
        try await waitUntil("the pushed URL to be recorded") {
            self.pump(0.05)
            return self.recorded(f).first?.url == pushed
        }
        pump(0.4)

        XCTAssertEqual(recorded(f).map(\.url), [pushed, f.base.absoluteString],
                       "one visit for the page pushed to, and no more")
        XCTAssertEqual(recorded(f).map(\.title), ["SPA Home", "a video - SPA"],
                       "each visit keeps the title of the page it was")
    }

    /// The title can settle *after* the visit is recorded — the SPA fetches its
    /// data first. The TASK-88 correction then rewrites this visit, and only
    /// this one (TASK-91).
    func testAPushStateVisitIsCorrectedByALateTitle() async throws {
        let f = try await makeFixture()
        let tab = makeTab(in: f)
        let webView = try await loadSPAPage(f, tab)
        let pushed = f.base.absoluteString + "home"

        try await js(webView, "history.pushState({}, '', '/home')")
        try await waitUntil("the pushed URL to be recorded") {
            self.pump(0.05)
            return self.recorded(f).first?.url == pushed
        }
        XCTAssertEqual(recorded(f).first?.title, "a video - SPA",
                       "recorded before the site renamed itself")

        try await js(webView, "document.title = 'SPA Home'")
        try await waitUntil("the late title to correct that visit") {
            self.pump(0.05)
            return self.recorded(f).first?.title == "SPA Home"
        }

        XCTAssertEqual(recorded(f).map(\.title), ["SPA Home", "a video - SPA"],
                       "the page the tab left keeps its own title")
        XCTAssertEqual(recorded(f).count, 2, "a correction adds no visit")
    }

    /// AC #7: a `replaceState` rewrites the current entry rather than pushing a
    /// new one — the History page's own `?q=` as the user types, a filter, a
    /// scroll position. None of it is a page view.
    func testReplaceStateChurnRecordsNothing() async throws {
        let f = try await makeFixture()
        let tab = makeTab(in: f)
        let webView = try await loadSPAPage(f, tab)

        for query in ["a", "ab", "abc"] {
            try await js(webView, "history.replaceState({}, '', '/?q=\(query)')")
            pump(0.1)
        }
        pump(0.6)

        XCTAssertEqual(tab.url?.absoluteString, f.base.absoluteString + "?q=abc",
                       "precondition: the tab's URL did move")
        XCTAssertEqual(recorded(f).map(\.url), [f.base.absoluteString],
                       "the query churn left no visits behind")
    }

    /// A site that pushes twice in a row — a redirect through a landing route —
    /// records where it came to rest, not every URL it passed through.
    func testTwoPushStatesInsideTheDebounceRecordOnlyTheSettledURL() async throws {
        // Long enough that both pushes land inside one debounce window whatever
        // the machine is doing.
        let f = try await makeFixture(debounce: 0.8)
        let tab = makeTab(in: f)
        let webView = try await loadSPAPage(f, tab)

        try await js(webView, "history.pushState({}, '', '/one'); history.pushState({}, '', '/two')")
        try await waitUntil("the tab to be on the second pushed URL") {
            self.pump(0.02)
            return tab.url?.absoluteString == f.base.absoluteString + "two"
        }
        pump(1.2)

        XCTAssertEqual(recorded(f).map(\.url),
                       [f.base.absoluteString + "two", f.base.absoluteString],
                       "the URL it passed through is not a visit")
    }

    // MARK: - The shared exclusions

    /// AC #7: incognito records nothing, in-page navigations included — the
    /// exclusion comes from the shared recorder, not from a second rule here.
    func testIncognitoRecordsNoInPageNavigation() async throws {
        let f = try await makeFixture(incognito: true)
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        try await loadAndWait(webView, URLRequest(url: f.base))
        pump(0.5)
        XCTAssertNotNil(webView.backForwardList.currentItem)

        try await js(webView, "history.pushState({}, '', '/home'); document.title = 'SPA Home'")
        pump(0.8)

        let visitRows = try await f.historyDB.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyVisit") ?? 0
        }
        XCTAssertEqual(visitRows, 0, "an incognito space records nothing at all")
    }

    /// AC #7: only http(s) reaches the history — `detour://` internal pages,
    /// `browser-error://` and extension pages are excluded by the shared
    /// recorder. Driven by hand because the exclusion is about the tab's URL,
    /// which no in-page navigation of an http document can change the scheme of.
    func testANonWebSchemeRecordsNoInPageNavigation() async throws {
        // Long enough that the debounced pipeline cannot fire during the test
        // and record the pushed URL behind the assertion's back.
        let f = try await makeFixture(debounce: 30)
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        try await loadAndWait(webView, URLRequest(url: f.base))
        try await waitUntil("the first visit to be recorded") {
            self.pump(0.05)
            return self.recorded(f).count == 1
        }

        // A new back/forward entry, so the policy would say yes…
        try await js(webView, "history.pushState({}, '', '/home')")
        pump(0.2)
        // …but the tab is on an internal page, which is not in the history.
        tab.url = URL(string: "detour://history/")!
        f.store.recordSameDocumentNavigationIfNeeded(for: tab)
        pump(0.3)

        XCTAssertEqual(recorded(f).map(\.url), [f.base.absoluteString])
        XCTAssertEqual(tab.lastRecordedHistoryURL, f.base, "and nothing was remembered for it")
    }

    // MARK: - Loads that are still in flight

    /// Why the policy needs no `isLoading` guard: a navigation that has not
    /// committed leaves `backForwardList.currentItem` on the *old* entry, so it
    /// can never look like an in-page navigation. Asserted against a real web
    /// view, because the whole rule rests on it (TASK-91).
    func testANavigationThatHasNotCommittedIsNotANewEntry() async throws {
        let f = try await makeFixture(stalled: ["/next": """
            <html><head><title>Next Page</title></head><body>next</body></html>
            """])
        let tab = makeTab(in: f)
        let webView = try await loadSPAPage(f, tab)
        let entryBefore = try XCTUnwrap(webView.backForwardList.currentItem)
        let next = f.base.appendingPathComponent("next")

        // A navigation delegate the way a hosted tab has one: WebKit does not
        // even issue the request for a web view that has none.
        let probe = NavigationProbe()
        navigationProbes.append(probe)
        webView.navigationDelegate = probe

        // The server answers nothing, so this navigation stays provisional.
        webView.load(URLRequest(url: next))
        pump(0.8)

        XCTAssertEqual(probe.events, ["start"], "precondition: started, never committed")
        XCTAssertTrue(webView.backForwardList.currentItem === entryBefore,
                      "an uncommitted navigation leaves the current entry alone")
        XCTAssertEqual(tab.url, next, "even though the tab already reports where it is going")
        XCTAssertEqual(recorded(f).map(\.url), [f.base.absoluteString],
                       "so the debounced recorder has nothing new to record")

        // And once it commits and finishes, the ordinary recorder files it.
        f.server.release("/next")
        try await waitUntil("the committed navigation to be recorded") {
            self.pump(0.05)
            return self.recorded(f).first?.url == next.absoluteString
        }
        XCTAssertEqual(recorded(f).count, 2)
    }

    /// Records what WebKit reports for a navigation; `webView.navigationDelegate`
    /// is weak, so the test holds it in `navigationProbes`.
    private final class NavigationProbe: NSObject, WKNavigationDelegate {
        private(set) var events: [String] = []

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            events.append("start")
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            events.append("commit")
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            events.append("finish")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            events.append("fail")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: any Error) {
            events.append("failProvisional")
        }
    }

    /// AC #7: a single-page app whose subresource keeps loading for a minute
    /// still records the pages the user visits in the meantime. This is what the
    /// dropped `isLoading` guard buys: before it, /a and /b were lost and only
    /// the URL that happened to be current when the load ended was recorded.
    func testInPageNavigationsDuringALongLoadAreAllRecorded() async throws {
        let f = try await makeFixture(routes: ["/spa": """
            <html><head><title>SPA</title></head><body><img src="/hang"></body></html>
            """], pending: ["/hang": ""])
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        let spa = f.base.appendingPathComponent("spa")

        webView.load(URLRequest(url: spa))
        try await waitUntil("the SPA page to commit") {
            self.pump(0.05)
            return tab.url == spa && webView.backForwardList.currentItem != nil
        }

        for page in ["a", "b", "c"] {
            try await js(webView, "history.pushState({}, '', '/\(page)')")
            try await waitUntil("/\(page) to be recorded") {
                self.pump(0.05)
                return self.recorded(f).first?.url == f.base.absoluteString + page
            }
        }

        XCTAssertTrue(tab.isLoading, "precondition: the load never ended")
        XCTAssertEqual(recorded(f).map(\.url),
                       ["c", "b", "a"].map { f.base.absoluteString + $0 })
        XCTAssertFalse(recorded(f).contains { $0.url == spa.absoluteString },
                       "the page the tab started on is the baseline, not a visit")
    }

    /// The other side of dropping the guard: a cross-document load that commits
    /// long before it finishes is recorded at commit time, when the document has
    /// no title yet — so the placeholder must not be what the visit keeps. The
    /// load ends inside the dedup window, and that branch retries the correction
    /// (TASK-88).
    func testASlowLoadRecordsOnceAndItsTitleIsCorrectedWhenItEnds() async throws {
        let f = try await makeFixture(routes: ["/slow": stalledPage], pending: ["/hang": "// done"])
        let tab = makeTab(in: f)
        let webView = try await loadSPAPage(f, tab)
        let slow = f.base.appendingPathComponent("slow")

        webView.load(URLRequest(url: slow))
        try await waitUntil("the committed-but-unfinished page to be recorded") {
            self.pump(0.05)
            return self.recorded(f).first?.url == slow.absoluteString
        }
        XCTAssertTrue(tab.isLoading, "precondition: the load has committed but not finished")
        XCTAssertNotEqual(recorded(f).first?.title, "Slow Page",
                          "the document has no title of its own yet")

        f.server.release("/hang")
        try await waitUntil("the settled title to reach the visit") {
            self.pump(0.05)
            return self.recorded(f).first?.title == "Slow Page"
        }

        XCTAssertEqual(recorded(f).map(\.url), [slow.absoluteString, f.base.absoluteString],
                       "the load end is inside the dedup window, so it adds no second visit")
    }

    // MARK: - No baseline to compare against

    /// A tab holding no entry of its own — a favourite or peek tab promoted into
    /// a space — must not turn its first `replaceState` into a visit. The entry
    /// becomes the baseline, and the next genuinely different one records
    /// (TASK-91).
    func testWithNoBaselineAReplaceStateRecordsNothingAndTheNextPushStateDoes() async throws {
        let f = try await makeFixture()
        let tab = makeTab(in: f)
        let webView = try await loadSPAPage(f, tab)
        // What a promotion into a space leaves: a loaded document nothing has
        // recorded a visit for.
        tab.lastRecordedBackForwardItem = nil
        tab.lastRecordedHistoryURL = nil
        tab.lastRecordedHistoryAt = nil
        tab.lastRecordedHistorySpaceID = nil
        tab.lastRecordedVisitID = nil

        try await js(webView, "history.replaceState({}, '', '/?q=1')")
        pump(0.8)

        XCTAssertEqual(recorded(f).count, 1, "the replaceState is not a visit")
        XCTAssertNotNil(tab.lastRecordedBackForwardItem, "but its entry is now the baseline")

        try await js(webView, "history.pushState({}, '', '/next')")
        try await waitUntil("the pushState after the baseline to be recorded") {
            self.pump(0.05)
            return self.recorded(f).first?.url == f.base.absoluteString + "next"
        }
    }

    // MARK: - The visit id

    /// A title that settles before the insert's id comes back is refused by the
    /// policy and nothing else would retry it — so the id's arrival does
    /// (TASK-91). The writer queue is held so the ordering is the test's, not
    /// the machine's.
    func testTheArrivalOfTheVisitIDRetriesADroppedTitleCorrection() async throws {
        let f = try await makeFixture(debounce: 0.1)
        let tab = makeTab(in: f)
        let webView = try await loadSPAPage(f, tab)
        let pushed = f.base.absoluteString + "home"

        // Hold the writer queue: the next insert commits — and hands back its id
        // — only after this returns.
        f.historyDB.dbQueue.asyncWrite({ _ in Thread.sleep(forTimeInterval: 1.0) }, completion: { _, _ in })

        try await js(webView, "history.pushState({}, '', '/home')")
        try await waitUntil("the recorder to file the pushed URL") {
            self.pump(0.02)
            return tab.lastRecordedHistoryURL?.absoluteString == pushed
        }
        XCTAssertNil(tab.lastRecordedVisitID, "the insert is still in flight")

        // The site renames itself now, so the only title event this visit will
        // ever get happens while there is no id to write to.
        try await js(webView, "document.title = 'SPA Home'")
        pump(0.4)
        XCTAssertNil(tab.lastRecordedVisitID, "still in flight, so the correction was dropped")

        try await waitUntil("the id to arrive and carry the settled title with it") {
            self.pump(0.05)
            return self.recorded(f).first?.title == "SPA Home"
        }
        XCTAssertEqual(recorded(f).map(\.url), [pushed, f.base.absoluteString])
    }

    /// An insert that comes back after the tab has recorded twice more must not
    /// install its id: record A, record B, then A again — the third pass is
    /// dedup-skipped and decides the tab holds *no* correctable visit, and A's
    /// first insert must not overrule that (TASK-91).
    func testAStaleInsertDoesNotInstallItsVisitID() async throws {
        let f = try await makeFixture()
        let tab = makeTab(in: f)
        _ = try await loadSPAPage(f, tab)
        let a = f.base.appendingPathComponent("a")
        let b = f.base.appendingPathComponent("b")

        // Hold the writer queue so all three passes happen before any id lands.
        f.historyDB.dbQueue.asyncWrite({ _ in Thread.sleep(forTimeInterval: 0.6) }, completion: { _, _ in })
        tab.url = a
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        let generationAfterA = tab.historyRecordingGeneration
        tab.url = b
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        tab.url = a
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertGreaterThan(tab.historyRecordingGeneration, generationAfterA,
                             "every pass counts, dedup-skipped ones included")

        // Long enough for all three inserts and their completions.
        pump(1.5)

        XCTAssertNil(tab.lastRecordedVisitID,
                     "the third pass was dedup-skipped for a URL it had left, so it holds no visit")
        XCTAssertEqual(recorded(f).map(\.url),
                       [b.absoluteString, a.absoluteString, f.base.absoluteString],
                       "A's second recording was the one the dedup skipped")
    }

    /// The 30 s dedup is the recorder's, and applies here too: a Back to the
    /// page the tab came from selects another entry, but the visit it already
    /// has is minutes fresh.
    func testABackToAJustRecordedURLIsDeduplicated() async throws {
        let f = try await makeFixture()
        let tab = makeTab(in: f)
        let webView = try await loadSPAPage(f, tab)
        let pushed = f.base.absoluteString + "home"

        try await js(webView, "history.pushState({}, '', '/home')")
        try await waitUntil("the pushed URL to be recorded") {
            self.pump(0.05)
            return self.recorded(f).first?.url == pushed
        }

        try await js(webView, "history.back()")
        try await waitUntil("the tab to be back on the page it came from") {
            self.pump(0.02)
            return tab.url == f.base
        }
        pump(0.6)

        XCTAssertEqual(recorded(f).map(\.url), [pushed, f.base.absoluteString],
                       "the Back is inside the 30 s window, so it adds no row")
        XCTAssertEqual(tab.lastRecordedHistoryURL, f.base,
                       "but the recorder did run, and the correction window reopened")
    }
}

