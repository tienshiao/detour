import XCTest
import WebKit
@testable import Detour

/// TASK-186.2: which panes a window shows the dev toolbar on, and what the
/// toolbar's controls do. A pane is in dev mode by `DevMode.isActive` for the
/// window's profile; the toolbar follows the tab's URL and the per-site switch
/// at once, sits on each pane of a split separately, and never in a Peek.
///
/// The hosts are `.test` (local by the rule) and `.invalid` (not): neither
/// resolves, so nothing reaches the network, and a failed load keeps the URL.
@MainActor
final class DevToolbarHostingTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var createdTabs: [BrowserTab] = []

    private let localURL = URL(string: "http://app.test:3000/")!
    private let otherLocalURL = URL(string: "http://app.test:3000/settings?tab=1")!
    private let remoteURL = URL(string: "http://remote.invalid/")!

    override func tearDown() {
        if let profileID = controller?.activeSpace?.profile?.id {
            // Back to the URL rule: removes any override a test stored.
            DevMode.setEnabled(true, for: localURL, profileID: profileID)
            DevMode.setEnabled(false, for: remoteURL, profileID: profileID)
        }
        controller?.window?.close()
        controller = nil
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        super.tearDown()
    }

    /// A Private window, so per-site choices stay in memory.
    private func makeController() throws -> (BrowserWindowController, Space) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        wc.sidebarSplitView.autosaveName = nil
        // Give the content area its size without showing the window: the
        // toolbar's geometry is measured against it.
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(wc.contentContainerView.bounds.height, 2 * DevToolbarLayout.height)
        return (wc, try XCTUnwrap(wc.activeSpace))
    }

    private func addTab(_ url: URL, to wc: BrowserWindowController, in space: Space) -> BrowserTab {
        let tab = wc.store.addTab(in: space, url: url)
        createdTabs.append(tab)
        return tab
    }

    /// Lets the `$url` sinks (delivered on the main run loop) run.
    private func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func assertShowsToolbar(_ tab: BrowserTab, url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try XCTUnwrap(tab.webViewContainer, file: file, line: line)
        let webView = try XCTUnwrap(tab.webView, file: file, line: line)
        XCTAssertTrue(container.isShowingDevToolbar, "toolbar shown for \(url)", file: file, line: line)
        let toolbar = try XCTUnwrap(container.devToolbar, file: file, line: line)
        XCTAssertEqual(toolbar.urlButton.title, url.absoluteString, file: file, line: line)
        XCTAssertGreaterThan(container.bounds.height, DevToolbarLayout.height, file: file, line: line)
        XCTAssertEqual(webView.frame.maxY, container.bounds.maxY - DevToolbarLayout.height,
                       "the page starts below the toolbar", file: file, line: line)
        XCTAssertEqual(toolbar.frame.minY, webView.frame.maxY, file: file, line: line)
        XCTAssertEqual(toolbar.frame.width, webView.frame.width, file: file, line: line)
    }

    private func assertNoToolbar(_ tab: BrowserTab, file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try XCTUnwrap(tab.webViewContainer, file: file, line: line)
        XCTAssertFalse(container.isShowingDevToolbar, file: file, line: line)
        XCTAssertEqual(tab.webView?.frame, container.bounds, "the page fills the container", file: file, line: line)
    }

    // MARK: - Which panes

    func testALocalTabShowsTheToolbarAboveItsPage() throws {
        let (wc, space) = try makeController()
        let tab = addTab(localURL, to: wc, in: space)
        wc.selectTab(id: tab.id)
        try assertShowsToolbar(tab, url: localURL)
    }

    func testARemoteTabHasNoToolbar() throws {
        let (wc, space) = try makeController()
        let tab = addTab(remoteURL, to: wc, in: space)
        wc.selectTab(id: tab.id)
        try assertNoToolbar(tab)
        XCTAssertNil(tab.webViewContainer?.devToolbar, "no toolbar is built for a page that never needed one")
    }

    func testTheToolbarFollowsNavigationInTheSameTab() throws {
        let (wc, space) = try makeController()
        let tab = addTab(localURL, to: wc, in: space)
        wc.selectTab(id: tab.id)
        try assertShowsToolbar(tab, url: localURL)

        tab.url = remoteURL
        spinRunLoop()
        try assertNoToolbar(tab)

        tab.url = otherLocalURL
        spinRunLoop()
        try assertShowsToolbar(tab, url: otherLocalURL)
    }

    func testSwitchingTabsShowsEachTabsOwnState() throws {
        let (wc, space) = try makeController()
        let local = addTab(localURL, to: wc, in: space)
        let remote = addTab(remoteURL, to: wc, in: space)
        wc.selectTab(id: local.id)
        wc.selectTab(id: remote.id)
        try assertNoToolbar(remote)
        wc.selectTab(id: local.id)
        try assertShowsToolbar(local, url: localURL)
    }

    func testThePerSiteSwitchHidesAndShowsTheToolbarAtOnce() throws {
        let (wc, space) = try makeController()
        let profileID = try XCTUnwrap(space.profile?.id)
        let local = addTab(localURL, to: wc, in: space)
        wc.selectTab(id: local.id)

        DevMode.setEnabled(false, for: localURL, profileID: profileID)
        try assertNoToolbar(local)

        DevMode.setEnabled(true, for: localURL, profileID: profileID)
        try assertShowsToolbar(local, url: localURL)
    }

    func testTurningDevModeOnForARemoteSiteShowsTheToolbar() throws {
        let (wc, space) = try makeController()
        let profileID = try XCTUnwrap(space.profile?.id)
        let remote = addTab(remoteURL, to: wc, in: space)
        wc.selectTab(id: remote.id)

        DevMode.setEnabled(true, for: remoteURL, profileID: profileID)
        try assertShowsToolbar(remote, url: remoteURL)
    }

    func testASplitShowsTheToolbarOnlyOnTheLocalPane() throws {
        let (wc, space) = try makeController()
        let left = addTab(remoteURL, to: wc, in: space)
        let right = addTab(localURL, to: wc, in: space)
        wc.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        wc.selectTab(id: left.id)

        XCTAssertNotNil(left.webViewContainer?.superview as? NSSplitView, "both panes are hosted")
        try assertNoToolbar(left)
        try assertShowsToolbar(right, url: localURL)

        // The unfocused pane follows its own navigation too.
        right.url = remoteURL
        spinRunLoop()
        try assertNoToolbar(right)
        left.url = otherLocalURL
        spinRunLoop()
        try assertShowsToolbar(left, url: otherLocalURL)
    }

    func testAPeekHasNoToolbarAndTheHostKeepsIts() throws {
        let (wc, space) = try makeController()
        let host = addTab(localURL, to: wc, in: space)
        wc.selectTab(id: host.id)
        wc.showPeekOverlay(url: otherLocalURL)

        let peek = try XCTUnwrap(host.peekTab)
        createdTabs.append(peek)
        XCTAssertFalse(peek.webView?.superview is WebViewContainerView, "the Peek panel hosts its bare web view")
        XCTAssertNil(peek.webViewContainer?.devToolbar)
        try assertShowsToolbar(host, url: localURL)
    }

    // MARK: - Controls

    /// The palette's field: its one editable text field.
    private func paletteText(_ wc: BrowserWindowController) -> String? {
        func fields(_ view: NSView) -> [NSTextField] {
            view.subviews.compactMap { $0 as? NSTextField } + view.subviews.flatMap(fields)
        }
        return wc.commandPaletteView.flatMap { fields($0).first { $0.isEditable }?.stringValue }
    }

    func testClickingTheURLOpensThePaletteToNavigateInPlace() throws {
        let (wc, space) = try makeController()
        let tab = addTab(localURL, to: wc, in: space)
        wc.selectTab(id: tab.id)

        try XCTUnwrap(tab.webViewContainer?.devToolbar).urlButton.performClick(nil)

        XCTAssertNotNil(wc.commandPaletteView)
        XCTAssertTrue(wc.commandPaletteNavigatesInPlace)
        XCTAssertEqual(paletteText(wc), localURL.absoluteString)
    }

    func testClickingTheUnfocusedPanesURLFocusesThatPaneFirst() throws {
        let (wc, space) = try makeController()
        let left = addTab(localURL, to: wc, in: space)
        let right = addTab(otherLocalURL, to: wc, in: space)
        wc.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        wc.selectTab(id: left.id)
        XCTAssertEqual(wc.selectedTabID, left.id)

        try XCTUnwrap(right.webViewContainer?.devToolbar).urlButton.performClick(nil)

        XCTAssertEqual(wc.selectedTabID, right.id, "the clicked pane takes focus")
        XCTAssertTrue(wc.commandPaletteNavigatesInPlace)
        XCTAssertEqual(paletteText(wc), otherLocalURL.absoluteString)
    }

    func testTheCopyButtonCopiesThePanesURL() throws {
        let (wc, space) = try makeController()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DetourTests.devToolbar.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        wc.urlPasteboard = pasteboard
        let left = addTab(remoteURL, to: wc, in: space)
        let right = addTab(localURL, to: wc, in: space)
        wc.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        wc.selectTab(id: left.id)

        try XCTUnwrap(right.webViewContainer?.devToolbar).copyButton.performClick(nil)

        XCTAssertEqual(pasteboard.string(forType: .string), localURL.absoluteString,
                       "the toolbar's own pane, not the focused one")
    }
}
