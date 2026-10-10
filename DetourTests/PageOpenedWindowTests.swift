import XCTest
import WebKit
@testable import Detour

/// A window a page opens (`window.open`, a `target=_blank` link) is a real
/// WebKit child: the page gets a window back, WebKit performs the navigation,
/// and the two can reach each other (TASK-167, TASK-168).
///
/// Before, `createWebViewWith` returned nil and loaded the URL into a tab of
/// its own. `window.open()` then returned null to the page, so anything that
/// opens a blank window and navigates it afterwards — xterm.js's link handler
/// does — was left with an empty tab, and a sign-in popup had no opener to
/// hand its result to and could not close itself.
///
/// The pages are served by loopback servers and the calls are made in a real
/// `BrowserWindowController`, so the delegate that answers is the window's.
@MainActor
final class PageOpenedWindowTests: XCTestCase {

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

    private static let openerPage = """
        <html><head><title>Opener</title></head><body>
        <a id="blank" target="_blank">blank</a>
        <script>
        window.received = [];
        window.addEventListener('message', e => window.received.push({ origin: e.origin, data: e.data }));
        </script></body></html>
        """

    private static let targetPage = "<html><head><title>Target</title></head><body>target</body></html>"

    /// What a sign-in popup does when it is done: hand the result to the page
    /// that opened it, then close itself.
    private static let popupPage = """
        <html><head><title>Popup</title></head><body><script>
        window.hadOpener = !!window.opener;
        if (window.opener) window.opener.postMessage({ token: 'signed-in' }, '*');
        </script></body></html>
        """

    private static let routes = ["/opener": openerPage, "/target": targetPage, "/popup": popupPage,
                                 "/second": "<html><head><title>Second</title></head><body>second</body></html>"]

    /// A server for the fixture pages. Two of them are two origins.
    private func makeServer() async throws -> (server: LoopbackHTTPServer, base: String) {
        let server = try LoopbackHTTPServer(routes: Self.routes)
        servers.append(server)
        let port = try await server.start()
        return (server, "http://127.0.0.1:\(port)")
    }

