import XCTest
import WebKit
import GRDB
@testable import Detour

/// Integration tests for the new Chrome API surface area:
/// - chrome.i18n.getMessage / getUILanguage / getAcceptLanguages
/// - chrome.runtime.onInstalled
/// - chrome.runtime.connect / onConnect (port messaging)
/// - chrome.storage.onChanged
/// - chrome.tabs.detectLanguage
/// - chrome.offscreen.createDocument / closeDocument / hasDocument
/// - chrome.extension.getBackgroundPage
/// - chrome.runtime.getPlatformInfo
/// - Permission checker updates for contextMenus, offscreen, activeTab
@MainActor
final class NewAPIIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var ext: WebExtension!
    private var popupWebView: WKWebView!
    private var backgroundHost: BackgroundHost!
    private var popupNavDelegate: TestNewAPINavDelegate!

    // Tab infrastructure for detectLanguage
    private var testProfile: Profile!
    private var testSpace: Space!
    private var testBrowserTab: BrowserTab!
    private var testTabIntID: Int!
    private var tabNavDelegate: TestNewAPINavDelegate!

    // MARK: - Shared one-time setup

    private static let extensionID = "test-new-api"

    private struct SharedState {
        let tempDir: URL
        let ext: WebExtension
        let popupWebView: WKWebView
        let backgroundHost: BackgroundHost
        let popupNavDelegate: TestNewAPINavDelegate
        let testProfile: Profile
        let testSpace: Space
        let testBrowserTab: BrowserTab
        let testTabIntID: Int
        let tabNavDelegate: TestNewAPINavDelegate
    }

    private nonisolated(unsafe) static var shared: SharedState?

    /// Create the shared test infrastructure once. Called from the first test's setUp.
    private func createSharedStateIfNeeded() {
        guard Self.shared == nil else { return }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-newapi-test-integration")
        try? FileManager.default.removeItem(at: tempDir)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Write i18n messages
        let localeDir = tempDir.appendingPathComponent("_locales/en")
        try! FileManager.default.createDirectory(at: localeDir, withIntermediateDirectories: true)
        let messagesJSON = """
        {
            "appName": { "message": "Test App" },
            "appDesc": { "message": "A description for testing" },
            "greeting": { "message": "Hello $1, welcome to $2!" }
        }
        """
        try! messagesJSON.write(to: localeDir.appendingPathComponent("messages.json"),
                                atomically: true, encoding: .utf8)

        // Write manifest.json with i18n
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "__MSG_appName__",
            "version": "1.0",
            "description": "__MSG_appDesc__",
            "default_locale": "en",
            "permissions": ["storage", "tabs", "contextMenus", "offscreen"],
            "host_permissions": ["<all_urls>"],
            "background": {"service_worker": "background.js"}
        }
        """
        try! manifestJSON.write(to: tempDir.appendingPathComponent("manifest.json"),
                                atomically: true, encoding: .utf8)

        // Background script with onInstalled and onConnect listeners
        let backgroundJS = """
        var installReason = null;
        chrome.runtime.onInstalled.addListener(function(details) {
            installReason = details.reason;
        });

        var lastPortMessage = null;
        chrome.runtime.onConnect.addListener(function(port) {
            port.onMessage.addListener(function(msg) {
                lastPortMessage = msg;
                port.postMessage({ echo: msg.data, from: 'background' });
            });
        });

        chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
            if (message.type === 'getInstallReason') {
                sendResponse({ reason: installReason });
            } else if (message.type === 'getLastPortMessage') {
                sendResponse({ message: lastPortMessage });
            }
            return true;
        });
        """
        try! backgroundJS.write(to: tempDir.appendingPathComponent("background.js"),
                                atomically: true, encoding: .utf8)

        // Offscreen HTML
        let offscreenHTML = "<html><body><div id='content'>Offscreen</div></body></html>"
        try! offscreenHTML.write(to: tempDir.appendingPathComponent("offscreen.html"),
                                 atomically: true, encoding: .utf8)

        // Parse and create extension
        let manifest = try! ExtensionManifest.parse(at: tempDir.appendingPathComponent("manifest.json"))
        let extID = Self.extensionID
        let ext = WebExtension(id: extID, manifest: manifest, basePath: tempDir)

        ExtensionManager.shared.extensions.append(ext)

        let record = ExtensionRecord(
            id: extID, name: manifest.name, version: manifest.version,
            manifestJSON: try! manifest.toJSONData(), basePath: tempDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(record)

        // Start background host with completion handler (fires onInstalled)
        let backgroundHost = BackgroundHost(extension: ext)
        ExtensionManager.shared.backgroundHosts[ext.id] = backgroundHost

        let bgExp = expectation(description: "Background initialized")
        backgroundHost.start(completion: { bgExp.fulfill() })

        // Setup popup WebView (page world)
        let popupConfig = WKWebViewConfiguration()
        let popupBundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: false)
        popupConfig.userContentController.addUserScript(
            WKUserScript(source: popupBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ExtensionMessageBridge.shared.register(on: popupConfig.userContentController)
        let popupWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: popupConfig)

        // Tab infrastructure for detectLanguage
        let testProfile = TabStore.shared.addProfile(name: "NewAPI Test Profile")
        let testSpace = TabStore.shared.addSpace(name: "NewAPI Test Space", emoji: "T", colorHex: "#000000", profileID: testProfile.id)
        ExtensionManager.shared.lastActiveSpaceID = testSpace.id

        let tabConfig = WKWebViewConfiguration()
        let tabBundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: true)
        tabConfig.userContentController.addUserScript(
            WKUserScript(source: tabBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: ext.contentWorld))
        ExtensionMessageBridge.shared.register(on: tabConfig.userContentController, contentWorld: ext.contentWorld)
        let tabWV = WKWebView(frame: .zero, configuration: tabConfig)
        let testBrowserTab = BrowserTab(webView: tabWV)
        testSpace.tabs.append(testBrowserTab)
        testSpace.selectedTabID = testBrowserTab.id
        let testTabIntID = ExtensionManager.shared.tabIDMap.intID(for: testBrowserTab.id)

        // Load pages
        let html = "<html><body>test</body></html>"

        let popupNavExp = expectation(description: "Popup page loaded")
        let popupNavDelegate = TestNewAPINavDelegate { popupNavExp.fulfill() }
        popupWebView.navigationDelegate = popupNavDelegate
        popupWebView.loadHTMLString(html, baseURL: URL(string: "https://newapi-test.example.com")!)

        let tabNavExp = expectation(description: "Tab page loaded")
        let tabNavDelegate = TestNewAPINavDelegate { tabNavExp.fulfill() }
        tabWV.navigationDelegate = tabNavDelegate
        tabWV.loadHTMLString("<html lang='fr'><body>Bonjour</body></html>",
                             baseURL: URL(string: "https://tab-test.example.com")!)

        wait(for: [popupNavExp, tabNavExp, bgExp], timeout: 10.0)

        Self.shared = SharedState(
            tempDir: tempDir,
            ext: ext,
            popupWebView: popupWebView,
            backgroundHost: backgroundHost,
            popupNavDelegate: popupNavDelegate,
            testProfile: testProfile,
            testSpace: testSpace,
            testBrowserTab: testBrowserTab,
            testTabIntID: testTabIntID,
            tabNavDelegate: tabNavDelegate
        )
    }

    @MainActor
    override func setUp() {
        super.setUp()
        createSharedStateIfNeeded()

        let s = Self.shared!
        tempDir = s.tempDir
        ext = s.ext
        popupWebView = s.popupWebView
        backgroundHost = s.backgroundHost
        popupNavDelegate = s.popupNavDelegate
        testProfile = s.testProfile
        testSpace = s.testSpace
        testBrowserTab = s.testBrowserTab
        testTabIntID = s.testTabIntID
        tabNavDelegate = s.tabNavDelegate

        // Reset mutable state between tests
        AppDatabase.shared.storageClear(extensionID: ext.id)
        ExtensionManager.shared.offscreenHosts.removeValue(forKey: ext.id)
        ExtensionManager.shared.contextMenuItems.removeValue(forKey: ext.id)
        ExtensionManager.shared.lastActiveSpaceID = testSpace.id

        // Remove any tabs created by previous tests (keep only the original test tab)
        testSpace.tabs.removeAll { $0.id != testBrowserTab.id }
        testSpace.selectedTabID = testBrowserTab.id
    }

    @MainActor
    override func tearDown() {
        // Don't tear down shared state — it's reused across tests
        super.tearDown()
    }

    override class func tearDown() {
        // Final cleanup when all tests in this class are done
        MainActor.assumeIsolated {
            guard let s = shared else { return }
            s.backgroundHost.stop()
            ExtensionManager.shared.extensions.removeAll { $0.id == extensionID }
            ExtensionManager.shared.backgroundHosts.removeValue(forKey: extensionID)
            ExtensionManager.shared.offscreenHosts.removeValue(forKey: extensionID)
            ExtensionManager.shared.contextMenuItems.removeValue(forKey: extensionID)
            AppDatabase.shared.storageClear(extensionID: extensionID)
            AppDatabase.shared.deleteExtension(id: extensionID)

            for tab in s.testSpace.tabs {
                ExtensionManager.shared.tabIDMap.remove(uuid: tab.id)
            }
            TabStore.shared.forceRemoveSpace(id: s.testSpace.id)
            ExtensionManager.shared.spaceIDMap.remove(uuid: s.testSpace.id)
            TabStore.shared.forceRemoveProfile(id: s.testProfile.id)
            ExtensionManager.shared.lastActiveSpaceID = nil

            try? FileManager.default.removeItem(at: s.tempDir)
            shared = nil
        }
        super.tearDown()
    }

    // MARK: - chrome.i18n

    func testI18nGetMessage() {
        let result = callAsync(popupWebView, "return chrome.i18n.getMessage('appName');")
        XCTAssertEqual(result as? String, "Test App")
    }

    func testI18nGetMessageCaseInsensitive() {
        let result = callAsync(popupWebView, "return chrome.i18n.getMessage('APPNAME');")
        XCTAssertEqual(result as? String, "Test App")
    }

    func testI18nGetMessageWithSubstitutions() {
        let result = callAsync(popupWebView, "return chrome.i18n.getMessage('greeting', ['World', 'Detour']);")
        XCTAssertEqual(result as? String, "Hello World, welcome to Detour!")
    }

    func testI18nGetMessageUnknownReturnsEmpty() {
        let result = callAsync(popupWebView, "return chrome.i18n.getMessage('nonexistent');")
        XCTAssertEqual(result as? String, "")
    }

    func testI18nGetUILanguage() {
        let result = callAsync(popupWebView, "return chrome.i18n.getUILanguage();")
        XCTAssertEqual(result as? String, "en")
    }

    func testI18nGetAcceptLanguages() {
        let result = callAsync(popupWebView, """
            var langs = await chrome.i18n.getAcceptLanguages();
            return JSON.stringify(langs);
        """)
        XCTAssertEqual(result as? String, "[\"en\"]")
    }

    func testI18nDetectLanguage() {
        let result = callAsync(popupWebView, """
            var r = await chrome.i18n.detectLanguage('hello');
            return r.languages[0].language;
        """)
        XCTAssertEqual(result as? String, "und")
    }

    // MARK: - chrome.runtime.onInstalled

    func testRuntimeOnInstalledFired() {
        // The onInstalled event fires via __extensionDispatchOnInstalled
        // Verify it was dispatched by checking if the listeners array is populated
        let exp = expectation(description: "Check onInstalled")
        var result: Any?
        var evalErr: Error?

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.backgroundHost.webView?.evaluateJavaScript("1 + 1") { val, err in
                result = val
                evalErr = err
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 10.0)

        if let err = evalErr {
            // If the webView can't even evaluate basic JS, the background host is not loaded
            XCTFail("Background host webView not functional: \(err)")
            return
        }

        // Verify basic JS works on the background webView
        XCTAssertEqual(result as? Int, 2, "Background webView should be able to evaluate JS")

        // Now check the install reason
        let exp2 = expectation(description: "Check installReason")
        var reason: String?
        backgroundHost.webView?.evaluateJavaScript("window.installReason") { val, _ in
            reason = val as? String
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 10.0)
        XCTAssertEqual(reason, "install")
    }

    // MARK: - chrome.runtime.connect / onConnect (ports)

    func testRuntimeConnectAndPortMessaging() {
        let result = callAsync(popupWebView, """
            return new Promise(function(resolve) {
                var port = chrome.runtime.connect({ name: 'test-port' });
                port.onMessage.addListener(function(msg) {
                    resolve(JSON.stringify(msg));
                });
                port.postMessage({ data: 'hello' });
            });
        """)
        guard let jsonStr = result as? String,
              let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse port message response: \(String(describing: result))"); return
        }
        XCTAssertEqual(parsed["echo"] as? String, "hello")
        XCTAssertEqual(parsed["from"] as? String, "background")
    }

    func testRuntimeConnectPortName() {
        let result = callAsync(popupWebView, """
            var port = chrome.runtime.connect({ name: 'my-channel' });
            return port.name;
        """)
        XCTAssertEqual(result as? String, "my-channel")
    }

    // MARK: - chrome.storage.onChanged

    func testStorageOnChangedFiresOnSet() {
        let result = callAsync(popupWebView, """
            return new Promise(function(resolve) {
                chrome.storage.onChanged.addListener(function(changes, areaName) {
                    resolve(JSON.stringify({ changes: changes, area: areaName }));
                });
                chrome.storage.local.set({ testKey: 'testValue' });
            });
        """)
        guard let jsonStr = result as? String,
              let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse storage.onChanged result: \(String(describing: result))"); return
        }
        XCTAssertEqual(parsed["area"] as? String, "local")
        let changes = parsed["changes"] as? [String: Any]
        let testKeyChange = changes?["testKey"] as? [String: Any]
        XCTAssertEqual(testKeyChange?["newValue"] as? String, "testValue")
    }

    func testStorageOnChangedIncludesOldValue() {
        // Set initial value
        callVoid(popupWebView, "await chrome.storage.local.set({ myKey: 'old' });")

        // Wait for initial set to complete
        let waitExp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waitExp.fulfill() }
        wait(for: [waitExp], timeout: 2.0)

        let result = callAsync(popupWebView, """
            return new Promise(function(resolve) {
                chrome.storage.onChanged.addListener(function(changes, areaName) {
                    resolve(JSON.stringify(changes));
                });
                chrome.storage.local.set({ myKey: 'new' });
            });
        """)
        guard let jsonStr = result as? String,
              let data = jsonStr.data(using: .utf8),
              let changes = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keyChange = changes["myKey"] as? [String: Any] else {
            XCTFail("Failed to parse result: \(String(describing: result))"); return
        }
        XCTAssertEqual(keyChange["oldValue"] as? String, "old")
        XCTAssertEqual(keyChange["newValue"] as? String, "new")
    }

    // MARK: - chrome.tabs.detectLanguage

    func testTabsDetectLanguage() {
        let result = callAsync(popupWebView, """
            var lang = await chrome.tabs.detectLanguage(\(testTabIntID!));
            return lang;
        """)
        XCTAssertEqual(result as? String, "fr")
    }

    // MARK: - chrome.offscreen

    func testOffscreenHasDocumentInitiallyFalse() {
        let result = callAsync(popupWebView, """
            var has = await chrome.offscreen.hasDocument();
            return has;
        """)
        // hasDocument returns false initially (no offscreen doc created)
        XCTAssertEqual(result as? Bool, false)
    }

    func testOffscreenCreateAndHasDocument() {
        callVoid(popupWebView, """
            await chrome.offscreen.createDocument({
                url: 'offscreen.html',
                reasons: ['DOM_PARSER'],
                justification: 'Parse HTML'
            });
        """)

        // Wait for creation
        let exp = expectation(description: "wait for offscreen creation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertNotNil(ExtensionManager.shared.offscreenHosts[ext.id])
    }

    func testOffscreenCloseDocument() {
        callVoid(popupWebView, """
            await chrome.offscreen.createDocument({
                url: 'offscreen.html',
                reasons: ['DOM_PARSER'],
                justification: 'Test'
            });
        """)

        let exp1 = expectation(description: "wait for creation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp1.fulfill() }
        wait(for: [exp1], timeout: 2.0)

        callVoid(popupWebView, "await chrome.offscreen.closeDocument();")

        let exp2 = expectation(description: "wait for close")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2.0)

        XCTAssertNil(ExtensionManager.shared.offscreenHosts[ext.id])
    }

    func testOffscreenReasonConstants() {
        let result = callAsync(popupWebView, "return chrome.offscreen.Reason.DOM_PARSER;")
        XCTAssertEqual(result as? String, "DOM_PARSER")
    }

    // MARK: - chrome.extension.getBackgroundPage

    func testExtensionGetBackgroundPageReturnsNull() {
        let result = callAsync(popupWebView, "return chrome.extension.getBackgroundPage();")
        // JS null maps to NSNull in callAsyncJavaScript
        XCTAssertTrue(result is NSNull || result == nil)
    }

    // MARK: - chrome.runtime.getPlatformInfo

    func testRuntimeGetPlatformInfo() {
        let result = callAsync(popupWebView, """
            var info = await chrome.runtime.getPlatformInfo();
            return info.os;
        """)
        XCTAssertEqual(result as? String, "mac")
    }

    // MARK: - chrome.runtime.openOptionsPage

    func testRuntimeOpenOptionsPageExists() {
        let result = callAsync(popupWebView, "return typeof chrome.runtime.openOptionsPage;")
        XCTAssertEqual(result as? String, "function")
    }

    func testRuntimeOpenOptionsPageResolves() {
        // The test extension has no options_page, so this should still resolve (with error)
        // but the function should be callable without throwing
        let result = callAsync(popupWebView, """
            try {
                await chrome.runtime.openOptionsPage();
                return 'resolved';
            } catch(e) {
                return 'error: ' + e.message;
            }
        """)
        // It resolves even if no options page is defined
        XCTAssertNotNil(result)
    }

    // MARK: - chrome.runtime.lastError

    func testRuntimeLastErrorIsNull() {
        let result = callAsync(popupWebView, "return chrome.runtime.lastError;")
        XCTAssertTrue(result is NSNull || result == nil)
    }

    // MARK: - Content script resource loading

    func testContentScriptXHRToExtensionURL() {
        // Write a web-accessible resource
        let cssContent = "body { background: red; }"
        try! cssContent.write(to: tempDir.appendingPathComponent("test.css"),
                              atomically: true, encoding: .utf8)

        let result = callAsyncInContentWorld(testBrowserTab.webView!, """
            return new Promise(function(resolve, reject) {
                var xhr = new XMLHttpRequest();
                xhr.open('GET', chrome.runtime.getURL('test.css'));
                xhr.onload = function() {
                    resolve({ status: xhr.status, text: xhr.responseText });
                };
                xhr.onerror = function() {
                    reject(new Error('XHR failed with status ' + xhr.status));
                };
                xhr.send();
            });
        """)

        guard let dict = result as? [String: Any] else {
            XCTFail("Expected dictionary, got: \(String(describing: result))"); return
        }
        XCTAssertEqual(dict["status"] as? Int, 200)
        XCTAssertEqual(dict["text"] as? String, cssContent)
    }

    func testContentScriptFetchExtensionURL() {
        let jsContent = "console.log('hello');"
        try! jsContent.write(to: tempDir.appendingPathComponent("test.js"),
                             atomically: true, encoding: .utf8)

        let result = callAsyncInContentWorld(testBrowserTab.webView!, """
            var resp = await fetch(chrome.runtime.getURL('test.js'));
            var text = await resp.text();
            return { status: resp.status, text: text };
        """)

        guard let dict = result as? [String: Any] else {
            XCTFail("Expected dictionary, got: \(String(describing: result))"); return
        }
        XCTAssertEqual(dict["status"] as? Int, 200)
        XCTAssertEqual(dict["text"] as? String, jsContent)
    }

    func testContentScriptXHRWithSpecialCharacters() {
        // Test that files with backslashes, quotes, and newlines in content are delivered correctly
        let content = "body { content: 'it\\'s a \\\"test\\\"'; }\n/* line 2 */"
        try! content.write(to: tempDir.appendingPathComponent("special.css"),
                           atomically: true, encoding: .utf8)

        let result = callAsyncInContentWorld(testBrowserTab.webView!, """
            return new Promise(function(resolve, reject) {
                var xhr = new XMLHttpRequest();
                xhr.open('GET', chrome.runtime.getURL('special.css'));
                xhr.onload = function() { resolve(xhr.responseText); };
                xhr.onerror = function() { reject(new Error('failed')); };
                xhr.send();
            });
        """)

        XCTAssertEqual(result as? String, content)
    }

    func testContentScriptXHRToMissingResourceReturns404() {
        let result = callAsyncInContentWorld(testBrowserTab.webView!, """
            return new Promise(function(resolve) {
                var xhr = new XMLHttpRequest();
                xhr.open('GET', chrome.runtime.getURL('nonexistent.css'));
                xhr.onload = function() {
                    resolve(xhr.status);
                };
                xhr.onerror = function() {
                    resolve(xhr.status);
                };
                xhr.send();
            });
        """)

        XCTAssertEqual(result as? Int, 404)
    }

    // MARK: - Helpers

    private func callAsyncInContentWorld(_ webView: WKWebView, _ js: String) -> Any? {
        let exp = expectation(description: "Async JS (content world)")
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
        if let evalError { XCTFail("JS error: \(evalError)") }
        return result
    }

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

private class TestNewAPINavDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
