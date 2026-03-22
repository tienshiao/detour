import XCTest
import WebKit
@testable import Detour

/// Integration tests verifying that the storage permission gate in ExtensionMessageBridge
/// correctly allows/denies chrome.storage.local.* calls based on manifest permissions.
@MainActor
final class StoragePermissionTests: XCTestCase {

    // Extension WITH storage permission
    private var allowedExt: WebExtension!
    private var allowedWebView: WKWebView!

    // Extension WITHOUT storage permission
    private var deniedExt: WebExtension!
    private var deniedWebView: WKWebView!

    // MARK: - Shared one-time setup

    private static let allowedID = "test-storage-perm-allowed"
    private static let deniedID = "test-storage-perm-denied"

    private struct SharedState {
        let allowedDir: URL
        let allowedExt: WebExtension
        let allowedWebView: WKWebView
        let allowedNavDelegate: TestStorageNavDelegate

        let deniedDir: URL
        let deniedExt: WebExtension
        let deniedWebView: WKWebView
        let deniedNavDelegate: TestStorageNavDelegate
    }

    private nonisolated(unsafe) static var shared: SharedState?

    /// Create the shared test infrastructure once. Called from the first test's setUp.
    private func createSharedStateIfNeeded() {
        guard Self.shared == nil else { return }

        // --- Extension with storage permission ---
        let allowedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-storage-allowed")
        try? FileManager.default.removeItem(at: allowedDir)
        try! FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)

        let allowedManifestJSON = """
        {
            "manifest_version": 3,
            "name": "Storage Allowed",
            "version": "1.0",
            "permissions": ["storage"]
        }
        """
        try! allowedManifestJSON.write(to: allowedDir.appendingPathComponent("manifest.json"),
                                       atomically: true, encoding: .utf8)

        let allowedManifest = try! ExtensionManifest.parse(at: allowedDir.appendingPathComponent("manifest.json"))
        let allowedExt = WebExtension(id: Self.allowedID, manifest: allowedManifest, basePath: allowedDir)
        ExtensionManager.shared.extensions.append(allowedExt)

        let allowedRecord = ExtensionRecord(
            id: Self.allowedID, name: allowedManifest.name, version: allowedManifest.version,
            manifestJSON: try! allowedManifest.toJSONData(), basePath: allowedDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(allowedRecord)

        let allowedConfig = WKWebViewConfiguration()
        let allowedBundle = ChromeAPIBundle.generateBundle(for: allowedExt, isContentScript: false)
        let allowedScript = WKUserScript(source: allowedBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        allowedConfig.userContentController.addUserScript(allowedScript)
        ExtensionMessageBridge.shared.register(on: allowedConfig.userContentController)
        let allowedWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: allowedConfig)

        // --- Extension without storage permission ---
        let deniedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-storage-denied")
        try? FileManager.default.removeItem(at: deniedDir)
        try! FileManager.default.createDirectory(at: deniedDir, withIntermediateDirectories: true)

        let deniedManifestJSON = """
        {
            "manifest_version": 3,
            "name": "Storage Denied",
            "version": "1.0",
            "permissions": []
        }
        """
        try! deniedManifestJSON.write(to: deniedDir.appendingPathComponent("manifest.json"),
                                      atomically: true, encoding: .utf8)

        let deniedManifest = try! ExtensionManifest.parse(at: deniedDir.appendingPathComponent("manifest.json"))
        let deniedExt = WebExtension(id: Self.deniedID, manifest: deniedManifest, basePath: deniedDir)
        ExtensionManager.shared.extensions.append(deniedExt)

        let deniedRecord = ExtensionRecord(
            id: Self.deniedID, name: deniedManifest.name, version: deniedManifest.version,
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
        let allowedNavDelegate = TestStorageNavDelegate { allowedNavExp.fulfill() }
        allowedWebView.navigationDelegate = allowedNavDelegate
        allowedWebView.loadHTMLString(html, baseURL: URL(string: "https://storage-test.example.com")!)

        let deniedNavExp = expectation(description: "Denied page loaded")
        let deniedNavDelegate = TestStorageNavDelegate { deniedNavExp.fulfill() }
        deniedWebView.navigationDelegate = deniedNavDelegate
        deniedWebView.loadHTMLString(html, baseURL: URL(string: "https://storage-test.example.com")!)

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
        allowedExt = s.allowedExt
        allowedWebView = s.allowedWebView
        deniedExt = s.deniedExt
        deniedWebView = s.deniedWebView
    }

    @MainActor
    override func tearDown() {
        // Don't tear down shared state — it's reused across tests
        super.tearDown()
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            guard let s = shared else { return }

            for extID in [allowedID, deniedID] {
                ExtensionManager.shared.extensions.removeAll { $0.id == extID }
                AppDatabase.shared.storageClear(extensionID: extID)
                AppDatabase.shared.deleteExtension(id: extID)
            }

            try? FileManager.default.removeItem(at: s.allowedDir)
            try? FileManager.default.removeItem(at: s.deniedDir)
            shared = nil
        }
        super.tearDown()
    }

    // MARK: - Allowed

    func testStorageSetGetAllowed() {
        callVoid(allowedWebView, "await chrome.storage.local.set({ key1: 'value1' })")
        let result = callAsync(allowedWebView, "var r = await chrome.storage.local.get('key1'); return r.key1;")
        XCTAssertEqual(result as? String, "value1")
    }

    func testStorageRemoveAllowed() {
        callVoid(allowedWebView, "await chrome.storage.local.set({ rmKey: 'x' })")
        callVoid(allowedWebView, "await chrome.storage.local.remove('rmKey')")
        let result = callAsync(allowedWebView, "var r = await chrome.storage.local.get('rmKey'); return r.rmKey === undefined;")
        XCTAssertEqual(result as? Bool, true)
    }

    func testStorageClearAllowed() {
        callVoid(allowedWebView, "await chrome.storage.local.set({ a: 1, b: 2 })")
        callVoid(allowedWebView, "await chrome.storage.local.clear()")
        let result = callAsync(allowedWebView, "var r = await chrome.storage.local.get(null); return Object.keys(r).length;")
        XCTAssertEqual(result as? Int, 0)
    }

    // MARK: - Denied

    func testStorageGetDenied() {
        let result = callAsync(deniedWebView, """
            try { await chrome.storage.local.get('x'); return 'resolved'; }
            catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("storage"), "Error should mention 'storage': \(msg)")
    }

    func testStorageSetDenied() {
        let result = callAsync(deniedWebView, """
            try { await chrome.storage.local.set({ x: 1 }); return 'resolved'; }
            catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("storage"), "Error should mention 'storage': \(msg)")
    }

    func testStorageRemoveDenied() {
        let result = callAsync(deniedWebView, """
            try { await chrome.storage.local.remove('x'); return 'resolved'; }
            catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("storage"), "Error should mention 'storage': \(msg)")
    }

    func testStorageClearDenied() {
        let result = callAsync(deniedWebView, """
            try { await chrome.storage.local.clear(); return 'resolved'; }
            catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("storage"), "Error should mention 'storage': \(msg)")
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

private class TestStorageNavDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
