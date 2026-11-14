import XCTest
@testable import Detour

/// TASK-326: every copy of a page's or tab's address in a browser window —
/// Edit > Copy URL (Shift-Cmd-C), the faux address bar's link button, the
/// sidebar tab menu's Copy URL / Copy Link — puts the address on the clipboard
/// without its tracking parameters (`TrackingParameters`), while the tab, its
/// history and its session record keep the address as loaded. (The dev
/// toolbar's button: `DevToolbarHostingTests`; Quick Detour's:
/// `QuickDetourWindowTests`.)
///
/// Real browser windows on a profile of the test's own, private pasteboards
/// (never the user's clipboard); pages are `.invalid` hosts.
nonisolated final class CopyURLTests: XCTestCase {

    @MainActor private var store: TabStore { .shared }
    private var profile: Profile!
    private var space: Space!
    private var windows: [BrowserWindowController] = []
    private var pasteboard: NSPasteboard!
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        profile = store.addProfile(name: "Copy URL \(UUID().uuidString.prefix(4))")
        space = store.addSpace(name: "Copy", emoji: "🔗", colorHex: "007AFF", profileID: profile.id)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("DetourTests.copyURL.\(UUID().uuidString)"))
    }

    @MainActor override func tearDown() async throws {
        pasteboard.releaseGlobally()
        for wc in windows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for tab in space.tabs { tab.teardown() }
        for entry in space.pinnedEntries { entry.tab?.teardown() }
        store.forceRemoveSpace(id: space.id)
        store.forceRemoveProfile(id: profile.id)
        AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        Self.retainedProfiles.append(profile)
        store.undoManager.removeAllActions()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let tracked = "https://copy-url.invalid/article?id=42&utm_source=news&utm_medium=email"
        + "&fbclid=abc&gclid=def&ref=home#comments"
    private static let clean = "https://copy-url.invalid/article?id=42&ref=home#comments"

    @MainActor private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor private func makeWindow() -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.urlPasteboard = pasteboard
        wc.tabSidebar.urlPasteboard = pasteboard
        wc.showWindow(nil)
        windows.append(wc)
        return wc
    }

    @MainActor private func copied() -> String? { pasteboard.string(forType: .string) }

    /// The sidebar's menu for table row `row`, as a right-click on it asks.
    @MainActor private func sidebarMenu(_ wc: BrowserWindowController, row: Int) throws -> NSMenu {
        spin()
        let sidebar = wc.tabSidebar
        let table = sidebar.tableView
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.minX + rect.width * 0.25, y: rect.midY), to: nil)
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

    // MARK: - Shift-Cmd-C and the address bar's button

    @MainActor func testCopyURLLeavesOutTrackingParameters() throws {
        let wc = makeWindow()
        let url = try XCTUnwrap(URL(string: Self.tracked))
        let tab = store.addTab(in: space, url: url)
        wc.selectTab(id: tab.id)

        wc.copyCurrentURL(nil)

        XCTAssertEqual(copied(), Self.clean)
        XCTAssertEqual(tab.url, url, "the tab keeps the address it loaded")
    }

    /// Edit > Copy URL is Shift-Cmd-C and reaches the window's `copyCurrentURL`.
    @MainActor func testTheMenuItemIsShiftCommandC() throws {
        let editMenu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let item = try XCTUnwrap(editMenu.items.first { $0.title == "Copy URL" })
        XCTAssertEqual(item.keyEquivalent.lowercased(), "c")
        XCTAssertEqual(item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]),
                       [.command, .shift])
        XCTAssertEqual(item.action, #selector(BrowserWindowController.copyCurrentURL(_:)))
    }

    @MainActor func testTheAddressBarButtonLeavesOutTrackingParameters() throws {
        let wc = makeWindow()
        let url = try XCTUnwrap(URL(string: Self.tracked))
        let tab = store.addTab(in: space, url: url)
        wc.selectTab(id: tab.id)

        try XCTUnwrap(wc.tabSidebar.fauxAddressBar.onCopyURL)()

        XCTAssertEqual(copied(), Self.clean)
        XCTAssertEqual(tab.url, url)
    }

    @MainActor func testAnAddressWithoutTrackingParametersIsCopiedAsItIs() throws {
        let wc = makeWindow()
        let url = try XCTUnwrap(URL(string: "https://copy-url.invalid/p?q=a+b%2B&ref=x#frag"))
        let tab = store.addTab(in: space, url: url)
        wc.selectTab(id: tab.id)

        wc.copyCurrentURL(nil)

        XCTAssertEqual(copied(), url.absoluteString)
    }

    // MARK: - The sidebar's tab menu

    @MainActor func testTheSidebarsCopyLinkLeavesOutTrackingParameters() throws {
        let wc = makeWindow()
        let selected = store.addTab(in: space, url: URL(string: "https://copy-url.invalid/selected")!)
        let url = try XCTUnwrap(URL(string: Self.tracked))
        let other = store.addTab(in: space, url: url)
        wc.selectTab(id: selected.id)

        try choose("Copy Link", in: sidebarMenu(wc, row: row(of: other, in: wc)))

        XCTAssertEqual(copied(), Self.clean)
        XCTAssertEqual(other.url, url)
    }

    @MainActor func testTheSidebarsCopyURLOnTheSelectedTabLeavesOutTrackingParameters() throws {
        let wc = makeWindow()
        let url = try XCTUnwrap(URL(string: Self.tracked))
        let tab = store.addTab(in: space, url: url)
        wc.selectTab(id: tab.id)

        try choose("Copy URL", in: sidebarMenu(wc, row: row(of: tab, in: wc)))

        XCTAssertEqual(copied(), Self.clean)
        XCTAssertEqual(tab.url, url)
    }

    @MainActor func testAPinnedTabsCopyURLLeavesOutTrackingParameters() throws {
        let wc = makeWindow()
        let url = try XCTUnwrap(URL(string: Self.tracked))
        let tab = store.addTab(in: space, url: url)
        store.pinTab(id: tab.id, in: space)
        spin()
        let index = try XCTUnwrap(wc.tabSidebar.flattenedPinnedItems.firstIndex {
            if case .entry(let entry, _) = $0 { return entry.tab === tab }
            return false
        })

        let menu = try sidebarMenu(wc, row: wc.tabSidebar.rowForPinnedItem(at: index))
        let title = try XCTUnwrap(menu.items.first { $0.title == "Copy URL" || $0.title == "Copy Link" }?.title)
        try choose(title, in: menu)

        XCTAssertEqual(copied(), Self.clean)
        XCTAssertEqual(tab.url, url)
    }

    // MARK: - Share…

    @MainActor func testTheSidebarsShareSharesTheLinkWithoutTrackingParameters() throws {
        let wc = makeWindow()
        let url = try XCTUnwrap(URL(string: Self.tracked))
        let tab = store.addTab(in: space, url: url)
        wc.selectTab(id: tab.id)
        var shared: [Any] = []
        wc.tabSidebar.makeSharingPicker = { items in
            shared = items
            return NSSharingServicePicker(items: items)
        }

        let menu = try sidebarMenu(wc, row: row(of: tab, in: wc))

        XCTAssertTrue(menu.items.contains { $0.title == "Share…" }, "\(menu.items.map(\.title))")
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual((shared.first as? URL)?.absoluteString, Self.clean)
        XCTAssertEqual(tab.url, url)
    }
}
