import XCTest
import WebKit
@testable import Detour

/// What a failure *after* commit does to a tab (TASK-178): nothing. The
/// document that committed is on screen, so the error page — which is for a
/// request that produced no page — must not replace it. Found on a YouTube
/// Short whose HTML response was still streaming a minute into playback: the
/// main resource timed out and the playing page became "The request timed out."
///
/// The failure is a real one, reported by WebKit through whichever navigation
/// delegate the web view has: the server sends the start of a document under a
/// `Content-Length` it never honours, then closes the connection.
@MainActor
final class CommittedLoadFailureTests: XCTestCase {

    private var tabs: [BrowserTab] = []
    private var controllers: [BrowserWindowController] = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    override func setUp() {
        super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    override func tearDown() {
        tabs.forEach { $0.teardown() }
        tabs.removeAll()
        for controller in controllers { controller.window?.close() }
        controllers.removeAll()
        for id in createdSpaceIDs { TabStore.shared.deleteSpace(id: id) }
        createdSpaceIDs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Fixture

    private static let partialPath = "/partial"

    /// The start of a page: enough to commit, take a title and render.
    private static let partialPage = "<html><head><title>Partial</title></head><body><p>the part that arrived</p>"
        + String(repeating: "<!-- padding -->", count: 128)

    /// A server whose `/partial` commits and then waits to be dropped.
    private func makeServer() async throws -> (server: LoopbackHTTPServer, url: URL) {
        let server = try LoopbackHTTPServer(routes: [:], truncated: [Self.partialPath: Self.partialPage])
        servers.append(server)
        let port = try await server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)\(Self.partialPath)")!)
    }

    /// Waits for the page to be showing, fails its load, and checks that the
    /// tab is still on the page.
    private func assertStaysOnThePage(_ tab: BrowserTab, at url: URL, server: LoopbackHTTPServer,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let webView = try XCTUnwrap(tab.webView, file: file, line: line)
        try await waitUntil("the start of the page to show", file: file, line: line) { tab.title == "Partial" }
        XCTAssertTrue(webView.isLoading, "the rest of the response is still owed", file: file, line: line)
        tab.favicon = NSImage(size: NSSize(width: 1, height: 1))

        server.release(Self.partialPath)
        try await waitUntil("the load to fail", file: file, line: line) { !webView.isLoading }
        // Give a stray error-page load time to show up.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNotEqual(webView.url?.scheme, ErrorPage.scheme, "no error page over a page that is showing",
                          file: file, line: line)
        XCTAssertEqual(webView.url, url, file: file, line: line)
        XCTAssertEqual(tab.url, url, file: file, line: line)
        XCTAssertEqual(tab.title, "Partial", "the row keeps the page's title", file: file, line: line)
        XCTAssertNotNil(tab.favicon, "the row keeps the page's favicon", file: file, line: line)
        let shown = try await webView.evaluateJavaScript("document.querySelector('p')?.textContent") as? String
        XCTAssertEqual(shown, "the part that arrived", "the document that committed is still there",
                       file: file, line: line)
    }

    // MARK: -

    /// A tab no window owns: the tab is its own navigation delegate.
    func testAFailureAfterCommitKeepsThePageInAnUnownedTab() async throws {
        let (server, url) = try await makeServer()
        let tab = BrowserTab(id: UUID())
        tabs.append(tab)
        tab.load(url)

        try await assertStaysOnThePage(tab, at: url, server: server)
    }

    /// The selected tab of a window: the window is the navigation delegate.
    func testAFailureAfterCommitKeepsThePageInTheSelectedTab() async throws {
        let (server, url) = try await makeServer()
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Committed failure", emoji: "C", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        controllers.append(wc)
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id)
        wc.showWindow(nil)

        let tab = store.addTab(in: space, url: url)
        wc.selectTab(id: tab.id)
        XCTAssertTrue(tab.webView?.navigationDelegate === wc, "the window reports this tab's failures")

        try await assertStaysOnThePage(tab, at: url, server: server)
    }
}