    private func makeSpace(_ name: String = "Opened windows") throws -> Space {
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: name, emoji: "W", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    private func makeWindow(on space: Space) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        controllers.append(wc)
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id)
        wc.showWindow(nil)
        return wc
    }

    /// A selected tab showing the opener page.
    private func openOpener(in space: Space, window wc: BrowserWindowController, base: String) async throws -> BrowserTab {
        let tab = TabStore.shared.addTab(in: space, url: URL(string: base + "/opener")!)
        wc.selectTab(id: tab.id)
        try await waitUntil("the opener page to load") { tab.webView?.title == "Opener" && tab.isLoading == false }
        return tab
    }

    /// Runs `script` in the tab's page. `evaluateJavaScript` counts as a user
    /// gesture, so the page is allowed to open a window.
    @discardableResult
    private func run(_ script: String, in tab: BrowserTab) async throws -> Any? {
        try await XCTUnwrap(tab.webView).evaluateJavaScript(script)
    }

    private func requests(for path: String, on server: LoopbackHTTPServer) -> Int {
        server.requestedPaths.filter { $0 == path }.count
    }

    /// The one tab `body` adds to `space`.
    private func tabOpened(in space: Space, by body: () async throws -> Void,
                           file: StaticString = #filePath, line: UInt = #line) async throws -> BrowserTab {
        let before = Set(space.tabs.map(\.id))
        try await body()
        try await waitUntil("a new tab to open", file: file, line: line) { space.tabs.count > before.count }
        let opened = space.tabs.filter { !before.contains($0.id) }
        XCTAssertEqual(opened.count, 1, "exactly one tab was opened", file: file, line: line)
        return try XCTUnwrap(opened.first, file: file, line: line)
    }

    // MARK: - window.open hands the page a window (TASK-167)

    /// xterm.js's link handler: open a blank window, drop its opener, then
    /// navigate it. With no window handed back the second half never ran.
    func testABlankWindowThePageThenNavigatesLoadsTheURLInOneNewTab() async throws {
        let (server, base) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let opener = try await openOpener(in: space, window: wc, base: base)

        let child = try await tabOpened(in: space) {
            let gotWindow = try await run("""
                (() => {
                    const w = window.open();
                    if (!w) return false;
                    try { w.opener = null; } catch (e) {}
                    w.location.href = '\(base)/target';
                    return true;
                })()
                """, in: opener) as? Bool
            XCTAssertEqual(gotWindow, true, "window.open() handed the page a window")
        }

        try await waitUntil("the new tab to load the assigned URL") { child.title == "Target" }
        XCTAssertEqual(child.url?.absoluteString, base + "/target", "the tab shows the URL it loaded")
        XCTAssertEqual(wc.selectedTabID, child.id, "the new tab is the one on screen")
        XCTAssertEqual(space.tabs.count, 2, "one new tab, not one per step")
        XCTAssertEqual(requests(for: "/target", on: server), 1)
    }

    func testWindowOpenWithAURLReturnsAWindowAndLoadsItOnce() async throws {
        let (server, base) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let opener = try await openOpener(in: space, window: wc, base: base)

        let child = try await tabOpened(in: space) {
            let gotWindow = try await run("window.open('\(base)/target') !== null", in: opener) as? Bool
            XCTAssertEqual(gotWindow, true, "window.open(url) handed the page a window")
        }

        try await waitUntil("the new tab to load") { child.title == "Target" && !child.isLoading }
        XCTAssertEqual(child.url?.absoluteString, base + "/target")
        XCTAssertEqual(wc.selectedTabID, child.id)
        // Long enough for a second load of the same URL to have reached the server.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(requests(for: "/target", on: server), 1, "WebKit loads the URL; the browser does not load it again")
    }

    /// The new tab is an ordinary tab of the opener's space: placed after its
    /// opener, on the opener's data store, with a web view and a user content
    /// controller of its own, and known to the store's web view lookups.
    func testTheOpenedTabIsAnOrdinaryTabNextToItsOpener() async throws {
        let (_, base) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let opener = try await openOpener(in: space, window: wc, base: base)
        // A tab with no parent goes to the top of the list.
        let other = TabStore.shared.addTab(in: space, url: URL(string: base + "/second")!)

        let child = try await tabOpened(in: space) { try await run("window.open('\(base)/target'); null", in: opener) }

        XCTAssertEqual(child.parentID, opener.id, "the opener is the new tab's parent")
        XCTAssertEqual(space.tabs.map(\.id), [other.id, opener.id, child.id], "inserted right after its opener")
        XCTAssertEqual(child.spaceID, space.id)
        let childWebView = try XCTUnwrap(child.webView)
        let openerWebView = try XCTUnwrap(opener.webView)
        XCTAssertTrue(childWebView is BrowserWebView)
        XCTAssertTrue(childWebView.configuration.websiteDataStore === openerWebView.configuration.websiteDataStore,
                      "the opener's data store, so the two share cookies and storage")
        XCTAssertFalse(childWebView.configuration.userContentController === openerWebView.configuration.userContentController,
                       "each tab keeps its own user content controller; a window unhosting one tab must not unhook the other")
        XCTAssertTrue(childWebView.navigationDelegate === wc, "the window claimed the new tab's web view")
        XCTAssertTrue(TabStore.shared.tab(hosting: childWebView, in: space) === child)
        try await waitUntil("the new tab to load") { child.title == "Target" }
    }

    /// The page asked for no opener link: it gets null either way, and the
    /// tab still opens and loads.
    func testANoopenerWindowStillOpensATabThatLoads() async throws {
        let (server, base) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let opener = try await openOpener(in: space, window: wc, base: base)

        let child = try await tabOpened(in: space) {
            let gotWindow = try await run("window.open('\(base)/popup', '_blank', 'noopener') !== null", in: opener) as? Bool
            XCTAssertEqual(gotWindow, false, "a noopener open returns null to the page")
        }

        try await waitUntil("the new tab to load") { child.title == "Popup" && !child.isLoading }
        let hadOpener = try await run("window.hadOpener", in: child) as? Bool
        XCTAssertEqual(hadOpener, false)
        XCTAssertEqual(requests(for: "/popup", on: server), 1)
    }

    func testABlankTargetLinkOpensATabThatLoadsOnce() async throws {
        let (server, base) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let opener = try await openOpener(in: space, window: wc, base: base)

        let child = try await tabOpened(in: space) {
            try await run("const a = document.getElementById('blank'); a.href = '\(base)/target'; a.click(); null", in: opener)
        }

        try await waitUntil("the new tab to load") { child.title == "Target" && !child.isLoading }
        XCTAssertEqual(wc.selectedTabID, child.id)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(requests(for: "/target", on: server), 1)
    }

    /// The link in the report points at a dev server; when that is not running
    /// the new tab must say so, with the URL, like any other failed load.
    func testAnOpenedWindowWhoseLoadFailsShowsTheErrorPageForItsURL() async throws {
        let (_, base) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let opener = try await openOpener(in: space, window: wc, base: base)
        // A port that was free a moment ago refuses the connection at once.
        let (deadServer, deadBase) = try await makeServer()
        deadServer.stop()

        let child = try await tabOpened(in: space) {
            try await run("const w = window.open(); w.location.href = '\(deadBase)/target'; null", in: opener)
        }

        try await waitUntil("the error page to show") { child.webView?.url?.scheme == ErrorPage.scheme }
        XCTAssertEqual(child.url?.absoluteString, deadBase + "/target", "the tab keeps the URL that failed")
        XCTAssertEqual(child.webView?.url.flatMap { ErrorPage.originalURL(from: $0) }?.absoluteString, deadBase + "/target",
                       "the error page names it, and is what a reload retries")
    }

    /// A window opened by a tab of a space this window is no longer showing
    /// belongs to that tab's space (and its profile's data), not to whichever
    /// space is on screen, and does not take the selection.
    func testAWindowOpenedByATabOfAnotherSpaceOpensInThatSpace() async throws {
        let (_, base) = try await makeServer()
        let background = try makeSpace("Background")
        let foreground = try makeSpace("Foreground")
        let wc = makeWindow(on: background)
        let opener = try await openOpener(in: background, window: wc, base: base)
        wc.setActiveSpace(id: foreground.id)
        let shown = TabStore.shared.addTab(in: foreground, url: URL(string: base + "/second")!)
        wc.selectTab(id: shown.id)

        let child = try await tabOpened(in: background) { try await run("window.open('\(base)/target'); null", in: opener) }

        XCTAssertEqual(child.spaceID, background.id)
        XCTAssertEqual(foreground.tabs.map(\.id), [shown.id], "nothing was added to the space on screen")
        XCTAssertEqual(wc.selectedTabID, shown.id, "the selection stays where the user is")
        try await waitUntil("the background tab to load") { child.title == "Target" }
    }

    // MARK: - The opened window and its opener (TASK-168)

    /// The sign-in popup's way back: a message to `window.opener`, here from
    /// another origin.
    func testAnOpenedWindowCanMessageItsOpenerAcrossOrigins() async throws {
        let (_, base) = try await makeServer()
        let (_, otherBase) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let opener = try await openOpener(in: space, window: wc, base: base)

        let child = try await tabOpened(in: space) {
            try await run("window.popup = window.open('\(otherBase)/popup', 'signin', 'width=500,height=600'); null", in: opener)
        }

        try await waitUntil("the popup to load") { child.title == "Popup" }
        let hadOpener = try await run("window.hadOpener", in: child) as? Bool
        XCTAssertEqual(hadOpener, true, "the popup has an opener")
        try await waitUntil("the opener to receive the popup's message") {
            try await self.run("window.received.length", in: opener) as? Int == 1
        }
        let received = try await run("JSON.stringify(window.received[0])", in: opener) as? String
        XCTAssertEqual(received, #"{"origin":"\#(otherBase)","data":{"token":"signed-in"}}"#)
    }

    /// The popup closes itself when it is done; the tab goes away and the
    /// page that opened it is on screen again.
    func testAnOpenedWindowThatClosesItselfClosesItsTabAndReturnsToItsOpener() async throws {
        let (_, base) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let opener = try await openOpener(in: space, window: wc, base: base)
        // A sibling the usual close order would pick ahead of the opener.
        let earlier = try await tabOpened(in: space) { try await run("window.open('\(base)/second'); null", in: opener) }
        wc.selectTab(id: opener.id)

        let popup = try await tabOpened(in: space) {
            try await run("window.popup = window.open('\(base)/popup', 'signin', 'width=500,height=600'); null", in: opener)
        }
        try await waitUntil("the popup to load") { popup.title == "Popup" }
        XCTAssertEqual(wc.selectedTabID, popup.id)

        try await run("window.close(); null", in: popup)

        try await waitUntil("the popup's tab to close") { !space.tabs.contains { $0.id == popup.id } }
        XCTAssertEqual(wc.selectedTabID, opener.id, "back on the page that opened the popup")
        XCTAssertEqual(Set(space.tabs.map(\.id)), [opener.id, earlier.id])
        try await waitUntil("the opener to see its popup closed") {
            try await self.run("window.popup.closed", in: opener) as? Bool == true
        }
    }

    /// The opener can close the window it opened, and a tab the user closes
    /// reads as closed to the page that opened it — a page waiting on a popup
    /// polls for exactly that.
    func testTheOpenerSeesItsWindowClosedHoweverItWasClosed() async throws {
        let (_, base) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let opener = try await openOpener(in: space, window: wc, base: base)

        let byOpener = try await tabOpened(in: space) { try await run("window.first = window.open('\(base)/target'); null", in: opener) }
        try await waitUntil("the first window to load") { byOpener.title == "Target" }
        try await run("window.first.close(); null", in: opener)
        try await waitUntil("the tab the opener closed to go away") { !space.tabs.contains { $0.id == byOpener.id } }
        let firstClosed = try await run("window.first.closed", in: opener) as? Bool
        XCTAssertEqual(firstClosed, true)

        let byUser = try await tabOpened(in: space) { try await run("window.second = window.open('\(base)/target'); null", in: opener) }
        try await waitUntil("the second window to load") { byUser.title == "Target" }
        let index = try XCTUnwrap(space.tabs.firstIndex { $0.id == byUser.id })
        wc.closeTab(at: index, wasSelected: wc.selectedTabID == byUser.id)
        try await waitUntil("the opener to see the tab the user closed as closed") {
            try await self.run("window.second.closed", in: opener) as? Bool == true
        }
    }

    /// WebKit's rule for which windows a script may close is kept: a tab the
    /// user opened and has navigated in is not closed by its page.
    func testAPageCannotCloseATabTheUserOpenedAndNavigated() async throws {
        let (_, base) = try await makeServer()
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let tab = try await openOpener(in: space, window: wc, base: base)
        tab.load(URL(string: base + "/second")!)
        try await waitUntil("the second page to load") { tab.title == "Second" && !tab.isLoading }

        try await run("window.close(); null", in: tab)

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(space.tabs.contains { $0.id == tab.id }, "the tab is still open")
        XCTAssertEqual(wc.selectedTabID, tab.id)
    }
}

