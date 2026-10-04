import XCTest
import WebKit
@testable import Detour

/// A top-level `data:` URL the browser itself loads (a tab created with it, a
/// URL typed into the selected tab) loads the same whether the tab is in the
/// background or on screen (TASK-159).
///
/// The difference between the two is the navigation delegate: a background
/// tab is its own, a selected tab's web view is claimed by the window, whose
/// policy hands non-web schemes to external applications. These tests host a
/// real `BrowserWindowController`, so the policy that decides is the window's.
@MainActor
final class DataURLTabTests: XCTestCase {

    private var controllers: [BrowserWindowController] = []
    private var createdSpaceIDs: [UUID] = []
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    override func setUp() {
        super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers.removeAll()
        for id in createdSpaceIDs { TabStore.shared.deleteSpace(id: id) }
        createdSpaceIDs.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Fixture

    private func makeSpace() throws -> Space {
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Data URLs", emoji: "D", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    /// A shown window on `space` with nothing selected.
    private func makeWindow(on space: Space) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        controllers.append(wc)
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id)
        wc.showWindow(nil)
        return wc
    }

    private func html(title: String, body: String = "") -> String {
        "<html><head><title>\(title)</title></head><body><p id='marker'>\(title)</p>\(body)</body></html>"
    }

    /// `data:text/html;base64,…`, the form the task was found with.
    private func base64DataURL(title: String, body: String = "") -> URL {
        URL(string: "data:text/html;base64," + Data(html(title: title, body: body).utf8).base64EncodedString())!
    }

    /// `data:text/html,…` with the document percent-encoded.
    private func percentEncodedDataURL(title: String) -> URL {
        let encoded = html(title: title).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return URL(string: "data:text/html," + encoded)!
    }

    private func markerText(in tab: BrowserTab) async -> String? {
        guard let webView = tab.webView else { return nil }
        let value = try? await webView.evaluateJavaScript(
            "(document.getElementById('marker') || {}).textContent || null")
        return value as? String
    }

    /// The text of the toast the window is showing, if any.
    private func toastMessage(in wc: BrowserWindowController) -> String? {
        func label(in view: NSView) -> String? {
            if let field = view as? NSTextField { return field.stringValue }
            return view.subviews.lazy.compactMap(label(in:)).first
        }
        return wc.contentContainerView.subviews.lazy
            .filter { $0 is ToastView }
            .compactMap(label(in:))
            .first
    }

    /// The question the window is asking in a sheet, if any.
    private func sheetMessage(in wc: BrowserWindowController) -> String? {
        guard let sheet = wc.window?.attachedSheet else { return nil }
        func labels(in view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(labels(in:))
        }
        return sheet.contentView.map { labels(in: $0).joined(separator: " / ") } ?? "a sheet"
    }

