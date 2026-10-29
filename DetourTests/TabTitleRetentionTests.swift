import XCTest
import WebKit
import GRDB
@testable import Detour

/// A tab keeps the title it has for a page while that page is only being shown
/// again, and the session saves a title that settles late (TASK-227).
///
/// When a web content process dies — a crash, or a memory kill of a background
/// tab — WebKit's `PageLoadState::reset` clears the web view's URL *and* title.
/// The tab keeps its URL, but used to replace its title with the stripped URL
/// (`youtube.com/watch?v=…`); the next save stored that, and a tab put to sleep
/// kept it across every relaunch after. A restored tab woken without being
/// shown did the same at commit, before its document reported a title.
@MainActor
final class TabTitleRetentionTests: XCTestCase {

    private var tabs: [BrowserTab] = []
    private let scheme = StallingSchemeHandler()
    private let pageURL = URL(string: "stall://title.test/watch?v=1")!
    private let otherURL = URL(string: "stall://title.test/other")!

    override func tearDown() {
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        super.tearDown()
    }

    private func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "stall")
        return configuration
    }

    private func track(_ tab: BrowserTab) -> BrowserTab {
        tabs.append(tab)
        return tab
    }

    /// Kills the tab's web content process with SIGKILL, as the system's memory
    /// kill does, and waits for WebKit to reset the web view: its URL goes nil
    /// and its title empty. (`_killWebContentProcess` leaves an unclaimed web
    /// view's process running on macOS 26.)
    private func killWebContentProcess(of tab: BrowserTab) async throws {
        let webView = try XCTUnwrap(tab.webView)
        let pid = try XCTUnwrap((webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value)
        XCTAssertGreaterThan(pid, 0, "the page has a web content process")
        XCTAssertEqual(kill(pid, SIGKILL), 0, "the test host may signal its own web content process")
        try await waitUntil("WebKit to reset the killed page") { webView.url == nil }
        XCTAssertEqual(webView.title ?? "", "", "WebKit clears the title of a page whose process exited")
    }

    // MARK: - BrowserTab

    func testAKilledWebProcessKeepsTheDocumentTitle() async throws {
        scheme.pages[pageURL.path] = "<html><head><title>A Video - YouTube</title></head><body>video</body></html>"
        let tab = track(BrowserTab(configuration: configuration()))
        tab.load(pageURL)
        try await waitUntil("the loaded page") { tab.title == "A Video - YouTube" && !tab.isLoading }

        try await killWebContentProcess(of: tab)

        XCTAssertEqual(tab.title, "A Video - YouTube", "the dead page is still the page this title names")
        XCTAssertEqual(tab.url, pageURL)
    }

    /// The bug as the user met it: the placeholder outlived the dead page
    /// because the tab went to sleep with it.
    func testATabPutToSleepAfterItsProcessDiedKeepsTheDocumentTitle() async throws {
        scheme.pages[pageURL.path] = "<html><head><title>A Video - YouTube</title></head><body>video</body></html>"
        let tab = track(BrowserTab(configuration: configuration()))
        tab.load(pageURL)
        try await waitUntil("the loaded page") { tab.title == "A Video - YouTube" && !tab.isLoading }

        try await killWebContentProcess(of: tab)
        tab.sleep(force: true)

        XCTAssertTrue(tab.isSleeping)
        XCTAssertEqual(tab.title, "A Video - YouTube")
        XCTAssertEqual(tab.url, pageURL)
    }

    /// A restored tab woken in the background commits before its document has
    /// a title — and a hidden web view may not reach the `<title>` for a long
    /// time. The persisted title names this page, so it stays until the
    /// document reports its own.
    func testAWokenRestoredTabKeepsItsPersistedTitleUntilTheDocumentReportsOne() async throws {
        // A real http page: `wake()` builds its web view from the tab's space
        // (none here, so a default configuration), which has no custom scheme.
        let server = try LoopbackHTTPServer(
            routes: ["/watch": "<html><body>untitled so far<img src=\"/hang.png\"></body></html>"],
            stalled: ["/hang.png": ""])
        let port = try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/watch"))

        let tab = track(BrowserTab(id: UUID(), title: "A Video - YouTube", url: url, faviconURL: nil,
                                   cachedInteractionState: nil, spaceID: UUID()))
        var titles: [String] = []
        let subscription = tab.$title.sink { titles.append($0) }
        defer { subscription.cancel() }
        tab.wake()
        let webView = try XCTUnwrap(tab.webView)

        try await waitUntil("the document to be parsed") {
            (try? await webView.evaluateJavaScript("document.readyState") as? String) == "interactive"
        }
        XCTAssertTrue(tab.isLoading, "the stalled image keeps the load going")
        XCTAssertEqual(tab.title, "A Video - YouTube")
        XCTAssertFalse(titles.contains { $0.hasPrefix("127.0.0.1") },
                       "the URL placeholder never replaced the persisted title: \(titles)")

        _ = try await webView.evaluateJavaScript("document.title = 'A Video (updated) - YouTube'")
        try await waitUntil("the document's own title") { tab.title == "A Video (updated) - YouTube" }
        server.release("/hang.png")
    }

    /// Going somewhere else is not the same page: the placeholder still says
    /// where the tab is going.
    func testANavigationToAnotherPageStillShowsWhereItIsGoing() async throws {
        scheme.pages[pageURL.path] = "<html><head><title>A Video - YouTube</title></head><body>video</body></html>"
        scheme.pages[otherURL.path] = "<html><body>untitled<img src=\"/hang.png\"></body></html>"
        let tab = track(BrowserTab(configuration: configuration()))
        tab.load(pageURL)
        try await waitUntil("the loaded page") { tab.title == "A Video - YouTube" && !tab.isLoading }

        tab.load(otherURL)
        XCTAssertEqual(tab.title, "stall://title.test/other")
        try await waitUntil("the other page to commit") { tab.webView?.url == self.otherURL && tab.url == self.otherURL }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(tab.title, "stall://title.test/other", "an untitled page is named by its URL")
        scheme.releaseHeld()
    }

    /// A navigation the page starts makes the web view's URL the destination
    /// while its title is still the old document's: an untitled destination is
    /// named by its URL, never by the page it left.
    func testAPageInitiatedNavigationToAnUntitledPageDoesNotKeepTheOldTitle() async throws {
        scheme.pages[pageURL.path] = "<html><head><title>A Video - YouTube</title></head><body>video</body></html>"
        scheme.pages[otherURL.path] = "<html><body>untitled</body></html>"
        let tab = track(BrowserTab(configuration: configuration()))
        tab.load(pageURL)
        try await waitUntil("the loaded page") { tab.title == "A Video - YouTube" && !tab.isLoading }
        let webView = try XCTUnwrap(tab.webView)

        _ = try await webView.evaluateJavaScript("location.href = '\(otherURL.absoluteString)'; 0")
        try await waitUntil("the other page to load") { webView.url == self.otherURL && !tab.isLoading }

        XCTAssertEqual(tab.title, "stall://title.test/other")
    }

    /// A load that redirected still names its page once the process dies: the
    /// page is the redirect's target, not the address the load left.
    func testAKilledWebProcessKeepsTheTitleOfARedirectedLoad() async throws {
        let server = try LoopbackHTTPServer(
            routes: ["/watch": "<html><head><title>A Video - YouTube</title></head><body>video</body></html>"],
            redirects: ["/short": "http://127.0.0.1:{port}/watch"])
        let port = try await server.start()
        defer { server.stop() }
        let shortURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/short"))
        let targetURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/watch"))
        let tab = track(BrowserTab(configuration: WKWebViewConfiguration()))
        tab.load(shortURL)
        try await waitUntil("the redirected page") { tab.title == "A Video - YouTube" && !tab.isLoading }
        XCTAssertEqual(tab.url, targetURL)

        try await killWebContentProcess(of: tab)

        XCTAssertEqual(tab.title, "A Video - YouTube")
    }

    /// The user's case: YouTube drops a tracking parameter (`&pp=…`) with
    /// `replaceState`, possibly while the page is still loading — a hidden web
    /// view can stay loading for a long time — and the process dies later. The
    /// title names the page at its new address.
    func testAKilledWebProcessKeepsTheTitleAfterAReplaceStateWhileLoading() async throws {
        let trackedURL = URL(string: "stall://title.test/watch?v=1&pp=abc")!
        scheme.pages[trackedURL.path] = """
            <html><head><title>A Video - YouTube</title></head><body>video
            <img src="/hang.png"></body></html>
            """
        let tab = track(BrowserTab(configuration: configuration()))
        tab.load(trackedURL)
        try await waitUntil("the document title") { tab.title == "A Video - YouTube" }
        let webView = try XCTUnwrap(tab.webView)

        _ = try await webView.evaluateJavaScript("history.replaceState(null, '', '/watch?v=1'); 0")
        try await waitUntil("the tab to follow the replaceState") { tab.url == self.pageURL }
        XCTAssertTrue(tab.isLoading, "the hanging image keeps the load going")

        try await killWebContentProcess(of: tab)

        XCTAssertEqual(tab.title, "A Video - YouTube")
        XCTAssertEqual(tab.url, pageURL)
    }

    // MARK: - Session save

    private struct SaveFixture {
        let db: AppDatabase
        let store: TabStore
        let tab: BrowserTab
    }

    private func makeSaveFixture(titleSaveDelay: TimeInterval) throws -> SaveFixture {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let store = TabStore(appDB: db, titleSaveDelay: titleSaveDelay)
        let profile = store.addProfile(name: "Work")
        let space = store.addSpace(name: "Work", emoji: "W", colorHex: "007AFF", profileID: profile.id)
        let tab = BrowserTab(id: UUID(), title: "youtube.com/watch?v=1", url: URL(string: "https://www.youtube.com/watch?v=1"),
                             faviconURL: nil, cachedInteractionState: nil, spaceID: space.id)
        space.tabs.append(tab)
        store.subscribeToTab(tab)
        store.saveNow()
        return SaveFixture(db: db, store: store, tab: tab)
    }

    private func savedTitle(_ fixture: SaveFixture) throws -> String? {
        try fixture.db.dbQueue.read { conn in
            try String.fetchOne(conn, sql: "SELECT title FROM tab WHERE id = ?", arguments: [fixture.tab.id.uuidString])
        }
    }

    /// A title that settles after the last URL or favicon change used to reach
    /// the database only with an unrelated save, or the save at quit — which a
    /// crash, a kill or a forced relaunch never runs.
    func testATitleChangeIsSavedWithoutAnyOtherChange() async throws {
        let fixture = try makeSaveFixture(titleSaveDelay: 0.2)
        XCTAssertEqual(try savedTitle(fixture), "youtube.com/watch?v=1")

        fixture.tab.title = "A Video - YouTube"

        try await waitUntil("the title to be saved", timeout: 3) { try self.savedTitle(fixture) == "A Video - YouTube" }
    }

    /// A page that rewrites its title faster than the save delay (a chat's
    /// unread flash) must not hold every session save off.
    func testATitleThatKeepsChangingDoesNotPostponeTheSave() async throws {
        let fixture = try makeSaveFixture(titleSaveDelay: 0.3)

        for index in 0 ..< 12 {
            fixture.tab.title = index.isMultiple(of: 2) ? "(1) Chat" : "Chat"
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let saved = try savedTitle(fixture)
        XCTAssertTrue(saved == "(1) Chat" || saved == "Chat",
                      "a save ran while the title was still changing; the database holds \(saved ?? "nil")")
    }
}
