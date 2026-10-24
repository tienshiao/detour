import XCTest
import AppKit
@testable import Detour

/// TASK-186.2: the dev toolbar sits above the web view inside the tab's
/// container, laid out by frames so WebKit's docked Web Inspector keeps
/// working. The geometry is `DevToolbarLayout`; the container applies it.
final class DevToolbarLayoutTests: XCTestCase {

    private let container = NSRect(x: 0, y: 0, width: 800, height: 600)
    private let h = DevToolbarLayout.height

    private func frames(_ webView: NSRect, shows: Bool, in bounds: NSRect? = nil) -> DevToolbarLayout.Frames {
        DevToolbarLayout.frames(containerBounds: bounds ?? container, webViewFrame: webView,
                                toolbarHeight: h, showsToolbar: shows)
    }

    // MARK: - The pure layout

    func testWithoutAnInspectorTheToolbarTakesTheTopAndTheWebViewTheRest() {
        let result = frames(container, shows: true)
        XCTAssertEqual(result.webView, NSRect(x: 0, y: 0, width: 800, height: 600 - h))
        XCTAssertEqual(result.toolbar, NSRect(x: 0, y: 600 - h, width: 800, height: h))
    }

    func testHiddenTheWebViewFillsTheContainerAndThereIsNoToolbar() {
        let result = frames(container, shows: false)
        XCTAssertEqual(result.webView, container)
        XCTAssertNil(result.toolbar)
    }

    func testABottomDockedInspectorKeepsItsHeight() {
        // The inspector takes the bottom 200 pt; the web view starts above it.
        let docked = NSRect(x: 0, y: 200, width: 800, height: 400)
        let result = frames(docked, shows: true)
        XCTAssertEqual(result.webView, NSRect(x: 0, y: 200, width: 800, height: 400 - h))
        XCTAssertEqual(result.toolbar, NSRect(x: 0, y: 600 - h, width: 800, height: h))
    }

    func testARightDockedInspectorNarrowsTheToolbarWithTheWebView() {
        // A side-docked inspector spans the container's full height.
        let docked = NSRect(x: 0, y: 0, width: 500, height: 600)
        let result = frames(docked, shows: true)
        XCTAssertEqual(result.webView, NSRect(x: 0, y: 0, width: 500, height: 600 - h))
        XCTAssertEqual(result.toolbar, NSRect(x: 0, y: 600 - h, width: 500, height: h))
    }

    func testALeftDockedInspectorMovesTheToolbarWithTheWebView() {
        let docked = NSRect(x: 300, y: 0, width: 500, height: 600)
        let result = frames(docked, shows: true)
        XCTAssertEqual(result.webView, NSRect(x: 300, y: 0, width: 500, height: 600 - h))
        XCTAssertEqual(result.toolbar, NSRect(x: 300, y: 600 - h, width: 500, height: h))
    }

    func testTogglingOnThenOffReturnsTheOriginalFrame() {
        for original in [container,
                         NSRect(x: 0, y: 200, width: 800, height: 400),
                         NSRect(x: 0, y: 0, width: 500, height: 600),
                         NSRect(x: 300, y: 0, width: 500, height: 600)] {
            let on = frames(original, shows: true)
            let off = frames(on.webView, shows: false)
            XCTAssertEqual(off.webView, original, "on then off for \(original)")
            XCTAssertNil(off.toolbar)
            // Showing twice is the same as showing once.
            XCTAssertEqual(frames(on.webView, shows: true), on, "idempotent for \(original)")
        }
    }

    func testAContainerResizeKeepsTheToolbarAtTheNewTop() {
        let bigger = NSRect(x: 0, y: 0, width: 1000, height: 700)
        // Autoresizing keeps the web view's margins, so it grows under the toolbar.
        let grown = NSRect(x: 0, y: 0, width: 1000, height: 700 - h)
        let result = frames(grown, shows: true, in: bigger)
        XCTAssertEqual(result.webView, grown)
        XCTAssertEqual(result.toolbar, NSRect(x: 0, y: 700 - h, width: 1000, height: h))
    }

