import XCTest
import Combine
import GRDB
import WebKit
@testable import Detour

/// Late title changes correcting a recorded history visit (TASK-88).
///
/// The bug: a visit is recorded the moment loading finishes, but a single-page
/// app rewrites `document.title` after that, so the new URL is stored with the
/// previous page's title — and `historyURL` holds one title per URL, so the
/// stale title renames every visit of that URL.
///
/// `HistoryTitleUpdatePolicy` pins the guard matrix without a web view; the
/// integration tests below drive real `WKWebView`s through a `TabStore` of
/// their own, writing to a private in-memory history database so nothing
/// touches the real one.
@MainActor
final class HistoryTitleUpdateTests: XCTestCase {

    private let pageURL = URL(string: "https://page.invalid/a")!
    private var createdTabs: [BrowserTab] = []

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        super.tearDown()
    }

    // MARK: - The pure policy

    private let recordedAt = Date(timeIntervalSince1970: 1_000_000)

    /// - Parameter webViewURL: defaults to `tabURL` — the document the title
    ///   came from is the page the tab is on, unless a test says otherwise.
    ///   `.some(nil)` is a web view with no URL at all.
    private func urlToRename(title: String = "Real Title",
                             webViewTitle: String? = "Real Title",
                             isLoading: Bool = false,
                             tabURL: URL? = URL(string: "https://page.invalid/a")!,
                             webViewURL: URL?? = nil,
                             lastRecordedHistoryURL: URL? = URL(string: "https://page.invalid/a")!,
                             recordedAt: Date? = Date(timeIntervalSince1970: 1_000_000),
                             now: Date = Date(timeIntervalSince1970: 1_000_000),
                             hasSpace: Bool = true,
                             isIncognito: Bool = false) -> URL? {
        HistoryTitleUpdatePolicy.urlToRename(
            title: title, webViewTitle: webViewTitle, isLoading: isLoading, tabURL: tabURL,
            webViewURL: webViewURL ?? tabURL, lastRecordedHistoryURL: lastRecordedHistoryURL,
            recordedAt: recordedAt, now: now, hasSpace: hasSpace, isIncognito: isIncognito)
    }

    func testPolicyRenamesTheURLTheTabRecorded() {
        XCTAssertEqual(urlToRename(), pageURL)
    }

    /// AC #3: nothing is written while a navigation is in flight — the title in
    /// hand may belong to either side of it.
    func testPolicyRefusesWhileTheTabIsLoading() {
        XCTAssertNil(urlToRename(isLoading: true))
    }

    func testPolicyRefusesAnEmptyTitle() {
        XCTAssertNil(urlToRename(title: "", webViewTitle: ""))
    }

    /// AC #3: `BrowserTab.updateTitle` publishes the scheme-stripped URL while a
    /// navigation is pending, and an internal page's name, and the persisted
    /// title of a session still restoring. None of them is the document's title,
    /// so none of them reaches the history.
    func testPolicyRefusesATitleTheDocumentDoesNotReport() {
        XCTAssertNil(urlToRename(title: "page.invalid/a", webViewTitle: "Real Title"))
        XCTAssertNil(urlToRename(title: "History", webViewTitle: nil))
    }

    /// A sleeping tab has no web view, so it can never write a title.
    func testPolicyRefusesASleepingTab() {
        XCTAssertNil(urlToRename(webViewTitle: nil))
    }

    /// AC #3: the tab has moved on — the new page's title must not rename the
    /// URL the tab recorded before it.
    func testPolicyRefusesOnceTheTabHasMovedOn() {
        XCTAssertNil(urlToRename(tabURL: URL(string: "https://page.invalid/b")!,
                                 lastRecordedHistoryURL: pageURL))
    }

    func testPolicyRefusesAURLTheTabNeverRecorded() {
        XCTAssertNil(urlToRename(lastRecordedHistoryURL: nil))
        XCTAssertNil(urlToRename(tabURL: nil, lastRecordedHistoryURL: nil))
    }

    /// AC #4: the same exclusions the recorder applies.
    func testPolicyRefusesNonWebSchemes() {
        for string in ["detour://history/", "browser-error://load?url=x",
                       "webkit-extension://abc/popup.html", "file:///tmp/page.html"] {
            let url = URL(string: string)!
            XCTAssertNil(urlToRename(tabURL: url, lastRecordedHistoryURL: url), "\(string) is not in the history")
        }
    }

    /// AC #4.
    func testPolicyRefusesIncognitoAndSpacelessTabs() {
        XCTAssertNil(urlToRename(isIncognito: true))
        XCTAssertNil(urlToRename(hasSpace: false))
    }

    /// A failed load leaves `tab.url` on the URL the user asked for while the
    /// web view shows the error page, whose title is the stripped URL. That
    /// title must never rename the row the failed URL already has.
    func testPolicyRefusesWhenTheWebViewIsShowingAnErrorPage() {
        let errorURL = ErrorPage.url(for: pageURL, error: URLError(.cannotFindHost))
        XCTAssertNil(urlToRename(title: "page.invalid/a", webViewTitle: "page.invalid/a",
                                 webViewURL: .some(errorURL)))
    }

    /// The general form of the guard above: the title only renames the URL it
    /// actually came from.
    func testPolicyRefusesWhenTheDocumentIsNotTheTabsURL() {
        XCTAssertNil(urlToRename(webViewURL: .some(nil)), "a web view with no URL reports no document")
        XCTAssertNil(urlToRename(webViewURL: .some(URL(string: "https://page.invalid/b")!)))
    }

    /// The correction is for a page still settling after its navigation, not a
    /// licence to follow an unread counter for the life of the tab.
    func testPolicyRefusesOutsideTheCorrectionWindow() {
        let window = HistoryTitleUpdatePolicy.correctionWindow
        XCTAssertEqual(urlToRename(now: recordedAt.addingTimeInterval(window)), pageURL,
                       "the window's last instant still corrects")
        XCTAssertNil(urlToRename(now: recordedAt.addingTimeInterval(window + 0.001)))
        XCTAssertNil(urlToRename(recordedAt: nil), "a tab that recorded nothing has no window")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: TabStore
        let historyDB: HistoryDatabase
        let space: Space
    }

    /// A store of its own, writing to in-memory databases: the assertions are
    /// about the database the recorder actually writes to, and nothing here may
    /// reach the real history.
    ///
    /// - Parameter debounce: how long the title must hold still. Short by
    ///   default so a test need not wait production's real second; a test that
    ///   has to act *within* the window passes a longer one.
    private func makeFixture(incognito: Bool = false, debounce: TimeInterval = 0.05) throws -> Fixture {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB,
                             historyTitleDebounce: debounce)
        let space: Space
        if incognito {
            space = store.addIncognitoSpace()
        } else {
            let profile = store.addProfile(name: "Titles")
            space = store.addSpace(name: "Titles", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        }
        return Fixture(store: store, historyDB: historyDB, space: space)
    }

    private func makeTab(in f: Fixture) -> BrowserTab {
        let tab = f.store.addTab(in: f.space)
        createdTabs.append(tab)
        return tab
    }

    /// Renames the loaded document, the way a page renames itself.
    private func setTitle(_ title: String, on webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript("document.title = t; return true;",
                                                  arguments: ["t": title], contentWorld: .page)
    }

    private func html(title: String, body: String = "") -> String {
        "<html><head><title>\(title)</title></head><body>\(body)</body></html>"
    }

    /// Spins the main run loop — the debounce is scheduled on it, and so is
    /// everything WebKit reports back.
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func storedTitle(_ db: HistoryDatabase, _ url: URL) throws -> String? {
        try db.dbQueue.read { conn in
            try String.fetchOne(conn, sql: "SELECT title FROM historyURL WHERE url = ?",
                                arguments: [url.absoluteString])
        }
    }

    private func visitCount(_ db: HistoryDatabase, _ url: URL) throws -> Int {
        try db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT visitCount FROM historyURL WHERE url = ?",
                             arguments: [url.absoluteString]) ?? 0
        }
    }

    /// Pumps until the stored title changes from `title`, or the deadline passes.
    private func waitForTitleToLeave(_ title: String?, _ db: HistoryDatabase, _ url: URL,
                                     timeout: TimeInterval = 3) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pump(0.05)
            let stored = try storedTitle(db, url)
            if stored != title { return stored }
        }
        return try storedTitle(db, url)
    }

    // MARK: - The recorded-then-retitled case

    /// AC #1/#2: the visit is recorded, then the page changes its title — the
    /// stored title follows, and the visit itself is untouched.
    func testALateTitleChangeCorrectsTheRecordedVisit() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "Old Title"), baseURL: pageURL)
        pump(0.1)
        XCTAssertEqual(tab.url, pageURL)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "Old Title")
        XCTAssertEqual(tab.lastRecordedHistoryURL, pageURL, "the recorder remembers what it wrote")

        try await setTitle("New Title", on: webView)

        XCTAssertEqual(try waitForTitleToLeave("Old Title", f.historyDB, pageURL), "New Title")
        XCTAssertEqual(try visitCount(f.historyDB, pageURL), 1, "a correction adds no visit")
    }

    /// AC #6: a page rewriting its title in a burst costs one write, not one per
    /// change — the debounce only fires once the title holds still.
    func testRepeatedTitleChangesAreCoalesced() async throws {
        // A long debounce and a burst the page runs by itself: the whole burst
        // has to fit inside one debounce window for the coalescing to be what is
        // under test, and a round trip per title would leave that to the load on
        // the machine.
        let f = try makeFixture(debounce: 0.5)
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "(1) Inbox"), baseURL: pageURL)
        pump(0.1)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)

        _ = try await webView.callAsyncJavaScript("""
            await new Promise(resolve => {
                let n = 1;
                const id = setInterval(() => {
                    n += 1;
                    document.title = `(${n}) Inbox`;
                    if (n === 6) { clearInterval(id); resolve(); }
                }, 20);
            });
            return true;
            """, contentWorld: .page)
        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "(1) Inbox",
                       "nothing is written while the title keeps moving")

        XCTAssertEqual(try waitForTitleToLeave("(1) Inbox", f.historyDB, pageURL), "(6) Inbox",
                       "the title that settled is the one that is stored")
        XCTAssertEqual(try visitCount(f.historyDB, pageURL), 1)
    }

    /// AC #3: a tab that recorded nothing writes nothing — the title change is
    /// dropped rather than landing on whatever row the URL happens to have.
    func testATitleIsNeverWrittenForAURLTheTabDidNotRecord() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "Unrecorded"), baseURL: pageURL)
        pump(0.2)
        // The load's own recording, undone: from here the tab is one that never
        // recorded this URL (a sleeping tab woken onto it, say).
        tab.lastRecordedHistoryURL = nil
        tab.lastRecordedHistoryAt = nil
        let before = try storedTitle(f.historyDB, pageURL)
        try await setTitle("Still Unrecorded", on: webView)
        pump(0.5)

        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), before,
                       "the stored title is untouched")
        XCTAssertNotEqual(try storedTitle(f.historyDB, pageURL), "Still Unrecorded")
    }

    /// AC #4: an incognito space records nothing, and corrects nothing either.
    /// `lastRecordedHistoryURL` is set by hand here because the recorder would
    /// never set it for an incognito tab — this is the incognito guard itself
    /// under test, not the recorder's.
    func testIncognitoNeverWritesATitle() async throws {
        let f = try makeFixture(incognito: true)
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        // A row from some earlier, non-incognito visit of the same URL: the
        // incognito tab must not rename it.
        f.historyDB.recordVisit(url: pageURL.absoluteString, title: "Public Title",
                                faviconURL: nil, spaceID: UUID().uuidString)

        try await loadHTMLStringAndWait(webView, html: html(title: "Private Title"), baseURL: pageURL)
        pump(0.1)
        tab.lastRecordedHistoryURL = pageURL
        tab.lastRecordedHistoryAt = Date()
        try await setTitle("Private Title 2", on: webView)
        pump(0.5)

        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "Public Title")
    }

    /// A title that settles *while* the next navigation is in flight is refused
    /// by the policy and never retried by the debounce — so the recorder picks
    /// it up when the load ends, even on the branch where the 30 s dedup skips
    /// the visit itself (TASK-88).
    func testATitleThatSettledWhileLoadingIsWrittenWhenTheLoadEnds() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "Old Title"), baseURL: pageURL)
        pump(0.1)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "Old Title")

        // A navigation starts, and the page renames itself while it is in
        // flight: the debounce fires into a loading tab and the title is
        // dropped.
        tab.isLoading = true
        try await setTitle("New Title", on: webView)
        pump(0.3)
        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "Old Title",
                       "nothing is written while the tab is loading")

        // The load ends on the same URL, inside the dedup window, so no visit is
        // recorded — the correction still has to happen.
        tab.isLoading = false
        pump(0.3)

        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "New Title")
        XCTAssertEqual(try visitCount(f.historyDB, pageURL), 1, "the dedup still skipped the visit")
    }

    // MARK: - Failed loads

    /// A failed load leaves `tab.url` on the URL the user asked for while the
    /// web view shows `browser-error://…` (TASK-88): the page never loaded, so
    /// it is not a visit, and the error page's title (the stripped URL) must not
    /// rename the row that URL already has.
    ///
    /// The state is set up the way `BrowserTab.showErrorPage` sets it up rather
    /// than by failing a real load: a tab's web view only gets navigation
    /// callbacks through the window controller that hosts it, so a tab with no
    /// window never reaches `didFailProvisionalNavigation` at all.
    func testAnErrorPageRecordsNoVisitAndDoesNotRenameTheURLItFailedOn() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        let failedURL = URL(string: "https://unreachable.invalid/dead")!
        // The row an earlier, successful visit of that URL left behind.
        f.historyDB.recordVisit(url: failedURL.absoluteString, title: "Real Page",
                                faviconURL: nil, spaceID: f.space.id.uuidString)
        try await waitUntil("the earlier visit to be stored") {
            pump(0.05)
            return try storedTitle(f.historyDB, failedURL) == "Real Page"
        }

        // What `showErrorPage` leaves behind: the tab on the URL that failed,
        // the web view on the error document.
        tab.url = failedURL
        let errorURL = ErrorPage.url(for: failedURL, error: URLError(.cannotFindHost))
        try await loadAndWait(webView, URLRequest(url: errorURL))
        pump(0.2)
        XCTAssertEqual(webView.url?.scheme, ErrorPage.scheme)
        XCTAssertEqual(tab.url, failedURL, "the tab still reports the URL that failed")

        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertEqual(try visitCount(f.historyDB, failedURL), 1, "the failed load is not a visit")
        XCTAssertNil(tab.lastRecordedHistoryURL, "and so is not a row a late title may correct")

        // Even a tab that *had* recorded this URL before the failure refuses to
        // write the error document's title onto it.
        tab.lastRecordedHistoryURL = failedURL
        tab.lastRecordedHistoryAt = Date()
        f.store.updateHistoryTitle(for: tab)
        pump(0.3)
        XCTAssertEqual(try storedTitle(f.historyDB, failedURL), "Real Page")
    }

    // MARK: - The real single-page-app sequence

    private let videoURL = URL(string: "https://spa.invalid/watch")!
    private let homeURL = URL(string: "https://spa.invalid/home")!

    /// Loads a page titled "a video - SPA" at `videoURL` and waits until the
    /// document's own title has reached both the tab and the history row — the
    /// visit is recorded the instant loading finishes, which can be a beat
    /// before WebKit reports the title, and the correction under test is what
    /// settles it.
    private func loadVideoPage(_ f: Fixture, _ tab: BrowserTab) async throws {
        let webView = try XCTUnwrap(tab.webView)
        try await loadHTMLStringAndWait(webView, html: html(title: "a video - SPA"), baseURL: videoURL)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        try await waitUntil("the video page's own title to be stored") {
            pump(0.05)
            return try storedTitle(f.historyDB, videoURL) == "a video - SPA"
        }
    }

    /// What a `pushState` actually does: the URL moves, `isLoading` never
    /// toggles, so nothing records a visit for the new URL — and the page the
    /// tab left keeps its own title when the site renames itself afterwards.
    func testPushStateRecordsNoVisitAndNeverRenamesThePageItLeft() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        try await loadVideoPage(f, tab)

        var loadingTransitions: [Bool] = []
        let loadingWatch = tab.$isLoading.dropFirst().sink { loadingTransitions.append($0) }
        defer { loadingWatch.cancel() }

        _ = try await webView.callAsyncJavaScript("history.pushState({}, '', '/home'); return true;",
                                                  contentWorld: .page)
        pump(0.2)
        XCTAssertEqual(tab.url, homeURL, "the tab is on the pushed URL")
        XCTAssertEqual(loadingTransitions, [], "a pushState starts no load, so nothing records a visit")

        // The site renames itself for the page it navigated *to*.
        try await setTitle("SPA Home", on: webView)
        pump(0.5)

        XCTAssertEqual(try storedTitle(f.historyDB, videoURL), "a video - SPA",
                       "the page the tab left is not renamed by the next page's title")
        XCTAssertNil(try storedTitle(f.historyDB, homeURL),
                     "an unrecorded URL gets no row from a title change")
    }

    /// AC #1, the bug itself: something *does* record a visit for the pushed URL
    /// while the title still belongs to the previous page — in production a load
    /// that finishes after the in-page navigation. The row is written with the
    /// stale title and then corrected when the site renames itself.
    func testAVisitRecordedDuringAnInPageNavigationIsCorrectedByTheLateTitle() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        try await loadVideoPage(f, tab)

        _ = try await webView.callAsyncJavaScript("history.pushState({}, '', '/home'); return true;",
                                                  contentWorld: .page)
        pump(0.2)
        XCTAssertEqual(tab.title, "a video - SPA", "the site has not renamed itself yet")

        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertEqual(try storedTitle(f.historyDB, homeURL), "a video - SPA",
                       "this is the bug: the new URL is recorded with the previous page's title")

        try await setTitle("SPA Home", on: webView)

        XCTAssertEqual(try waitForTitleToLeave("a video - SPA", f.historyDB, homeURL), "SPA Home",
                       "the late title corrects the row")
        XCTAssertEqual(try visitCount(f.historyDB, homeURL), 1, "and adds no visit")
        XCTAssertEqual(try storedTitle(f.historyDB, videoURL), "a video - SPA",
                       "the video page keeps its own title")
    }

    /// The debounce reads the tab a second *after* the title changed, and an
    /// in-page navigation inside that second (a Back, a `replaceState`) puts the
    /// tab back on a URL the new title does not belong to. The URL is captured
    /// with the title, so the write is dropped instead of renaming the page the
    /// tab returned to (TASK-88).
    func testATitleIsNotWrittenOntoAURLTheTabReturnedToWithinTheDebounce() async throws {
        // Long enough that the retitle-then-Back sequence fits inside one
        // debounce window whatever the machine is doing.
        let debounce: TimeInterval = 1.0
        let f = try makeFixture(debounce: debounce)
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        try await loadVideoPage(f, tab)

        _ = try await webView.callAsyncJavaScript("history.pushState({}, '', '/home'); return true;",
                                                  contentWorld: .page)
        pump(0.1)
        XCTAssertEqual(tab.url, homeURL)

        let retitledAt = Date()
        try await setTitle("SPA Home", on: webView)
        // A `replaceState` rather than `history.back()`: the document here came
        // from `loadHTMLString`, which leaves no back-forward entry to traverse.
        // What the pipeline sees is the same either way — the tab's URL moves
        // back to the one it recorded after the title changed.
        _ = try await webView.callAsyncJavaScript("history.replaceState({}, '', '/watch'); return true;",
                                                  contentWorld: .page)
        try await waitUntil("the tab to be back on the page it recorded") {
            pump(0.05)
            return tab.url == videoURL
        }
        XCTAssertLessThan(Date().timeIntervalSince(retitledAt), debounce,
                          "the Back has to land before the debounce fires, or this tests nothing")

        // Past the debounce: the title that settled belongs to /home, and /home
        // is not where the tab is.
        pump(debounce + 0.5)

        XCTAssertEqual(try storedTitle(f.historyDB, videoURL), "a video - SPA",
                       "the page the tab returned to keeps its own title")
        XCTAssertNil(try storedTitle(f.historyDB, homeURL), "and the unrecorded URL gets no row")
    }
}