    /// Waits for `tab` to show the document titled `title`, and reports what
    /// the window did instead when it never does. A toast is only up for two
    /// seconds, so it is looked for while waiting.
    private func assertLoads(_ tab: BrowserTab, title: String, in wc: BrowserWindowController,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        var toast: String?
        let deadline = Date().addingTimeInterval(5)
        while tab.webView?.title != title || tab.title != title, Date() < deadline {
            toast = toast ?? toastMessage(in: wc)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        toast = toast ?? toastMessage(in: wc)
        let sheet = sheetMessage(in: wc)
        XCTAssertEqual(tab.webView?.title, title, """
            the data: document never loaded; the tab's title is "\(tab.title)", the web view is at \
            \(tab.webView?.url?.scheme ?? "nil"):, the window's toast said \(toast.map { "\"\($0)\"" } ?? "nothing"), \
            its sheet says \(sheet.map { "\"\($0)\"" } ?? "nothing")
            """, file: file, line: line)
        let marker = await markerText(in: tab)
        XCTAssertEqual(marker, title, "the document's content is there", file: file, line: line)
        XCTAssertEqual(tab.title, title, "the tab takes the document's title", file: file, line: line)
        XCTAssertNil(toast, "the URL was not treated as an external application's", file: file, line: line)
        XCTAssertNil(sheet, "nothing was offered to an external application", file: file, line: line)
    }

    // MARK: - Background and selected

    func testADataURLTabLeftInTheBackgroundLoads() async throws {
        let space = try makeSpace()
        let wc = makeWindow(on: space)

        let tab = TabStore.shared.addTab(in: space, url: base64DataURL(title: "Background"))

        try await assertLoads(tab, title: "Background", in: wc)
        XCTAssertNotEqual(wc.selectedTabID, tab.id)
    }

    /// The case the task was found with: created and selected in one run-loop
    /// turn, so the window is the navigation delegate by the time WebKit asks
    /// for the policy.
    func testADataURLTabSelectedRightAfterItIsCreatedLoads() async throws {
        let space = try makeSpace()
        let wc = makeWindow(on: space)

        let tab = TabStore.shared.addTab(in: space, url: base64DataURL(title: "Selected"))
        wc.selectTab(id: tab.id)

        XCTAssertTrue(tab.webView?.navigationDelegate === wc, "the window claimed the web view")
        try await assertLoads(tab, title: "Selected", in: wc)
    }

    func testAPercentEncodedDataURLTabSelectedRightAfterItIsCreatedLoads() async throws {
        let space = try makeSpace()
        let wc = makeWindow(on: space)

        let tab = TabStore.shared.addTab(in: space, url: percentEncodedDataURL(title: "Percent"))
        wc.selectTab(id: tab.id)

        try await assertLoads(tab, title: "Percent", in: wc)
    }

    func testAPrivateWindowsDataURLTabSelectedRightAfterItIsCreatedLoads() async throws {
        let wc = BrowserWindowController(incognito: true)
        controllers.append(wc)
        wc.sidebarSplitView.autosaveName = nil
        wc.showWindow(nil)
        let space = try XCTUnwrap(wc.activeSpace)

        let tab = TabStore.shared.addTab(in: space, url: base64DataURL(title: "Private"))
        wc.selectTab(id: tab.id)

        try await assertLoads(tab, title: "Private", in: wc)
    }

    /// A URL typed into the tab on screen, and a reload of it: both are asked
    /// of the window's policy.
    func testADataURLLoadedIntoTheSelectedTabLoadsAndReloads() async throws {
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let tab = TabStore.shared.addTab(in: space, url: URL(string: "about:blank"))
        wc.selectTab(id: tab.id)
        try await waitUntil("the blank page to load") { tab.webView?.url?.absoluteString == "about:blank" }

        tab.load(base64DataURL(title: "Typed"), typed: true)
        try await assertLoads(tab, title: "Typed", in: wc)

        // Something only a reload undoes, so the wait below cannot pass on the
        // document that is already there.
        _ = try await tab.webView?.evaluateJavaScript("document.title = 'Changed'")
        try await waitUntil("the changed title to reach the tab") { tab.title == "Changed" }
        tab.reload()
        try await assertLoads(tab, title: "Typed", in: wc)
    }

    /// Session restore: a sleeping tab woken by selecting it restores its
    /// back/forward item under the window's policy.
    func testASleepingDataURLTabWokenBySelectingItLoads() async throws {
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let tab = TabStore.shared.addTab(in: space, url: base64DataURL(title: "Restored"))
        try await assertLoads(tab, title: "Restored", in: wc)
        tab.sleep()
        XCTAssertNil(tab.webView)

        wc.selectTab(id: tab.id)

        XCTAssertTrue(tab.webView?.navigationDelegate === wc, "the window claimed the woken web view")
        try await assertLoads(tab, title: "Restored", in: wc)
        XCTAssertEqual(tab.webView?.url?.scheme, "data")
    }

    // MARK: - What a page may do is WebKit's rule

    /// A selected tab showing a blank document a test can script.
    private func makeSelectedBlankTab(in wc: BrowserWindowController, space: Space) async throws -> WKWebView {
        let tab = TabStore.shared.addTab(in: space, url: URL(string: "about:blank"))
        wc.selectTab(id: tab.id)
        let webView = try XCTUnwrap(tab.webView)
        try await waitUntil("the blank page to load") { webView.url?.absoluteString == "about:blank" && !webView.isLoading }
        XCTAssertTrue(webView.navigationDelegate === wc, "the window claimed the web view")
        return webView
    }

    /// A `data:` frame is content, not a link to an application.
    func testADataURLFrameInASelectedTabLoads() async throws {
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let webView = try await makeSelectedBlankTab(in: wc, space: space)
        let frameDocument = "<script>parent.postMessage('frame-ran', '*')</script>"
        let frameSource = "data:text/html;base64," + Data(frameDocument.utf8).base64EncodedString()

        _ = try await webView.evaluateJavaScript("""
            addEventListener('message', event => { document.title = event.data });
            const frame = document.createElement('iframe');
            frame.src = '\(frameSource)';
            document.body.appendChild(frame);
            null
            """)

        try await waitUntil("the data: frame's script to run", timeout: 5) { webView.title == "frame-ran" }
        XCTAssertNil(toastMessage(in: wc))
        XCTAssertNil(sheetMessage(in: wc))
    }

    /// WebKit refuses a page's own top-level navigation to a `data:` URL, and
    /// the window's policy adds nothing to that: the page stays where it is.
    func testAPageCannotNavigateItsTopFrameToADataURL() async throws {
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let webView = try await makeSelectedBlankTab(in: wc, space: space)

        let target = base64DataURL(title: "Hijacked").absoluteString
        _ = try await webView.evaluateJavaScript("document.title = 'Origin'; location.href = '\(target)'; null")
        // Long enough for a navigation that was going to happen to commit.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(webView.title, "Origin")
        XCTAssertNotEqual(webView.url?.scheme, "data")
    }

    /// A page's `target=_blank` link does not reach WebKit's refusal: the
    /// window answers it in `createWebViewWith` by loading the URL into a new
    /// tab itself, and a load the app asks for is one WebKit allows. So the
    /// window refuses a page's `data:` URL there.
    func testAPagesBlankTargetLinkCannotOpenADataURLInANewTab() async throws {
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let webView = try await makeSelectedBlankTab(in: wc, space: space)
        let tabIDs = space.tabs.map(\.id)

        let target = base64DataURL(title: "Opened").absoluteString
        _ = try await webView.evaluateJavaScript("""
            const link = document.createElement('a');
            link.href = '\(target)';
            link.target = '_blank';
            document.body.appendChild(link);
            link.click();
            null
            """)
        // Long enough for a tab that was going to open to open.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(space.tabs.map(\.id), tabIDs, "no tab was opened for the page's data: URL")
        XCTAssertNil(toastMessage(in: wc), "the URL was not treated as an external application's")
    }

    /// The same for a script's `window.open`, which never consults the
    /// navigation policy at all.
    func testAPagesWindowOpenCannotOpenADataURLInANewTab() async throws {
        let space = try makeSpace()
        let wc = makeWindow(on: space)
        let webView = try await makeSelectedBlankTab(in: wc, space: space)
        let tabIDs = space.tabs.map(\.id)

        let target = base64DataURL(title: "Opened").absoluteString
        _ = try await webView.evaluateJavaScript("window.open('\(target)'); null")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertEqual(space.tabs.map(\.id), tabIDs, "no tab was opened for the page's data: URL")
    }
}
