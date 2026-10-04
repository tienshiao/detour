import XCTest
import WebKit
@testable import Detour

/// TASK-150: an action popup taller than the popover has to scroll.
///
/// `ExtensionPopoverController` clamps the popover to 100...800 x 100...600 and,
/// while the popup's content is taller than that, switches WebKit's
/// size-to-content mode off so the page scrolls inside the view. These tests
/// cover the decisions — the sizing, when to measure — and the guarded private
/// setter. What WebKit then does is checked in the running app: the state in
/// which it refuses to scroll a tall popup (the view held to 600 pt before the
/// page loads into it) did not reproduce in the test host, where the page of
/// an unshown popup web view scrolled by itself.
final class ExtensionPopoverSizingTests: XCTestCase {

    private typealias Controller = ExtensionPopoverController

    private func sizing(_ width: CGFloat, _ height: CGFloat, content: CGFloat? = nil,
                        scrolling: Bool = false) -> Controller.PopupSizing? {
        Controller.sizing(width: width, height: height, contentHeight: content, pageScrollsNow: scrolling)
    }

    // MARK: - A popup that fits

    func testAPopupThatFitsKeepsItsMeasuredSizeAndDoesNotScroll() {
        XCTAssertEqual(sizing(300, 200, content: 200),
                       Controller.PopupSizing(popoverSize: NSSize(width: 300, height: 200), pageScrolls: false))
        XCTAssertEqual(sizing(360, 480),
                       Controller.PopupSizing(popoverSize: NSSize(width: 360, height: 480), pageScrolls: false),
                       "a measurement without contentHeight sizes the popover as it always did")
        // Exactly the maximum still fits.
        XCTAssertEqual(sizing(800, 600, content: 600),
                       Controller.PopupSizing(popoverSize: NSSize(width: 800, height: 600), pageScrolls: false))
    }

    func testThePopoverIsClampedToItsLimits() {
        XCTAssertEqual(sizing(40, 30)?.popoverSize, NSSize(width: 100, height: 100))
        XCTAssertEqual(sizing(1200, 300)?.popoverSize, NSSize(width: 800, height: 300))
        XCTAssertEqual(sizing(1200, 300)?.pageScrolls, false, "a popup that is only too wide does not scroll vertically")
    }

    // MARK: - A popup taller than the popover

    func testAPopupTallerThanThePopoverScrollsInAPopoverOfTheMaximumHeight() {
        XCTAssertEqual(sizing(440, 3456, content: 3456),
                       Controller.PopupSizing(popoverSize: NSSize(width: 440, height: 600), pageScrolls: true))
        XCTAssertEqual(sizing(440, 601)?.pageScrolls, true)
        XCTAssertEqual(sizing(440, 601)?.popoverSize.height, 600)
    }

    // MARK: - While the page scrolls

    /// While the page scrolls the document is at least as tall as the view, so
    /// the body's own height is what says whether the content still overflows.
    func testAScrollingPopupKeepsScrollingWhileItsContentOverflows() {
        XCTAssertEqual(sizing(440, 3456, content: 3456, scrolling: true),
                       Controller.PopupSizing(popoverSize: NSSize(width: 440, height: 600), pageScrolls: true))
        XCTAssertEqual(sizing(440, 900, content: 900, scrolling: true)?.pageScrolls, true)
    }

    func testAScrollingPopupThatShrinksBackIsSizedToItsContentAgain() {
        // The document still reports the 600 pt view; the body says 180.
        XCTAssertEqual(sizing(440, 600, content: 180, scrolling: true),
                       Controller.PopupSizing(popoverSize: NSSize(width: 440, height: 180), pageScrolls: false))
        XCTAssertEqual(sizing(440, 600, content: 20, scrolling: true)?.popoverSize.height, 100,
                       "the minimum still applies")
    }

    /// NEGATIVE: a body sized to the viewport reports the view's own 600 pt
    /// while the page scrolls. Handing such a page back to WebKit would grow it
    /// again, and the two modes would alternate for ever.
    func testContentOfExactlyTheMaximumKeepsAScrollingPopupScrolling() {
        XCTAssertEqual(sizing(440, 600, content: 600, scrolling: true),
                       Controller.PopupSizing(popoverSize: NSSize(width: 440, height: 600), pageScrolls: true))
        XCTAssertEqual(sizing(440, 600, content: 599, scrolling: true)?.pageScrolls, false)
    }

    /// NEGATIVE: without the body's height there is no telling that the
    /// content shrank, so a scrolling popup stays as it is.
    func testAScrollingPopupWithoutAContentHeightStaysScrolling() {
        XCTAssertEqual(sizing(440, 600, scrolling: true),
                       Controller.PopupSizing(popoverSize: NSSize(width: 440, height: 600), pageScrolls: true))
    }

