import XCTest
import WebKit
import GRDB
@testable import Detour

/// Integration tests that load a test extension and verify the chrome.* API
/// surface works end-to-end through WKWebView.
@MainActor
final class ExtensionAPIIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var ext: WebExtension!
    private var webView: WKWebView!
    private var backgroundHost: BackgroundHost!
    private var navDelegate: TestNavigationDelegate!

    @MainActor
    override func setUp() {
        super.setUp()

        // Create temp extension directory
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-ext-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Write manifest.json
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "API Test Extension",
            "version": "1.2.3",
            "description": "Tests chrome API surface",
            "permissions": ["storage"],
            "background": {"service_worker": "background.js"},
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}
            ]
        }
        """
        try! manifestJSON.write(to: tempDir.appendingPathComponent("manifest.json"),
                                atomically: true, encoding: .utf8)

        // Background script: echoes messages back with added field
        let backgroundJS = """
        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
            if (message.type === 'ping') {
                sendResponse({ type: 'pong', original: message });
            }
            return true;
        });
        """
        try! backgroundJS.write(to: tempDir.appendingPathComponent("background.js"),
                                atomically: true, encoding: .utf8)

        // Content script: empty (we test via evaluateJavaScript)
        try! "".write(to: tempDir.appendingPathComponent("content.js"),
                      atomically: true, encoding: .utf8)

        // Parse manifest and create extension model
        let manifest = try! ExtensionManifest.parse(at: tempDir.appendingPathComponent("manifest.json"))
        let extID = "test-\(UUID().uuidString)"
        ext = WebExtension(id: extID, manifest: manifest, basePath: tempDir)

        // Register with ExtensionManager so the message bridge can find it
        ExtensionManager.shared.extensions.append(ext)

        // Save an extension record so chrome.storage.local has a valid FK target
        let record = ExtensionRecord(
            id: extID,
            name: manifest.name,
            version: manifest.version,
            manifestJSON: try! manifest.toJSONData(),
            basePath: tempDir.path,
            isEnabled: true,
            installedAt: Date().timeIntervalSince1970
        )
        ExtensionDatabase.shared.saveExtension(record)

        // Set up WKWebView with chrome API polyfills in the extension's content world
        let config = WKWebViewConfiguration()
        let apiBundle = ChromeAPIBundle.generateBundle(for: ext)
        let apiScript = WKUserScript(
            source: apiBundle,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: ext.contentWorld
        )
        config.userContentController.addUserScript(apiScript)
        ExtensionMessageBridge.shared.register(on: config.userContentController,
                                                contentWorld: ext.contentWorld)

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                            configuration: config)

        // Set up navigation delegate BEFORE loading
        let navExpectation = expectation(description: "Page loaded")
        navDelegate = TestNavigationDelegate { navExpectation.fulfill() }
        webView.navigationDelegate = navDelegate

        // Start background host
        backgroundHost = BackgroundHost(extension: ext)
        ExtensionManager.shared.backgroundHosts[extID] = backgroundHost
        backgroundHost.start()

        // Load a blank page to trigger script injection
        let html = "<html><body>test</body></html>"
        webView.loadHTMLString(html, baseURL: URL(string: "https://test.example.com")!)

        // Wait for navigation + background init
        wait(for: [navExpectation], timeout: 10.0)

        // Give background host time to load its script
        let bgExpectation = expectation(description: "Background ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { bgExpectation.fulfill() }
        wait(for: [bgExpectation], timeout: 5.0)
    }

    @MainActor
    override func tearDown() {
        backgroundHost?.stop()
        ExtensionManager.shared.extensions.removeAll { $0.id == ext?.id }
        if let extID = ext?.id {
            ExtensionManager.shared.backgroundHosts.removeValue(forKey: extID)
            ExtensionDatabase.shared.storageClear(extensionID: extID)
            ExtensionDatabase.shared.deleteExtension(id: extID)
        }
        webView = nil
        navDelegate = nil
        ext = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - chrome.runtime

    func testRuntimeIDExists() {
        let result = evalSync("typeof chrome.runtime.id")
        XCTAssertEqual(result as? String, "string")
    }

    func testRuntimeIDMatchesExtension() {
        let result = evalSync("chrome.runtime.id")
        XCTAssertEqual(result as? String, ext.id)
    }

    func testRuntimeGetManifestReturnsName() {
        let result = evalSync("chrome.runtime.getManifest().name")
        XCTAssertEqual(result as? String, "API Test Extension")
    }

    func testRuntimeGetManifestReturnsVersion() {
        let result = evalSync("chrome.runtime.getManifest().version")
        XCTAssertEqual(result as? String, "1.2.3")
    }

    func testRuntimeGetManifestReturnsManifestVersion() {
        let result = evalSync("chrome.runtime.getManifest().manifest_version")
        XCTAssertEqual(result as? Int, 3)
    }

    func testRuntimeGetURLReturnsCorrectFormat() {
        let result = evalSync("chrome.runtime.getURL('popup.html')")
        XCTAssertEqual(result as? String, "extension://\(ext.id)/popup.html")
    }

    func testRuntimeGetURLRootPath() {
        let result = evalSync("chrome.runtime.getURL('/')")
        XCTAssertEqual(result as? String, "extension://\(ext.id)/")
    }

    func testRuntimeOnMessageAPIShape() {
        let result = evalSync("""
            typeof chrome.runtime.onMessage.addListener === 'function' &&
            typeof chrome.runtime.onMessage.removeListener === 'function' &&
            typeof chrome.runtime.onMessage.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testRuntimeSendMessageAPIExists() {
        let result = evalSync("typeof chrome.runtime.sendMessage")
        XCTAssertEqual(result as? String, "function")
    }

    // MARK: - chrome.storage.local

    func testStorageLocalExists() {
        let result = evalSync("typeof chrome.storage.local")
        XCTAssertEqual(result as? String, "object")
    }

    func testStorageLocalAPIShape() {
        let result = evalSync("""
            typeof chrome.storage.local.get === 'function' &&
            typeof chrome.storage.local.set === 'function' &&
            typeof chrome.storage.local.remove === 'function' &&
            typeof chrome.storage.local.clear === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testStorageLocalSetAndGet() {
        callAsyncVoid("await chrome.storage.local.set({ testKey: 42 })")
        let result = callAsync("var r = await chrome.storage.local.get('testKey'); return r.testKey;")
        XCTAssertEqual(result as? Int, 42)
    }

    func testStorageLocalSetStringValue() {
        callAsyncVoid("await chrome.storage.local.set({ greeting: 'hello world' })")
        let result = callAsync("var r = await chrome.storage.local.get('greeting'); return r.greeting;")
        XCTAssertEqual(result as? String, "hello world")
    }

    func testStorageLocalRemove() {
        callAsyncVoid("await chrome.storage.local.set({ removeMe: 'here' })")
        callAsyncVoid("await chrome.storage.local.remove('removeMe')")
        let result = callAsync("var r = await chrome.storage.local.get('removeMe'); return r.removeMe === undefined;")
        XCTAssertEqual(result as? Bool, true)
    }

    func testStorageLocalClear() {
        callAsyncVoid("await chrome.storage.local.set({ x: 1, y: 2 })")
        callAsyncVoid("await chrome.storage.local.clear()")
        let result = callAsync("var r = await chrome.storage.local.get(null); return Object.keys(r).length;")
        XCTAssertEqual(result as? Int, 0)
    }

    // MARK: - chrome.runtime.sendMessage (content → background)

    func testSendMessageToBackground() {
        let result = callAsync("var response = await chrome.runtime.sendMessage({ type: 'ping' }); return JSON.stringify(response);")
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse response JSON: \(String(describing: result))")
            return
        }
        XCTAssertEqual(json["type"] as? String, "pong")
        let original = json["original"] as? [String: Any]
        XCTAssertEqual(original?["type"] as? String, "ping")
    }

    // MARK: - API isolation

    func testChromeAPINotInPageWorld() {
        let exp = expectation(description: "JS eval")
        var result: Any?
        webView.evaluateJavaScript("typeof chrome") { value, _ in
            result = value
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(result as? String, "undefined",
                       "chrome.* APIs should not leak into the page world")
    }

    // MARK: - Helpers

    /// Evaluate JavaScript synchronously in the extension's content world.
    private func evalSync(_ js: String) -> Any? {
        let exp = expectation(description: "JS eval")
        var result: Any?
        var evalError: Error?
        webView.evaluateJavaScript(js, in: nil, in: ext.contentWorld) { res in
            switch res {
            case .success(let value): result = value
            case .failure(let error): evalError = error
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        if let evalError {
            XCTFail("JS evaluation error: \(evalError)")
        }
        return result
    }

    /// Evaluate async JavaScript using callAsyncJavaScript (awaits Promises).
    private func callAsync(_ js: String) -> Any? {
        let exp = expectation(description: "Async JS eval")
        var result: Any?
        var evalError: Error?
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: ext.contentWorld) { res in
            switch res {
            case .success(let value): result = value
            case .failure(let error): evalError = error
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        if let evalError {
            XCTFail("Async JS evaluation error: \(evalError)")
        }
        return result
    }

    /// Fire-and-forget async JS evaluation.
    private func callAsyncVoid(_ js: String) {
        _ = callAsync(js)
    }
}

private class TestNavigationDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}
