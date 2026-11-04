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
nonisolated final class ExtensionPopoverSizingTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var createdProfiles: [Profile] = []
    private var windows: [NSWindow] = []
    private var controllers: [ExtensionPopoverController] = []
    private var contexts: [WKWebExtensionContext] = []

    /// Kept alive for the rest of the test process: releasing a profile whose
    /// configuration hosted a popup web view frees its process pool inside an
    /// IPC dispatch and WebKit traps (see ExtensionMenuPopupDecisionTests).
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func tearDown() async throws {
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
    @MainActor private static func boxPage(width: Int, height: Int, color: String = "#c33") -> String {
        """
        <!doctype html><html><head><style>
        html, body { margin: 0; padding: 0; }
        #box { width: \(width)px; height: \(height)px; background: \(color); }
        </style></head><body><div id="box"></div></body></html>
        """
    }

    @MainActor private struct Popup {
        let context: WKWebExtensionContext
        let extensionID: String
        let profile: Profile
    }

    @MainActor private func loadPopupExtension(files: [String: String]) async throws -> Popup {
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
    @MainActor private func makeAnchor() -> NSView {
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
    @MainActor private func firstPresentedSize(of controller: ExtensionPopoverController,
                                    file: StaticString = #filePath, line: UInt = #line) async throws -> NSSize? {
        try await waitUntil("the popover to be shown", timeout: 10, pollInterval: 0.01,
                            file: file, line: line) { controller.presentedContentSize != nil }
        return controller.presentedContentSize
    }

    @MainActor private func waitForSize(_ size: NSSize, of controller: ExtensionPopoverController,
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
    @MainActor func testAFixedSizePopupOpensAtItsContentSize() async throws {
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
    @MainActor func testAnAlreadyLoadedPopupWebViewIsPresentedAtItsContentSize() async throws {
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
    @MainActor func testThePopoverSizeIsClampedToItsLimits() async throws {
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
    @MainActor func testReopeningThePopupSizesItAgain() async throws {
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
    @MainActor func testClosingBeforeThePageLoadsNeverPresents() async throws {
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
    @MainActor func testALateCloseOfThePreviousPopoverLeavesTheNextOneItsWebView() async throws {
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
    @MainActor func testAPopupWhoseAnchorIsGoneByLoadIsReportedClosed() async throws {
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
    @MainActor func testAPopupThatChangesSizeAfterLoadResizesThePopover() async throws {
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
    @MainActor func testAPopupThatNavigatesToAnotherPageTakesThatPagesSize() async throws {
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

    // MARK: - Content taller than the popover (TASK-150)

    /// WebKit never scrolls a popup page in its size-to-content mode, so a
    /// popup whose content reaches the maximum height scrolls inside a popover
    /// of that height, and the mode comes back when the popover closes.
    @MainActor func testAPopupTallerThanThePopoverScrollsInAPopoverOfTheMaximumHeight() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 2000)])
        let anchor = makeAnchor()
        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)

        controller.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        let webView = try XCTUnwrap(popup.context.action(for: nil)?.popupWebView)
        try await waitForSize(NSSize(width: 220, height: 600), of: controller, webView: webView,
                              "the popover at the content's width and the maximum height")
        XCTAssertTrue(ExtensionPopoverController.isPageScrolling(webView), "the page scrolls inside the popover")
        // Laid out again with the mode off: the view keeps the popover's size.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(webView.frame.size, NSSize(width: 220, height: 600))
        XCTAssertEqual(controller.presentedContentSize, NSSize(width: 220, height: 600))

        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertFalse(ExtensionPopoverController.isPageScrolling(webView),
                       "a closed popover gives the web view's layout back to WebKit")
    }

    /// NEGATIVE: a popup that fits keeps WebKit's size-to-content mode.
    @MainActor func testAPopupThatFitsDoesNotScroll() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 300)])
        let anchor = makeAnchor()
        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)

        controller.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        let webView = try XCTUnwrap(popup.context.action(for: nil)?.popupWebView)
        try await waitForSize(NSSize(width: 220, height: 300), of: controller, webView: webView, "the content's size")
        XCTAssertFalse(ExtensionPopoverController.isPageScrolling(webView))
    }

    /// Content that grows past the popover after it opened scrolls too.
    @MainActor func testAPopupThatGrowsPastThePopoverAfterLoadScrolls() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 300)])
        let anchor = makeAnchor()
        let controller = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(controller)
        controller.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let webView = try XCTUnwrap(popup.context.action(for: nil)?.popupWebView)
        try await waitForSize(NSSize(width: 220, height: 300), of: controller, webView: webView, "the first size")

        _ = try await webView.evaluateJavaScript("document.getElementById('box').style.height = '1800px'; true")
        try await waitForSize(NSSize(width: 220, height: 600), of: controller, webView: webView,
                              "the popover at the maximum height")
        try await waitUntil("the page to scroll", timeout: 5) { ExtensionPopoverController.isPageScrolling(webView) }
    }

    /// Re-opening a popup that a previous popover left scrolling: the page is
    /// WebKit's to size again first, so a reloaded page that fits is not held
    /// at the maximum height.
    @MainActor func testAPopupLeftScrollingIsSizedByWebKitWhenItIsShownAgain() async throws {
        let popup = try await loadPopupExtension(files: ["popup.html": Self.boxPage(width: 220, height: 2000)])
        let anchor = makeAnchor()
        let webView = try XCTUnwrap(popup.context.action(for: nil)?.popupWebView)
        let first = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(first)
        first.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        try await waitUntil("the first popup to scroll") { ExtensionPopoverController.isPageScrolling(webView) }
        first.close()

        let second = ExtensionPopoverController(extensionID: popup.extensionID, profile: popup.profile)
        controllers.append(second)
        second.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        XCTAssertFalse(ExtensionPopoverController.isPageScrolling(webView),
                       "the second presentation hands the view back to WebKit before it measures")
        _ = try await firstPresentedSize(of: second)
        try await waitUntil("the second popup to scroll") { ExtensionPopoverController.isPageScrolling(webView) }
        // Not the fallback size: WebKit kept the page's size through the
        // switch (see `sizeToContentOff`).
        try await waitForSize(NSSize(width: 220, height: 600), of: second, webView: webView,
                              "the second popover at the content's width and the maximum height")

        // NEGATIVE: the first popover's late close must not switch the mode
        // back under the second, which now shows the view.
        first.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertTrue(ExtensionPopoverController.isPageScrolling(webView))
    }
}