    // MARK: - Measurements

    func testMeasurementsThatAreNotSizesAreRefused() {
        XCTAssertNil(sizing(0, 200))
        XCTAssertNil(sizing(300, 0))
        XCTAssertNil(sizing(-5, 200))
        XCTAssertNil(Controller.sizing(fromMeasurement: ["width": 300], pageScrollsNow: false))
        XCTAssertNil(Controller.sizing(fromMeasurement: ["width": "300", "height": 200], pageScrollsNow: false))
        XCTAssertNil(Controller.sizing(fromMeasurement: [:], pageScrollsNow: false))
    }

    func testAMeasurementDictionaryIsReadAsThePageSendsIt() {
        // The resize observer posts numbers; callAsyncJavaScript and
        // JSONSerialization both deliver them as NSNumber.
        let measured: [String: Any] = ["width": NSNumber(value: 440), "height": NSNumber(value: 3456.0),
                                       "contentHeight": NSNumber(value: 3456)]
        XCTAssertEqual(Controller.sizing(fromMeasurement: measured, pageScrollsNow: false),
                       Controller.PopupSizing(popoverSize: NSSize(width: 440, height: 600), pageScrolls: true))
        XCTAssertEqual(Controller.sizing(fromMeasurement: ["width": 300, "height": 600, "contentHeight": 150],
                                         pageScrollsNow: true),
                       Controller.PopupSizing(popoverSize: NSSize(width: 300, height: 150), pageScrolls: false))
        XCTAssertEqual(Controller.sizing(fromMeasurement: ["width": 300, "height": 200], pageScrollsNow: false)?.pageScrolls,
                       false, "a measurement from before contentHeight existed still sizes the popover")
    }

    // MARK: - When to measure

    /// The popup is measured once its page has loaded — `show` reloads it, and
    /// a measurement taken earlier lands in a document that is replaced or is
    /// still empty — or, for a page that will not finish, after `loadWait`.
    func testThePopupIsMeasuredWhenItHasLoadedOrHadItsTime() {
        XCTAssertFalse(Controller.shouldMeasure(isLoading: true, waited: 0.05), "still loading: wait")
        XCTAssertFalse(Controller.shouldMeasure(isLoading: true, waited: Controller.loadWait - 0.01))
        XCTAssertTrue(Controller.shouldMeasure(isLoading: false, waited: 0.05), "loaded: measure at once")
        XCTAssertTrue(Controller.shouldMeasure(isLoading: true, waited: Controller.loadWait),
                      "a page that never finishes is presented anyway")
        XCTAssertLessThanOrEqual(Controller.loadWait, 2, "a slow popup must not keep the click waiting for long")
    }

    // MARK: - The private setter

    /// An object with WebKit's setter, standing in for the popup web view.
    private final class FakeAutoSizingView: NSObject {
        var maximum = NSSize(width: 800, height: 600)
        var sets = 0

        @objc(_setSizeToContentAutoSizeMaximumSize:) func setMaximum(_ size: NSSize) {
            maximum = size
            sets += 1
        }
    }

    func testTheSetterIsUsedWhenWebKitHasIt() {
        let view = FakeAutoSizingView()
        XCTAssertTrue(Controller.setSizeToContentMaximum(NSValue(size: .zero), on: view))
        XCTAssertEqual(view.maximum, .zero)
        XCTAssertTrue(Controller.setSizeToContentMaximum(NSValue(size: NSSize(width: 800, height: 600)), on: view))
        XCTAssertEqual(view.maximum, NSSize(width: 800, height: 600))
        XCTAssertEqual(view.sets, 2)
    }

    /// NEGATIVE: on a WebKit without the setter nothing is touched — and
    /// nothing throws, which a blind `setValue(_:forKey:)` would.
    func testWithoutTheSetterNothingIsTouched() {
        XCTAssertFalse(Controller.setSizeToContentMaximum(NSValue(size: .zero), on: NSObject()))
    }
}

/// TASK-150: which controller owns a popup web view's scrolling mode.
///
/// WebKit hands the same popup web view out for every presentation and each
/// presentation builds a new `ExtensionPopoverController`, so the mode is the
/// view's, not a controller's — and a controller whose popover closes after
/// another has taken the view over must leave the mode alone.
@MainActor
final class ExtensionPopoverScrollStateTests: XCTestCase {

    /// A web view that records what its size-to-content maximum is set to,
    /// standing in for WebKit's popup web view (whose getter answers 0 x 0).
    private final class RecordingWebView: WKWebView {
        var maximums: [NSSize] = []

        @objc(_setSizeToContentAutoSizeMaximumSize:) func recordMaximum(_ size: NSSize) {
            maximums.append(size)
        }
    }

    private let off = NSSize.zero
    private let on = ExtensionPopoverController.webKitSizeToContentMaximum
    private let closed = Notification(name: NSPopover.didCloseNotification)

