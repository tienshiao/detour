import XCTest
import WebKit
@testable import Detour

/// TASK-220: an action popup's popover takes the size of the popup page's
/// content when it opens, and follows it when the content changes size — or
/// the popup navigates to another page — after it opened.
///
/// The popover used to be measured 50 ms after `show` reloaded the popup web
/// view, which was still on about:blank then: the 16×8 blank body clamped to
/// 100×100, and the ResizeObserver meant to correct it was installed in that
/// same about:blank document, which the popup page replaced. The popover
/// stayed at 100×100 for good while WebKit laid the page out at its own
/// content size, so the page was cut off.
@MainActor
final class ExtensionPopoverSizingTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var createdProfiles: [Profile] = []
    private var windows: [NSWindow] = []
    private var controllers: [ExtensionPopoverController] = []
    private var contexts: [WKWebExtensionContext] = []

    /// Kept alive for the rest of the test process: releasing a profile whose
    /// configuration hosted a popup web view frees its process pool inside an
    /// IPC dispatch and WebKit traps (see ExtensionMenuPopupDecisionTests).
    private static var retainedProfiles: [Profile] = []

    override func tearDown() async throws {
        for controller in controllers { controller.close() }
        controllers.removeAll()
        for context in contexts { context.action(for: nil)?.closePopup() }
        contexts.removeAll()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// A page whose only content is a `width`×`height` box with no body margin.
    private static func boxPage(width: Int, height: Int, color: String = "#c33") -> String {
        """
        <!doctype html><html><head><style>
        html, body { margin: 0; padding: 0; }
        #box { width: \(width)px; height: \(height)px; background: \(color); }
        </style></head><body><div id="box"></div></body></html>
        """
    }

    private struct Popup {
        let context: WKWebExtensionContext
        let extensionID: String
        let profile: Profile
    }

    private func loadPopupExtension(files: [String: String]) async throws -> Popup {
        let ext = try await makeTestExtension(
            id: "popup-size-\(UUID().uuidString.prefix(8))",
            manifestJSON: """
            {"manifest_version": 3, "name": "Popup Size Test", "version": "1.0.0",
             "action": { "default_popup": "popup.html" }}
            """,
            files: files)
        tempDirs.append(ext.basePath)
        let profile = TabStore.shared.addProfile(name: "Popup Size")
        createdProfiles.append(profile)
        let context = try loadTestContext(ext, in: profile)
        contexts.append(context)
        return Popup(context: context, extensionID: ext.id, profile: profile)
    }

    /// A window with a button-sized anchor to present from.
    private func makeAnchor() -> NSView {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 280, y: 360, width: 30, height: 30))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        windows.append(window)
        return anchor
    }

    /// The popover's size when it first appears: polled finely, so a popover
    /// presented small and corrected later is caught small.
    private func firstPresentedSize(of controller: ExtensionPopoverController,
                                    file: StaticString = #filePath, line: UInt = #line) async throws -> NSSize? {
        try await waitUntil("the popover to be shown", timeout: 10, pollInterval: 0.01,
                            file: file, line: line) { controller.presentedContentSize != nil }
        return controller.presentedContentSize
    }

    private func waitForSize(_ size: NSSize, of controller: ExtensionPopoverController,
                             webView: WKWebView?, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil(what, timeout: 10, file: file, line: line) {
            controller.presentedContentSize == size && webView?.frame.size == size
        }
        XCTAssertEqual(controller.presentedContentSize, size, what, file: file, line: line)
        XCTAssertEqual(webView?.frame.size, size, "the web view fills the popover", file: file, line: line)
    }

    // MARK: - Opening

    /// AC #1, the toolbar-button path (`show`), which both the main window and
    /// the Quick Detour bar use.
    func testAFixedSizePopupOpensAtItsContentSize() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 300)])
        let anchor = makeAnchor()
        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)

        controller.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        let first = try await firstPresentedSize(of: controller)
        XCTAssertEqual(first, NSSize(width: 220, height: 300), "the popover opens at the content's size")
        let webView = popup.context.action(for: nil)?.popupWebView
        try await waitForSize(NSSize(width: 220, height: 300), of: controller, webView: webView,
                              "the popover stays at the content's size")
    }

    /// The `action.openPopup()` path: WebKit hands over a web view that has
    /// already loaded the page.
    func testAnAlreadyLoadedPopupWebViewIsPresentedAtItsContentSize() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 260, height: 180)])
        let anchor = makeAnchor()
        let webView = try XCTUnwrap(popup.context.action(for: nil)?.popupWebView)
        try await waitUntil("the popup page to load") {
            !webView.isLoading && webView.url?.lastPathComponent == "popup.html"
        }

        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)
        controller.setPositioning(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        controller.presentPopupWebView(webView)

        let first = try await firstPresentedSize(of: controller)
        XCTAssertEqual(first, NSSize(width: 260, height: 180))
    }

    /// Content beyond 800×600 is held to it, and a tiny page to 100×100 — the
    /// limits the popover always had.
    func testThePopoverSizeIsClampedToItsLimits() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 1200, height: 40)])
        let anchor = makeAnchor()
        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)

        controller.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        let webView = popup.context.action(for: nil)?.popupWebView
        try await waitForSize(NSSize(width: 800, height: 100), of: controller, webView: webView,
                              "the popover at the clamped size")
    }

    /// WebKit keeps the popup web view between opens: a second open of the
    /// same popup sizes it again, with nothing left over from the first.
    func testReopeningThePopupSizesItAgain() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 300)])
        let anchor = makeAnchor()
        let webView = try XCTUnwrap(popup.context.action(for: nil)?.popupWebView)
        // Width limits as the popover adds them: plain constraints, not the
        // content-size constraints AppKit derives from the intrinsic size.
        func widthLimits() -> Int {
            webView.constraints.filter { type(of: $0) == NSLayoutConstraint.self && $0.firstAttribute == .width }.count
        }
        let widthConstraintsBefore = widthLimits()

        let first = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(first)
        first.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        try await waitForSize(NSSize(width: 220, height: 300), of: first, webView: webView, "the first open")
        first.close()
        // AppKit never finishes a popover's close animation in the test host
        // (the window goes, isShown stays true and the delegate is never
        // told), so deliver what it would.
        first.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertNil(first.presentedContentSize)
        XCTAssertNil(webView.superview, "a closed popover lets go of the web view")
        XCTAssertTrue(webView.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(widthLimits(), widthConstraintsBefore,
                       "the closed popover's size limits are gone from the web view")

        let second = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(second)
        second.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        XCTAssertTrue(popup.context.action(for: nil)?.popupWebView === webView, "the same web view is reused")
        let size = try await firstPresentedSize(of: second)
        XCTAssertEqual(size, NSSize(width: 220, height: 300), "the second open")
        XCTAssertEqual(widthLimits(), widthConstraintsBefore + 3,
                       "only this open's width limits (min, max, fallback) are on the web view")
    }

    /// Closed while it waits for the page to load: it never appears, and
    /// `onClose` is called — the Quick Detour closes the previous popup the
    /// moment it opens the next.
    func testClosingBeforeThePageLoadsNeverPresents() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 300)])
        let anchor = makeAnchor()
        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)
        var closes = 0
        controller.onClose = { closes += 1 }

        controller.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        XCTAssertNil(controller.presentedContentSize, "still waiting for the page")
        controller.close()
        XCTAssertEqual(closes, 1, "the close is reported at once")

        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertNil(controller.presentedContentSize, "a closed popup must not appear when the page loads")
        XCTAssertEqual(closes, 1)
    }

    /// The Quick Detour closes the previous popup as it opens the next, and
    /// the next can be presented before the previous one's close animation
    /// ends: that late close must not take the web view out of the new popover.
    func testALateCloseOfThePreviousPopoverLeavesTheNextOneItsWebView() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 300)])
        let anchor = makeAnchor()
        let webView = try XCTUnwrap(popup.context.action(for: nil)?.popupWebView)

        let first = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(first)
        first.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        try await waitForSize(NSSize(width: 220, height: 300), of: first, webView: webView, "the first open")
        first.close()

        let second = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(second)
        second.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        _ = try await firstPresentedSize(of: second)
        let host = try XCTUnwrap(webView.superview, "the second popover hosts the web view")

        first.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertTrue(webView.superview === host, "the first popover's close leaves the web view where it is")
        XCTAssertFalse(webView.translatesAutoresizingMaskIntoConstraints)
    }

    /// The anchor's window closed while the page loaded: nothing is presented
    /// and the close is reported, so an `openPopup()` caller is not left waiting.
    func testAPopupWhoseAnchorIsGoneByLoadIsReportedClosed() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 300)])
        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)
        var closes = 0
        controller.onClose = { closes += 1 }

        do {
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
            controller.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
        try await waitUntil("the close to be reported", timeout: 5) { closes == 1 }
        XCTAssertNil(controller.presentedContentSize)
    }

    // MARK: - After opening

    /// AC #2: content that changes size after the page loaded resizes the
    /// popover, both larger and smaller.
    func testAPopupThatChangesSizeAfterLoadResizesThePopover() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 300)])
        let anchor = makeAnchor()
        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)
        controller.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let webView = try XCTUnwrap(popup.context.action(for: nil)?.popupWebView)
        try await waitForSize(NSSize(width: 220, height: 300), of: controller, webView: webView,
                              "the popover at the first size")

        _ = try await webView.evaluateJavaScript(
            "const b = document.getElementById('box'); b.style.width = '340px'; b.style.height = '420px'; true")
        try await waitForSize(NSSize(width: 340, height: 420), of: controller, webView: webView,
                              "the popover to grow with its content")

        _ = try await webView.evaluateJavaScript(
            "const c = document.getElementById('box'); c.style.width = '180px'; c.style.height = '150px'; true")
        try await waitForSize(NSSize(width: 180, height: 150), of: controller, webView: webView,
                              "the popover to shrink with its content")
    }

    /// A popup that navigates to another of its pages takes that page's size:
    /// nothing that tracks the size may live in a document the popup leaves.
    func testAPopupThatNavigatesToAnotherPageTakesThatPagesSize() async throws {
        let popup = try await loadPopupExtension(files: [
            "popup.html": Self.boxPage(width: 220, height: 300),
            "second.html": Self.boxPage(width: 300, height: 240, color: "#36c"),
        ])
        let anchor = makeAnchor()
        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)
        controller.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let webView = try XCTUnwrap(popup.context.action(for: nil)?.popupWebView)
        try await waitForSize(NSSize(width: 220, height: 300), of: controller, webView: webView,
                              "the popover at the first page's size")

        _ = try await webView.evaluateJavaScript("location.href = 'second.html'; true")
        try await waitForSize(NSSize(width: 300, height: 240), of: controller, webView: webView,
                              "the popover at the second page's size")
    }
}
