import XCTest
import WebKit
@testable import Detour

/// TASK-191.4: typed URLs and links clicked in a page, routed by Link
/// Routes in real windows of the shared store. The rule itself is
/// `LinkRoutingEligibilityTests`; this checks the wiring in the window's
/// delegates and the command palette.
///
/// The pages come from a loopback server reached as two hosts, `127.0.0.1`
/// (the page) and `localhost` (routed to Work). A click is made with
/// `evaluateJavaScript`, which WebKit counts as a user gesture, so it reports
/// what a real click reports (a link activation, `_isUserInitiated`); a page's
/// own timer has no gesture. Cmd+click cannot be made this way (a script's
/// event carries no modifiers to the navigation action) and is checked at
/// runtime only. Typed URLs use `.test` hosts, which never resolve.
@MainActor
final class InPageLinkRoutingTests: XCTestCase {

    private var appDelegate: AppDelegate!
    private var store: TabStore { .shared }
    private var routes: LinkRouteStore { TabStore.shared.linkRoutes }

    private var windowsBefore: Set<ObjectIdentifier> = []
    private var quickDetoursBefore: Set<ObjectIdentifier> = []
    private var createdSpaceIDs: [UUID] = []
    private var addedRouteIDs: [UUID] = []
    private var previousDefault: LinkRouteTarget = .mostRecentSpace
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!
    private var servers: [LoopbackHTTPServer] = []

    private var personal: Space!
    private var work: Space!
    private var localhostRouteID: UUID?

    override func setUpWithError() throws {
        try super.setUpWithError()
        appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        windowsBefore = Set(browserWindows().map(ObjectIdentifier.init))
        quickDetoursBefore = Set(QuickDetourWindowController.openControllers.map(ObjectIdentifier.init))
        previousDefault = routes.defaultTarget
        routes.setDefaultTarget(.mostRecentSpace)
        previousLastActiveSpaceID = store.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }

