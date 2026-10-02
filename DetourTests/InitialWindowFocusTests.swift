import XCTest
import WebKit
@testable import Detour

/// TASK-128: a freshly shown window must not leave keyboard focus on a sidebar
/// control nobody chose (AppKit focuses the first key view by itself). The
/// page gets it, or nothing does.
@MainActor
final class InitialWindowFocusTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var createdTabs: [BrowserTab] = []

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        super.tearDown()
    }

    private func makeController() throws -> (BrowserWindowController, Space) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        return (wc, try XCTUnwrap(wc.activeSpace))
    }

    private func addTab(to wc: BrowserWindowController, in space: Space) -> BrowserTab {
        let tab = wc.store.addTab(in: space, url: URL(string: "https://a.example.com/"))
        createdTabs.append(tab)
        return tab
    }

    private func isInSidebar(_ responder: NSResponder?, of wc: BrowserWindowController) -> Bool {
        (responder as? NSView)?.isDescendant(of: wc.tabSidebar.view) ?? false
    }

    func testWindowShownWithNoTabFocusesNothingInTheSidebar() throws {
        let (wc, _) = try makeController()
        wc.showWindow(nil)

        let window = try XCTUnwrap(wc.window)
        XCTAssertFalse(isInSidebar(window.firstResponder, of: wc))
        XCTAssertTrue(window.firstResponder === window)
    }

    func testWindowShownWithASelectedTabFocusesItsWebView() throws {
        let (wc, space) = try makeController()
        let tab = addTab(to: wc, in: space)
        wc.selectTab(id: tab.id)
        wc.showWindow(nil)

        XCTAssertNotNil(tab.webView)
        XCTAssertTrue(wc.window?.firstResponder === tab.webView)
    }

    /// The launch order: the window is shown first, the session's tab is
    /// selected afterwards.
    func testTabSelectedAfterTheWindowIsShownTakesFocus() throws {
        let (wc, space) = try makeController()
        wc.showWindow(nil)
        let tab = addTab(to: wc, in: space)
        wc.selectTab(id: tab.id)

        XCTAssertTrue(wc.window?.firstResponder === tab.webView)
    }

    /// Switching tabs from the keyboard while the page has focus: the outgoing
    /// web view leaves the window, and the incoming one inherits the focus.
    func testSwitchingTabsKeepsFocusOnThePage() throws {
        let (wc, space) = try makeController()
        wc.showWindow(nil)
        let first = addTab(to: wc, in: space)
        let second = addTab(to: wc, in: space)
        wc.selectTab(id: first.id)
        XCTAssertTrue(wc.window?.firstResponder === first.webView)

        wc.selectTab(id: second.id)
        XCTAssertTrue(wc.window?.firstResponder === second.webView)
    }

    /// A tab playing audio stays parented for a moment after the switch (the
    /// PiP capture), so its web view never drops the focus by itself.
    func testSwitchingAwayFromATabPlayingAudioFocusesTheIncomingPage() throws {
        let (wc, space) = try makeController()
        wc.showWindow(nil)
        let first = addTab(to: wc, in: space)
        let second = addTab(to: wc, in: space)
        wc.selectTab(id: first.id)
        XCTAssertTrue(wc.window?.firstResponder === first.webView)
        first.isPlayingAudio = true

        wc.selectTab(id: second.id)
        XCTAssertNotNil(first.webViewContainer?.superview, "the outgoing page is still in the window")
        XCTAssertTrue(wc.window?.firstResponder === second.webView)
    }

    func testSelectingATabLeavesFocusOnASidebarControl() throws {
        let (wc, space) = try makeController()
        wc.showWindow(nil)
        let tab = addTab(to: wc, in: space)
        let window = try XCTUnwrap(wc.window)
        // As a click on the tab's row does.
        XCTAssertTrue(window.makeFirstResponder(wc.tabSidebar.tableView))

        wc.selectTab(id: tab.id)
        XCTAssertTrue(window.firstResponder === wc.tabSidebar.tableView)
    }

    /// The archive page sits off screen before the first space, which makes
    /// its search field the window's first key view.
    func testArchivePageTakesKeyboardFocusOnlyWhileShowing() {
        let page = ArchivePageView(onScrollWheel: { _ in false })
        XCTAssertFalse(page.searchField.acceptsFirstResponder)
        XCTAssertFalse(page.tableView.acceptsFirstResponder)
        XCTAssertTrue(page.filterButton.refusesFirstResponder)

        page.acceptsKeyboardFocus = true
        XCTAssertTrue(page.searchField.acceptsFirstResponder)
        XCTAssertTrue(page.tableView.acceptsFirstResponder)
        XCTAssertFalse(page.filterButton.refusesFirstResponder)

        page.acceptsKeyboardFocus = false
        XCTAssertFalse(page.searchField.acceptsFirstResponder)
        XCTAssertFalse(page.tableView.acceptsFirstResponder)
        XCTAssertTrue(page.filterButton.refusesFirstResponder)
    }
}