    private func makeWebView() -> RecordingWebView {
        RecordingWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 600), configuration: WKWebViewConfiguration())
    }

    func testTheModeIsSwitchedOncePerChange() {
        let webView = makeWebView()
        let controller = ExtensionPopoverController(extensionID: "scroll-state")
        controller.presentPopupWebView(webView)
        XCTAssertFalse(ExtensionPopoverController.isPageScrolling(webView))

        controller.setPageScrolls(true, in: webView)
        controller.setPageScrolls(true, in: webView)
        XCTAssertEqual(webView.maximums, [off], "switching on twice touches WebKit once")
        XCTAssertTrue(ExtensionPopoverController.isPageScrolling(webView))

        controller.setPageScrolls(false, in: webView)
        controller.setPageScrolls(false, in: webView)
        XCTAssertEqual(webView.maximums, [off, on])
        XCTAssertFalse(ExtensionPopoverController.isPageScrolling(webView))
    }

    /// The controller whose popover closes gives the view's layout back to
    /// WebKit, for the next presentation.
    func testClosingThePopoverRestoresWebKitsMode() {
        let webView = makeWebView()
        let controller = ExtensionPopoverController(extensionID: "scroll-state")
        controller.presentPopupWebView(webView)
        controller.setPageScrolls(true, in: webView)

        controller.popoverDidClose(closed)
        XCTAssertEqual(webView.maximums, [off, on])
        XCTAssertFalse(ExtensionPopoverController.isPageScrolling(webView))
    }

    /// Re-clicking the toolbar button while a tall popup is open: a second
    /// controller presents the same web view, and the first one's popover
    /// closes afterwards. NEGATIVE: that late close must not switch the mode
    /// back under the controller now showing the view.
    func testAControllerThatLostTheViewDoesNotRestoreItsModeOnClose() {
        let webView = makeWebView()
        let first = ExtensionPopoverController(extensionID: "scroll-state")
        first.presentPopupWebView(webView)
        first.setPageScrolls(true, in: webView)

        let second = ExtensionPopoverController(extensionID: "scroll-state")
        second.presentPopupWebView(webView)
        XCTAssertTrue(webView.uiDelegate === second)

        first.popoverDidClose(closed)
        XCTAssertEqual(webView.maximums, [off], "the first controller no longer owns the view")
        XCTAssertTrue(ExtensionPopoverController.isPageScrolling(webView))
    }

    /// The state is the view's: a controller that takes over a view its
    /// predecessor left scrolling knows it scrolls — it does not switch it off
    /// "again" for nothing, and it is the one that restores WebKit's mode,
    /// whether or not the predecessor ever got its close callback.
    func testAControllerTakingOverAScrollingViewStartsFromTheViewsMode() {
        let webView = makeWebView()
        let first = ExtensionPopoverController(extensionID: "scroll-state")
        first.presentPopupWebView(webView)
        first.setPageScrolls(true, in: webView)

        // The first controller goes away without a close callback.
        let second = ExtensionPopoverController(extensionID: "scroll-state")
        second.presentPopupWebView(webView)
        second.setPageScrolls(true, in: webView)
        XCTAssertEqual(webView.maximums, [off], "already scrolling: nothing to switch")

        // The reloaded page fits: the second controller restores WebKit's mode.
        second.setPageScrolls(false, in: webView)
        XCTAssertEqual(webView.maximums, [off, on])
        XCTAssertFalse(ExtensionPopoverController.isPageScrolling(webView))

        // And when it was left scrolling instead, its own close restores it.
        second.setPageScrolls(true, in: webView)
        second.popoverDidClose(closed)
        XCTAssertEqual(webView.maximums, [off, on, off, on])
    }

    /// NEGATIVE: one view's mode says nothing about another's.
    func testTheStateIsPerWebView() {
        let scrolling = makeWebView()
        let other = makeWebView()
        let controller = ExtensionPopoverController(extensionID: "scroll-state")
        controller.presentPopupWebView(scrolling)
        controller.setPageScrolls(true, in: scrolling)
        XCTAssertTrue(ExtensionPopoverController.isPageScrolling(scrolling))
        XCTAssertFalse(ExtensionPopoverController.isPageScrolling(other))
        controller.setPageScrolls(false, in: other)
        XCTAssertEqual(other.maximums, [], "a view that never scrolled is not touched")
        controller.setPageScrolls(false, in: scrolling)
    }
}

