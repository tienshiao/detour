import XCTest
import WebKit
@testable import Detour

/// TASK-135: when a window takes a tab's web view over from another window
/// showing the same tab, the page gets keyboard focus unless a control in that
/// window holds it (the TASK-128 rule), and the window that lost the web view
/// keeps no first responder outside itself.
@MainActor
final class WebViewHandoffFocusTests: XCTestCase {

    private var controllers: [BrowserWindowController] = []
    private var createdSpaceIDs: [UUID] = []
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?

    override func setUp() {
        super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
    }

    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers.removeAll()
        for id in createdSpaceIDs { TabStore.shared.deleteSpace(id: id) }
        createdSpaceIDs.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        super.tearDown()
    }

    /// Two regular windows on one fresh space with the same tab selected. The
    /// first hosts the web view; the second was shown while the first had it,
    /// so it displays the snapshot.
    private func makeWindows() throws -> (first: BrowserWindowController, second: BrowserWindowController, tab: BrowserTab) {
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Handoff", emoji: "H", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        let tab = store.addTab(in: space, url: URL(string: "https://handoff.example.com/"))

        let first = makeController(on: space, selecting: tab)
        becomeKey(first)
        let second = makeController(on: space, selecting: tab)
        // Whether showing the second window made it key depends on the test
        // host being the active app; put the web view back in the first so
        // every test starts from the same place.
        becomeKey(first)
        XCTAssertTrue(tab.webView?.window === first.window, "the first window hosts the web view")
        return (first, second, tab)
    }

    private func makeController(on space: Space, selecting tab: BrowserTab) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        controllers.append(wc)
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id)
        wc.selectTab(id: tab.id)
        wc.showWindow(nil)
        return wc
    }

    /// What AppKit tells the window's delegate when the user switches to it.
    private func becomeKey(_ wc: BrowserWindowController) {
        wc.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: wc.window))
    }

    func testTheWindowTakingOverTheWebViewFocusesThePage() throws {
        let (first, second, tab) = try makeWindows()
        XCTAssertFalse(second.window?.firstResponder === tab.webView)

        becomeKey(second)

        XCTAssertTrue(tab.webView?.window === second.window, "the second window took the web view over")
        XCTAssertTrue(second.window?.firstResponder === tab.webView,
                      "the page takes keys without a click, got \(String(describing: second.window?.firstResponder))")
        _ = first
    }

    func testTheWindowLosingTheWebViewKeepsNoStaleFirstResponder() throws {
        let (first, second, tab) = try makeWindows()
        XCTAssertTrue(first.window?.firstResponder === tab.webView, "the hosting window's page has focus")

        becomeKey(second)

        let responder = try XCTUnwrap(first.window?.firstResponder)
        XCTAssertFalse(responder === tab.webView, "the web view now lives in the other window")
        if let view = responder as? NSView {
            XCTAssertTrue(view.window === first.window, "a first responder outside the window: \(view)")
        } else {
            XCTAssertTrue(responder === first.window)
        }
        XCTAssertFalse(tab.webViewContainer?.isDescendant(of: try XCTUnwrap(first.window?.contentView)) ?? false,
                       "the losing window shows its snapshot, not the web view")
    }

    func testSwitchingBackFocusesThePageAgain() throws {
        let (first, second, tab) = try makeWindows()
        becomeKey(second)
        becomeKey(first)

        XCTAssertTrue(tab.webView?.window === first.window)
        XCTAssertTrue(first.window?.firstResponder === tab.webView)
        XCTAssertFalse(second.window?.firstResponder === tab.webView)
    }

    /// Focus a control in the window holds stays where it is.
    func testFocusHeldByAControlInTheWindowIsLeftAlone() throws {
        let (_, second, tab) = try makeWindows()
        let window = try XCTUnwrap(second.window)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        try XCTUnwrap(window.contentView).addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let held = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(held === field || held.isDescendant(of: field))

        becomeKey(second)

        XCTAssertTrue(tab.webView?.window === window, "the web view is still taken over")
        XCTAssertTrue(window.firstResponder === held, "the control keeps the keyboard")
    }

    func testAnOpenPaletteKeepsTheKeyboard() throws {
        let (_, second, tab) = try makeWindows()
        let window = try XCTUnwrap(second.window)
        second.focusAddressBar(nil)
        XCTAssertNotNil(second.commandPaletteView)
        let held = try XCTUnwrap(window.firstResponder)
        XCTAssertFalse(held === tab.webView)
        XCTAssertFalse(held === window, "the palette's field holds focus while shown")

        becomeKey(second)

        XCTAssertNotNil(second.commandPaletteView)
        XCTAssertTrue(window.firstResponder === held, "the palette keeps the keyboard")
    }

    /// The other hand-off: a window that is acted on while another one hosts
    /// its tab's web view claims it without becoming key.
    func testEnsureOwnsWebViewFocusesThePage() throws {
        let (_, second, tab) = try makeWindows()

        second.ensureOwnsWebView()

        XCTAssertTrue(tab.webView?.window === second.window)
        XCTAssertTrue(second.window?.firstResponder === tab.webView)
    }

    /// Becoming key again with the web view already here (a popover closed,
    /// the app was reactivated) and nothing holding the keyboard also leaves
    /// it with the page rather than with nothing.
    func testBecomingKeyWithNothingFocusedFocusesTheHostedPage() throws {
        let (first, _, tab) = try makeWindows()
        let window = try XCTUnwrap(first.window)
        window.makeFirstResponder(nil)
        XCTAssertTrue(window.firstResponder === window)

        becomeKey(first)

        XCTAssertTrue(window.firstResponder === tab.webView)
    }
}