    func testAWebViewThatLostItsGapIsPushedBackUnderTheToolbar() {
        // A container that grew from zero size autoresizes the web view to its
        // full height; the layout restores the toolbar's space.
        let bigger = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let result = frames(bigger, shows: true, in: bigger)
        XCTAssertEqual(result.webView, NSRect(x: 0, y: 0, width: 1000, height: 700 - h))
        XCTAssertEqual(result.toolbar, NSRect(x: 0, y: 700 - h, width: 1000, height: h))
    }

    func testAContainerShorterThanTheToolbarGivesTheWebViewNoHeight() {
        let tiny = NSRect(x: 0, y: 0, width: 300, height: 20)
        let result = frames(tiny, shows: true, in: tiny)
        XCTAssertEqual(result.webView.height, 0)
        XCTAssertEqual(result.webView.minY, 0)
        XCTAssertEqual(result.toolbar, NSRect(x: 0, y: 20 - h, width: 300, height: h))
    }

    func testTheToolbarTracksTheWebViewFrameWebKitSets() {
        // WebKit re-frames the web view when the inspector docks on the right.
        let docked = NSRect(x: 0, y: 0, width: 520, height: 600 - h)
        XCTAssertEqual(DevToolbarLayout.toolbarFrame(containerBounds: container, webViewFrame: docked, toolbarHeight: h),
                       NSRect(x: 0, y: 600 - h, width: 520, height: h))
        let bottomDocked = NSRect(x: 0, y: 180, width: 800, height: 600 - h - 180)
        XCTAssertEqual(DevToolbarLayout.toolbarFrame(containerBounds: container, webViewFrame: bottomDocked, toolbarHeight: h),
                       NSRect(x: 0, y: 600 - h, width: 800, height: h))
    }

    // MARK: - The container applying it

    private func makeContainer() -> (WebViewContainerView, NSView) {
        let container = WebViewContainerView(frame: container)
        container.autoresizingMask = [.width, .height]
        let webView = NSView(frame: container.bounds)
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        container.hostedWebView = webView
        return (container, webView)
    }

    func testTheContainerShowsTheToolbarAboveTheWebView() throws {
        let (container, webView) = makeContainer()
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/app"))

        XCTAssertTrue(container.isShowingDevToolbar)
        let toolbar = try XCTUnwrap(container.devToolbar)
        XCTAssertTrue(toolbar.superview === container)
        XCTAssertEqual(webView.frame, NSRect(x: 0, y: 0, width: 800, height: 600 - h))
        XCTAssertEqual(toolbar.frame, NSRect(x: 0, y: 600 - h, width: 800, height: h))
        XCTAssertEqual(toolbar.urlButton.title, "http://localhost:3000/app")
    }

    func testHidingTheToolbarGivesTheWebViewTheWholeContainerBack() throws {
        let (container, webView) = makeContainer()
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/"))
        container.updateDevToolbar(shown: false, url: URL(string: "https://example.com/"))

        XCTAssertFalse(container.isShowingDevToolbar)
        XCTAssertEqual(webView.frame, container.bounds)
        XCTAssertTrue(try XCTUnwrap(container.devToolbar).isHidden)
    }

    func testAContainerWithoutTheToolbarIsUntouched() {
        let (container, webView) = makeContainer()
        container.updateDevToolbar(shown: false, url: URL(string: "https://example.com/"))
        XCTAssertNil(container.devToolbar, "no toolbar is made for a page that never needs one")
        XCTAssertEqual(webView.frame, container.bounds)
    }

    func testTheToolbarFollowsTheWebViewWhenSomethingElseReframesIt() throws {
        let (container, webView) = makeContainer()
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/"))
        // What WebKit does when the inspector docks on the right.
        webView.frame = NSRect(x: 0, y: 0, width: 450, height: 600 - h)
        XCTAssertEqual(try XCTUnwrap(container.devToolbar).frame, NSRect(x: 0, y: 600 - h, width: 450, height: h))
    }

