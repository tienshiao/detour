import XCTest
import WebKit
@testable import Detour

/// TASK-297: with no tab selected, the empty-state line is hidden while the
/// command palette is open, in all three modes, and comes back when the
/// palette is dismissed without opening anything.
nonisolated final class EmptyStatePaletteTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var createdTabs: [BrowserTab] = []

    @MainActor override func tearDown() async throws {
        controller?.window?.close()
        controller = nil
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        try await super.tearDown()
    }

    @MainActor private func makeEmptyController() throws -> (BrowserWindowController, Space) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        wc.sidebarSplitView.autosaveName = nil
        let space = try XCTUnwrap(wc.activeSpace)
        wc.deselectAllTabs()
        XCTAssertNil(wc.selectedTabID)
        XCTAssertTrue(wc.isEmptyStateLabelVisible, "precondition: the empty state shows")
        return (wc, space)
    }

    @MainActor func testNewTabPaletteHidesTheLabelAndEscShowsItAgain() throws {
        let (wc, _) = try makeEmptyController()
        wc.newTab(nil)
        let palette = try XCTUnwrap(wc.commandPaletteView)
        XCTAssertFalse(wc.isEmptyStateLabelVisible)

        palette.dismiss()
        XCTAssertNil(wc.commandPaletteView)
        XCTAssertTrue(wc.isEmptyStateLabelVisible)
    }

    @MainActor func testNavigateInPlacePaletteHidesTheLabel() throws {
        let (wc, _) = try makeEmptyController()
        wc.focusAddressBar(nil)
        XCTAssertNotNil(wc.commandPaletteView)
        XCTAssertFalse(wc.isEmptyStateLabelVisible)

        wc.newTab(nil) // Cmd+T again over a centered palette closes it
        XCTAssertNil(wc.commandPaletteView)
        XCTAssertTrue(wc.isEmptyStateLabelVisible)
    }

    @MainActor func testAnchoredPaletteHidesTheLabel() throws {
        let (wc, _) = try makeEmptyController()
        wc.openCommandPaletteInPlace(anchorFrame: NSRect(x: 20, y: 400, width: 200, height: 28))
        let palette = try XCTUnwrap(wc.commandPaletteView)
        XCTAssertTrue(palette.isAnchored)
        XCTAssertFalse(wc.isEmptyStateLabelVisible)

        palette.dismiss()
        XCTAssertTrue(wc.isEmptyStateLabelVisible)
    }

    @MainActor func testOpeningAPageLeavesTheLabelHidden() throws {
        let (wc, _) = try makeEmptyController()
        wc.newTab(nil)
        let palette = try XCTUnwrap(wc.commandPaletteView)
        wc.commandPalette(palette, didSubmitInput: "https://b.example.com/")

        let tab = try XCTUnwrap(wc.selectedTab)
        createdTabs.append(tab)
        XCTAssertNil(wc.commandPaletteView)
        XCTAssertFalse(wc.isEmptyStateLabelVisible)
    }

    @MainActor func testDeselectingWhilePaletteIsOpenKeepsTheLabelHidden() throws {
        let (wc, space) = try makeEmptyController()
        let tab = wc.store.addTab(in: space, url: URL(string: "https://a.example.com/"))
        createdTabs.append(tab)
        wc.selectTab(id: tab.id)
        XCTAssertFalse(wc.isEmptyStateLabelVisible)

        wc.focusAddressBar(nil)
        wc.deselectAllTabs()
        XCTAssertFalse(wc.isEmptyStateLabelVisible, "the palette is still up")

        wc.commandPaletteView?.dismiss()
        XCTAssertTrue(wc.isEmptyStateLabelVisible)
    }
}