/// TASK-150: the decision and the guarded private setter behind a popup that
/// scrolls, and whose controller owns a popup web view's scrolling mode.
nonisolated final class ExtensionPopoverScrollStateTests: XCTestCase {

    private typealias Controller = ExtensionPopoverController

    @MainActor func testContentReachingTheMaximumHeightScrolls() {
        XCTAssertFalse(Controller.pageScrolls(contentHeight: 300, maximumHeight: 600))
        XCTAssertFalse(Controller.pageScrolls(contentHeight: 599, maximumHeight: 600))
        XCTAssertTrue(Controller.pageScrolls(contentHeight: 600, maximumHeight: 600))
        XCTAssertTrue(Controller.pageScrolls(contentHeight: 599, maximumHeight: 599))
        XCTAssertTrue(Controller.pageScrolls(contentHeight: 3456, maximumHeight: 600))
        XCTAssertFalse(Controller.pageScrolls(contentHeight: NSView.noIntrinsicMetric, maximumHeight: 600),
                       "a web view that reports no size yet does not scroll")
    }

    /// An object with WebKit's setter, standing in for the popup web view.
    @MainActor private final class FakeAutoSizingView: NSObject {
        var maximum = NSSize(width: 800, height: 600)
        var sets = 0

        @objc(_setSizeToContentAutoSizeMaximumSize:) func setMaximum(_ size: NSSize) {
            maximum = size
            sets += 1
        }
    }

    @MainActor func testTheSetterIsUsedWhenWebKitHasIt() {
        let view = FakeAutoSizingView()
        XCTAssertTrue(Controller.setSizeToContentMaximum(NSValue(size: .zero), on: view))
        XCTAssertEqual(view.maximum, .zero)
        XCTAssertTrue(Controller.setSizeToContentMaximum(NSValue(size: NSSize(width: 800, height: 600)), on: view))
        XCTAssertEqual(view.maximum, NSSize(width: 800, height: 600))
        XCTAssertEqual(view.sets, 2)
    }

    /// NEGATIVE: on a WebKit without the setter nothing is touched — and
    /// nothing throws, which a blind `setValue(_:forKey:)` would.
    @MainActor func testWithoutTheSetterNothingIsTouched() {
        XCTAssertFalse(Controller.setSizeToContentMaximum(NSValue(size: .zero), on: NSObject()))
    }

    /// A web view that records what its size-to-content maximum is set to,
    /// standing in for WebKit's popup web view (whose getter answers 0 x 0).
    @MainActor private final class RecordingWebView: WKWebView {
        var maximums: [NSSize] = []

        @objc(_setSizeToContentAutoSizeMaximumSize:) func recordMaximum(_ size: NSSize) {
            maximums.append(size)
        }
    }

    private let off = NSSize(width: 800, height: 0)
    private let on = NSSize(width: 800, height: 600)

    @MainActor private func makeWebView() -> RecordingWebView {
        RecordingWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 600), configuration: WKWebViewConfiguration())
    }

    @MainActor func testTheModeIsSwitchedOncePerChange() {
        let webView = makeWebView()
        let controller = Controller(extensionID: "scroll-state")
        XCTAssertFalse(Controller.isPageScrolling(webView))

        XCTAssertTrue(controller.setPageScrolls(true, in: webView))
        XCTAssertTrue(controller.setPageScrolls(true, in: webView))
        XCTAssertEqual(webView.maximums, [off], "switching on twice touches WebKit once")
        XCTAssertTrue(Controller.isPageScrolling(webView))

        controller.setPageScrolls(false, in: webView)
        controller.setPageScrolls(false, in: webView)
        XCTAssertEqual(webView.maximums, [off, on])
        XCTAssertFalse(Controller.isPageScrolling(webView))
    }

    /// The mode is switched off with a zero height, never a zero width: a
    /// zero width makes WebKit drop the web view's intrinsic size, which a
    /// page that keeps its size never reports again.
    @MainActor func testTheModeIsSwitchedOffWithAZeroHeightAndAWidth() {
        XCTAssertEqual(Controller.sizeToContentOff.height, 0)
        XCTAssertGreaterThan(Controller.sizeToContentOff.width, 0)
    }

    /// The state is the view's: a controller that is handed a view another
    /// left scrolling hands it back to WebKit before the new page is sized.
    @MainActor func testPresentingAViewLeftScrollingRestoresWebKitsMode() {
        let webView = makeWebView()
        let first = Controller(extensionID: "scroll-state")
        first.setPageScrolls(true, in: webView)

        let second = Controller(extensionID: "scroll-state")
        second.presentPopupWebView(webView)
        XCTAssertEqual(webView.maximums, [off, on])
        XCTAssertFalse(Controller.isPageScrolling(webView))
    }

    /// NEGATIVE: one view's mode says nothing about another's.
    @MainActor func testTheStateIsPerWebView() {
        let scrolling = makeWebView()
        let other = makeWebView()
        Controller(extensionID: "scroll-state").setPageScrolls(true, in: scrolling)
        XCTAssertTrue(Controller.isPageScrolling(scrolling))
        XCTAssertFalse(Controller.isPageScrolling(other))
        XCTAssertEqual(other.maximums, [])
    }
}
