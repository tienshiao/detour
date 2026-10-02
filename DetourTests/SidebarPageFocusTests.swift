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
