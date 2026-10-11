import XCTest
import WebKit
import Carbon.HIToolbox
@testable import Detour

/// TASK-173: a tab that comes back with a Peek over it says so in the
/// Control+Tab switcher. Its entry names the tab whose Peek will show, and
/// the Peek is pictured when the tab is left, like the page under it.
@MainActor
final class RecentTabSwitcherPeekTests: XCTestCase {

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
        wc.showWindow(nil)
        return (wc, try XCTUnwrap(wc.activeSpace))
    }

    private func addTab(to wc: BrowserWindowController, in space: Space, host: String) -> BrowserTab {
        let tab = wc.store.addTab(in: space, url: URL(string: "https://\(host).example.com/"))
        createdTabs.append(tab)
        return tab
    }

    private func presentPeek(on host: BrowserTab, in wc: BrowserWindowController) throws -> BrowserTab {
        wc.selectTab(id: host.id)
        wc.showPeekOverlay(url: URL(string: "https://peeked.example.org/")!)
        return try XCTUnwrap(host.peekTab)
    }

    private func entry(holding tab: BrowserTab, in wc: BrowserWindowController) throws -> RecentTabSwitcher.Entry {
        try XCTUnwrap(wc.recentTabSwitcherEntries().first { $0.tabs.contains { $0 === tab } })
    }

    // MARK: - Which entries carry a Peek

    func testATabLeftWithAPeekCarriesItInItsEntry() throws {
        let (wc, space) = try makeController()
        let host = addTab(to: wc, in: space, host: "host")
        let other = addTab(to: wc, in: space, host: "other")
        _ = try presentPeek(on: host, in: wc)

        wc.selectTab(id: other.id)
        XCTAssertTrue(try entry(holding: host, in: wc).peekHost === host)
        XCTAssertNil(try entry(holding: other, in: wc).peekHost)
    }

    func testTheCurrentTabsEntryCarriesItsPresentedPeek() throws {
        let (wc, space) = try makeController()
        let host = addTab(to: wc, in: space, host: "host")
        _ = try presentPeek(on: host, in: wc)

        let current = try entry(holding: host, in: wc)
        XCTAssertTrue(current.isCurrent)
        XCTAssertTrue(current.peekHost === host)
    }

    func testClosingThePeekRemovesItFromTheEntry() throws {
        let (wc, space) = try makeController()
        let host = addTab(to: wc, in: space, host: "host")
        let other = addTab(to: wc, in: space, host: "other")
        _ = try presentPeek(on: host, in: wc)

        wc.closePeekOverlay()
        XCTAssertNil(try entry(holding: host, in: wc).peekHost)
        wc.selectTab(id: other.id)
        XCTAssertNil(try entry(holding: host, in: wc).peekHost)
    }

    /// A parked Peek is rebuilt when its host is selected, so it still shows.
    func testAParkedPeekIsStillCarried() throws {
        let (wc, space) = try makeController()
        let host = addTab(to: wc, in: space, host: "host")
        let other = addTab(to: wc, in: space, host: "other")
        let peek = try presentPeek(on: host, in: wc)
        wc.selectTab(id: other.id)

        host.parkPeek(force: true)
        XCTAssertNil(peek.webView)
        XCTAssertTrue(try entry(holding: host, in: wc).peekHost === host)
    }

    /// Only the focused pane's Peek is presented, so a split's entry carries
    /// the Peek of the pane that gets focus when the entry is chosen.
    func testASplitsEntryCarriesThePeekOfThePaneThatGetsFocus() throws {
        let (wc, space) = try makeController()
        let left = addTab(to: wc, in: space, host: "left")
        let right = addTab(to: wc, in: space, host: "right")
        let other = addTab(to: wc, in: space, host: "other")
        wc.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        _ = try presentPeek(on: right, in: wc)

        wc.selectTab(id: other.id)
        var split = try entry(holding: left, in: wc)
        XCTAssertEqual(split.focusTabID, right.id)
        XCTAssertTrue(split.peekHost === right)

        // Back in the split with the other pane focused: the Peek stays
        // hidden behind it, and the card shows none.
        wc.selectTab(id: left.id)
        wc.selectTab(id: other.id)
        split = try entry(holding: left, in: wc)
        XCTAssertEqual(split.focusTabID, left.id)
        XCTAssertNil(split.peekHost)
    }

    // MARK: - The Peek's picture

    /// `switcherPreviewRequest` counts captures; the picture itself arrives
    /// from the web process later.
    func testLeavingATabPicturesItsPeek() throws {
        let (wc, space) = try makeController()
        let host = addTab(to: wc, in: space, host: "host")
        let other = addTab(to: wc, in: space, host: "other")
        let peek = try presentPeek(on: host, in: wc)
        XCTAssertEqual(peek.switcherPreviewRequest, 0)

        wc.selectTab(id: other.id)
        XCTAssertEqual(peek.switcherPreviewRequest, 1)
    }

    func testOpeningTheSwitcherPicturesThePresentedPeek() throws {
        let (wc, space) = try makeController()
        let host = addTab(to: wc, in: space, host: "host")
        let peek = try presentPeek(on: host, in: wc)
        let window = try XCTUnwrap(wc.window)
        let switcher = try XCTUnwrap(wc.recentTabSwitcher)

        let controlTab = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false,
            keyCode: UInt16(kVK_Tab)))
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: controlTab, switcher: switcher))
        switcher.cancel()
        XCTAssertEqual(peek.switcherPreviewRequest, 1)
    }
}