/// TASK-150: what the measure script reports, in a real web view held to the
/// popover's 600 pt — the state a popup is in while its page scrolls.
@MainActor
final class ExtensionPopoverMeasureScriptTests: XCTestCase {

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        window = nil
        try await super.tearDown()
    }

    /// Loads `html` in a 300 x 600 web view and returns the measurement.
    private func measure(_ html: String) async throws -> [String: Any] {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 600), configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(webView)
        self.window = window
        try await loadHTMLStringAndWait(webView, html: html, baseURL: nil)
        let raw = try await webView.callAsyncJavaScript(
            ExtensionPopoverController.measureFnJS + """

            const measured = window.__detourMeasureBody();
            measured.innerHeight = window.innerHeight;
            measured.documentHeight = document.documentElement.scrollHeight;
            measured.bodyHeight = Math.max(document.body.offsetHeight, document.body.scrollHeight);
            return JSON.stringify(measured);
            """, arguments: [:], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String)
        let measured = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(measured["innerHeight"] as? Int, 600, "the fixture view is the popover's height")
        return measured
    }

    private func page(_ style: String, _ body: String) -> String {
        "<!DOCTYPE html><html><head><style>* { margin: 0; padding: 0; } \(style)</style></head><body>\(body)</body></html>"
    }

    private func scrolls(_ measured: [String: Any], scrollingNow: Bool) -> Bool? {
        ExtensionPopoverController.sizing(fromMeasurement: measured, pageScrollsNow: scrollingNow)?.pageScrolls
    }

    /// A document taller than its body — padding on <html> — at just over the
    /// popover's height: scrolling must be decided on the document in both
    /// modes. Decided on the body alone, the popup would switch scrolling on
    /// (document 610) and straight off again (body 590), bottom out of reach.
    func testADocumentTallerThanItsBodyKeepsScrolling() async throws {
        let measured = try await measure(page("html { padding-bottom: 20px; } #content { height: 590px; }",
                                              "<div id=\"content\"></div>"))
        XCTAssertEqual(measured["bodyHeight"] as? Int, 590)
        XCTAssertEqual(measured["documentHeight"] as? Int, 610)
        XCTAssertEqual(measured["height"] as? Int, 610)
        XCTAssertEqual(measured["contentHeight"] as? Int, 610, "the content is as tall as the document, not the body")
        XCTAssertEqual(scrolls(measured, scrollingNow: false), true)
        XCTAssertEqual(scrolls(measured, scrollingNow: true), true, "both modes must agree, or the popup alternates")
    }

    /// The same with an absolutely positioned footer below the body's box.
    func testAnAbsolutelyPositionedFooterBelowTheBodyKeepsScrolling() async throws {
        let measured = try await measure(page(
            "#content { height: 580px; } #footer { position: absolute; top: 585px; left: 0; height: 30px; width: 100px; }",
            "<div id=\"content\"></div><button id=\"footer\">footer</button>"))
        XCTAssertEqual(measured["bodyHeight"] as? Int, 580)
        XCTAssertEqual(measured["documentHeight"] as? Int, 615)
        XCTAssertEqual(measured["contentHeight"] as? Int, 615)
        XCTAssertEqual(scrolls(measured, scrollingNow: false), true)
        XCTAssertEqual(scrolls(measured, scrollingNow: true), true)
    }

    /// Still true: content that shrank back is seen through the body's height,
    /// because the document is stretched to the 600 pt view.
    func testContentShorterThanTheViewIsMeasuredByTheBody() async throws {
        let measured = try await measure(page("#content { height: 180px; }", "<div id=\"content\"></div>"))
        XCTAssertEqual(measured["documentHeight"] as? Int, 600, "the document is stretched to the view")
        XCTAssertEqual(measured["height"] as? Int, 600)
        XCTAssertEqual(measured["contentHeight"] as? Int, 180)
        XCTAssertEqual(scrolls(measured, scrollingNow: true), false, "a scrolling popup that shrank is WebKit's again")
        XCTAssertEqual(ExtensionPopoverController.sizing(fromMeasurement: measured, pageScrollsNow: true)?.popoverSize.height, 180)
    }

    /// Still true: a body sized to the viewport reports the view's own height
    /// and keeps a scrolling popup scrolling, rather than alternating.
    func testAViewportSizedBodyKeepsAScrollingPopupScrolling() async throws {
        let measured = try await measure(page("body { height: 100vh; }", "<p>fills the view</p>"))
        XCTAssertEqual(measured["contentHeight"] as? Int, 600)
        XCTAssertEqual(scrolls(measured, scrollingNow: true), true)
        XCTAssertEqual(scrolls(measured, scrollingNow: false), false, "as opened it simply fits")
    }

    func testATallBodyIsMeasuredAtItsFullHeight() async throws {
        let measured = try await measure(page("#content { height: 2000px; }", "<div id=\"content\"></div>"))
        XCTAssertEqual(measured["height"] as? Int, 2000)
        XCTAssertEqual(measured["contentHeight"] as? Int, 2000)
        XCTAssertEqual(scrolls(measured, scrollingNow: true), true)
    }
}
