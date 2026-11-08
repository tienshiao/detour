import XCTest
import WebKit
@testable import Detour

/// TASK-307 in a real window: the File menu's Cmd+O item opens a presented
/// Peek as a tab, and a Peek the user closes comes back with Undo.
nonisolated final class PeekWindowCommandsTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var createdTabs: [BrowserTab] = []

    @MainActor override func tearDown() async throws {
        controller?.window?.close()
        controller = nil
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        try await super.tearDown()
    }

    @MainActor private func makeControllerWithHost() throws -> (BrowserWindowController, Space, BrowserTab) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        wc.sidebarSplitView.autosaveName = nil
        let space = try XCTUnwrap(wc.activeSpace)
        let host = wc.store.addTab(in: space, url: URL(string: "https://host.example.com/"))
        createdTabs.append(host)
        wc.selectTab(id: host.id)
        return (wc, space, host)
    }

    @MainActor private func openItem() -> NSMenuItem {
        NSMenuItem(title: QuickDetourWindowController.openInMenuItemTitle,
                   action: #selector(QuickDetourWindowController.openInDefaultSpace(_:)), keyEquivalent: "o")
    }

    @MainActor func testCommandOIsOpenPeekInNewTabOnlyWhileAPeekIsUp() throws {
        let (wc, _, _) = try makeControllerWithHost()
        let item = openItem()

        XCTAssertFalse(wc.validateMenuItem(item))
        XCTAssertEqual(item.title, QuickDetourWindowController.openInMenuItemTitle, "the Quick Detour title, disabled")

        wc.showPeekOverlay(url: URL(string: "https://peeked.example.org/")!)
        XCTAssertTrue(wc.validateMenuItem(item))
        XCTAssertEqual(item.title, "Open Peek in New Tab")

        wc.closePeekOverlay()
        XCTAssertFalse(wc.validateMenuItem(item))
        XCTAssertEqual(item.title, QuickDetourWindowController.openInMenuItemTitle)
    }

    @MainActor func testCommandOOpensThePeekAsATabWithItsWebView() throws {
        let (wc, space, host) = try makeControllerWithHost()
        wc.showPeekOverlay(url: URL(string: "https://peeked.example.org/")!)
        let peekWebView = try XCTUnwrap(host.peekTab?.webView)

        wc.openInDefaultSpace(nil)

        XCTAssertNil(host.peekTab)
        let opened = try XCTUnwrap(space.tabs.first { $0.id != host.id })
        createdTabs.append(opened)
        XCTAssertTrue(opened.webView === peekWebView, "the same page, as Open in New Tab hands it over")
        XCTAssertFalse(wc.validateMenuItem(openItem()), "no Peek is up any more")
    }

    @MainActor func testUndoBringsAClosedPeekBackOverItsHost() throws {
        let (wc, _, host) = try makeControllerWithHost()
        wc.showPeekOverlay(url: URL(string: "https://peeked.example.org/")!)
        let firstPeek = try XCTUnwrap(host.peekTab)
        // Only the close in the undo group the next undo runs.
        wc.store.undoManager.removeAllActions()

        wc.closePeekOverlayByUser()
        XCTAssertNil(host.peekURL)
        XCTAssertEqual(wc.store.undoManager.undoActionName, "Close Peek")

        wc.store.undoManager.undo()

        let restored = try XCTUnwrap(host.peekTab, "selecting the host presented the Peek again")
        XCTAssertFalse(restored === firstPeek, "rebuilt from the saved state")
        XCTAssertEqual(host.peekURL?.absoluteString, "https://peeked.example.org/")
        XCTAssertEqual(wc.selectedTabID, host.id)
        XCTAssertTrue(wc.validateMenuItem(openItem()), "and it is presented")
    }

    @MainActor func testClosingThroughTheExtensionPathRecordsNothing() throws {
        let (wc, _, _) = try makeControllerWithHost()
        wc.store.undoManager.removeAllActions()
        wc.showPeekOverlay(url: URL(string: "https://peeked.example.org/")!)

        wc.closePeekOverlay()

        XCTAssertNotEqual(wc.store.undoManager.undoActionName, "Close Peek")
    }
}