/// A window an extension page opens is the exception: WebKit would build it
/// from a copy of the extension context's configuration (CORS checks off for
/// the extension's hosts, the web view counted as one of the extension's own
/// pages), and a web page must not load in that. It stays a tab of the space's
/// own that the browser loads, with no window handed to the extension page.
@MainActor
final class ExtensionPageOpenedWindowTests: XCTestCase {

    private var controllers: [BrowserWindowController] = []
    private var servers: [LoopbackHTTPServer] = []
    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?

    override func setUp() {
        super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
    }

    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        for spaceID in createdSpaceIDs {
            guard let space = TabStore.shared.space(withID: spaceID) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: spaceID)
        }
        createdSpaceIDs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        super.tearDown()
    }

    func testAWindowAnExtensionPageOpensIsNotBuiltFromTheExtensionsConfiguration() async throws {
        let server = try LoopbackHTTPServer(routes: [
            "/target": "<html><head><title>Target</title></head><body>target</body></html>",
        ])
        servers.append(server)
        let base = "http://127.0.0.1:\(try await server.start())"

        let ext = try await makeOptionsPageTestExtension(idPrefix: "opened-window", name: "Opened Window Test")
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(ext.id)
        installTestExtension(ext, in: AppDatabase.shared)
        let profile = TabStore.shared.addProfile(name: "Opened Window Test")
        createdProfiles.append(profile)
        let context = try loadTestContext(ext, in: profile)
        let space = TabStore.shared.addSpace(name: "Opened", emoji: "W", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)

        let wc = BrowserWindowController(incognito: false)
        controllers.append(wc)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id)
        wc.showWindow(nil)
        let page = TabStore.shared.addExtensionTab(in: space, url: try XCTUnwrap(context.optionsPageURL),
                                                   configuration: try XCTUnwrap(context.webViewConfiguration))
        wc.selectTab(id: page.id)
        let pageWebView = try XCTUnwrap(page.webView)
        try await waitUntil("the options page to load") { isExtensionPageURL(pageWebView.url) && !pageWebView.isLoading }
        XCTAssertNotNil(pageWebView.configuration.value(forKey: "_requiredWebExtensionBaseURL") as? URL,
                        "the extension page's configuration is its context's (what the check below is about)")

        let gotWindow = try await pageWebView.evaluateJavaScript("window.open('\(base)/target') !== null") as? Bool
        try await waitUntil("the new tab to open") { space.tabs.count == 2 }
        let child = try XCTUnwrap(space.tabs.first { $0.id != page.id })
        try await waitUntil("the new tab to load") { child.title == "Target" }

        let childConfiguration = try XCTUnwrap(child.webView).configuration
        XCTAssertNil(childConfiguration.value(forKey: "_requiredWebExtensionBaseURL") as? URL,
                     "the web page's tab is not one of the extension's own pages")
        XCTAssertFalse(childConfiguration.userContentController === pageWebView.configuration.userContentController)
        XCTAssertTrue(childConfiguration.websiteDataStore === profile.dataStore, "an ordinary tab of the space")
        XCTAssertEqual(gotWindow, false, "the extension page gets no handle on the web page's window")
        XCTAssertEqual(child.parentID, page.id)
        XCTAssertEqual(wc.selectedTabID, child.id)
    }
}
