import XCTest
import AppKit
@testable import Detour

/// TASK-191.2: a link from another app goes through `AppDelegate`'s
/// `application(_:open:)` (or `openExternalURLs(_:sourceApp:)`, which it calls
/// with the Apple Event's sender) to the space a route names, in real windows
/// of the shared store. The rules themselves are `LinkPlacementTests` and
/// `LinkRouteResolverTests`.
///
/// The URLs use `.test` hosts, which never resolve: nothing reaches the network.
@MainActor
final class ExternalLinkRoutingTests: XCTestCase {

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

    private var work: Space!
    private var personal: Space!
    private var other: Space!

    override func setUpWithError() throws {
        try super.setUpWithError()
        appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        windowsBefore = Set(browserWindows().map(ObjectIdentifier.init))
        quickDetoursBefore = Set(QuickDetourWindowController.openControllers.map(ObjectIdentifier.init))
        previousDefault = routes.defaultTarget
        previousLastActiveSpaceID = store.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }

        let profileID = try XCTUnwrap(store.nonIncognitoSpaces.first).profileID
        work = addSpace("Work", profileID)
        personal = addSpace("Personal", profileID)
        other = addSpace("Other", profileID)
        route(.domainIs, "work.test", to: .space(work.id))
        route(.domainIs, "personal.test", to: .space(personal.id))
        route(.domainIs, "other.test", to: .space(other.id))
        route(.contains, "secret", to: .privateWindow)
        route(nil, app: "com.tinyspeck.slackmacgap", to: .space(personal.id))
        route(.domainIs, "mail-only.test", app: "com.apple.mail", to: .space(work.id))
        route(.domainIs, "later.test", to: .quarantine)
        route(.domainIs, "quick.test", to: .quickDetour)
        route(nil, app: "com.example.chat", to: .quickDetour)
    }

    override func tearDown() {
        for controller in newQuickDetours() {
            controller.closeDisposition = .discard
            controller.close()
        }
        for wc in browserWindows() where !windowsBefore.contains(ObjectIdentifier(wc)) {
            // Windows the code under test opened still autosave the sidebar
            // geometry other windows restore from.
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        // A link that took today's path may have opened in a window that was
        // there before the test (the test host's own).
        for space in store.spaces where !createdSpaceIDs.contains(space.id) {
            for tab in space.tabs where tab.url?.host?.hasSuffix(".test") == true {
                store.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
            }
        }
        // Routes first: a space a route targets cannot be deleted.
        for id in addedRouteIDs { routes.removeRoute(id: id) }
        addedRouteIDs.removeAll()
        routes.setDefaultTarget(previousDefault)
        for id in createdSpaceIDs { store.deleteSpace(id: id) }
        createdSpaceIDs.removeAll()
        store.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Fixture

    private func addSpace(_ name: String, _ profileID: UUID) -> Space {
        let space = store.addSpace(name: name, emoji: "🛫", colorHex: "007AFF", profileID: profileID)
        createdSpaceIDs.append(space.id)
        return space
    }

    private func route(_ kind: LinkRouteMatchKind?, _ pattern: String = "", app: String? = nil,
                       to target: LinkRouteTarget) {
        let added = routes.add(LinkRoute(match: kind.map { LinkRouteMatch(kind: $0, pattern: pattern) },
                                         sourceApp: app, target: target))
        if let added { addedRouteIDs.append(added.id) }
    }

    private func browserWindows() -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.filter { $0.window?.isVisible == true }
    }

    private func newBrowserWindows() -> [BrowserWindowController] {
        browserWindows().filter { !windowsBefore.contains(ObjectIdentifier($0)) }
    }

    /// A normal window on `space`, put in front of the others.
    @discardableResult
    private func makeWindow(showing space: Space) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        appDelegate.registerWindowController(wc)
        return wc
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    private func newQuickDetours() -> [QuickDetourWindowController] {
        QuickDetourWindowController.openControllers.filter { !quickDetoursBefore.contains(ObjectIdentifier($0)) }
    }

    private func tabAnywhere(_ url: URL) -> BrowserTab? {
        store.spaces.lazy.flatMap(\.tabs).first { $0.url == url }
    }

    private func tab(_ url: URL, in space: Space) -> BrowserTab? {
        space.tabs.first { $0.url == url }
    }

    private func frontBrowserWindow() -> BrowserWindowController? {
        NSApp.browserWindowControllersFrontToBack.first
    }

    // MARK: - A space shown by a window

    func testARoutedLinkOpensInTheWindowShowingItsSpaceAndBringsItForward() throws {
        let workWindow = makeWindow(showing: work)
        let personalWindow = makeWindow(showing: personal)   // in front
        XCTAssertTrue(frontBrowserWindow() === personalWindow)

        let link = url("https://app.work.test/inbox")
        appDelegate.application(NSApp, open: [link])

        let opened = try XCTUnwrap(tab(link, in: work), "the link opens in Work")
        XCTAssertEqual(workWindow.activeSpaceID, work.id)
        XCTAssertEqual(workWindow.selectedTabID, opened.id)
        XCTAssertEqual(personalWindow.activeSpaceID, personal.id, "the other window is left alone")
        XCTAssertTrue(frontBrowserWindow() === workWindow, "the window showing Work comes forward")
        XCTAssertEqual(newBrowserWindows().count, 2, "no window is opened")
    }

    func testASpaceShownBySeveralWindowsOpensInTheMostRecentOfThem() throws {
        let older = makeWindow(showing: work)
        let recent = makeWindow(showing: work)
        let front = makeWindow(showing: personal)
        _ = (older, front)

        let link = url("https://work.test/a")
        appDelegate.application(NSApp, open: [link])

        let opened = try XCTUnwrap(tab(link, in: work))
        XCTAssertEqual(recent.selectedTabID, opened.id)
        XCTAssertTrue(frontBrowserWindow() === recent)
    }

    // MARK: - A space no window shows

    func testASpaceShownByNoWindowSwitchesTheMostRecentNormalWindow() throws {
        let back = makeWindow(showing: work)
        let front = makeWindow(showing: personal)

        let link = url("https://other.test/page")
        appDelegate.application(NSApp, open: [link])

        let opened = try XCTUnwrap(tab(link, in: other))
        XCTAssertEqual(front.activeSpaceID, other.id, "the most recent window switches to Other")
        XCTAssertEqual(front.selectedTabID, opened.id)
        XCTAssertEqual(back.activeSpaceID, work.id)
        XCTAssertTrue(frontBrowserWindow() === front)
        XCTAssertEqual(newBrowserWindows().count, 2, "no window is opened")
    }

    func testAPrivateWindowInFrontIsNotSwitchedToANormalSpace() throws {
        let normal = makeWindow(showing: work)
        let privateWC = BrowserWindowController(incognito: true)
        privateWC.sidebarSplitView.autosaveName = nil
        privateWC.showWindow(nil)
        appDelegate.registerWindowController(privateWC)
        let privateSpaceID = privateWC.activeSpaceID

        let link = url("https://other.test/x")
        appDelegate.application(NSApp, open: [link])

        XCTAssertNotNil(tab(link, in: other))
        XCTAssertEqual(normal.activeSpaceID, other.id)
        XCTAssertEqual(privateWC.activeSpaceID, privateSpaceID)
        XCTAssertTrue(frontBrowserWindow() === normal)
    }

    // MARK: - Private window

    func testAPrivateRouteOpensANewPrivateWindowThenReusesIt() throws {
        makeWindow(showing: work)
        let first = url("https://secret.test/1")
        appDelegate.application(NSApp, open: [first])

        let privateWindows = newBrowserWindows().filter(\.isIncognito)
        XCTAssertEqual(privateWindows.count, 1, "a new Private window")
        let privateWC = try XCTUnwrap(privateWindows.first)
        let privateSpace = try XCTUnwrap(privateWC.activeSpace)
        XCTAssertTrue(privateSpace.isIncognito)
        let firstTab = try XCTUnwrap(tab(first, in: privateSpace))
        XCTAssertEqual(privateWC.selectedTabID, firstTab.id)
        XCTAssertNil(tab(first, in: work))

        // Another normal window in front: the next Private link still goes to
        // the Private window, as a tab.
        makeWindow(showing: personal)
        let second = url("https://secret.test/2")
        appDelegate.application(NSApp, open: [second])
        XCTAssertEqual(newBrowserWindows().filter(\.isIncognito).count, 1)
        let secondTab = try XCTUnwrap(tab(second, in: privateSpace))
        XCTAssertEqual(privateWC.selectedTabID, secondTab.id)
        XCTAssertTrue(frontBrowserWindow() === privateWC)
    }

    // MARK: - The source app

    func testASourceAppRouteMatchesLinksFromThatAppOnly() throws {
        let workWindow = makeWindow(showing: work)
        let personalWindow = makeWindow(showing: personal)
        workWindow.window?.makeKeyAndOrderFront(nil)

        let fromSlack = url("https://anything.test/from-slack")
        appDelegate.openExternalURLs([fromSlack], sourceApp: "com.tinyspeck.slackmacgap")
        let opened = try XCTUnwrap(tab(fromSlack, in: personal), "everything from Slack goes to Personal")
        XCTAssertEqual(personalWindow.selectedTabID, opened.id)

        // A route for links from Mail ignores the same URL from elsewhere.
        let mailLink = url("https://mail-only.test/x")
        appDelegate.openExternalURLs([mailLink], sourceApp: "com.tinyspeck.slackmacgap")
        XCTAssertNil(tab(mailLink, in: work), "from Slack, the Mail-only route does not apply")
        XCTAssertNotNil(tab(mailLink, in: personal), "the Slack route does")

        let fromMail = url("https://mail-only.test/y")
        appDelegate.openExternalURLs([fromMail], sourceApp: "com.apple.mail")
        XCTAssertNotNil(tab(fromMail, in: work))
        XCTAssertTrue(frontBrowserWindow() === workWindow)
    }

    func testWithoutASenderNoSourceAppRouteMatches() throws {
        makeWindow(showing: personal)
        let link = url("https://mail-only.test/z")
        let expectation = todaysBehaviour()
        appDelegate.application(NSApp, open: [link])   // no current Apple Event: no sender
        XCTAssertNil(tab(link, in: work))
        try expectation.verify(link, in: self)
    }

    // MARK: - Unmatched links and Most Recent Space

    func testAnUnmatchedLinkGoesToTheDefaultSpace() throws {
        routes.setDefaultTarget(.space(personal.id))
        makeWindow(showing: work)
        let personalWindow = makeWindow(showing: personal)
        makeWindow(showing: other)

        let link = url("https://unrouted.test/")
        appDelegate.application(NSApp, open: [link])
        let opened = try XCTUnwrap(tab(link, in: personal))
        XCTAssertEqual(personalWindow.selectedTabID, opened.id)
        XCTAssertTrue(frontBrowserWindow() === personalWindow)
    }

    func testAnUnmatchedLinkWithTheMostRecentSpaceDefaultBehavesAsBefore() throws {
        makeWindow(showing: work)
        makeWindow(showing: personal)
        let link = url("https://unrouted.test/most-recent")
        let expectation = todaysBehaviour()
        appDelegate.application(NSApp, open: [link])
        try expectation.verify(link, in: self)
    }

    func testAQuarantineRouteBehavesAsBeforeUntilQuarantineExists() throws {
        makeWindow(showing: work)
        let link = url("https://later.test/")
        let expectation = todaysBehaviour()
        appDelegate.application(NSApp, open: [link])
        try expectation.verify(link, in: self)
    }

    // MARK: - Quick Detour (TASK-193.5)

    func testAQuickDetourRouteOpensAQuickDetourOnTheFrontWindowsProfile() throws {
        let workWindow = makeWindow(showing: work)
        let link = url("https://app.quick.test/lookup")

        appDelegate.application(NSApp, open: [link])

        let quick = try XCTUnwrap(newQuickDetours().first, "a new Quick Detour window")
        XCTAssertEqual(newQuickDetours().count, 1)
        XCTAssertEqual(quick.tab?.url, link)
        XCTAssertTrue(quick.profile === work.profile, "the front window's profile")
        XCTAssertEqual(quick.sourceSpaceID, work.id, "Open in names the space in front")
        XCTAssertNil(tabAnywhere(link), "no tab in any space: not the Most Recent Space fallback")
        XCTAssertTrue(newBrowserWindows().allSatisfy { $0 === workWindow })
    }

    func testLinksFromOneAppOpenInQuickDetour() throws {
        // "Links from Slack open in Quick Detour": an app-only route.
        makeWindow(showing: work)
        let link = url("https://anything.test/from-chat")

        appDelegate.openExternalURLs([link], sourceApp: "com.example.chat")
        let quick = try XCTUnwrap(newQuickDetours().first)
        XCTAssertEqual(quick.tab?.url, link)

        let other = url("https://anything.test/from-mail")
        let expectation = todaysBehaviour()
        appDelegate.openExternalURLs([other], sourceApp: "com.apple.mail")
        try expectation.verify(other, in: self)
        XCTAssertEqual(newQuickDetours().count, 1, "another app's link follows the Default")
    }

    func testAQuickDetourDefaultTakesUnmatchedLinks() throws {
        makeWindow(showing: work)
        XCTAssertTrue(routes.setDefaultTarget(.quickDetour))
        let link = url("https://unrouted.test/default")

        appDelegate.application(NSApp, open: [link])

        XCTAssertEqual(newQuickDetours().first?.tab?.url, link)
        XCTAssertNil(tabAnywhere(link))
    }

    func testWithAPrivateWindowInFrontTheQuickDetourIsNotPrivate() throws {
        makeWindow(showing: work)
        let privateWindow = BrowserWindowController(incognito: true)
        privateWindow.sidebarSplitView.autosaveName = nil
        privateWindow.showWindow(nil)
        appDelegate.registerWindowController(privateWindow)
        XCTAssertTrue(frontBrowserWindow() === privateWindow)

        appDelegate.application(NSApp, open: [url("https://quick.test/private-front")])

        let quick = try XCTUnwrap(newQuickDetours().first)
        XCTAssertFalse(quick.profile.isIncognito, "only a Private route takes a link from another app into Private")
        XCTAssertTrue(quick.profile === work.profile)
    }

    /// What a link from another app did before routes: a tab in the key
    /// browser window's active space, else a new window. Captured before the
    /// open, checked after.
    private struct TodaysBehaviour {
        let keyWindow: BrowserWindowController?
        let keySpace: Space?
        let windowsBefore: Set<ObjectIdentifier>

        @MainActor
        func verify(_ link: URL, in test: ExternalLinkRoutingTests) throws {
            if let keyWindow, let keySpace {
                let opened = try XCTUnwrap(keySpace.tabs.first { $0.url == link }, "a tab in the key window's space")
                XCTAssertEqual(keyWindow.selectedTabID, opened.id)
            } else {
                let created = test.browserWindows().filter { !windowsBefore.contains(ObjectIdentifier($0)) }
                XCTAssertEqual(created.count, 1, "no key browser window: a new window")
                let window = try XCTUnwrap(created.first)
                XCTAssertFalse(window.isIncognito)
                let space = try XCTUnwrap(window.activeSpace)
                XCTAssertEqual(window.selectedTabID, space.tabs.first { $0.url == link }?.id)
            }
        }
    }

    private func todaysBehaviour() -> TodaysBehaviour {
        let key = NSApp.keyWindow?.windowController as? BrowserWindowController
        return TodaysBehaviour(keyWindow: key, keySpace: key?.activeSpace,
                               windowsBefore: Set(browserWindows().map(ObjectIdentifier.init)))
    }

    // MARK: - Several URLs

    func testEachURLOfAMultiURLOpenRoutesOnItsOwn() throws {
        let workWindow = makeWindow(showing: work)
        let personalWindow = makeWindow(showing: personal)

        let links = [url("https://work.test/1"), url("https://personal.test/1"),
                     url("https://work.test/2"), url("https://secret.test/3")]
        appDelegate.application(NSApp, open: links)

        XCTAssertNotNil(tab(links[0], in: work))
        XCTAssertNotNil(tab(links[1], in: personal))
        let second = try XCTUnwrap(tab(links[2], in: work))
        XCTAssertEqual(workWindow.selectedTabID, second.id)
        XCTAssertEqual(personalWindow.selectedTabID, tab(links[1], in: personal)?.id)
        let privateWC = try XCTUnwrap(newBrowserWindows().first(where: \.isIncognito))
        XCTAssertNotNil(privateWC.activeSpace.flatMap { tab(links[3], in: $0) })
        XCTAssertTrue(frontBrowserWindow() === privateWC, "the last link's window is in front")
    }

    func testTwoLinksToAnUnshownSpaceUseOneWindowSwitch() throws {
        let front = makeWindow(showing: work)
        let links = [url("https://other.test/1"), url("https://other.test/2")]
        appDelegate.application(NSApp, open: links)
        XCTAssertEqual(front.activeSpaceID, other.id)
        XCTAssertNotNil(tab(links[0], in: other))
        XCTAssertNotNil(tab(links[1], in: other))
        XCTAssertEqual(newBrowserWindows().count, 1)
    }

    func testNonWebURLsAreIgnored() {
        let before = Set(store.spaces.flatMap(\.tabs).map(\.id))
        appDelegate.application(NSApp, open: [url("file:///tmp/x.html"), url("detour://history")])
        XCTAssertEqual(Set(store.spaces.flatMap(\.tabs).map(\.id)), before)
    }
}
