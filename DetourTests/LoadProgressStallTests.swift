import XCTest
import AppKit
import WebKit
@testable import Detour

/// A background tab's load can sit part-finished until the tab is shown: WebKit
/// de-prioritises a hidden page's web process, and on a busy machine that
/// leaves it almost no CPU (TASK-124). The sidebar stops drawing the progress
/// bar of such a row once its progress has not moved for
/// `BrowserTab.loadStallInterval`. Each page here holds one image request open,
/// so the load stays in flight with its progress parked.
@MainActor
final class LoadProgressStallTests: XCTestCase {

    private var tabs: [BrowserTab] = []
    private var windows: [NSWindow] = []
    private var defaultInterval: TimeInterval = 0
    private let scheme = StallingSchemeHandler()
    private let pageURL = URL(string: "stall://stall.test/page")!

    override func setUp() {
        super.setUp()
        defaultInterval = BrowserTab.loadStallInterval
        BrowserTab.loadStallInterval = 0.3
        scheme.pages[pageURL.path] = "<html><head><title>Stalled</title></head><body><img src=\"/hang.png\"></body></html>"
    }

    override func tearDown() {
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        windows.removeAll()
        BrowserTab.loadStallInterval = defaultInterval
        super.tearDown()
    }

    private func makeLoadingTab() async throws -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "stall")
        let tab = BrowserTab(configuration: configuration)
        tabs.append(tab)
        tab.load(pageURL)
        try await waitUntil("the page to commit and park its progress") {
            tab.isLoading && tab.estimatedProgress > 0.1
        }
        return tab
    }

    func testAHiddenLoadWhoseProgressStopsMovingCountsAsStalled() async throws {
        let tab = try await makeLoadingTab()

        try await waitUntil("the stall to be noticed") { tab.isLoadProgressStalled }

        XCTAssertTrue(tab.isLoading, "the load itself is untouched")
        XCTAssertGreaterThan(tab.estimatedProgress, 0)
        XCTAssertEqual(tab.sidebarProgress, 0, "the sidebar stops drawing the bar")
    }

    func testTheStallClearsWhenTheLoadMovesAgain() async throws {
        let tab = try await makeLoadingTab()
        try await waitUntil("the stall to be noticed") { tab.isLoadProgressStalled }

        scheme.releaseHeld()

        try await waitUntil("the load to finish") { !tab.isLoading }
        XCTAssertFalse(tab.isLoadProgressStalled)
    }

    func testShowingAStalledTabClearsTheStallWithoutProgressMoving() async throws {
        let tab = try await makeLoadingTab()
        try await waitUntil("the stall to be noticed") { tab.isLoadProgressStalled }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)

        tab.noteShown()
        window.contentView?.addSubview(try XCTUnwrap(tab.webView))

        XCTAssertFalse(tab.isLoadProgressStalled)
        try await Task.sleep(nanoseconds: UInt64(BrowserTab.loadStallInterval * 4 * 1_000_000_000))
        XCTAssertTrue(tab.isLoading, "the held request keeps the load in flight")
        XCTAssertFalse(tab.isLoadProgressStalled)
        XCTAssertEqual(tab.sidebarProgress, tab.estimatedProgress)
    }

    func testATabShownInAWindowNeverCountsAsStalled() async throws {
        let tab = try await makeLoadingTab()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let webView = try XCTUnwrap(tab.webView)
        // As the window controller does when it attaches a pane; also clears a
        // stall the tab may already have run into on a slow machine.
        tab.noteShown()
        window.contentView?.addSubview(webView)

        try await Task.sleep(nanoseconds: UInt64(BrowserTab.loadStallInterval * 4 * 1_000_000_000))

        XCTAssertTrue(tab.isLoading)
        XCTAssertFalse(tab.isLoadProgressStalled)
        XCTAssertEqual(tab.sidebarProgress, tab.estimatedProgress)

        // Sent to the background mid-load, it is picked up on the next check.
        webView.removeFromSuperview()
        try await waitUntil("the stall to be noticed once hidden") { tab.isLoadProgressStalled }
    }
}
