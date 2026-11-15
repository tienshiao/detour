import AppKit
import WebKit
import XCTest
@testable import Detour

/// TASK-331: Back and Forward with the page focused. `WKWebView` declares
/// its own `goBack:` and `goForward:` actions, validated against WebKit's
/// back list, and while the page has the keys it is ahead of the window
/// controller in the responder chain, so Cmd+[ on a tab opened from another
/// one, with no back item, found a disabled item instead of the Back
/// button's rule. `BrowserWebView` now hands both actions, and their
/// validation, to its browser window's controller.
///
/// The items are resolved and validated as the menu does
/// (`CommandDispatch.perform` with no live menu: the window's responder
/// chain from its first responder, then the target's validation).
nonisolated final class BackForwardResponderTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var servers: [LoopbackHTTPServer] = []

    @MainActor override func tearDown() async throws {
        controller?.window?.close()
        controller = nil
        servers.forEach { $0.stop() }
        servers = []
        try await super.tearDown()
    }

    private static let back = #selector(BrowserWindowController.goBack(_:))
    private static let forward = #selector(BrowserWindowController.goForward(_:))

    /// A Private window, so nothing is written.
    @MainActor private func makeWindow() throws -> (BrowserWindowController, Space) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        wc.sidebarSplitView.autosaveName = nil
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (wc, try XCTUnwrap(wc.activeSpace))
    }

    /// Makes the tab's page its window's first responder, as a click in it does.
    @discardableResult
    @MainActor private func focusPage(of tab: BrowserTab, in wc: BrowserWindowController,
                                      file: StaticString = #filePath, line: UInt = #line) throws -> BrowserWebView {
        let webView = try XCTUnwrap(tab.webView as? BrowserWebView, file: file, line: line)
        let window = try XCTUnwrap(wc.window, file: file, line: line)
        XCTAssertTrue(window.makeFirstResponder(webView), file: file, line: line)
        XCTAssertTrue(window.firstResponder === webView, "the page has the keys", file: file, line: line)
        return webView
    }

    @MainActor private func perform(_ command: BrowserCommand, in wc: BrowserWindowController) throws -> Bool {
        CommandDispatch.perform(command, in: try XCTUnwrap(wc.window), menu: nil)
    }

    @MainActor private func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTableView(in: subview) { return table }
        }
        return nil
    }

    // MARK: - Who answers

    /// The cause: with the page focused, the chain still finds the web view
    /// first. The web view's validation is now the controller's rule.
    @MainActor func testThePageFocusedResolvesBothActionsToItsWebViewWhichAsksTheController() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let webView = try focusPage(of: child, in: wc)
        let window = try XCTUnwrap(wc.window)
        XCTAssertFalse(webView.canGoBack)
        XCTAssertFalse(webView.canGoForward)

        for command in [BrowserCommands.back, BrowserCommands.forward] {
            let item = command.makeMenuItem()
            let action = try XCTUnwrap(item.action)
            let target = try XCTUnwrap(CommandDispatch.responderTarget(for: action, in: window))
            XCTAssertTrue(target === webView, "\(command.id.rawValue): WKWebView's own action is ahead of the controller")
            XCTAssertTrue(CommandDispatch.isEnabled(item, autoenables: true, target: target),
                          "\(command.id.rawValue): enabled by the controller's rule, not WebKit's back list")
            XCTAssertEqual(CommandDispatch.isEnabled(item, autoenables: true, target: target),
                           wc.validateMenuItem(item))
        }
    }

    @MainActor func testWithTheSidebarFocusedTheControllerAnswers() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        let window = try XCTUnwrap(wc.window)
        let table = try XCTUnwrap(firstTableView(in: wc.tabSidebar.view))
        XCTAssertTrue(window.makeFirstResponder(table))

        XCTAssertTrue(CommandDispatch.responderTarget(for: Self.back, in: window) === wc)
        XCTAssertTrue(CommandDispatch.responderTarget(for: Self.forward, in: window) === wc)
        XCTAssertTrue(try perform(BrowserCommands.back, in: wc))
        XCTAssertFalse(space.tabs.contains { $0 === child })
        XCTAssertEqual(wc.selectedTabID, opener.id)
    }

    // MARK: - What Back and Forward do with the page focused

    @MainActor func testBackWithThePageFocusedClosesAChildToItsOpener() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let other = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        try focusPage(of: child, in: wc)

        XCTAssertTrue(try perform(BrowserCommands.back, in: wc), "Back is not refused")
        XCTAssertFalse(space.tabs.contains { $0 === child }, "the child closes")
        XCTAssertTrue(space.tabs.contains { $0 === other })
        XCTAssertEqual(wc.selectedTabID, opener.id, "its opener is selected")
    }

    /// Forward with nothing ahead does nothing, as from the sidebar.
    @MainActor func testForwardWithNothingAheadLeavesTheTab() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        try focusPage(of: child, in: wc)

        XCTAssertTrue(try perform(BrowserCommands.forward, in: wc))
        XCTAssertTrue(space.tabs.contains { $0 === child })
        XCTAssertEqual(wc.selectedTabID, child.id)
    }

    /// Focusing a split's other pane makes it the focused pane, and Back acts
    /// on it.
    @MainActor func testBackActsOnTheSplitPaneThatHasTheKeys() throws {
        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let partner = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.store.createSplit(draggedTabID: child.id, targetTabID: partner.id, edge: .right, in: space)
        wc.selectTab(id: partner.id)
        try focusPage(of: child, in: wc)
        XCTAssertEqual(wc.selectedTabID, child.id, "pane focus follows the first responder")

        XCTAssertTrue(try perform(BrowserCommands.back, in: wc))
        XCTAssertFalse(space.tabs.contains { $0 === child })
        XCTAssertTrue(space.tabs.contains { $0 === partner }, "the other pane stays")
        XCTAssertEqual(wc.selectedTabID, opener.id)
    }

    /// A child with history of its own walks it with WebKit, both ways, and
    /// stays open.
    @MainActor func testWithHistoryBackAndForwardWalkWebKitsList() async throws {
        let server = try LoopbackHTTPServer(routes: [
            "/a": "<html><head><title>A</title></head><body>a</body></html>",
            "/b": "<html><head><title>B</title></head><body>b</body></html>",
        ])
        servers.append(server)
        let port = try await server.start()
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))

        let (wc, space) = try makeWindow()
        let opener = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.selectTab(id: child.id)
        child.load(base.appendingPathComponent("a"))
        try await waitUntil("the first page") { child.title == "A" && child.webView?.isLoading == false }
        child.load(base.appendingPathComponent("b"))
        try await waitUntil("the second page") { child.title == "B" && child.canGoBack }
        try focusPage(of: child, in: wc)

        XCTAssertTrue(try perform(BrowserCommands.back, in: wc))
        try await waitUntil("back in the tab's history") { child.webView?.url?.path == "/a" && child.canGoForward }
        XCTAssertTrue(space.tabs.contains { $0 === child }, "a tab with history is not closed")
        XCTAssertEqual(wc.selectedTabID, child.id)

        try focusPage(of: child, in: wc)
        XCTAssertTrue(try perform(BrowserCommands.forward, in: wc))
        try await waitUntil("forward again") { child.webView?.url?.path == "/b" }
    }
}
