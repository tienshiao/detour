import XCTest
import WebKit
@testable import Detour

/// A guard on WebKit's gate (TASK-373, from TASK-352's probe): a Quick Detour
/// or quarantine window never shows a `webkit-extension://` page. WebKit's
/// extension scheme handler refuses a main-frame load unless the web view's
/// configuration has the extension's `_requiredWebExtensionBaseURL`, which
/// only `WKWebExtensionContext.webViewConfiguration` sets, and a Quick Detour
/// is never built from one. That is why the rehoming walk and the deferred
/// update count leave Quick Detour pages out (`extensionPageLocations`). If a
/// WebKit release relaxes the gate, these fail: each cell waits for either
/// Detour's error page or the extension's own document, and asserts which.
///
/// The space-tab cases (a page's `window.open`, a page-chosen load, a page
/// navigating itself, `tabs.create`) are `ExtensionPageProvenanceTests`'.
nonisolated final class QuickDetourExtensionPageGateTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var servers: [LoopbackHTTPServer] = []
    private var bareWebViews: [WKWebView] = []
    private var controllersBefore: [ObjectIdentifier] = []
    /// Profiles outlive the test: WebKit traps when a profile that hosted
    /// extension web views is released while they wind down.
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        controllersBefore = QuickDetourWindowController.openControllers.map(ObjectIdentifier.init)
    }

    @MainActor override func tearDown() async throws {
        // Every window a test opened, the `window.open` children included.
        for controller in QuickDetourWindowController.openControllers
        where !controllersBefore.contains(ObjectIdentifier(controller)) {
            controller.close()
        }
        for webView in bareWebViews {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        bareWebViews.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs { ExtensionManager.shared.extensions.removeAll { $0.id == id } }
        registeredExtensionIDs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let optionsTitle = "Opts"
    private static let accessibleTitle = "War"
    private static let webTitle = "Web"

    /// An extension loaded into a fresh profile (Private when `incognito`),
    /// with a page that is not web-accessible (`options.html`) and one that is
    /// (`war.html`), and a loopback web page with a link to retarget.
    private struct Fixture {
        let profile: Profile
        let context: WKWebExtensionContext
        let host: String
        let options: URL
        let accessible: URL
        let web: URL
    }

    @MainActor private func makeFixture(incognito: Bool = false) async throws -> Fixture {
        let id = "qd-gate-\(UUID().uuidString.prefix(8))"
        let ext = try await makeTestExtension(id: id, manifestJSON: """
        {
            "manifest_version": 3,
            "name": "Quick Detour Gate",
            "version": "1.0.0",
            "options_ui": { "page": "options.html" },
            "web_accessible_resources": [{ "resources": ["war.html"], "matches": ["<all_urls>"] }]
        }
        """, files: [
            "options.html": "<html><head><title>\(Self.optionsTitle)</title></head><body>options page</body></html>",
            "war.html": "<html><head><title>\(Self.accessibleTitle)</title></head><body>web-accessible page</body></html>",
        ])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)

        let name = "QD Gate \(id)"
        let profile = incognito ? Profile(name: name, isIncognito: true) : TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        _ = profile.extensionController
        let context = try loadTestContext(ext, in: profile)

        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>\(Self.webTitle)</title></head><body>web page <a id='l' href='#'>link</a></body></html>",
        ])
        servers.append(server)
        let port = try await server.start()
        return Fixture(profile: profile, context: context, host: try XCTUnwrap(context.baseURL.host),
                       options: try extensionPageURL("options.html", on: context.baseURL),
                       accessible: try extensionPageURL("war.html", on: context.baseURL),
                       web: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/")))
    }

    @MainActor private func openQuickDetour(_ profile: Profile) -> QuickDetourWindowController {
        let controller = QuickDetourWindowController(profile: profile, sourceSpace: nil)
        controller.showWindow(nil)
        return controller
    }

    /// A Quick Detour (or `quarantine`) window showing the fixture's web page.
    @MainActor private func openOnWebPage(_ fixture: Fixture, quarantine: Bool = false) async throws
        -> (QuickDetourWindowController, BrowserTab) {
        let controller = quarantine
            ? QuickDetourWindowController.openQuarantine(url: fixture.web, privateProfile: fixture.profile)
            : openQuickDetour(fixture.profile)
        if !quarantine { controller.load(fixture.web, typed: true) }
        let tab = try XCTUnwrap(controller.tab)
        try await waitUntil("the web page") { tab.webView?.title == Self.webTitle && tab.webView?.isLoading == false }
        return (controller, tab)
    }

    /// Whether `webView` shows one of the extension's pages. Its `title` can
    /// lag the loaded document (measured), so a settled extension URL asks
    /// the document itself.
    @MainActor private func isExtensionDocument(_ webView: WKWebView) async -> Bool {
        let titles = [Self.optionsTitle, Self.accessibleTitle]
        if titles.contains(webView.title ?? "") { return true }
        guard isExtensionPageURL(webView.url), !webView.isLoading else { return false }
        let title = try? await webView.evaluateJavaScript("document.title") as? String
        return titles.contains(title ?? "")
    }

    /// Waits for the load of `target` in `tab` to end, either way, and asserts
    /// WebKit refused it: Detour's error page names it, the document is not
    /// the extension's, and nothing of the tab reports an extension page.
    /// `keptURL` is the tab's `url` afterwards (TASK-381: a refused extension
    /// URL never becomes it).
    @MainActor private func assertRefused(_ target: URL, in tab: BrowserTab, _ fixture: Fixture, keptURL: URL?,
                                          _ cell: String, file: StaticString = #filePath,
                                          line: UInt = #line) async throws {
        try await waitUntil("\(cell): the error page or the extension's page", file: file, line: line) {
            guard let webView = tab.webView else { return false }
            if await isExtensionDocument(webView) { return true }
            return webView.url?.scheme == ErrorPage.scheme && !webView.isLoading
        }
        let webView = try XCTUnwrap(tab.webView, file: file, line: line)
        let showsExtensionDocument = await isExtensionDocument(webView)
        XCTAssertFalse(showsExtensionDocument,
                       "\(cell): WebKit showed the extension's page in a Quick Detour; the rehoming walk and the deferred-update count now miss it",
                       file: file, line: line)
        XCTAssertEqual(webView.url?.scheme, ErrorPage.scheme, "\(cell): Detour's error page", file: file, line: line)
        XCTAssertEqual(webView.url.flatMap(ErrorPage.originalURL(from:)), target,
                       "\(cell): the error page names the refused URL", file: file, line: line)
        XCTAssertFalse(isExtensionPageURL(webView.url), "\(cell)", file: file, line: line)
        XCTAssertFalse(tab.showsExtensionPage(ofOriginHost: fixture.host), "\(cell)", file: file, line: line)
        XCTAssertEqual(tab.url, keptURL, "\(cell): the tab's url", file: file, line: line)
    }

    /// The error WebKit refuses `target` with in a web view built from
    /// `configuration` (a copy of a Quick Detour tab's): the gate's
    /// `NSURLErrorResourceUnavailable`, read through a delegate of the test's
    /// own, since the error page carries only the message.
    @MainActor private func assertConfigurationRefuses(_ configuration: WKWebViewConfiguration, _ target: URL,
                                                       _ cell: String, file: StaticString = #filePath,
                                                       line: UInt = #line) async {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        bareWebViews.append(webView)
        do {
            try await loadAndWait(webView, URLRequest(url: target))
            XCTFail("\(cell): WebKit loaded \(target) in a Quick Detour's configuration", file: file, line: line)
        } catch {
            let error = error as NSError
            XCTAssertEqual(error.domain, NSURLErrorDomain, "\(cell): \(error)", file: file, line: line)
            XCTAssertEqual(error.code, NSURLErrorResourceUnavailable, "\(cell): \(error)", file: file, line: line)
        }
    }

    // MARK: - Positive control

    /// The same pages load where WebKit allows them, so a refusal below is the
    /// gate's and not a broken fixture's: in a web view of the context's own
    /// configuration, in a normal and in a Private profile.
    @MainActor func testTheExtensionsOwnConfigurationShowsBothPages() async throws {
        for incognito in [false, true] {
            let fixture = try await makeFixture(incognito: incognito)
            for (page, title) in [(fixture.options, Self.optionsTitle), (fixture.accessible, Self.accessibleTitle)] {
                let configuration = try XCTUnwrap(fixture.context.webViewConfiguration)
                let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
                bareWebViews.append(webView)
                try await loadAndWait(webView, URLRequest(url: page))
                let shown = try await webView.evaluateJavaScript("document.title") as? String
                XCTAssertEqual(shown, title, "incognito \(incognito)")
                XCTAssertEqual(webView.url, page, "incognito \(incognito)")
            }
        }
    }

    // MARK: - Quick Detour

    /// A fresh window loading the URL: what the sidebar's Opt-Cmd-click or
    /// Open in Quick Detour on an extension-page tab does, and an archived
    /// record's restore.
    @MainActor func testAFreshQuickDetourRefusesTheExtensionsPages() async throws {
        let fixture = try await makeFixture()
        for (page, cell) in [(fixture.options, "fresh -> options"), (fixture.accessible, "fresh -> war")] {
            let controller = openQuickDetour(fixture.profile)
            controller.load(page, typed: false)
            let tab = try XCTUnwrap(controller.tab)
            try await assertRefused(page, in: tab, fixture, keptURL: nil, cell)
            await assertConfigurationRefuses(try XCTUnwrap(tab.webView).configuration, page, cell)
            controller.close()
        }
    }

    /// A web page in the window navigating itself (a script, a clicked link;
    /// a content script's `location.href` is the same navigation, not run
    /// here): the tab stays on the web page.
    @MainActor func testAQuickDetourPageCannotNavigateItselfToTheExtensionsPages() async throws {
        let fixture = try await makeFixture()
        let cells: [(URL, String, String)] = [
            (fixture.accessible, "location.href = '\(fixture.accessible.absoluteString)';", "script -> war"),
            (fixture.options, "location.href = '\(fixture.options.absoluteString)';", "script -> options"),
            (fixture.accessible, "const a = document.getElementById('l'); a.href = '\(fixture.accessible.absoluteString)'; a.click();",
             "link -> war"),
        ]
        for (page, script, cell) in cells {
            let (controller, tab) = try await openOnWebPage(fixture)
            _ = try await XCTUnwrap(tab.webView).callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
            try await assertRefused(page, in: tab, fixture, keptURL: fixture.web, cell)
            controller.close()
        }
    }

    /// `tabs.update` on the window's tab (`loadURL(_:for:)`): an extension
    /// acting on the popup window's tab.
    @MainActor func testTabsUpdateCannotLoadTheExtensionsPagesInAQuickDetour() async throws {
        let fixture = try await makeFixture()
        for (page, cell) in [(fixture.accessible, "tabs.update -> war"), (fixture.options, "tabs.update -> options")] {
            let (controller, tab) = try await openOnWebPage(fixture)
            tab.loadURL(page, for: fixture.context) { _ in }
            try await assertRefused(page, in: tab, fixture, keptURL: fixture.web, cell)
            controller.close()
        }
    }

    /// The page's `window.open`: a child Quick Detour on WebKit's copy of the
    /// opener's configuration.
    @MainActor func testAWindowOpenedInAQuickDetourRefusesTheExtensionsPage() async throws {
        let fixture = try await makeFixture()
        let (_, opener) = try await openOnWebPage(fixture)
        let before = Set(TabStore.shared.quickDetourTabs.map(\.id))
        _ = try await XCTUnwrap(opener.webView).evaluateJavaScript("window.open('\(fixture.accessible.absoluteString)'); 1")
        try await waitUntil("the child window") { TabStore.shared.quickDetourTabs.contains { !before.contains($0.id) } }
        let child = try XCTUnwrap(TabStore.shared.quickDetourTabs.first { !before.contains($0.id) })
        try await assertRefused(fixture.accessible, in: child, fixture, keptURL: nil, "window.open -> war")
        await assertConfigurationRefuses(try XCTUnwrap(child.webView).configuration, fixture.accessible,
                                         "window.open -> war")
    }

    // MARK: - Quarantine

    /// A quarantine is a Quick Detour on the Private profile with a store of
    /// its own: the same configuration, the same refusal.
    @MainActor func testAQuarantineRefusesTheExtensionsPages() async throws {
        let fixture = try await makeFixture(incognito: true)
        for (page, cell) in [(fixture.options, "quarantine -> options"), (fixture.accessible, "quarantine -> war")] {
            let controller = QuickDetourWindowController.openQuarantine(url: page, privateProfile: fixture.profile)
            XCTAssertTrue(controller.isQuarantine)
            let tab = try XCTUnwrap(controller.tab)
            try await assertRefused(page, in: tab, fixture, keptURL: nil, cell)
            await assertConfigurationRefuses(try XCTUnwrap(tab.webView).configuration, page, cell)
            controller.close()
        }

        let (controller, tab) = try await openOnWebPage(fixture, quarantine: true)
        _ = try await XCTUnwrap(tab.webView).callAsyncJavaScript(
            "location.href = '\(fixture.accessible.absoluteString)';", arguments: [:], contentWorld: .page)
        try await assertRefused(fixture.accessible, in: tab, fixture, keptURL: fixture.web, "quarantine web -> script -> war")
        controller.close()
    }
}
