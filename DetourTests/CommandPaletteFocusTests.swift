import XCTest
import WebKit
@testable import Detour

/// TASK-78: dismissing the command palette — by committing or by Esc — hands
/// first responder back to the page's web view, so the page takes keys without
/// a click. In a split that is the focused pane (`selectedTabID`).
@MainActor
final class CommandPaletteFocusTests: XCTestCase {

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
        // Never let this never-shown window's split view touch the autosaved
        // sidebar geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        return (wc, try XCTUnwrap(wc.activeSpace))
    }

    private func addTab(_ url: String, to wc: BrowserWindowController, in space: Space) -> BrowserTab {
        let tab = wc.store.addTab(in: space, url: URL(string: url))
        createdTabs.append(tab)
        return tab
    }

    /// Opens the palette as Cmd+L does and checks it took first responder, so
    /// each test starts from the state the bug left behind.
    private func openPalette(_ wc: BrowserWindowController) throws -> CommandPaletteView {
        wc.focusAddressBar(nil)
        let palette = try XCTUnwrap(wc.commandPaletteView)
        let webView = wc.selectedTab?.webView
        XCTAssertFalse(wc.window?.firstResponder === webView, "the palette holds focus while shown")
        return palette
    }

    func testCommitInPlaceFocusesTheSelectedWebView() throws {
        let (wc, space) = try makeController()
        let tab = addTab("https://a.example.com/", to: wc, in: space)
        wc.selectTab(id: tab.id)

        let palette = try openPalette(wc)
        wc.commandPalette(palette, didSubmitInput: "https://b.example.com/")

        XCTAssertNil(wc.commandPaletteView)
        XCTAssertEqual(wc.selectedTabID, tab.id, "Cmd+L navigates in place")
        XCTAssertTrue(wc.window?.firstResponder === tab.webView)
    }

    func testCommitIntoNewTabFocusesTheNewWebView() throws {
        let (wc, space) = try makeController()
        let tab = addTab("https://a.example.com/", to: wc, in: space)
        wc.selectTab(id: tab.id)

        wc.newTab(nil)
        let palette = try XCTUnwrap(wc.commandPaletteView)
        wc.commandPalette(palette, didSubmitInput: "https://b.example.com/")

        let newTab = try XCTUnwrap(wc.selectedTab)
        createdTabs.append(newTab)
        XCTAssertNotEqual(newTab.id, tab.id, "Cmd+T commits into a new tab")
        XCTAssertNotNil(newTab.webView)
        XCTAssertTrue(wc.window?.firstResponder === newTab.webView)
    }

    func testEscFocusesThePageThatWasShowing() throws {
        let (wc, space) = try makeController()
        let tab = addTab("https://a.example.com/", to: wc, in: space)
        wc.selectTab(id: tab.id)

        let palette = try openPalette(wc)
        palette.dismiss()

        XCTAssertNil(wc.commandPaletteView)
        XCTAssertTrue(wc.window?.firstResponder === tab.webView)
    }

    func testEscInASplitFocusesTheFocusedPane() throws {
        let (wc, space) = try makeController()
        let left = addTab("https://left.example.com/", to: wc, in: space)
        let right = addTab("https://right.example.com/", to: wc, in: space)
        wc.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        XCTAssertNotNil(wc.store.splitGroup(containing: right.id, in: space))
        wc.selectTab(id: right.id)

        let palette = try openPalette(wc)
        palette.dismiss()

        XCTAssertTrue(wc.window?.firstResponder === right.webView, "the focused pane, not its partner")
    }
}
