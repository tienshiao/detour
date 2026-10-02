import XCTest
import WebKit
@testable import Detour

/// TASK-130: only the sidebar page the strip rests on takes keyboard focus.
/// A tab list that slid off screen — another space became active, or the
/// Archived Tabs page is showing — gives the keyboard to the web page instead
/// of answering the arrow keys where nobody can see it.
@MainActor
final class SidebarPageFocusTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var createdSpaceIDs: [UUID] = []
    /// A regular window records the space it switches to (and, once key, tells
    /// the extension manager): put both back, or they name a deleted space.
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?

    override func setUp() {
        super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
    }

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        for id in createdSpaceIDs { TabStore.shared.deleteSpace(id: id) }
        createdSpaceIDs.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        super.tearDown()
    }

    /// A regular window on two fresh spaces, the first one active. Incognito
    /// windows have a single page and no archive.
    private func makeController() throws -> (BrowserWindowController, Space, Space) {
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let first = store.addSpace(name: "Focus A", emoji: "A", colorHex: "007AFF", profileID: profile.id)
        let second = store.addSpace(name: "Focus B", emoji: "B", colorHex: "34C759", profileID: profile.id)
        createdSpaceIDs = [first.id, second.id]

        let wc = BrowserWindowController(incognito: false)
        controller = wc
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: first.id)
        wc.showWindow(nil)
        return (wc, first, second)
    }

    /// One more space on the test profile, removed again in `tearDown`.
    @discardableResult
    private func addSpace(named name: String) -> Space {
        let store = TabStore.shared
        let space = store.addSpace(name: name, emoji: "C", colorHex: "FF9500", profileID: store.space(withID: createdSpaceIDs[0])!.profileID)
        createdSpaceIDs.append(space.id)
        return space
    }

    private func addTab(to wc: BrowserWindowController, in space: Space, host: String) -> BrowserTab {
        wc.store.addTab(in: space, url: URL(string: "https://\(host).example.com/"))
    }

    private func archivePage(of wc: BrowserWindowController) -> ArchivePageView? {
        func find(in view: NSView) -> ArchivePageView? {
            if let page = view as? ArchivePageView { return page }
            for subview in view.subviews {
                if let page = find(in: subview) { return page }
            }
            return nil
        }
        return find(in: wc.tabSidebar.view)
    }

    /// `makeFirstResponder` reports success even when the view declines and
    /// the window takes the focus itself, so look at who ended up with it.
    private func assertCannotFocus(_ view: NSView, in wc: BrowserWindowController,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard let window = wc.window else { return XCTFail("no window", file: file, line: line) }
        window.makeFirstResponder(view)
        XCTAssertFalse(window.firstResponder === view, file: file, line: line)
    }

    // MARK: - The gate

    func testOnlyTheActiveSpacesListAcceptsKeyboardFocus() throws {
        let (wc, _, second) = try makeController()
        let firstList = wc.tabSidebar.tableView
        XCTAssertTrue(firstList.acceptsFirstResponder)

        wc.setActiveSpace(id: second.id)
        let secondList = wc.tabSidebar.tableView
        XCTAssertFalse(secondList === firstList)
        XCTAssertFalse(firstList.acceptsFirstResponder, "its page is off screen")
        XCTAssertTrue(secondList.acceptsFirstResponder)
        assertCannotFocus(firstList, in: wc)
    }

    func testNoSpaceListAcceptsKeyboardFocusWhileTheArchivePageShows() throws {
        let (wc, _, _) = try makeController()
        let list = wc.tabSidebar.tableView
        let archive = try XCTUnwrap(archivePage(of: wc))
        XCTAssertFalse(archive.tableView.acceptsFirstResponder)

        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertFalse(list.acceptsFirstResponder)
        assertCannotFocus(list, in: wc)
        XCTAssertTrue(archive.searchField.acceptsFirstResponder)
        XCTAssertTrue(archive.tableView.acceptsFirstResponder)

        wc.tabSidebar.dismissArchivePage(animated: false)
        XCTAssertTrue(list.acceptsFirstResponder)
        XCTAssertFalse(archive.searchField.acceptsFirstResponder)
        XCTAssertFalse(archive.tableView.acceptsFirstResponder)
    }

    // MARK: - Focus left behind

    func testSwitchingSpaceHandsAFocusedListsKeyboardToTheNewPage() throws {
        let (wc, first, second) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        let other = addTab(to: wc, in: second, host: "b")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        // As a click on the tab's row does.
        XCTAssertTrue(window.makeFirstResponder(wc.tabSidebar.tableView))

        wc.setActiveSpace(id: second.id)
        XCTAssertNotNil(other.webView)
        XCTAssertTrue(window.firstResponder === other.webView)
    }

    func testSwitchingToASpaceWithNoTabLeavesNothingFocused() throws {
        let (wc, first, second) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(window.makeFirstResponder(wc.tabSidebar.tableView))

        wc.setActiveSpace(id: second.id)
        XCTAssertTrue(window.firstResponder === window)
    }

    func testShowingTheArchivePageHandsAFocusedListsKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(window.makeFirstResponder(wc.tabSidebar.tableView))

        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    func testDismissingTheArchivePageHandsItsKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let archive = try XCTUnwrap(archivePage(of: wc))
        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertTrue(window.makeFirstResponder(archive.tableView))

        wc.tabSidebar.dismissArchivePage(animated: false)
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    /// The search field's focus is held by its field editor, and the field
    /// stops accepting focus before it is asked to give it up.
    func testDismissingTheArchivePageHandsItsSearchFieldsKeyboardToThePage() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let archive = try XCTUnwrap(archivePage(of: wc))
        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertTrue(window.makeFirstResponder(archive.searchField))
        XCTAssertTrue((window.firstResponder as? NSView)?.isDescendant(of: archive) ?? false)

        wc.tabSidebar.dismissArchivePage(animated: false)
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    // MARK: - Rebuilt pages (TASK-131)

    /// A change to the space list recreates every page. The keyboard stays
    /// with the active space's list, old or new.
    func testAddingASpaceKeepsAFocusedListFocused() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let oldList = wc.tabSidebar.tableView
        XCTAssertTrue(window.makeFirstResponder(oldList))

        addSpace(named: "Focus C")
        let newList = wc.tabSidebar.tableView
        XCTAssertFalse(newList === oldList, "the pages were rebuilt")
        XCTAssertTrue(window.firstResponder === newList)
    }

    /// The rebuilt list keeps the selected row: the highlight, and where the
    /// arrow keys start from.
    func testAddingASpaceKeepsTheSelectedRowSelected() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        _ = addTab(to: wc, in: first, host: "c")
        wc.selectTab(id: tab.id)
        let oldList = wc.tabSidebar.tableView
        let row = oldList.selectedRow
        XCTAssertGreaterThanOrEqual(row, 0)

        addSpace(named: "Focus C")
        let newList = wc.tabSidebar.tableView
        XCTAssertFalse(newList === oldList, "the pages were rebuilt")
        XCTAssertEqual(newList.selectedRow, row)
        XCTAssertEqual(wc.selectedTabID, tab.id, "re-selecting the row selects nothing anew")
    }

    func testDeletingAnotherSpaceKeepsAFocusedListFocused() throws {
        let (wc, first, second) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let oldList = wc.tabSidebar.tableView
        XCTAssertTrue(window.makeFirstResponder(oldList))

        TabStore.shared.deleteSpace(id: second.id)
        let newList = wc.tabSidebar.tableView
        XCTAssertFalse(newList === oldList, "the pages were rebuilt")
        XCTAssertTrue(window.firstResponder === newList)
    }

    /// A reorder moves the active space's page to another index of the strip.
    func testMovingTheActiveSpaceKeepsItsListFocusedAndItsRowSelected() throws {
        let (wc, first, second) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let oldList = wc.tabSidebar.tableView
        XCTAssertTrue(window.makeFirstResponder(oldList))
        let row = oldList.selectedRow
        XCTAssertGreaterThanOrEqual(row, 0)

        let store = TabStore.shared
        let from = try XCTUnwrap(store.spaces.firstIndex { $0.id == first.id })
        let to = try XCTUnwrap(store.spaces.firstIndex { $0.id == second.id })
        store.moveSpace(from: from, to: to)
        let newList = wc.tabSidebar.tableView
        XCTAssertFalse(newList === oldList, "the pages were rebuilt")
        XCTAssertTrue(window.firstResponder === newList)
        XCTAssertEqual(newList.selectedRow, row)
        XCTAssertEqual(wc.selectedTabID, tab.id)
    }

    /// With the active space gone the window lands on another space. That is
    /// a space switch: the list it lands on is not the one the user focused,
    /// and does not inherit the keyboard (TASK-130).
    func testDeletingTheActiveSpaceDoesNotFocusTheListOfTheSpaceTheWindowLandsOn() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(window.makeFirstResponder(wc.tabSidebar.tableView))

        TabStore.shared.deleteSpace(id: first.id)
        XCTAssertNotEqual(wc.activeSpaceID, first.id)
        let responder = window.firstResponder as? NSView
        XCTAssertFalse(responder?.isDescendant(of: wc.tabSidebar.view) ?? false)
    }

    func testAddingASpaceLeavesTheWebPageFocused() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(window.firstResponder === tab.webView)

        addSpace(named: "Focus C")
        XCTAssertTrue(window.firstResponder === tab.webView)
    }

    func testAddingASpaceLeavesTheArchivePageFocused() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let archive = try XCTUnwrap(archivePage(of: wc))
        wc.tabSidebar.showArchivePage(animated: false)
        XCTAssertTrue(window.makeFirstResponder(archive.tableView))

        addSpace(named: "Focus C")
        XCTAssertTrue(window.firstResponder === archive.tableView)
    }

    func testAddingASpaceWithNothingFocusedFocusesNothing() throws {
        let (wc, _, _) = try makeController()
        let window = try XCTUnwrap(wc.window)
        XCTAssertTrue(window.firstResponder === window)

        addSpace(named: "Focus C")
        XCTAssertTrue(window.firstResponder === window)
    }

    /// Focus on the page the strip rests on stays where the user put it.
    func testFocusOnTheCurrentPageStays() throws {
        let (wc, first, _) = try makeController()
        let tab = addTab(to: wc, in: first, host: "a")
        let second = addTab(to: wc, in: first, host: "c")
        wc.selectTab(id: tab.id)
        let window = try XCTUnwrap(wc.window)
        let list = wc.tabSidebar.tableView
        XCTAssertTrue(window.makeFirstResponder(list))

        wc.selectTab(id: second.id)
        wc.tabSidebar.rebuildPages()
        XCTAssertTrue(window.firstResponder === list)
    }
}
