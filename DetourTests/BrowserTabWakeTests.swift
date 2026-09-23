import XCTest
import WebKit
@testable import Detour

/// What a freshly woken web view's first (nil) URL is allowed to do to the tab
/// behind it (TASK-28) — and what a *failed* first navigation is not allowed to
/// do to a session restored from the previous launch (TASK-45).
@MainActor
final class BrowserTabWakeTests: XCTestCase {

    /// Nothing listens on port 1, so a navigation here fails at once without
    /// leaving the machine: the tests never depend on the network being up.
    private let restoredURL = URL(string: "http://127.0.0.1:1/restored")!
    /// Where WebKit leaves a web view whose first navigation failed before committing.
    private let blankURL = URL(string: "about:blank")!

    private var tabs: [BrowserTab] = []

    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    override func setUp() {
        super.setUp()
        // `load(_:)` fetches a favicon optimistically; keep that off the network
        // and out of the shared loader's caches.
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    override func tearDown() {
        tabs.forEach { $0.teardown() }
        tabs.removeAll()
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    private func track(_ tab: BrowserTab) -> BrowserTab {
        tabs.append(tab)
        return tab
    }

    /// An interaction state whose current back/forward item is `restoredURL`,
    /// archived the way `BrowserTab.sleep()` archives it.
    private func archivedInteractionState() async throws -> Data {
        let source = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        try await loadHTMLStringAndWait(
            source, html: "<html><head><title>Restored</title></head><body>restored</body></html>",
            baseURL: restoredURL)
        let state = try XCTUnwrap(source.interactionState, "the source web view should have session state")
        return try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
    }

    // MARK: -

    /// A tab restored asleep with the session state of `restoredURL`, woken the
    /// way `BrowserWindowController.claimWebView` wakes it: `wake()` hands the
    /// web view the cached state — which does not start a navigation — and the
    /// safety net then kicks the tab's URL. That kick is the "restore navigation"
    /// that fails offline in practice, and its URL is reported synchronously, so
    /// the URL observer has already recorded it by the time the failure lands.
    private func wakeRestoredTab() async throws -> BrowserTab {
        let tab = track(BrowserTab(
            id: UUID(), title: "Persisted title", url: restoredURL, faviconURL: nil,
            cachedInteractionState: try await archivedInteractionState(), spaceID: UUID()))
        tab.favicon = NSImage(size: NSSize(width: 1, height: 1))

        tab.wake()
        let webView = try XCTUnwrap(tab.webView)
        XCTAssertNil(webView.url, "restoring the session state starts no navigation by itself")
        XCTAssertFalse(webView.isLoading)
        tab.loadIfStalled()
        XCTAssertEqual(webView.url, restoredURL, "the kick is under way")
        return tab
    }

    /// TASK-45: a tab restored asleep whose restore navigation fails (offline
    /// relaunch, DNS failure, captive portal) keeps the restored session — no
    /// error page is loaded over it, and its persisted title and favicon stay.
    func testFailedWakeOfARestoredTabKeepsItsSession() async throws {
        let tab = try await wakeRestoredTab()
        let webView = try XCTUnwrap(tab.webView)
        XCTAssertEqual(tab.title, "Persisted title", "the kick does not retitle the tab with its raw URL")

        // What the navigation delegate reports when the restore navigation dies
        // before it commits. Nothing was *attempted* by the user, so this must
        // not replace the restored session.
        tab.didFailProvisionalNavigation(error: URLError(.notConnectedToInternet))
        // ...and the kick's real (connection-refused) failure unwinds: WebKit
        // falls back to about:blank, which must not leak into the tab either.
        try await waitUntil("the kick to unwind") { webView.url == self.blankURL }

        XCTAssertEqual(tab.url, restoredURL, "the restored URL survives the failure")
        XCTAssertEqual(tab.title, "Persisted title", "the persisted title is not replaced by the raw URL")
        XCTAssertNotNil(tab.favicon, "the persisted favicon is kept")
        XCTAssertNotEqual(webView.url?.scheme, ErrorPage.scheme, "no error page was loaded")
        XCTAssertNotNil(tab.currentInteractionStateData(), "the restored session state is still there")
    }

    /// TASK-114: a session restored *onto* about:blank (`window.open('')`,
    /// `tabs.create({url: 'about:blank'})`) commits about:blank because the
    /// restore succeeded, not because it failed — so the commit ends the
    /// restore, and a later failed navigation still earns its error page.
    func testAWakeRestoredOntoAboutBlankEndsTheRestoreAtCommit() async throws {
        let source = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        try await loadAndWait(source, URLRequest(url: blankURL))
        let state = try XCTUnwrap(source.interactionState, "the source web view should have session state")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)

        let tab = track(BrowserTab(
            id: UUID(), title: "Blank", url: blankURL, faviconURL: nil,
            cachedInteractionState: archived, spaceID: UUID()))
        tab.wake()
        XCTAssertTrue(tab.restoringSession)
        tab.loadIfStalled()

        try await waitUntil("the about:blank commit to end the restore") { !tab.restoringSession }
    }

    /// TASK-45: the user asking to reload such a tab still retries the page,
    /// and *that* failure earns the error page — the user asked for it.
    func testReloadingATabWhoseWakeFailedRetriesItsURL() async throws {
        let tab = try await wakeRestoredTab()
        tab.didFailProvisionalNavigation(error: URLError(.notConnectedToInternet))
        // Let the kick's real (connection-refused) failure unwind, as it has by
        // the time a user reaches for reload: the web view sits on about:blank.
        try await waitUntil("the kick to unwind") { tab.webView?.url == self.blankURL }

        tab.reload()
        XCTAssertEqual(tab.webView?.url, restoredURL, "reload asks for the tab's own URL")

        tab.didFailProvisionalNavigation(error: URLError(.notConnectedToInternet))
        XCTAssertEqual(tab.webView?.url?.scheme, ErrorPage.scheme, "a user-initiated retry that fails shows the error page")
    }

    /// TASK-45: once the restored session commits, the tab is an ordinary page
    /// again — a later navigation that fails shows the error page as usual.
    func testCommittedRestoreEndsTheProtection() async throws {
        let tab = try await wakeRestoredTab()
        tab.didCommitNavigation()

        tab.didFailProvisionalNavigation(error: URLError(.notConnectedToInternet))
        XCTAssertEqual(tab.webView?.url?.scheme, ErrorPage.scheme)
    }

    /// TASK-45: a slept tab is restored from its cached session on the next
    /// wake, so the same protection covers the in-session sleep/wake cycle —
    /// even though `lastAttemptedURL` from its previous life is still set.
    func testFailedWakeAfterSleepKeepsItsSession() async throws {
        let tab = track(BrowserTab(id: UUID()))
        tab.load(restoredURL)  // leaves `lastAttemptedURL` = restoredURL behind
        try await loadHTMLStringAndWait(
            try XCTUnwrap(tab.webView),
            html: "<html><head><title>Committed title</title></head><body>live</body></html>",
            baseURL: restoredURL)
        tab.didCommitNavigation()
        // The web view's title lands through KVO a turn after `didFinish`, so
        // the tab's title is not synchronous with the load.
        try await waitUntil("the committed title to land") { tab.title == "Committed title" }
        tab.sleep(force: true)
        XCTAssertTrue(tab.isSleeping)
        XCTAssertNotNil(tab.currentInteractionStateData(), "the live session was cached by sleep()")

        tab.wake()
        tab.loadIfStalled()
        tab.didFailProvisionalNavigation(error: URLError(.notConnectedToInternet))

        XCTAssertNotEqual(tab.webView?.url?.scheme, ErrorPage.scheme, "no error page over the slept session")
        XCTAssertEqual(tab.title, "Committed title")
    }

    /// TASK-28: a tab created sleeping keeps its URL across the wake — the new
    /// web view's initial nil URL must not clear it before `wake()` loads it.
    func testWakingATabCreatedSleepingKeepsItsURL() throws {
        let url = URL(string: "http://127.0.0.1:1/sleeping")!
        let tab = track(BrowserTab(
            id: UUID(), title: "Sleeping", url: url, faviconURL: nil,
            cachedInteractionState: nil, spaceID: UUID()))

        tab.wake()
        // Both reads matter: the observer subscribes — and emits nil — before
        // `wake()` reads `url` to load it, so clearing it would also leave the
        // woken tab blank.
        XCTAssertEqual(tab.url, url, "the URL survives the web view's first nil emission")
        XCTAssertEqual(tab.webView?.url, url, "and the wake loaded it")
    }

    /// TASK-45: the error page is still what a *user-initiated* load gets when
    /// it fails — only the wake path changed.
    func testFailedUserLoadStillShowsTheErrorPage() throws {
        let tab = track(BrowserTab(id: UUID()))
        let target = URL(string: "http://127.0.0.1:1/typed")!

        tab.load(target)
        XCTAssertEqual(tab.url, target)

        tab.didFailProvisionalNavigation(error: URLError(.notConnectedToInternet))

        XCTAssertEqual(tab.url, target, "the error page reports the URL the user asked for")
        XCTAssertEqual(tab.webView?.url?.scheme, ErrorPage.scheme, "the error page was loaded")
        XCTAssertEqual(tab.webView?.url.flatMap(ErrorPage.originalURL(from:)), target)
    }
}
