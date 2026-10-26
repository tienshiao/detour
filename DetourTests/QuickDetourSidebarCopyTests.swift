import XCTest
import AppKit
@testable import Detour

/// TASK-193.5: Opt-Cmd-click on a sidebar tab opens a copy of it — its
/// current address — in a new Quick Detour on the sidebar's profile, and the
/// tab is left alone (not selected, not moved). Normal tabs, a sleeping tab
/// (its stored address), each pane of a split row, a pinned entry, and a
/// favourite, live and dormant.
///
/// A real browser window on a space of a profile of the test's own; the
/// clicks are mouse-down events handed to the sidebar's table, which takes
/// them before the table's own tracking. The pages are `.invalid` hosts.
@MainActor
final class QuickDetourSidebarCopyTests: XCTestCase {

    private var store: TabStore { .shared }
    private var profile: Profile!
    private var space: Space!
    private var wc: BrowserWindowController!
    private var quickDetoursBefore: Set<ObjectIdentifier> = []
    private static var retainedProfiles: [Profile] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        quickDetoursBefore = Set(QuickDetourWindowController.openControllers.map(ObjectIdentifier.init))
        profile = store.addProfile(name: "Sidebar Copy \(UUID().uuidString.prefix(4))")
        space = store.addSpace(name: "Copy", emoji: "📋", colorHex: "007AFF", profileID: profile.id)
        wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
    }

    override func tearDown() async throws {
        for controller in newQuickDetours() {
            controller.closeDisposition = .discard
            controller.close()
        }
        wc.window?.close()
        wc = nil
        for tab in space.tabs { tab.teardown() }
        for entry in space.pinnedEntries { entry.tab?.teardown() }
        store.forceRemoveSpace(id: space.id)
        for favorite in profile.favorites { favorite.tab?.teardown() }
        store.forceRemoveProfile(id: profile.id)
        AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        Self.retainedProfiles.append(profile)
        store.undoManager.removeAllActions()
        try await super.tearDown()
    }

    private func newQuickDetours() -> [QuickDetourWindowController] {
        QuickDetourWindowController.openControllers.filter { !quickDetoursBefore.contains(ObjectIdentifier($0)) }
    }

    private func url(_ path: String) -> URL { URL(string: "https://sidebar-copy.invalid/\(path)")! }

    private func addTab(_ path: String) -> BrowserTab {
        store.addTab(in: space, url: url(path))
    }

    private var sidebar: TabSidebarViewController { wc.tabSidebar }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    /// The table row of the item holding `tab`.
    private func row(of tab: BrowserTab) throws -> Int {
        settle()
        let item = try XCTUnwrap(sidebar.tabItems.firstIndex { $0.tabs.contains { $0 === tab } })
        return rowForNormalTab(at: item, pinnedItemCount: sidebar.flattenedPinnedItems.count)
    }

    /// An Opt-Cmd mouse-down on `row`, at `fraction` of its width.
    private func optionCommandClick(row: Int, at fraction: CGFloat = 0.25,
                                    flags: NSEvent.ModifierFlags = [.command, .option]) throws {
        let table = sidebar.tableView
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.minX + rect.width * fraction, y: rect.midY), to: nil)
        let window = try XCTUnwrap(table.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        table.mouseDown(with: event)
    }

    private func onlyNewQuickDetour() throws -> QuickDetourWindowController {
        XCTAssertEqual(newQuickDetours().count, 1)
        return try XCTUnwrap(newQuickDetours().first)
    }

    // MARK: - Normal tabs

    func testANormalTabOpensACopyAndStaysUntouched() throws {
        let first = addTab("first")
        let copied = addTab("copied")
        wc.selectTab(id: first.id)
        let tabsBefore = space.tabs.map(\.id)

        try optionCommandClick(row: try row(of: copied))

        let quick = try onlyNewQuickDetour()
        XCTAssertEqual(quick.tab?.url, url("copied"))
        XCTAssertTrue(quick.profile === profile, "the sidebar's profile")
        XCTAssertEqual(quick.sourceSpaceID, space.id)
        XCTAssertFalse(quick.tab === copied, "a copy, not the tab")
        XCTAssertEqual(wc.selectedTabID, first.id, "the clicked tab is not selected")
        XCTAssertEqual(space.tabs.map(\.id), tabsBefore, "nothing moved or closed")
        XCTAssertEqual(copied.url, url("copied"))
    }

    func testASleepingTabCopiesItsStoredAddress() throws {
        let asleep = addTab("asleep")
        _ = addTab("other")
        asleep.sleep(force: true)
        XCTAssertTrue(asleep.isSleeping)

        try optionCommandClick(row: try row(of: asleep))

        XCTAssertEqual(try onlyNewQuickDetour().tab?.url, url("asleep"))
        XCTAssertTrue(asleep.isSleeping, "the tab is not woken")
    }

    func testASplitRowCopiesThePaneClicked() throws {
        let left = addTab("left")
        let right = addTab("right")
        store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        XCTAssertNotNil(left.splitGroupID)
        let splitRow = try row(of: left)

        try optionCommandClick(row: splitRow, at: 0.25)
        try optionCommandClick(row: splitRow, at: 0.75)

        XCTAssertEqual(Set(newQuickDetours().compactMap { $0.tab?.url }), [url("left"), url("right")])
        XCTAssertEqual(left.splitGroupID, right.splitGroupID, "the split is untouched")
    }

    func testOtherModifiersAreNotTheQuickDetourClick() throws {
        let tab = addTab("cmd-only")
        _ = addTab("other")
        XCTAssertFalse(QuickDetour.isQuickDetourClick(.command, enabled: true))
        XCTAssertNil(sidebar.quickDetourCopyURL(forRow: 0, at: .zero), "the top spacer has no tab")
        XCTAssertEqual(sidebar.quickDetourCopyURL(forRow: try row(of: tab), at: .zero), url("cmd-only"))
    }

    // MARK: - Pinned entries and favourites

    func testAPinnedEntryCopiesItsPage() throws {
        let tab = addTab("pinned")
        store.pinTab(id: tab.id, in: space)
        settle()
        let index = try XCTUnwrap(sidebar.flattenedPinnedItems.firstIndex {
            if case .entry(let entry, _) = $0 { return entry.tab === tab }
            return false
        })

        try optionCommandClick(row: rowForPinnedItem(at: index))

        XCTAssertEqual(try onlyNewQuickDetour().tab?.url, url("pinned"))
        XCTAssertNotEqual(wc.selectedTabID, tab.id)
    }

    func testAFavouriteCopiesItsPageOrItsSavedAddress() throws {
        XCTAssertTrue(store.addFavoriteFromEntry(url: url("dormant-favourite"), title: "Fav", faviconURL: nil,
                                                 favicon: nil, profileID: profile.id, at: 0))
        settle()
        let bar = FavoritesBarView()

        XCTAssertTrue(sidebar.favoritesBar(bar, didQuickDetourClickFavoriteAt: 0))
        XCTAssertFalse(sidebar.favoritesBar(bar, didQuickDetourClickFavoriteAt: 5), "no such tile")

        XCTAssertEqual(try onlyNewQuickDetour().tab?.url, url("dormant-favourite"))
        XCTAssertNil(profile.favorites.first?.tab, "the dormant favourite is not woken")
    }
}
