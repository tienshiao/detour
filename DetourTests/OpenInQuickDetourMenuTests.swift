import XCTest
import WebKit
@testable import Detour

/// TASK-300: a browser window's link menu offers Open Link in Quick Detour
/// next to the other Open Link items, whatever the Opt-Cmd-click setting
/// says and inside a Peek too, and choosing it does what Opt-Cmd-click does
/// (the page's profile; Private in a Private window). The sidebar's tab menu
/// offers Open in Quick Detour, a copy of the row's address as Opt-Cmd-click
/// on the row makes.
///
/// Real browser windows on a profile of the test's own; the link menu is a
/// stand-in for WebKit's (its two link items, by identifier) handed to a
/// BrowserWebView in the window. Pages are `.invalid` hosts.
nonisolated final class OpenInQuickDetourMenuTests: XCTestCase {

    @MainActor private var store: TabStore { .shared }
    private var profile: Profile!
    private var space: Space!
    private var windows: [BrowserWindowController] = []
    private var quickDetoursBefore: Set<ObjectIdentifier> = []
    private var settingBefore: Bool = true
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        settingBefore = QuickDetourSettings.shared.isOptionCommandClickEnabled
        quickDetoursBefore = Set(QuickDetourWindowController.openControllers.map(ObjectIdentifier.init))
        profile = store.addProfile(name: "Menu QD \(UUID().uuidString.prefix(4))")
        space = store.addSpace(name: "Menu", emoji: "📋", colorHex: "007AFF", profileID: profile.id)
    }

    @MainActor override func tearDown() async throws {
        QuickDetourSettings.shared.isOptionCommandClickEnabled = settingBefore
        spin()
        for controller in newQuickDetours() {
            controller.closeDisposition = .discard
            controller.close()
        }
        for wc in windows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for tab in space.tabs { tab.teardown() }
        store.forceRemoveSpace(id: space.id)
        store.forceRemoveProfile(id: profile.id)
        AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        Self.retainedProfiles.append(profile)
        store.undoManager.removeAllActions()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    @MainActor private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor private func newQuickDetours() -> [QuickDetourWindowController] {
        QuickDetourWindowController.openControllers.filter { !quickDetoursBefore.contains(ObjectIdentifier($0)) }
    }

    @MainActor private func url(_ path: String) -> URL { URL(string: "https://menu-quick-detour.invalid/\(path)")! }

    @MainActor private func makeWindow(incognito: Bool = false) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: incognito)
        wc.sidebarSplitView.autosaveName = nil
        if !incognito { wc.setActiveSpace(id: space.id, selectTab: false) }
        wc.showWindow(nil)
        windows.append(wc)
        return wc
    }

    /// A web view in `wc`'s window, as a page's is.
    @MainActor private func webView(in wc: BrowserWindowController) throws -> BrowserWebView {
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        try XCTUnwrap(wc.window?.contentView).addSubview(webView)
        return webView
    }

    /// Records WebKit's link item being performed.
    private final class WebKitLinkItem: NSObject {
        var performed = 0
        @objc func open(_ sender: Any?) { performed += 1 }
    }

    /// WebKit's link menu, as far as `willOpenMenu` reads it: Open Link and
    /// Open Link in New Window, by identifier.
    @MainActor private func linkMenu(target: WebKitLinkItem) -> NSMenu {
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow"] {
            let item = NSMenuItem(title: id, action: #selector(WebKitLinkItem.open(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            item.target = target
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: ""))
        return menu
    }

    @MainActor private func openMenu(_ menu: NSMenu, on webView: BrowserWebView) throws {
        let window = try XCTUnwrap(webView.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        webView.willOpenMenu(menu, with: event)
    }

    // MARK: - The link menu

    @MainActor func testTheLinkMenuOffersQuickDetourAfterTheOtherOpenLinkItems() throws {
        let wc = makeWindow()
        let menu = linkMenu(target: WebKitLinkItem())

        try openMenu(menu, on: try webView(in: wc))

        XCTAssertEqual(Array(menu.items.map(\.title).prefix(5)), [
            "Open Link in New Tab", "Open Link in New Window", "Open Link in Quick Detour",
            "Open Link in Split View", "Copy Link",
        ])
    }

    @MainActor func testTheItemIsOfferedWithTheOptionCommandClickSettingOff() throws {
        QuickDetourSettings.shared.isOptionCommandClickEnabled = false
        let wc = makeWindow()
        let menu = linkMenu(target: WebKitLinkItem())

        try openMenu(menu, on: try webView(in: wc))

        XCTAssertTrue(menu.items.contains { $0.title == BrowserWebView.openLinkInQuickDetourTitle })
    }

    @MainActor func testTheItemIsOfferedInsideAPeek() throws {
        let wc = makeWindow()
        let host = store.addTab(in: space, url: url("host"))
        wc.selectTab(id: host.id)
        let peekWebView = try webView(in: wc)
        let peek = BrowserTab(webView: peekWebView)
        host.peekTab = peek
        defer {
            host.peekTab = nil
            peek.teardown()
        }
        let menu = linkMenu(target: WebKitLinkItem())

        try openMenu(menu, on: peekWebView)

        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains(BrowserWebView.openLinkInQuickDetourTitle))
        XCTAssertFalse(titles.contains("Open Link in Split View"), "a Peek still has no split item")
    }

    @MainActor func testChoosingItRunsWebKitsItemForTheQuickDetourAction() throws {
        let wc = makeWindow()
        let webKit = WebKitLinkItem()
        let menu = linkMenu(target: webKit)
        try openMenu(menu, on: try webView(in: wc))
        let item = try XCTUnwrap(menu.items.first { $0.title == BrowserWebView.openLinkInQuickDetourTitle })

        _ = (item.target as AnyObject?)?.perform(item.action, with: item)

        XCTAssertEqual(webKit.performed, 1, "WebKit's item asks for the new window")
        XCTAssertEqual(wc.contextMenuLinkAction, .openInQuickDetour)
        wc.contextMenuLinkAction = .none
    }

    // MARK: - What choosing it does

    @MainActor func testAWebLinkOpensAQuickDetourOnThePagesProfile() throws {
        let wc = makeWindow()
        let page = store.addTab(in: space, url: url("page"))
        wc.selectTab(id: page.id)
        let tabsBefore = space.tabs.map(\.id)

        wc.openLinkInQuickDetourFromMenu(url("linked"), firing: try webView(in: wc), in: space)
        spin()

        XCTAssertEqual(newQuickDetours().count, 1)
        let quick = try XCTUnwrap(newQuickDetours().first)
        XCTAssertTrue(quick.profile === profile)
        XCTAssertEqual(quick.tab?.url, url("linked"))
        XCTAssertEqual(quick.sourceSpaceID, space.id)
        XCTAssertEqual(space.tabs.map(\.id), tabsBefore, "no tab opened")
    }

    @MainActor func testInAPrivateWindowItIsAPrivateQuickDetour() throws {
        let wc = makeWindow(incognito: true)
        let privateSpace = try XCTUnwrap(wc.activeSpace)

        wc.openLinkInQuickDetourFromMenu(url("private"), firing: try webView(in: wc), in: privateSpace)
        spin()

        let quick = try XCTUnwrap(newQuickDetours().first)
        XCTAssertTrue(quick.profile.isIncognito)
        XCTAssertEqual(quick.tab?.url, url("private"))
    }

    @MainActor func testALinkThatIsNotAWebPageOpensABackgroundTabAsOptionCommandClickDoes() throws {
        let wc = makeWindow()
        let page = store.addTab(in: space, url: url("page"))
        wc.selectTab(id: page.id)
        let mail = URL(string: "mailto:someone@menu-quick-detour.invalid")!

        wc.openLinkInQuickDetourFromMenu(mail, firing: try webView(in: wc), in: space)
        spin()

        XCTAssertTrue(newQuickDetours().isEmpty)
        XCTAssertEqual(space.tabs.last?.url, mail)
        XCTAssertEqual(wc.selectedTabID, page.id, "in the background")
    }

    @MainActor func testOnlyWebLinksOpenAQuickDetour() {
        XCTAssertTrue(QuickDetour.opensLinkInQuickDetour(URL(string: "https://example.com/")!))
        XCTAssertTrue(QuickDetour.opensLinkInQuickDetour(URL(string: "HTTP://example.com/")!))
        XCTAssertFalse(QuickDetour.opensLinkInQuickDetour(URL(string: "mailto:a@example.com")!))
        XCTAssertFalse(QuickDetour.opensLinkInQuickDetour(URL(string: "data:text/plain,hi")!))
        XCTAssertFalse(QuickDetour.opensLinkInQuickDetour(URL(string: "detour://history")!))
    }

    // MARK: - The sidebar's tab menu

    /// The sidebar's menu for table row `row`, as a right-click at `fraction`
    /// of its width asks for it.
    @MainActor private func sidebarMenu(_ wc: BrowserWindowController, row: Int,
                                        at fraction: CGFloat = 0.25) throws -> NSMenu {
        spin()
        let sidebar = wc.tabSidebar
        let table = sidebar.tableView
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.minX + rect.width * fraction, y: rect.midY), to: nil)
        let window = try XCTUnwrap(table.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(table.menu(for: event))
        XCTAssertEqual(table.clickedRow, row)
        sidebar.menuNeedsUpdate(menu)
        return menu
    }

    @MainActor private func row(of tab: BrowserTab, in wc: BrowserWindowController) throws -> Int {
        spin()
        let sidebar = wc.tabSidebar
        let item = try XCTUnwrap(sidebar.tabItems.firstIndex { $0.tabs.contains { $0 === tab } })
        return rowForNormalTab(at: item, pinnedItemCount: sidebar.flattenedPinnedItems.count)
    }

    @MainActor private func choose(_ title: String, in menu: NSMenu) throws {
        let item = try XCTUnwrap(menu.items.first { $0.title == title }, "\(menu.items.map(\.title))")
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
    }

    @MainActor func testTheSidebarTabMenuOpensACopyInQuickDetour() throws {
        QuickDetourSettings.shared.isOptionCommandClickEnabled = false
        let wc = makeWindow()
        let first = store.addTab(in: space, url: url("first"))
        let copied = store.addTab(in: space, url: url("copied"))
        wc.selectTab(id: first.id)
        let tabsBefore = space.tabs.map(\.id)

        try choose(TabSidebarViewController.openInQuickDetourTitle,
                   in: try sidebarMenu(wc, row: try row(of: copied, in: wc)))

        XCTAssertEqual(newQuickDetours().count, 1)
        let quick = try XCTUnwrap(newQuickDetours().first)
        XCTAssertEqual(quick.tab?.url, url("copied"))
        XCTAssertTrue(quick.profile === profile)
        XCTAssertFalse(quick.tab === copied, "a copy, not the tab")
        XCTAssertEqual(wc.selectedTabID, first.id)
        XCTAssertEqual(space.tabs.map(\.id), tabsBefore)
    }

    @MainActor func testASplitRowsMenuCopiesThePaneUnderThePointer() throws {
        let wc = makeWindow()
        let left = store.addTab(in: space, url: url("left"))
        let right = store.addTab(in: space, url: url("right"))
        store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        let splitRow = try row(of: left, in: wc)

        try choose(TabSidebarViewController.openInQuickDetourTitle, in: try sidebarMenu(wc, row: splitRow, at: 0.75))

        XCTAssertEqual(newQuickDetours().compactMap { $0.tab?.url }, [url("right")])
    }

    @MainActor func testAPrivateWindowsTabMenuOpensAPrivateQuickDetour() throws {
        let wc = makeWindow(incognito: true)
        let privateSpace = try XCTUnwrap(wc.activeSpace)
        let tab = store.addTab(in: privateSpace, url: url("private-tab"))
        defer { tab.teardown() }

        try choose(TabSidebarViewController.openInQuickDetourTitle,
                   in: try sidebarMenu(wc, row: try row(of: tab, in: wc)))

        let quick = try XCTUnwrap(newQuickDetours().first)
        XCTAssertTrue(quick.profile.isIncognito)
        XCTAssertEqual(quick.tab?.url, url("private-tab"))
    }
}
