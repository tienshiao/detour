import XCTest
import WebKit
@testable import Detour

/// The Quick Detour window (TASK-193.1): it starts with the palette, Return
/// loads in its one web view, dismissing an empty palette closes it, the host
/// reopens the palette in place, and closing tears its page down with nothing
/// left behind in the store, the extension registry or memory.
///
/// Real windows on `TabStore.shared`, with a profile of the test's own; pages
/// from a loopback server.
@MainActor
final class QuickDetourWindowTests: XCTestCase {

    private var controllers: [QuickDetourWindowController] = []
    private var createdProfiles: [Profile] = []
    private var servers: [LoopbackHTTPServer] = []
    private static var retainedProfiles: [Profile] = []

    override func tearDown() async throws {
        for controller in controllers { controller.close() }
        controllers.removeAll()
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        try await super.tearDown()
    }

    private func makeProfile() -> Profile {
        let profile = TabStore.shared.addProfile(name: "Quick Detour Window \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        return profile
    }

    /// A Quick Detour opened as the launcher opens one: already on a page
    /// (an `.invalid` host by default, which never reaches the network).
    private func open(_ profile: Profile,
                      url: URL = URL(string: "https://quick-detour.invalid/")!) -> QuickDetourWindowController {
        let controller = QuickDetourWindowController.open(profile: profile, url: url)
        controllers.append(controller)
        return controller
    }

    private func serve(_ routes: [String: String] = [:]) async throws -> URL {
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>First</title></head><body><a id=next href=/next>next</a></body></html>",
            "/next": "<html><head><title>Second</title></head><body>second</body></html>",
        ].merging(routes) { $1 })
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    private func waitForTitle(_ title: String, in controller: QuickDetourWindowController) async throws {
        let tab = try XCTUnwrap(controller.tab)
        try await waitUntil("the page titled \(title)") { tab.title == title && !tab.isLoading }
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Opening

    func testItOpensOnThePageWithNoPalette() throws {
        let profile = makeProfile()
        let url = URL(string: "https://quick-detour.invalid/start")!
        let controller = open(profile, url: url)

        XCTAssertNil(controller.commandPaletteView, "the launcher panel did the asking")
        XCTAssertEqual(controller.tab?.url, url, "never an empty page")
        for _ in 0..<20 where controller.titleBar.hostButton.title != "quick-detour.invalid" { spin() }
        XCTAssertEqual(controller.titleBar.hostButton.title, "quick-detour.invalid")
        XCTAssertTrue(QuickDetourWindowController.openControllers.contains { $0 === controller })
        XCTAssertTrue(controller.tab?.quickDetourProfile === profile)
        XCTAssertEqual(controller.window?.level, .normal, "a normal window, like Little Arc")
    }

    func testTheWindowLoadsInItsOneWebView() async throws {
        let url = try await serve()
        let controller = open(makeProfile(), url: url)
        let webView = controller.tab?.webView

        try await waitForTitle("First", in: controller)
        XCTAssertTrue(controller.tab?.webView === webView, "the same web view: one page per window")
        XCTAssertEqual(controller.titleBar.hostButton.title, "127.0.0.1")
        XCTAssertEqual(controller.window?.title, "First")
    }

    /// The host's palette, as the launcher's: no open tabs, the profile's
    /// Quick Detour history (opened from no space).
    func testTheHostPaletteIsTheProfiles() throws {
        let profile = makeProfile()
        let controller = open(profile)

        controller.titleBar.hostButton.performClick(nil)

        let palette = try XCTUnwrap(controller.commandPaletteView)
        XCTAssertTrue(palette.profile === profile)
        XCTAssertNil(palette.tabStore, "no other window's tabs are offered")
        XCTAssertEqual(palette.activeSpaceID, QuickDetour.historySpaceID(forProfileID: profile.id))
    }

    func testDismissingTheHostPaletteKeepsTheWindow() async throws {
        let url = try await serve()
        let controller = open(makeProfile(), url: url)
        try await waitForTitle("First", in: controller)

        controller.titleBar.hostButton.performClick(nil)
        let palette = try XCTUnwrap(controller.commandPaletteView, "the host reopens the palette")
        palette.dismiss()

        XCTAssertNil(controller.commandPaletteView)
        XCTAssertTrue(QuickDetourWindowController.openControllers.contains { $0 === controller })
        XCTAssertNotNil(controller.tab)
    }

    func testASearchFromTheHostPaletteUsesTheProfilesEngine() throws {
        let profile = makeProfile()
        let controller = open(profile)
        controller.titleBar.hostButton.performClick(nil)
        let palette = try XCTUnwrap(controller.commandPaletteView)

        controller.commandPalette(palette, didSubmitInput: "quick lookup words")

        XCTAssertEqual(controller.tab?.url, profile.searchEngine.searchURL(for: "quick lookup words"))
    }

    /// Clicking the host reopens the palette with the page's URL, and what is
    /// submitted navigates the same page in place.
    func testTheHostReopensThePaletteNavigatingInPlace() async throws {
        let url = try await serve()
        let controller = open(makeProfile(), url: url)
        try await waitForTitle("First", in: controller)
        let tab = try XCTUnwrap(controller.tab)

        controller.titleBar.hostButton.performClick(nil)
        let palette = try XCTUnwrap(controller.commandPaletteView)
        XCTAssertEqual(palette.currentTabID, controller.tabID)
        controller.commandPalette(palette, didSubmitInput: url.appendingPathComponent("next").absoluteString)

        try await waitForTitle("Second", in: controller)
        XCTAssertTrue(controller.tab === tab, "in place")
        XCTAssertEqual(QuickDetourWindowController.openControllers.filter { $0.profile === controller.profile }.count, 1)
        XCTAssertTrue(tab.canGoBack, "back to the first page")
    }

    // MARK: - Actions

    func testBackForwardReloadZoomAndFind() async throws {
        let controller = open(makeProfile())
        let url = try await serve()
        controller.load(url, typed: true)
        try await waitForTitle("First", in: controller)
        controller.load(url.appendingPathComponent("next"), typed: true)
        try await waitForTitle("Second", in: controller)

        controller.goBack(nil)
        try await waitForTitle("First", in: controller)
        controller.goForward(nil)
        try await waitForTitle("Second", in: controller)

        let webView = try XCTUnwrap(controller.tab?.webView)
        controller.zoomIn(nil)
        XCTAssertEqual(webView.pageZoom, 1.1, accuracy: 0.001)
        controller.zoomActualSize(nil)
        XCTAssertEqual(webView.pageZoom, 1.0, accuracy: 0.001)

        controller.showFindBar(nil)
        XCTAssertFalse(controller.findBar.isHidden)
        controller.dismissFindBar(nil)

        let item = NSMenuItem(title: "Back", action: #selector(QuickDetourWindowController.goBack(_:)),
                              keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(item))
    }

    /// Cmd+Z in the page is the page's: the browser undo stack belongs to the
    /// browser windows, and undoing a tab close from here would act on a
    /// window the user is not looking at.
    func testCmdZDoesNotUndoABrowserAction() throws {
        let controller = open(makeProfile())
        let webView = try XCTUnwrap(controller.tab?.webView as? BrowserWebView)
        let undoManager = TabStore.shared.undoManager
        var undone = false
        undoManager.removeAllActions()
        undoManager.registerUndo(withTarget: self) { _ in undone = true }
        defer { undoManager.removeAllActions() }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: controller.window?.windowNumber ?? 0, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))

