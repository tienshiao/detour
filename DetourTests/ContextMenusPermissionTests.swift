import XCTest
import WebKit
@testable import Detour

/// Integration tests verifying that the contextMenus permission gate in ExtensionMessageBridge
/// correctly allows/denies chrome.contextMenus.* calls based on manifest permissions.
@MainActor
final class ContextMenusPermissionTests: XCTestCase {

    // Extension WITH contextMenus permission
    private var allowedDir: URL!
    private var allowedExt: WebExtension!
    private var allowedWebView: WKWebView!
    private var allowedNavDelegate: TestCtxMenuNavDelegate!

    // Extension WITHOUT contextMenus permission
    private var deniedDir: URL!
    private var deniedExt: WebExtension!
    private var deniedWebView: WKWebView!
    private var deniedNavDelegate: TestCtxMenuNavDelegate!

    // MARK: - Shared one-time setup

    private static let allowedExtensionID = "ctxmenu-allowed-test"
    private static let deniedExtensionID = "ctxmenu-denied-test"

    private struct SharedState {
        let allowedDir: URL
        let allowedExt: WebExtension
        let allowedWebView: WKWebView
        let allowedNavDelegate: TestCtxMenuNavDelegate
        let deniedDir: URL
        let deniedExt: WebExtension
        let deniedWebView: WKWebView
        let deniedNavDelegate: TestCtxMenuNavDelegate
    }

    private nonisolated(unsafe) static var shared: SharedState?

    /// Create the shared test infrastructure once. Called from the first test's setUp.
    private func createSharedStateIfNeeded() {
        guard Self.shared == nil else { return }

        // --- Extension with contextMenus permission ---
        let allowedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-ctxmenu-allowed-test")
        try? FileManager.default.removeItem(at: allowedDir)
        try! FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)

        let allowedManifestJSON = """
        {
            "manifest_version": 3,
            "name": "ContextMenus Allowed",
            "version": "1.0",
            "permissions": ["contextMenus"]
        }
        """
        try! allowedManifestJSON.write(to: allowedDir.appendingPathComponent("manifest.json"),
                                       atomically: true, encoding: .utf8)

        let allowedManifest = try! ExtensionManifest.parse(at: allowedDir.appendingPathComponent("manifest.json"))
        let allowedID = Self.allowedExtensionID
        let allowedExt = WebExtension(id: allowedID, manifest: allowedManifest, basePath: allowedDir)
        ExtensionManager.shared.extensions.append(allowedExt)

        let allowedRecord = ExtensionRecord(
            id: allowedID, name: allowedManifest.name, version: allowedManifest.version,
            manifestJSON: try! allowedManifest.toJSONData(), basePath: allowedDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(allowedRecord)

        let allowedConfig = WKWebViewConfiguration()
        let allowedBundle = ChromeAPIBundle.generateBundle(for: allowedExt, isContentScript: false)
        let allowedScript = WKUserScript(source: allowedBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        allowedConfig.userContentController.addUserScript(allowedScript)
        ExtensionMessageBridge.shared.register(on: allowedConfig.userContentController)
        let allowedWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: allowedConfig)

        // --- Extension without contextMenus permission ---
        let deniedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-ctxmenu-denied-test")
        try? FileManager.default.removeItem(at: deniedDir)
        try! FileManager.default.createDirectory(at: deniedDir, withIntermediateDirectories: true)

        let deniedManifestJSON = """
        {
            "manifest_version": 3,
            "name": "ContextMenus Denied",
            "version": "1.0",
            "permissions": ["storage"]
        }
        """
        try! deniedManifestJSON.write(to: deniedDir.appendingPathComponent("manifest.json"),
                                      atomically: true, encoding: .utf8)

        let deniedManifest = try! ExtensionManifest.parse(at: deniedDir.appendingPathComponent("manifest.json"))
        let deniedID = Self.deniedExtensionID
        let deniedExt = WebExtension(id: deniedID, manifest: deniedManifest, basePath: deniedDir)
        ExtensionManager.shared.extensions.append(deniedExt)

        let deniedRecord = ExtensionRecord(
            id: deniedID, name: deniedManifest.name, version: deniedManifest.version,
            manifestJSON: try! deniedManifest.toJSONData(), basePath: deniedDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(deniedRecord)

        let deniedConfig = WKWebViewConfiguration()
        let deniedBundle = ChromeAPIBundle.generateBundle(for: deniedExt, isContentScript: false)
        let deniedScript = WKUserScript(source: deniedBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        deniedConfig.userContentController.addUserScript(deniedScript)
        ExtensionMessageBridge.shared.register(on: deniedConfig.userContentController)
        let deniedWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: deniedConfig)

        // Load pages
        let html = "<html><body>test</body></html>"
        let allowedNavExp = expectation(description: "Allowed page loaded")
        let allowedNavDelegate = TestCtxMenuNavDelegate { allowedNavExp.fulfill() }
        allowedWebView.navigationDelegate = allowedNavDelegate
        allowedWebView.loadHTMLString(html, baseURL: URL(string: "https://ctxmenu-test.example.com")!)

        let deniedNavExp = expectation(description: "Denied page loaded")
        let deniedNavDelegate = TestCtxMenuNavDelegate { deniedNavExp.fulfill() }
        deniedWebView.navigationDelegate = deniedNavDelegate
        deniedWebView.loadHTMLString(html, baseURL: URL(string: "https://ctxmenu-test.example.com")!)

        wait(for: [allowedNavExp, deniedNavExp], timeout: 10.0)

        Self.shared = SharedState(
            allowedDir: allowedDir,
            allowedExt: allowedExt,
            allowedWebView: allowedWebView,
            allowedNavDelegate: allowedNavDelegate,
            deniedDir: deniedDir,
            deniedExt: deniedExt,
            deniedWebView: deniedWebView,
            deniedNavDelegate: deniedNavDelegate
        )
    }

    @MainActor
    override func setUp() {
        super.setUp()
        createSharedStateIfNeeded()

        let s = Self.shared!
        allowedDir = s.allowedDir
        allowedExt = s.allowedExt
        allowedWebView = s.allowedWebView
        allowedNavDelegate = s.allowedNavDelegate
        deniedDir = s.deniedDir
        deniedExt = s.deniedExt
        deniedWebView = s.deniedWebView
        deniedNavDelegate = s.deniedNavDelegate

        // Reset mutable state between tests
        ExtensionManager.shared.contextMenuItems.removeValue(forKey: allowedExt.id)
        ExtensionManager.shared.contextMenuItems.removeValue(forKey: deniedExt.id)
    }

    @MainActor
    override func tearDown() {
        // Don't tear down shared state — it's reused across tests
        super.tearDown()
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            guard let s = shared else { return }
            for ext in [s.allowedExt, s.deniedExt] {
                ExtensionManager.shared.extensions.removeAll { $0.id == ext.id }
                ExtensionManager.shared.contextMenuItems.removeValue(forKey: ext.id)
                AppDatabase.shared.storageClear(extensionID: ext.id)
                AppDatabase.shared.deleteExtension(id: ext.id)
            }
            try? FileManager.default.removeItem(at: s.allowedDir)
            try? FileManager.default.removeItem(at: s.deniedDir)
            shared = nil
        }
        super.tearDown()
    }

