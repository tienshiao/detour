import XCTest
import WebKit
@testable import Detour

/// Which URL a failed navigation's error page names, the tab shows and Reload
/// retries (TASK-170): the URL that failed. A navigation the page starts
/// (a script's location change, a clicked link) reached the tab only through
/// its observer of the web view's URL, which WebKit sets back to the committed
/// page before it reports the failure, so the error page used to name the page
/// the tab was on, and Reload went back to it.
@MainActor
final class NavigationFailureURLTests: XCTestCase {

    private var controllers: [BrowserWindowController] = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var previousLastActiveSpaceID: UUID?
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    override func setUp() {
        super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    override func tearDown() {
        for controller in controllers {
            controller.sidebarSplitView.autosaveName = nil
            controller.window?.close()
        }
        controllers.removeAll()
        for id in createdSpaceIDs {
            if let space = TabStore.shared.space(withID: id) { space.tabs.forEach { $0.teardown() } }
            TabStore.shared.deleteSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Fixture

    private struct Fixture {
        let page: URL
        let redirect: URL
        let dead: URL
    }

    /// A live server with `/page` and a `/redirect` to a port nothing listens
    /// on any more.
    private func makeFixture() async throws -> Fixture {
        let gone = try LoopbackHTTPServer(routes: ["/": "<html></html>"])
        let deadPort = try await gone.start()
        gone.stop()
        let dead = URL(string: "http://127.0.0.1:\(deadPort)/target")!
        let server = try LoopbackHTTPServer(
            routes: ["/page": "<html><head><title>Opener</title></head><body>opener</body></html>"],
            redirects: ["/redirect": dead.absoluteString])
        servers.append(server)
        let port = try await server.start()
        return Fixture(page: URL(string: "http://127.0.0.1:\(port)/page")!,
                       redirect: URL(string: "http://127.0.0.1:\(port)/redirect")!, dead: dead)
    }

    private func makeSpace() -> Space {
        let profile = TabStore.shared.profiles.first { !$0.isIncognito }!
        let space = TabStore.shared.addSpace(name: "TASK-170", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    /// A tab selected in a window, or (`inWindow: false`) a tab of a space no
    /// window shows, whose web view's delegate is the tab's own.
    private func openerTab(_ fixture: Fixture, inWindow: Bool) async throws -> BrowserTab {
        let space = makeSpace()
        let tab = TabStore.shared.addTab(in: space, url: fixture.page)
        if inWindow {
            let wc = BrowserWindowController(incognito: false)
            wc.sidebarSplitView.autosaveName = nil
            controllers.append(wc)
            wc.setActiveSpace(id: space.id, selectTab: false)
            wc.selectTab(id: tab.id)
            wc.showWindow(nil)
        }
        try await waitUntil("the opener to show") { tab.title == "Opener" }
        return tab
    }

    private func run(_ script: String, in tab: BrowserTab) async throws {
        _ = try await XCTUnwrap(tab.webView).callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
    }

    /// Waits for the error page and returns the URL it names.
    private func errorPageURL(of tab: BrowserTab, file: StaticString = #filePath, line: UInt = #line) async throws -> URL? {
        try await waitUntil("the error page", file: file, line: line) {
            tab.webView?.url?.scheme == ErrorPage.scheme && tab.webView?.isLoading == false
        }
        return tab.webView?.url.flatMap(ErrorPage.originalURL(from:))
    }

    private func assertNamesTheDeadURL(_ tab: BrowserTab, _ fixture: Fixture,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let named = try await errorPageURL(of: tab, file: file, line: line)
        XCTAssertEqual(named, fixture.dead, "the error page names the URL that failed", file: file, line: line)
        XCTAssertEqual(tab.url, fixture.dead, "the tab shows the URL that failed", file: file, line: line)
    }

    // MARK: - Page-started navigations

    func testAScriptLocationChangeToADeadHostNamesItInASelectedTab() async throws {
        let fixture = try await makeFixture()
        let tab = try await openerTab(fixture, inWindow: true)
        try await run("location.href = '\(fixture.dead.absoluteString)';", in: tab)
        try await assertNamesTheDeadURL(tab, fixture)
    }

    func testAClickedLinkToADeadHostNamesItInASelectedTab() async throws {
        let fixture = try await makeFixture()
        let tab = try await openerTab(fixture, inWindow: true)
        try await run("""
            const a = document.createElement('a');
            a.href = '\(fixture.dead.absoluteString)';
            document.body.appendChild(a);
            a.click();
            """, in: tab)
        try await assertNamesTheDeadURL(tab, fixture)
    }

    func testAScriptLocationChangeToADeadHostNamesItInABackgroundTab() async throws {
        let fixture = try await makeFixture()
        let tab = try await openerTab(fixture, inWindow: false)
        try await run("location.href = '\(fixture.dead.absoluteString)';", in: tab)
        try await assertNamesTheDeadURL(tab, fixture)
    }

    /// Reload retries the URL that failed, not the page the tab was on: the
    /// host is still down, so it ends on the same error page.
    func testReloadRetriesTheURLThatFailed() async throws {
        let fixture = try await makeFixture()
        let tab = try await openerTab(fixture, inWindow: true)
        try await run("location.href = '\(fixture.dead.absoluteString)';", in: tab)
        try await assertNamesTheDeadURL(tab, fixture)

        tab.reload()
        try await Task.sleep(nanoseconds: 300_000_000)
        try await assertNamesTheDeadURL(tab, fixture)
        XCTAssertNotEqual(tab.title, "Opener", "Reload must not go back to the opener")
    }

    // MARK: - Loads the tab starts

    /// The user's decision (2026-10-28): a typed URL (or any load the tab
    /// starts) that redirects to a host that fails names the redirect target,
    /// as Chrome and Safari do; Reload retries it.
    func testATypedURLRedirectingToADeadHostNamesTheRedirectTarget() async throws {
        let fixture = try await makeFixture()
        let tab = try await openerTab(fixture, inWindow: true)
        tab.load(fixture.redirect, typed: true)
        try await assertNamesTheDeadURL(tab, fixture)
    }

    func testATypedDeadURLStillNamesItself() async throws {
        let fixture = try await makeFixture()
        let tab = try await openerTab(fixture, inWindow: true)
        tab.load(fixture.dead, typed: true)
        try await assertNamesTheDeadURL(tab, fixture)
    }

    // MARK: - Failing URLs the tab does not adopt

    /// A failure naming `about:blank`, the error scheme or an internal URL
    /// keeps the URL the tab had: Reload passes it to `loadRecordedURL`, which
    /// would arm an internal one a page chose.
    func testAFailingURLThatIsBlankAnErrorPageOrInternalIsNotAdopted() async throws {
        let fixture = try await makeFixture()
        let unadoptable = [URL(string: "about:blank")!,
                           ErrorPage.url(for: fixture.dead, error: URLError(.cannotConnectToHost)),
                           URL(string: "detour://history/?q=x")!]
        for failingURL in unadoptable {
            let tab = try await openerTab(fixture, inWindow: true)
            tab.didFailProvisionalNavigation(error: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                userInfo: [NSURLErrorFailingURLErrorKey: failingURL]))
            let named = try await errorPageURL(of: tab)
            XCTAssertEqual(named, fixture.page, "\(failingURL) is not adopted")
            XCTAssertEqual(tab.url, fixture.page, "\(failingURL) is not adopted")
            tab.reload()
            XCTAssertNil(tab.armedInternalPage, "Reload after \(failingURL) arms nothing")
            XCTAssertEqual(tab.url, fixture.page, "Reload after \(failingURL) retries the page")
        }
    }
}
