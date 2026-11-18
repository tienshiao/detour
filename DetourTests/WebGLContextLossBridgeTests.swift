import XCTest
import WebKit
@testable import Detour

/// TASK-410: a page losing a WebGL context, or failing to get one, reaches the
/// recycler from any frame of a tab, without page script seeing how.
nonisolated final class WebGLContextLossBridgeTests: XCTestCase {

    private struct Report: Equatable {
        let kind: WebGLContextLossKind
        let tabID: UUID
        let isMainFrame: Bool
    }

    private var reports: [Report] = []
    private var tabs: [BrowserTab] = []
    private var defaultDeliver: ((WebGLContextLossKind, BrowserTab, Bool) -> Void)!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        defaultDeliver = WebGLContextLossBridge.shared.deliver
        WebGLContextLossBridge.shared.deliver = { [weak self] kind, tab, isMainFrame in
            self?.reports.append(Report(kind: kind, tabID: tab.id, isMainFrame: isMainFrame))
        }
    }

    @MainActor override func tearDown() async throws {
        WebGLContextLossBridge.shared.deliver = defaultDeliver
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        reports.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The canvases' contexts are created by the page itself, so the test can
    /// tell a host without WebGL (skip) from a broken bridge (fail).
    private static let page = """
        <html><body>
        <canvas id="a"></canvas><canvas id="b"></canvas>
        <iframe id="f" srcdoc="<canvas id='c'></canvas><script>window.gl = document.getElementById('c').getContext('webgl');</script>"></iframe>
        <script>
          window.glA = document.getElementById('a').getContext('webgl');
          window.glB = document.getElementById('b').getContext('webgl');
        </script>
        </body></html>
        """

    @MainActor private func loadedTab() async throws -> (BrowserTab, WKWebView) {
        let tab = BrowserTab(configuration: WKWebViewConfiguration())
        tabs.append(tab)
        let webView = try XCTUnwrap(tab.webView)
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://webgl.test/"))
        try await waitUntil("the page and its frame to have WebGL contexts") {
            (try? await webView.evaluateJavaScript(
                "document.readyState === 'complete' && !!document.getElementById('f').contentWindow.gl") as? Bool) == true
        }
        let hasWebGL = try await webView.evaluateJavaScript("!!window.glA") as? Bool ?? false
        try XCTSkipUnless(hasWebGL, "no WebGL in this test host")
        return (tab, webView)
    }

    @MainActor private func loseContext(_ expression: String, in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript(
            "\(expression).getExtension('WEBGL_lose_context').loseContext(); true")
    }

    // MARK: - Tests

    @MainActor func testALostContextInTheMainFrameReachesTheRecycler() async throws {
        let (tab, webView) = try await loadedTab()
        try await loseContext("window.glA", in: webView)
        try await waitUntil("a report") { !self.reports.isEmpty }
        XCTAssertEqual(reports, [Report(kind: .lost, tabID: tab.id, isMainFrame: true)])
    }

    @MainActor func testALostContextInASubframeIsReportedToo() async throws {
        let (tab, webView) = try await loadedTab()
        try await loseContext("document.getElementById('f').contentWindow.gl", in: webView)
        try await waitUntil("a report") { !self.reports.isEmpty }
        XCTAssertEqual(reports, [Report(kind: .lost, tabID: tab.id, isMainFrame: false)])
    }

    @MainActor func testAFrameReportsEachKindOnceInFiveSeconds() async throws {
        let (_, webView) = try await loadedTab()
        try await loseContext("window.glA", in: webView)
        try await loseContext("window.glB", in: webView)
        try await waitUntil("a report") { !self.reports.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(reports.count, 1, "the second loss in the same frame is within the 5 s gap")
    }

    /// Only events WebKit raised count: a page faking either one could make
    /// the recycler sample (and near the cap, recycle) at will. A real failed
    /// creation needs a GPU process out of IOSurfaces, so that kind is covered
    /// by the policy tests and the runtime check, not here.
    @MainActor func testEventsThePageDispatchesItselfAreIgnored() async throws {
        let (_, webView) = try await loadedTab()
        _ = try await webView.evaluateJavaScript("""
            const a = document.getElementById('a');
            a.dispatchEvent(new Event('webglcontextcreationerror'));
            a.dispatchEvent(new Event('webglcontextlost'));
            true
            """)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(reports.isEmpty)
        // The bridge is listening: a real loss right after is reported.
        try await loseContext("window.glA", in: webView)
        try await waitUntil("a report") { !self.reports.isEmpty }
        XCTAssertEqual(reports.map(\.kind), [.lost])
    }

    @MainActor func testThePageSeesNeitherTheHandlerNorTheListener() async throws {
        let (_, webView) = try await loadedTab()
        let handler = try await webView.evaluateJavaScript(
            "typeof window.webkit?.messageHandlers?.\(WebGLContextLossBridge.handlerName)") as? String
        XCTAssertEqual(handler, "undefined")
        // Even the bridge itself, reached through a page-world handler of the
        // same name, does not hear it: the message must come from its own world.
        let controller = webView.configuration.userContentController
        controller.add(WebGLContextLossBridge.shared, contentWorld: .page, name: WebGLContextLossBridge.handlerName)
        defer { controller.removeScriptMessageHandler(forName: WebGLContextLossBridge.handlerName, contentWorld: .page) }
        _ = try await webView.evaluateJavaScript("""
            window.webkit.messageHandlers.\(WebGLContextLossBridge.handlerName).postMessage('lost'); true
            """)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(reports.isEmpty)
    }

    @MainActor func testInstallIsIdempotent() {
        let configuration = WKWebViewConfiguration()
        WebGLContextLossBridge.install(on: configuration)
        WebGLContextLossBridge.install(on: configuration)
        let scripts = configuration.userContentController.userScripts.filter {
            $0.source == WebGLContextLossBridge.userScriptSource
        }
        XCTAssertEqual(scripts.count, 1)
        XCTAssertFalse(scripts[0].isForMainFrameOnly, "every frame")
    }
}