    func testTheToolbarStaysAtTheTopWhenTheContainerResizes() throws {
        let (container, webView) = makeContainer()
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/"))
        container.setFrameSize(NSSize(width: 1000, height: 700))
        XCTAssertEqual(webView.frame, NSRect(x: 0, y: 0, width: 1000, height: 700 - h))
        XCTAssertEqual(try XCTUnwrap(container.devToolbar).frame, NSRect(x: 0, y: 700 - h, width: 1000, height: h))
    }

    func testAToolbarShownInAZeroSizedContainerKeepsItsSpaceOnceSized() throws {
        let container = WebViewContainerView()
        container.autoresizingMask = [.width, .height]
        let webView = NSView(frame: .zero)
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        container.hostedWebView = webView
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/"))

        container.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        XCTAssertEqual(webView.frame, NSRect(x: 0, y: 0, width: 640, height: 480 - h))
        XCTAssertEqual(try XCTUnwrap(container.devToolbar).frame, NSRect(x: 0, y: 480 - h, width: 640, height: h))
    }

    func testRoundedPanesRoundOnlyTheOuterCornersWhileTheToolbarShows() throws {
        let (container, webView) = makeContainer()
        container.contentCornerRadius = 8
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/"))
        let toolbar = try XCTUnwrap(container.devToolbar)
        XCTAssertEqual(toolbar.layer?.maskedCorners, DevToolbarLayout.topCorners)
        XCTAssertEqual(webView.layer?.maskedCorners, DevToolbarLayout.bottomCorners)
        XCTAssertEqual(webView.layer?.cornerRadius, 8)

        container.updateDevToolbar(shown: false, url: URL(string: "https://example.com/"))
        XCTAssertEqual(webView.layer?.maskedCorners, DevToolbarLayout.allCorners, "all corners again without the toolbar")
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// `WKWebView` is flipped, so its layer's `MaxY` edge is its bottom: the
    /// page's bottom corners are the `MaxY` ones, wherever the pane is hosted.
    func testAFlippedWebViewRoundsItsVisualBottomCorners() throws {
        let container = WebViewContainerView(frame: container)
        let webView = FlippedView(frame: container.bounds)
        container.addSubview(webView)
        container.hostedWebView = webView
        container.contentCornerRadius = 8
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/"))
        XCTAssertEqual(webView.layer?.maskedCorners, DevToolbarLayout.topCorners, "MaxY corners: the bottom of a flipped view")
        XCTAssertEqual(try XCTUnwrap(container.devToolbar).layer?.maskedCorners, DevToolbarLayout.topCorners)

        // Re-hosting (radius off, then on, as a split pane is) keeps it.
        container.contentCornerRadius = 0
        container.contentCornerRadius = 16
        XCTAssertEqual(webView.layer?.maskedCorners, DevToolbarLayout.topCorners)
    }

    func testTheURLLabelFollowsTheURL() throws {
        let (container, _) = makeContainer()
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/a"))
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/b?q=1"))
        XCTAssertEqual(try XCTUnwrap(container.devToolbar).urlButton.title, "http://localhost:3000/b?q=1")
    }

    func testEveryToolbarButtonHasAnAccessibilityLabel() throws {
        let (container, _) = makeContainer()
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/"))
        let toolbar = try XCTUnwrap(container.devToolbar)
        XCTAssertEqual(toolbar.infoButton.accessibilityLabel(), "Site Settings")
        XCTAssertEqual(toolbar.copyButton.accessibilityLabel(), "Copy URL")
        XCTAssertFalse(toolbar.urlButton.accessibilityLabel()?.isEmpty ?? true)
    }

    func testATrailingGroupIsAddedAfterTheCopyButton() throws {
        let (container, _) = makeContainer()
        container.updateDevToolbar(shown: true, url: URL(string: "http://localhost:3000/"))
        let toolbar = try XCTUnwrap(container.devToolbar)
        let capture = NSButton(title: "C", target: nil, action: nil)
        toolbar.addTrailingGroup([capture])
        let views = toolbar.trailingStack.arrangedSubviews
        XCTAssertEqual(views.first, toolbar.copyButton)
        XCTAssertEqual(views.last, capture)
        XCTAssertEqual(views.count, 3, "copy, a separator, then the group")
    }
}
