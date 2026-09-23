import XCTest
import AppKit
import WebKit
@testable import Detour

/// A background tab has to get its page's favicon while the page is still
/// loading (TASK-112). Hidden web views can leave a load unfinished until the
/// tab is first shown, and the end-of-load lookup alone left those rows on the
/// generic globe. Each page here holds one image request open forever, so the
/// load never ends and only `FaviconLinkBridge` can deliver the icon; downloads
/// go through `FaviconLoader`'s fetch seam.
@MainActor
final class FaviconLinkBridgeTests: XCTestCase {

    private var pendingFetches: [URL: [(NSImage?) -> Void]] = [:]
    private var defaultFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!
    private var tabs: [BrowserTab] = []
    private let scheme = StallingSchemeHandler()

    private let pageURL = URL(string: "stall://fav.test/page")!
    private let iconURL = URL(string: "stall://fav.test/icon.png")!

    override func setUp() {
        super.setUp()
        defaultFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { [weak self] url, completion in
            self?.pendingFetches[url, default: []].append(completion)
        }
    }

    override func tearDown() {
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        FaviconLoader.shared.fetch = defaultFetch
        FaviconLoader.shared.resetForTesting()
        pendingFetches.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A tab built the way `TabStore.addTab` builds one (so `makeWebView`
    /// installs the bridge), on a configuration that also serves `stall://`.
    private func makeTab(serving html: String) -> BrowserTab {
        scheme.pages[pageURL.path] = html
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "stall")
        let tab = BrowserTab(configuration: configuration)
        tabs.append(tab)
        return tab
    }

    /// A page whose load never finishes: its image request is never answered.
    private func stalledPage(head: String = "", body: String = "") -> String {
        "<html><head><title>Stalled</title>\(head)</head><body>\(body)<img src=\"/hang.png\"></body></html>"
    }

    private func waitForFetch(of url: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("a favicon fetch of \(url)", file: file, line: line) {
            self.pendingFetches[url] != nil
        }
    }

    private func completeFetch(_ url: URL) {
        let completions = pendingFetches.removeValue(forKey: url) ?? []
        for completion in completions { completion(NSImage(size: NSSize(width: 16, height: 16))) }
    }

    // MARK: - Tests

    /// The icon link in the served HTML is downloaded and shown while the page
    /// is still loading.
    func testAnIconLinkReachesTheTabWhileThePageIsStillLoading() async throws {
        let tab = makeTab(serving: stalledPage(head: "<link rel=\"icon\" href=\"/icon.png\">"))
        tab.load(pageURL)

        try await waitForFetch(of: iconURL)
        XCTAssertTrue(tab.isLoading, "the page must still be loading, or the end-of-load lookup could be the one that found the icon")
        completeFetch(iconURL)
        try await waitUntil("the favicon to land on the tab") { tab.favicon != nil }
        XCTAssertTrue(tab.isLoading)
    }

    /// The optimistic `/favicon.ico` guess, finishing after the page's declared
    /// icon, does not replace it — the early report makes the two race.
    func testALateOptimisticGuessDoesNotReplaceTheDeclaredIcon() async throws {
        let tab = makeTab(serving: stalledPage(head: "<link rel=\"icon\" href=\"/icon.png\">"))
        tab.load(pageURL)
        let guessURL = URL(string: "stall://fav.test/favicon.ico")!

        try await waitForFetch(of: iconURL)
        XCTAssertNotNil(pendingFetches[guessURL], "load(_:) starts the optimistic guess")
        completeFetch(iconURL)
        try await waitUntil("the declared icon to land") { tab.faviconURL == self.iconURL }
        completeFetch(guessURL)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(tab.faviconURL, iconURL)
    }

    /// A link a script adds after parsing, the way a client-rendered head does,
    /// is picked up by the observer.
    func testALinkAddedByScriptIsReported() async throws {
        let script = """
            <script>setTimeout(() => {
              const link = document.createElement('link');
              link.rel = 'shortcut icon';
              link.href = '/icon.png';
              document.head.appendChild(link);
            }, 200);</script>
            """
        let tab = makeTab(serving: stalledPage(body: script))
        tab.load(pageURL)

        try await waitForFetch(of: iconURL)
        completeFetch(iconURL)
        try await waitUntil("the favicon to land on the tab") { tab.favicon != nil }
    }

    /// Changing the link's `href` reports the new icon.
    func testAChangedHrefIsReported() async throws {
        let script = """
            <script>setTimeout(() => {
              document.querySelector("link[rel~='icon']").href = '/icon-2.png';
            }, 200);</script>
            """
        let tab = makeTab(serving: stalledPage(head: "<link rel=\"icon\" href=\"/icon.png\">", body: script))
        tab.load(pageURL)

        try await waitForFetch(of: iconURL)
        try await waitForFetch(of: URL(string: "stall://fav.test/icon-2.png")!)
    }

    /// A report whose origin is not the page the tab is showing now — one still
    /// in flight from the document being left — downloads nothing.
    func testAReportFromAnotherOriginIsIgnored() async throws {
        let tab = makeTab(serving: stalledPage())
        tab.load(pageURL)
        try await waitUntil("the page to commit") { tab.webView?.url == self.pageURL }

        let foreignIcon = URL(string: "https://other.test/icon.png")!
        tab.pageDidReportFaviconLink(foreignIcon, originHost: "other.test")
        XCTAssertNil(pendingFetches[foreignIcon])

        tab.pageDidReportFaviconLink(foreignIcon, originHost: "FAV.test")
        XCTAssertNotNil(pendingFetches[foreignIcon], "the tab's own origin, in any case, is heard")
    }
}

/// Serves `pages` by path as HTML and never answers `/hang*`, so a page that
/// embeds one never finishes loading. Anything else fails at once.
final class StallingSchemeHandler: NSObject, WKURLSchemeHandler {
    var pages: [String: String] = [:]
    private var held: [ObjectIdentifier: WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        if url.path.hasPrefix("/hang") {
            held[ObjectIdentifier(urlSchemeTask)] = urlSchemeTask
            return
        }
        guard let html = pages[url.path] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let data = Data(html.utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html",
                                             expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        held.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }
}