        let profileID = try XCTUnwrap(store.nonIncognitoSpaces.first).profileID
        personal = addSpace("Personal", profileID)
        work = addSpace("Work", profileID)
        // First, so it wins over the localhost route for the secret link.
        route(.contains, "secret", to: .privateWindow)
        localhostRouteID = route(.domainIs, "localhost", to: .space(work.id))
        route(.domainIs, "work.test", to: .space(work.id))
    }

    override func tearDown() {
        for controller in newQuickDetours() {
            controller.closeDisposition = .discard
            controller.close()
        }
        for wc in browserWindows() where !windowsBefore.contains(ObjectIdentifier(wc)) {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        for space in store.spaces where !createdSpaceIDs.contains(space.id) {
            for tab in space.tabs where Self.isFixtureURL(tab.url) {
                store.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
            }
        }
        for id in addedRouteIDs { routes.removeRoute(id: id) }
        addedRouteIDs.removeAll()
        routes.setDefaultTarget(previousDefault)
        for id in createdSpaceIDs { store.deleteSpace(id: id) }
        createdSpaceIDs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        store.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    private static func isFixtureURL(_ url: URL?) -> Bool {
        guard let host = url?.host else { return false }
        return host.hasSuffix(".test") || host == "localhost" || host == "127.0.0.1"
    }

    // MARK: - Fixture

    private static let linksPage = """
        <html><head><title>Links</title></head><body>
        <a id="cross">cross</a> <a id="same" href="/target">same</a> <a id="blank" target="_blank">blank</a>
        <a id="secret">secret</a> <a id="redirect" href="/redirect">redirect</a> <a id="quarantined">quarantined</a>
        <button id="scriptnav">script navigation</button>
        <script>
        const other = 'http://localhost:' + location.port;
        document.getElementById('cross').href = other + '/target?cross';
        document.getElementById('blank').href = other + '/target?blank';
        document.getElementById('secret').href = other + '/target?secret';
        document.getElementById('quarantined').href = other + '/target?quarantined';
        document.getElementById('scriptnav').onclick = () => { location.href = other + '/target?scriptnav'; };
        window.openTab = () => window.open(other + '/target?open');
        window.openPopup = () => window.open(other + '/popup', 'p', 'popup,width=320,height=240');
        if (location.search === '?auto') setTimeout(() => document.getElementById('cross').click(), 300);
        </script></body></html>
        """

    private static let targetPage = "<html><head><title>Target</title></head><body>target</body></html>"
    private static let popupPage = """
        <html><head><title>Popup</title></head><body><script>window.hadOpener = !!window.opener;</script></body></html>
        """

    private func makeServer() async throws -> String {
        var routes = ["/links": Self.linksPage, "/links?auto": Self.linksPage, "/popup": Self.popupPage]
        for path in ["/target", "/target?cross", "/target?blank", "/target?secret", "/target?scriptnav",
                     "/target?open", "/target?redirected", "/target?quarantined"] {
            routes[path] = Self.targetPage
        }
        let server = try LoopbackHTTPServer(routes: routes,
                                            redirects: ["/redirect": "http://localhost:{port}/target?redirected"])
        servers.append(server)
        let port = try await server.start()
        return "http://127.0.0.1:\(port)"
    }

    private func addSpace(_ name: String, _ profileID: UUID) -> Space {
        let space = store.addSpace(name: name, emoji: "🛬", colorHex: "007AFF", profileID: profileID)
        createdSpaceIDs.append(space.id)
        return space
    }

    @discardableResult
    private func route(_ kind: LinkRouteMatchKind, _ pattern: String, to target: LinkRouteTarget) -> UUID? {
        let added = routes.add(LinkRoute(match: LinkRouteMatch(kind: kind, pattern: pattern), target: target))
        if let added { addedRouteIDs.append(added.id) }
        return added?.id
    }

    private func browserWindows() -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.filter { $0.window?.isVisible == true }
    }

    private func newPrivateWindows() -> [BrowserWindowController] {
        browserWindows().filter { !windowsBefore.contains(ObjectIdentifier($0)) && $0.isIncognito }
    }

    /// A window on `space`, in front of the others.
    @discardableResult
    private func makeWindow(showing space: Space) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        appDelegate.registerWindowController(wc)
        return wc
    }

    private func newQuickDetours() -> [QuickDetourWindowController] {
        QuickDetourWindowController.openControllers.filter { !quickDetoursBefore.contains(ObjectIdentifier($0)) }
    }

    /// A route sending links that contain "quarantined" to Quarantine, tried
    /// before the others.
    private func routeQuarantinedLinksFirst() throws {
        let id = try XCTUnwrap(route(.contains, "quarantined", to: .quarantine))
        routes.moveRoute(id: id, to: 0)
    }

    private func makePrivateWindow() -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: true)
        wc.sidebarSplitView.autosaveName = nil
        wc.showWindow(nil)
        appDelegate.registerWindowController(wc)
        return wc
    }

    /// A selected tab in `wc` showing `url`, loaded.
    private func openPage(_ url: String, in wc: BrowserWindowController) async throws -> BrowserTab {
        let space = try XCTUnwrap(wc.activeSpace)
        let tab = store.addTab(in: space, url: URL(string: url)!)
        wc.selectTab(id: tab.id)
        try await waitUntil("the page to load") { tab.webView?.title == "Links" && tab.isLoading == false }
        return tab
    }

    @discardableResult
    private func run(_ script: String, in webView: WKWebView?) async throws -> Any? {
        try await XCTUnwrap(webView).evaluateJavaScript(script + "; true")
    }

    private func tabs(in space: Space, query: String) -> [BrowserTab] {
        space.tabs.filter { $0.url?.host == "localhost" && $0.url?.query == query }
    }

    /// Time for a navigation that should not route to have done anything else.
    private func settle() async throws { try await Task.sleep(nanoseconds: 700_000_000) }

    // MARK: - Clicks that route

    func testACrossHostClickOpensInTheRoutedSpaceAndTheTabStays() async throws {
        let base = try await makeServer()
        let workWindow = makeWindow(showing: work)
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        try await run("document.getElementById('cross').click()", in: tab.webView)
        try await waitUntil("the link to open in Work") { !self.tabs(in: self.work, query: "cross").isEmpty }
        try await settle()

        XCTAssertEqual(tab.webView?.url?.path, "/links", "the clicked tab stays on its page")
        XCTAssertEqual(personal.tabs.count, 1, "no tab in the current space")
        XCTAssertEqual(workWindow.selectedTabID, tabs(in: work, query: "cross").first?.id,
                       "selected in the window showing Work")
        XCTAssertEqual(wc.activeSpaceID, personal.id)
        XCTAssertTrue(NSApp.browserWindowControllersFrontToBack.first === workWindow, "that window comes forward")
    }

    func testWithNoWindowOnTheRoutedSpaceTheClickingWindowSwitchesToIt() async throws {
        let base = try await makeServer()
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        try await run("document.getElementById('cross').click()", in: tab.webView)
        try await waitUntil("the link to open in Work") { !self.tabs(in: self.work, query: "cross").isEmpty }

        XCTAssertEqual(wc.activeSpaceID, work.id, "as a link from another app: the most recent window switches")
        XCTAssertEqual(wc.selectedTabID, tabs(in: work, query: "cross").first?.id)
        XCTAssertEqual(tab.webView?.url?.path, "/links")
        XCTAssertTrue(personal.tabs.contains { $0 === tab })
    }

    func testABlankTargetLinkOpensInTheRoutedSpaceInsteadOfANewTabHere() async throws {
        let base = try await makeServer()
        makeWindow(showing: work)
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        try await run("document.getElementById('blank').click()", in: tab.webView)
        try await waitUntil("the link to open in Work") { !self.tabs(in: self.work, query: "blank").isEmpty }
        try await settle()

        XCTAssertEqual(personal.tabs.count, 1, "no new tab in the current space")
        XCTAssertEqual(tab.webView?.url?.path, "/links")
    }

    func testATabStyleWindowOpenOpensInTheRoutedSpace() async throws {
        let base = try await makeServer()
        makeWindow(showing: work)
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        let gotNull = try await XCTUnwrap(tab.webView).evaluateJavaScript("window.openTab() === null") as? Bool
        try await waitUntil("the window to open in Work") { !self.tabs(in: self.work, query: "open").isEmpty }
        try await settle()

        XCTAssertEqual(gotNull, true, "routed elsewhere, the page gets no window")
        XCTAssertEqual(personal.tabs.count, 1)
    }

    func testAPrivateRouteFromANormalWindowOpensAPrivateWindow() async throws {
        let base = try await makeServer()
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        try await run("document.getElementById('secret').click()", in: tab.webView)
        try await waitUntil("a Private window with the link") {
            self.newPrivateWindows().contains { $0.activeSpace?.tabs.contains { $0.url?.query == "secret" } == true }
        }
        XCTAssertEqual(tab.webView?.url?.path, "/links")
        XCTAssertEqual(personal.tabs.count, 1)
    }

    // MARK: - Quarantine (TASK-194)

    func testAClickMatchingAQuarantineRouteOpensAQuarantineWindowAndTheTabStays() async throws {
        let base = try await makeServer()
        try routeQuarantinedLinksFirst()
        makeWindow(showing: work)
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        try await run("document.getElementById('quarantined').click()", in: tab.webView)
        try await waitUntil("a quarantine window with the link") {
            self.newQuickDetours().contains { $0.isQuarantine && $0.tab?.url?.query == "quarantined" }
        }
        try await settle()

        let quarantine = try XCTUnwrap(newQuickDetours().first)
        XCTAssertEqual(newQuickDetours().count, 1)
        XCTAssertEqual(quarantine.sourceSpaceID, personal.id, "Open in names the space it was clicked in")
        XCTAssertEqual(tab.webView?.url?.path, "/links", "the clicked tab stays on its page")
        XCTAssertEqual(personal.tabs.count, 1)
        XCTAssertTrue(tabs(in: work, query: "quarantined").isEmpty, "the route below it is not reached")
    }

    func testAClickInAPrivateWindowIsNeverQuarantined() async throws {
        // A quarantine's Open in reaches normal spaces: nothing leaves a
        // Private window, so the link navigates there as before.
        let base = try await makeServer()
        try routeQuarantinedLinksFirst()
        let wc = makePrivateWindow()
        let tab = try await openPage(base + "/links", in: wc)

        try await run("document.getElementById('quarantined').click()", in: tab.webView)
        try await waitUntil("the link to load in place") { tab.webView?.url?.query == "quarantined" }
        try await settle()
        XCTAssertTrue(newQuickDetours().isEmpty)
    }

    func testATypedURLMatchingAQuarantineRouteIsNeverQuarantined() throws {
        try routeQuarantinedLinksFirst()
        let wc = makeWindow(showing: personal)

        submit("https://quarantined.test/typed", in: wc, inPlace: false)

        XCTAssertEqual(personal.tabs.first?.url?.host, "quarantined.test", "opens here, as with no route")
        XCTAssertTrue(newQuickDetours().isEmpty)
    }

    // MARK: - Links that do not route

    func testASameHostClickNavigatesInPlace() async throws {
        let base = try await makeServer()
        route(.domainIs, "127.0.0.1", to: .space(work.id))
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        try await run("document.getElementById('same').click()", in: tab.webView)
        try await waitUntil("the tab to navigate") { tab.webView?.url?.path == "/target" && tab.isLoading == false }
        XCTAssertTrue(work.tabs.isEmpty, "a same-host click is never routed, even to a routed host")
        XCTAssertEqual(wc.activeSpaceID, personal.id)
    }

    func testAServerRedirectToARoutedHostIsNotRouted() async throws {
        let base = try await makeServer()
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        try await run("document.getElementById('redirect').click()", in: tab.webView)
        try await waitUntil("the redirect to land in the tab") {
            tab.webView?.url?.host == "localhost" && tab.webView?.url?.query == "redirected" && tab.isLoading == false
        }
        XCTAssertTrue(work.tabs.isEmpty)
    }

    func testAScriptNavigationToARoutedHostIsNotRouted() async throws {
        let base = try await makeServer()
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        // The click handler's location.href keeps the user gesture, but is
        // not a link activation.
        try await run("document.getElementById('scriptnav').click()", in: tab.webView)
        try await waitUntil("the tab to navigate") { tab.webView?.url?.query == "scriptnav" && tab.isLoading == false }
        XCTAssertTrue(work.tabs.isEmpty)
    }

    func testAPagesOwnClickWithoutAUserGestureIsNotRouted() async throws {
        let base = try await makeServer()
        let wc = makeWindow(showing: personal)
        let space = try XCTUnwrap(wc.activeSpace)
        let tab = store.addTab(in: space, url: URL(string: base + "/links?auto")!)
        wc.selectTab(id: tab.id)

        try await waitUntil("the timer's click to navigate the tab") {
            tab.webView?.url?.query == "cross" && tab.isLoading == false
        }
        XCTAssertTrue(work.tabs.isEmpty)
    }

    func testAPopupKeepsItsOpenerAndIsNotRouted() async throws {
        let base = try await makeServer()
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        let gotWindow = try await XCTUnwrap(tab.webView).evaluateJavaScript("window.openPopup() !== null") as? Bool
        try await waitUntil("the popup to open here") {
            self.personal.tabs.contains { $0.webView?.url?.path == "/popup" && $0.isLoading == false }
        }
        let popup = try XCTUnwrap(personal.tabs.first { $0.webView?.url?.path == "/popup" })
        let hadOpener = try await XCTUnwrap(popup.webView).evaluateJavaScript("window.hadOpener") as? Bool
        XCTAssertEqual(gotWindow, true)
        XCTAssertEqual(hadOpener, true)
        XCTAssertTrue(work.tabs.isEmpty)
    }

    func testAClickInsideAPeekIsNotRouted() async throws {
        let base = try await makeServer()
        let wc = makeWindow(showing: personal)
        _ = try await openPage(base + "/links", in: wc)
        wc.showPeekOverlay(url: URL(string: base + "/links")!)
        let peek = try XCTUnwrap(wc.selectedTab?.peekTab)
        try await waitUntil("the Peek to load") { peek.webView?.title == "Links" && peek.isLoading == false }

        try await run("document.getElementById('cross').click()", in: peek.webView)
        try await waitUntil("the Peek to navigate") { peek.webView?.url?.query == "cross" && peek.isLoading == false }
        XCTAssertTrue(work.tabs.isEmpty)
        XCTAssertNotNil(wc.peekOverlayView, "the Peek stays up")
    }

    func testFromAPrivateWindowARouteToANormalSpaceIsIgnored() async throws {
        let base = try await makeServer()
        let wc = makePrivateWindow()
        let tab = try await openPage(base + "/links", in: wc)

        try await run("document.getElementById('cross').click()", in: tab.webView)
        try await waitUntil("the tab to navigate") { tab.webView?.url?.query == "cross" && tab.isLoading == false }
        XCTAssertTrue(work.tabs.isEmpty)
        XCTAssertTrue(wc.isIncognito)
    }

    // MARK: - The anchor intercept

    func testOnAPinnedTabARouteElsewhereWinsOverThePeek() async throws {
        let base = try await makeServer()
        makeWindow(showing: work)
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)
        store.pinTab(id: tab.id, in: personal)
        wc.selectTab(id: tab.id)
        XCTAssertNotNil(PeekAnchor.anchorURL(forTabID: tab.id, pinnedEntries: personal.pinnedEntries, favorites: []))

        try await run("document.getElementById('cross').click()", in: tab.webView)
        try await waitUntil("the link to open in Work") { !self.tabs(in: self.work, query: "cross").isEmpty }
        try await settle()
        XCTAssertNil(wc.peekOverlayView, "routed, so no Peek")
        XCTAssertEqual(tab.webView?.url?.path, "/links")
    }

    func testOnAPinnedTabWithNoRouteTheCrossHostClickStillPeeks() async throws {
        let base = try await makeServer()
        if let id = localhostRouteID { routes.removeRoute(id: id) }
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)
        store.pinTab(id: tab.id, in: personal)
        wc.selectTab(id: tab.id)

        try await run("document.getElementById('cross').click()", in: tab.webView)
        try await waitUntil("the Peek to open") { wc.peekOverlayView != nil }
        XCTAssertTrue(work.tabs.isEmpty)
    }

    // MARK: - Typed URLs

    private func submit(_ input: String, in wc: BrowserWindowController, inPlace: Bool) {
        wc.commandPaletteNavigatesInPlace = inPlace
        wc.commandPalette(CommandPaletteView(), didSubmitInput: input)
    }

    func testATypedURLInTheNewTabPaletteOpensInTheRoutedSpace() async throws {
        let workWindow = makeWindow(showing: work)
        let wc = makeWindow(showing: personal)

        submit("https://app.work.test/typed", in: wc, inPlace: false)

        let opened = try XCTUnwrap(work.tabs.first { $0.url?.host == "app.work.test" }, "opened in Work")
        XCTAssertTrue(opened.consumeNextVisitIsTyped(), "its visit still records as typed")
        XCTAssertEqual(workWindow.selectedTabID, opened.id)
        XCTAssertTrue(personal.tabs.isEmpty, "no tab in the current space")
        XCTAssertEqual(wc.activeSpaceID, personal.id)
    }

    func testATypedURLNavigatingInPlaceIsNeverRouted() async throws {
        let base = try await makeServer()
        let wc = makeWindow(showing: personal)
        let tab = try await openPage(base + "/links", in: wc)

        submit("https://app.work.test/typed", in: wc, inPlace: true)

        XCTAssertEqual(tab.url?.host, "app.work.test", "the selected tab loads it")
        XCTAssertTrue(work.tabs.isEmpty)
    }

    func testASearchIsNeverRouted() throws {
        let wc = makeWindow(showing: personal)
        let engine = personal.profile?.searchEngine ?? .google
        let searchHost = try XCTUnwrap(engine.searchURL(for: "anything")?.host)
        route(.domainIs, searchHost, to: .space(work.id))

        submit("flights to work", in: wc, inPlace: false)

        XCTAssertEqual(personal.tabs.first?.url?.host, searchHost, "the search opens here")
        XCTAssertTrue(work.tabs.isEmpty)
    }

    func testATypedURLWithNoRouteOpensHereAsBefore() throws {
        let wc = makeWindow(showing: personal)
        submit("https://unrouted.test/", in: wc, inPlace: false)
        XCTAssertEqual(personal.tabs.first?.url?.host, "unrouted.test")
        XCTAssertEqual(wc.selectedTabID, personal.tabs.first?.id)
    }

    func testATypedURLRoutedToTheCurrentSpaceOpensHere() throws {
        let wc = makeWindow(showing: work)
        submit("https://app.work.test/", in: wc, inPlace: false)
        XCTAssertEqual(work.tabs.count, 1)
        XCTAssertEqual(wc.selectedTabID, work.tabs.first?.id)
    }

    func testATypedURLInAPrivateWindowIgnoresRoutesToNormalSpaces() throws {
        let wc = makePrivateWindow()
        submit("https://app.work.test/", in: wc, inPlace: false)
        XCTAssertEqual(wc.activeSpace?.tabs.first?.url?.host, "app.work.test", "opens in the Private window")
        XCTAssertTrue(work.tabs.isEmpty)
    }

    func testATypedURLRoutedToPrivateOpensAPrivateWindow() throws {
        let wc = makeWindow(showing: personal)
        submit("https://secret.test/x", in: wc, inPlace: false)
        XCTAssertTrue(newPrivateWindows().contains { $0.activeSpace?.tabs.contains { $0.url?.host == "secret.test" } == true })
        XCTAssertTrue(personal.tabs.isEmpty)
    }
}