        _ = webView.performKeyEquivalent(with: event)

        XCTAssertFalse(undone)
        XCTAssertTrue(undoManager.canUndo)
    }

    func testCopyLinkCopiesThePageURL() async throws {
        let controller = open(makeProfile())
        let url = try await serve()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-detour-test-\(UUID().uuidString)"))
        controller.urlPasteboard = pasteboard
        controller.load(url, typed: true)
        try await waitForTitle("First", in: controller)

        controller.titleBar.copyButton.performClick(nil)

        XCTAssertEqual(pasteboard.string(forType: .string), url.absoluteString)
        pasteboard.releaseGlobally()
    }

    func testCloseTabClosesTheWindow() throws {
        let controller = open(makeProfile())
        let tabID = controller.tabID

        controller.closeCurrentTab(nil)

        XCTAssertNil(TabStore.shared.quickDetourTab(withID: tabID))
        XCTAssertFalse(QuickDetourWindowController.openControllers.contains { $0 === controller })
    }

    // MARK: - Several windows, and closing from outside

    func testTwoWindowsAreIndependent() async throws {
        let profile = makeProfile()
        let first = open(profile)
        let second = open(profile)
        XCTAssertNotEqual(first.tabID, second.tabID)
        XCTAssertFalse(first.tab?.webView === second.tab?.webView)
        XCTAssertNotEqual(first.window?.frame.origin, second.window?.frame.origin, "cascaded")

        first.close()

        XCTAssertNil(TabStore.shared.quickDetourTab(withID: first.tabID))
        XCTAssertNotNil(second.tab?.webView)
        XCTAssertTrue(QuickDetourWindowController.openControllers.contains { $0 === second })
    }

    /// An extension's `tabs.remove`, or the profile being deleted, closes the
    /// page from the store: the window goes with it.
    func testClosingThePageFromTheStoreClosesTheWindow() throws {
        let controller = open(makeProfile())
        let tab = try XCTUnwrap(controller.tab)

        TabStore.shared.closeQuickDetourTab(tab)

        XCTAssertFalse(QuickDetourWindowController.openControllers.contains { $0 === controller })
        XCTAssertFalse(controller.window?.isVisible ?? false)
    }

    /// A window the page opens is another Quick Detour, holding the very web
    /// view WebKit asked for, on the same profile.
    func testAWindowThePageOpensIsAnotherQuickDetour() throws {
        let profile = makeProfile()
        let controller = open(profile)
        let opener = try XCTUnwrap(controller.tab?.webView)
        let before = QuickDetourWindowController.openControllers.count

        let config = opener.configuration.copy() as! WKWebViewConfiguration
        let child = controller.webView(opener, createWebViewWith: config,
                                       for: NavigationActionStub(url: URL(string: "https://example.com/")!),
                                       windowFeatures: WKWindowFeatures())

        XCTAssertEqual(QuickDetourWindowController.openControllers.count, before + 1)
        let childController = try XCTUnwrap(QuickDetourWindowController.openControllers.last)
        controllers.append(childController)
        XCTAssertTrue(childController.tab?.webView === child)
        XCTAssertTrue(childController.profile === profile)
        XCTAssertNil(childController.commandPaletteView, "it shows the page it was opened for")
    }

    // MARK: - Extensions and the space-walking lookups

    func testExtensionsFindTheWindowThroughItsTab() throws {
        let controller = open(makeProfile())
        let tab = try XCTUnwrap(controller.tab)

        XCTAssertTrue(tab.extensionWindow() === controller)
        XCTAssertTrue(extensionListedWindows().contains { $0 === controller })
        XCTAssertEqual(controller.extensionTabs.map(\.id), [tab.id])
        XCTAssertTrue(controller.extensionActiveTab === tab)
        XCTAssertEqual(controller.extensionProfileID, controller.profile.id)
        XCTAssertTrue(TabStore.shared.tab(hosting: try XCTUnwrap(tab.webView)) === tab)
    }

    /// Nothing is left holding a closed window or its page.
    func testClosingLeavesNothingBehind() throws {
        weak var weakController: QuickDetourWindowController?
        weak var weakTab: BrowserTab?
        weak var weakWebView: WKWebView?
        autoreleasepool {
            let controller = QuickDetourWindowController.open(
                profile: makeProfile(), url: URL(string: "https://quick-detour.invalid/")!)
            weakController = controller
            weakTab = controller.tab
            weakWebView = controller.tab?.webView
            controller.close()
        }
        for _ in 0..<20 where weakController != nil || weakTab != nil || weakWebView != nil { spin() }
        XCTAssertNil(weakController, "the window controller is released")
        XCTAssertNil(weakTab, "the tab is released")
        XCTAssertNil(weakWebView, "the web view is released")
    }
}

/// A `WKNavigationAction` for a `createWebViewWith` call made by hand.
private final class NavigationActionStub: WKNavigationAction {
    private let stubRequest: URLRequest
    init(url: URL) {
        stubRequest = URLRequest(url: url)
        super.init()
    }
    override var request: URLRequest { stubRequest }
    override var navigationType: WKNavigationType { .other }
}
