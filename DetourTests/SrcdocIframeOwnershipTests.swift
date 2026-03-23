import XCTest
import WebKit
@testable import Detour

/// Tests that extension srcdoc iframe script injection is scoped to the owning
/// extension, preventing other extensions from prematurely signaling ready.
@MainActor
final class SrcdocIframeOwnershipTests: XCTestCase {

    private var tempDir1: URL!
    private var tempDir2: URL!
    private var ext1: WebExtension!
    private var ext2: WebExtension!

    private static let ext1ID = "test-srcdoc-owner"
    private static let ext2ID = "test-srcdoc-other"

    override func setUp() {
        super.setUp()

        tempDir1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-srcdoc-ext1")
        tempDir2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-srcdoc-ext2")

        for dir in [tempDir1!, tempDir2!] {
            try? FileManager.default.removeItem(at: dir)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Both extensions need MAIN world scripts so ContentScriptInjector
        // installs the full relay + srcdoc infrastructure.
        let manifestJSON = { (name: String) in """
        {
            "manifest_version": 3,
            "name": "\(name)",
            "version": "1.0.0",
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_start"},
                {"matches": ["<all_urls>"], "js": ["main.js"], "world": "MAIN", "run_at": "document_start"}
            ]
        }
        """
        }

        try! manifestJSON("Extension 1").write(
            to: tempDir1.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)
        try! manifestJSON("Extension 2").write(
            to: tempDir2.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)

        for dir in [tempDir1!, tempDir2!] {
            try! "// content".write(to: dir.appendingPathComponent("content.js"),
                                    atomically: true, encoding: .utf8)
            try! "// main world".write(to: dir.appendingPathComponent("main.js"),
                                       atomically: true, encoding: .utf8)
        }

        let manifest1 = try! ExtensionManifest.parse(at: tempDir1.appendingPathComponent("manifest.json"))
        let manifest2 = try! ExtensionManifest.parse(at: tempDir2.appendingPathComponent("manifest.json"))

        ext1 = WebExtension(id: Self.ext1ID, manifest: manifest1, basePath: tempDir1)
        ext2 = WebExtension(id: Self.ext2ID, manifest: manifest2, basePath: tempDir2)

        ExtensionManager.shared.extensions.append(ext1)
        ExtensionManager.shared.extensions.append(ext2)
    }

    override func tearDown() {
        ExtensionManager.shared.extensions.removeAll { $0.id == Self.ext1ID || $0.id == Self.ext2ID }
        try? FileManager.default.removeItem(at: tempDir1)
        try? FileManager.default.removeItem(at: tempDir2)
        super.tearDown()
    }

    // MARK: - Helpers

    /// JS expression that mirrors the production `readJS` in handleEvalIframeScripts:
    /// returns the pending scripts array if the key exists, or null if missing.
    private func pendingScriptsCheckJS(requestId: String) -> String {
        """
        JSON.stringify(
            window.__detourPendingScripts &&
            window.__detourPendingScripts.hasOwnProperty('\(requestId)')
                ? window.__detourPendingScripts['\(requestId)']
                : null
        )
        """
    }

    // MARK: - iframe.src interception sets data-detour-extension-id

    func testInterceptSrcSetsExtensionIDAttribute() {
        let config = WKWebViewConfiguration()
        ContentScriptInjector().registerContentScripts(for: ext1, on: config.userContentController)

        let wv = WKWebView(frame: .zero, configuration: config)
        let navExp = expectation(description: "Page loaded")
        let nav = TestSrcdocNavDelegate { navExp.fulfill() }
        wv.navigationDelegate = nav
        wv.loadHTMLString("<html><body>test</body></html>",
                          baseURL: URL(string: "https://test.example.com")!)
        wait(for: [navExp], timeout: 10.0)

        let checkExp = expectation(description: "Check attribute")
        var attrValue: Any?
        wv.evaluateJavaScript("""
            var iframe = document.createElement('iframe');
            document.body.appendChild(iframe);
            iframe.src = 'chrome-extension://\(Self.ext1ID)/page.html';
            iframe.getAttribute('data-detour-extension-id');
        """, in: nil, in: ext1.contentWorld) { result in
            if case .success(let val) = result { attrValue = val }
            checkExp.fulfill()
        }
        wait(for: [checkExp], timeout: 10.0)

        XCTAssertEqual(attrValue as? String, Self.ext1ID,
                       "interceptSrc should tag the iframe with the owning extension's ID")
        _ = nav
    }

    // MARK: - evalIframeScripts defense in depth

    func testEvalIframeScriptsSkipsReadyForNonOwner() {
        let config = WKWebViewConfiguration()
        let apiBundle = ChromeAPIBundle.generateBundle(for: ext2)
        let apiScript = WKUserScript(
            source: apiBundle,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: ext2.contentWorld
        )
        config.userContentController.addUserScript(apiScript)
        ExtensionMessageBridge.shared.register(on: config.userContentController,
                                                contentWorld: ext2.contentWorld)

        let wv = WKWebView(frame: .zero, configuration: config)
        let navExp = expectation(description: "Page loaded")
        let nav = TestSrcdocNavDelegate { navExp.fulfill() }
        wv.navigationDelegate = nav
        wv.loadHTMLString("<html><body>test</body></html>",
                          baseURL: URL(string: "https://test.example.com")!)
        wait(for: [navExp], timeout: 10.0)

        let checkExp = expectation(description: "Check pending scripts")
        var hasPending: Any?
        wv.evaluateJavaScript(
            pendingScriptsCheckJS(requestId: "req_fake_12345"),
            in: nil, in: ext2.contentWorld
        ) { result in
            if case .success(let val) = result { hasPending = val }
            checkExp.fulfill()
        }
        wait(for: [checkExp], timeout: 5.0)

        XCTAssertEqual(hasPending as? String, "null",
                       "Non-owning extension should have no pending scripts, returning null")
        _ = nav
    }

    func testEvalIframeScriptsSignalsReadyForOwner() {
        let config = WKWebViewConfiguration()
        ContentScriptInjector().registerContentScripts(for: ext1, on: config.userContentController)
        ExtensionMessageBridge.shared.register(on: config.userContentController,
                                                contentWorld: ext1.contentWorld)

        let wv = WKWebView(frame: .zero, configuration: config)
        let navExp = expectation(description: "Page loaded")
        let nav = TestSrcdocNavDelegate { navExp.fulfill() }
        wv.navigationDelegate = nav
        wv.loadHTMLString("<html><body>test</body></html>",
                          baseURL: URL(string: "https://test.example.com")!)
        wait(for: [navExp], timeout: 10.0)

        let storeExp = expectation(description: "Store scripts")
        wv.evaluateJavaScript("""
            if (!window.__detourPendingScripts) window.__detourPendingScripts = {};
            window.__detourPendingScripts['req_test_owner'] = [{ type: 'classic', code: 'window.__testInjected = true;' }];
            'stored';
        """, in: nil, in: ext1.contentWorld) { _ in storeExp.fulfill() }
        wait(for: [storeExp], timeout: 5.0)

        let checkExp = expectation(description: "Check owner scripts")
        var result: Any?
        wv.evaluateJavaScript(
            pendingScriptsCheckJS(requestId: "req_test_owner"),
            in: nil, in: ext1.contentWorld
        ) { res in
            if case .success(let val) = res { result = val }
            checkExp.fulfill()
        }
        wait(for: [checkExp], timeout: 5.0)

        let jsonString = result as? String ?? "null"
        XCTAssertNotEqual(jsonString, "null",
                          "Owning extension should find its pending scripts for the requestId")
        XCTAssertTrue(jsonString.contains("__testInjected"),
                      "Returned scripts should contain the stored code")
        _ = nav
    }

    // MARK: - Multi-extension iframe isolation

    func testPendingScriptsIsolatedBetweenExtensions() {
        let config = WKWebViewConfiguration()
        ContentScriptInjector().registerContentScripts(for: ext1, on: config.userContentController)
        ContentScriptInjector().registerContentScripts(for: ext2, on: config.userContentController)

        let wv = WKWebView(frame: .zero, configuration: config)
        let navExp = expectation(description: "Page loaded")
        let nav = TestSrcdocNavDelegate { navExp.fulfill() }
        wv.navigationDelegate = nav
        wv.loadHTMLString("<html><body>test</body></html>",
                          baseURL: URL(string: "https://test.example.com")!)
        wait(for: [navExp], timeout: 10.0)

        let requestId = "req_isolation_test"

        let storeExp = expectation(description: "Store in ext1")
        wv.evaluateJavaScript("""
            if (!window.__detourPendingScripts) window.__detourPendingScripts = {};
            window.__detourPendingScripts['\(requestId)'] = [{ type: 'classic', code: 'true;' }];
            'ok';
        """, in: nil, in: ext1.contentWorld) { _ in storeExp.fulfill() }
        wait(for: [storeExp], timeout: 5.0)

        let check1Exp = expectation(description: "Check ext1")
        var ext1Result: Any?
        wv.evaluateJavaScript(
            pendingScriptsCheckJS(requestId: requestId),
            in: nil, in: ext1.contentWorld
        ) { res in
            if case .success(let val) = res { ext1Result = val }
            check1Exp.fulfill()
        }

        let check2Exp = expectation(description: "Check ext2")
        var ext2Result: Any?
        wv.evaluateJavaScript(
            pendingScriptsCheckJS(requestId: requestId),
            in: nil, in: ext2.contentWorld
        ) { res in
            if case .success(let val) = res { ext2Result = val }
            check2Exp.fulfill()
        }

        wait(for: [check1Exp, check2Exp], timeout: 5.0)

        let ext1JSON = ext1Result as? String ?? "null"
        let ext2JSON = ext2Result as? String ?? "null"

        XCTAssertNotEqual(ext1JSON, "null",
                          "Owning extension (ext1) should find pending scripts")
        XCTAssertEqual(ext2JSON, "null",
                       "Non-owning extension (ext2) should NOT find pending scripts — " +
                       "content worlds are isolated")
        _ = nav
    }
}

private class TestSrcdocNavDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