    // MARK: - Allowed

    func testContextMenuCreateAllowed() {
        let result = callAsync(allowedWebView, """
            var id = await chrome.contextMenus.create({ id: 'test-item', title: 'Translate', contexts: ['selection'] });
            return typeof id === 'string' ? 'ok' : 'fail';
        """)
        XCTAssertEqual(result as? String, "ok")
    }

    func testContextMenuCreateRegistersItem() {
        callVoid(allowedWebView, """
            chrome.contextMenus.create({ id: 'registered-item', title: 'Test Item', contexts: ['page'] });
        """)

        // Wait briefly for the async message to be processed
        let exp = expectation(description: "Wait for menu registration")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        let items = ExtensionManager.shared.contextMenuItems[allowedExt.id] ?? []
        XCTAssertTrue(items.contains(where: { $0.id == "registered-item" }))
    }

    func testContextMenuRemoveAllAllowed() {
        callVoid(allowedWebView, """
            chrome.contextMenus.create({ id: 'item1', title: 'Item 1' });
            chrome.contextMenus.create({ id: 'item2', title: 'Item 2' });
        """)

        let exp1 = expectation(description: "Wait for creation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp1.fulfill() }
        wait(for: [exp1], timeout: 2.0)

        let result = callAsync(allowedWebView, """
            await chrome.contextMenus.removeAll();
            return 'done';
        """)
        XCTAssertEqual(result as? String, "done")

        let exp2 = expectation(description: "Wait for removal")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2.0)

        let items = ExtensionManager.shared.contextMenuItems[allowedExt.id] ?? []
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - Denied

    func testContextMenuCreateDenied() {
        let result = callAsync(deniedWebView, """
            try {
                await chrome.contextMenus.create({ id: 'test', title: 'Test' });
                return 'resolved';
            } catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("contextMenus"), "Error should mention 'contextMenus': \(msg)")
    }

    func testContextMenuRemoveAllDenied() {
        let result = callAsync(deniedWebView, """
            try {
                await chrome.contextMenus.removeAll();
                return 'resolved';
            } catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("contextMenus"), "Error should mention 'contextMenus': \(msg)")
    }

    // MARK: - Helpers

    private func callAsync(_ webView: WKWebView, _ js: String) -> Any? {
        let exp = expectation(description: "Async JS")
        var result: Any?
        var evalError: Error?
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { res in
            switch res {
            case .success(let value): result = value
            case .failure(let error): evalError = error
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        if let evalError { XCTFail("JS error: \(evalError)") }
        return result
    }

    private func callVoid(_ webView: WKWebView, _ js: String) {
        _ = callAsync(webView, js)
    }
}

private class TestCtxMenuNavDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
