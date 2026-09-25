import XCTest
import WebKit
import Darwin
@testable import Detour

/// What a navigation failure does to a tab no window owns (TASK-122): while no
/// window has claimed its web view, the tab is its own navigation delegate, and
/// WebKit's real failure callbacks must reach the tab — so none of these tests
/// calls the tab's `didFail*` methods directly.
///
/// The failing URLs use a loopback port that was free a moment ago, so the
/// connection is refused at once without leaving the machine. Not port 1:
/// WebKit refuses restricted ports (1, 7, 9, …) itself, committing about:blank
/// with no failure callback at all, so a load there never fails "for real".
@MainActor
final class BrowserTabUnclaimedNavigationTests: XCTestCase {

    /// A page that loads without the network — and where WebKit leaves a web
    /// view whose first navigation failed before committing.
    private let blankURL = URL(string: "about:blank")!

    private var tabs: [BrowserTab] = []

    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    override func setUp() {
        super.setUp()
        // `load(_:)` fetches a favicon optimistically; keep that off the network
        // and out of the shared loader's caches.
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    override func tearDown() {
        tabs.forEach { $0.teardown() }
        tabs.removeAll()
        openSockets.forEach { close($0) }
        openSockets.removeAll()
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    private func track(_ tab: BrowserTab) -> BrowserTab {
        tabs.append(tab)
        return tab
    }

    /// Sockets the test holds open; closed in `tearDown`.
    private var openSockets: [Int32] = []

    /// A TCP socket bound to a loopback port the kernel hands out.
    private func boundLoopbackSocket() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("socket() failed: \(errno)") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, length) == 0 && getsockname(fd, raw, &length) == 0
            }
        }
        guard bound else {
            close(fd)
            throw XCTSkip("bind() failed: \(errno)")
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    /// `http://127.0.0.1:<port>/<path>` on a port the kernel just handed out
    /// and that was closed again, so nothing listens there.
    private func refusedURL(_ path: String) throws -> URL {
        let (fd, port) = try boundLoopbackSocket()
        close(fd)
        return URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    /// `http://127.0.0.1:<port>/<path>` on a port that accepts the connection
    /// (the kernel's listen backlog) but never answers, so a load there stays
    /// provisional until something else ends it.
    private func unansweredURL(_ path: String) throws -> URL {
        let (fd, port) = try boundLoopbackSocket()
        openSockets.append(fd)
        guard listen(fd, 8) == 0 else { throw XCTSkip("listen() failed: \(errno)") }
        return URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    /// An interaction state whose current back/forward item is `url`, archived
    /// the way `BrowserTab.sleep()` archives it.
    private func archivedInteractionState(for url: URL) async throws -> Data {
        let source = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        try await loadHTMLStringAndWait(
            source, html: "<html><head><title>Restored</title></head><body>restored</body></html>",
            baseURL: url)
        let state = try XCTUnwrap(source.interactionState, "the source web view should have session state")
        return try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
    }

    // MARK: -

    /// A background load that fails for real (connection refused) shows the
    /// error page for the URL that was asked for.
    func testFailedBackgroundLoadShowsTheErrorPage() async throws {
        let target = try refusedURL("typed")
        let tab = track(BrowserTab(id: UUID()))
        tab.load(target)
        let webView = try XCTUnwrap(tab.webView)

        try await waitUntil("the error page to load") { webView.url?.scheme == ErrorPage.scheme }

        XCTAssertEqual(webView.url.flatMap(ErrorPage.originalURL(from:)), target)
        XCTAssertEqual(tab.url, target, "the tab reports the URL that was asked for")
    }

    /// A background load superseded by another fails with `NSURLErrorCancelled`,
    /// which is not a failure worth an error page.
    func testSupersededBackgroundLoadShowsNoErrorPage() async throws {
        let tab = track(BrowserTab(id: UUID()))
        tab.load(try unansweredURL("first"))
        let webView = try XCTUnwrap(tab.webView)
        // Let the first load clear the (async) policy decision and go
        // provisional: superseding it while the decision is still pending
        // drops it without any failure callback, which would test nothing.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(webView.isLoading, "the first load is still waiting for an answer")

        tab.load(blankURL)
        try await waitUntil("the second load to land") { webView.url == self.blankURL && !webView.isLoading }
        // Give a stray error-page load time to show up.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNotEqual(webView.url?.scheme, ErrorPage.scheme, "no error page for a superseded load")
        XCTAssertEqual(webView.url, blankURL)
    }

    /// TASK-45 through the new delegate path: a tab restored asleep whose wake
    /// kick fails for real while no window owns it keeps its restored session,
    /// title and favicon, and shows no error page.
    func testFailedRestoreWhileUnownedKeepsTheSession() async throws {
        let restoredURL = try refusedURL("restored")
        let tab = track(BrowserTab(
            id: UUID(), title: "Persisted title", url: restoredURL, faviconURL: nil,
            cachedInteractionState: try await archivedInteractionState(for: restoredURL), spaceID: UUID()))
        tab.favicon = NSImage(size: NSSize(width: 1, height: 1))

        tab.wake()
        let webView = try XCTUnwrap(tab.webView)
        tab.loadIfStalled()
        XCTAssertEqual(webView.url, restoredURL, "the kick is under way")

        try await waitUntil("the kick to fail") { !webView.isLoading }
        // Give a stray error-page load time to show up.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(tab.url, restoredURL, "the restored URL survives the failure")
        XCTAssertEqual(tab.title, "Persisted title", "the persisted title is not replaced by the raw URL")
        XCTAssertNotNil(tab.favicon, "the persisted favicon is kept")
        XCTAssertNotEqual(webView.url?.scheme, ErrorPage.scheme, "no error page was loaded")
        XCTAssertNotNil(tab.currentInteractionStateData(), "the restored session state is still there")
    }
}
