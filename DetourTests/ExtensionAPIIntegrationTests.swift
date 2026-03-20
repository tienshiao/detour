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
    private var webView: WKWebView!          // content script context (ext.contentWorld)
    private var popupWebView: WKWebView!     // popup context (.page world, isContentScript: false)
    private var backgroundHost: BackgroundHost!
    private var navDelegate: TestNavigationDelegate!
    private var popupNavDelegate: TestNavigationDelegate!

    // E2E infrastructure: a real Space + BrowserTab in TabStore for testing
    // tabs.create/remove/get/update, tabs.sendMessage, scripting.* etc.
    private var testProfile: Profile!
    private var testSpace: Space!
    private var testBrowserTab: BrowserTab!
    private var testTabIntID: Int!
    private var tabNavDelegate: TestNavigationDelegate!

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
            "permissions": ["storage", "tabs", "scripting"],
            "host_permissions": ["<all_urls>"],
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
        AppDatabase.shared.saveExtension(record)

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

        // Set up a popup-like WKWebView with chrome APIs in .page world (isContentScript: false)
        let popupConfig = WKWebViewConfiguration()
        let popupAPIBundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: false)
        let popupAPIScript = WKUserScript(
            source: popupAPIBundle,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        popupConfig.userContentController.addUserScript(popupAPIScript)
        ExtensionMessageBridge.shared.register(on: popupConfig.userContentController)

        popupWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                                  configuration: popupConfig)

        // Set up navigation delegates BEFORE loading
        let navExpectation = expectation(description: "Page loaded")
        navDelegate = TestNavigationDelegate { navExpectation.fulfill() }
        webView.navigationDelegate = navDelegate

        let popupNavExpectation = expectation(description: "Popup page loaded")
        popupNavDelegate = TestNavigationDelegate { popupNavExpectation.fulfill() }
        popupWebView.navigationDelegate = popupNavDelegate

        // Start background host
        backgroundHost = BackgroundHost(extension: ext)
        ExtensionManager.shared.backgroundHosts[extID] = backgroundHost
        backgroundHost.start()

        // Write injectable test files for scripting.executeScript / insertCSS tests
        try! "document.title;".write(
            to: tempDir.appendingPathComponent("inject.js"), atomically: true, encoding: .utf8)
        try! "body { --test-injected: 1; outline: 4px solid red !important; }".write(
            to: tempDir.appendingPathComponent("inject.css"), atomically: true, encoding: .utf8)

        // Create a real Space + BrowserTab in TabStore for E2E bridge tests
        testProfile = TabStore.shared.addProfile(name: "Test Profile")
        testSpace = TabStore.shared.addSpace(name: "Test Space", emoji: "T", colorHex: "#000000", profileID: testProfile.id)
        ExtensionManager.shared.lastActiveSpaceID = testSpace.id

        // Create a tab WebView with content script APIs (needed for tabs.sendMessage / scripting)
        let tabConfig = WKWebViewConfiguration()
        let tabAPIBundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: true)
        let tabAPIScript = WKUserScript(
            source: tabAPIBundle,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: ext.contentWorld
        )
        tabConfig.userContentController.addUserScript(tabAPIScript)
        ExtensionMessageBridge.shared.register(on: tabConfig.userContentController,
                                                contentWorld: ext.contentWorld)

        let tabWV = WKWebView(frame: .zero, configuration: tabConfig)
        testBrowserTab = BrowserTab(webView: tabWV)
        testSpace.tabs.append(testBrowserTab)
        testSpace.selectedTabID = testBrowserTab.id
        testTabIntID = ExtensionManager.shared.tabIDMap.intID(for: testBrowserTab.id)

        // Load all pages
        let html = "<html><body>test</body></html>"
        webView.loadHTMLString(html, baseURL: URL(string: "https://test.example.com")!)
        popupWebView.loadHTMLString(html, baseURL: URL(string: "https://popup.test.example.com")!)

        let tabNavExpectation = expectation(description: "Tab page loaded")
        tabNavDelegate = TestNavigationDelegate { tabNavExpectation.fulfill() }
        tabWV.navigationDelegate = tabNavDelegate
        tabWV.loadHTMLString(
            "<html><head><title>Test Tab Page</title></head><body>tab content</body></html>",
            baseURL: URL(string: "https://tab.test.example.com")!)

        // Wait for all navigations + background init
        wait(for: [navExpectation, popupNavExpectation, tabNavExpectation], timeout: 10.0)

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
            AppDatabase.shared.storageClear(extensionID: extID)
            AppDatabase.shared.deleteExtension(id: extID)
        }

        // Clean up E2E test infrastructure
        if let spaceID = testSpace?.id {
            // Remove all tabs from the space first so deleteSpace doesn't leave dangling refs
            for tab in testSpace.tabs {
                ExtensionManager.shared.tabIDMap.remove(uuid: tab.id)
            }
            TabStore.shared.forceRemoveSpace(id: spaceID)
            ExtensionManager.shared.spaceIDMap.remove(uuid: spaceID)
        }
        if let profileID = testProfile?.id {
            TabStore.shared.forceRemoveProfile(id: profileID)
        }
        ExtensionManager.shared.lastActiveSpaceID = nil
        testBrowserTab = nil
        testSpace = nil
        testProfile = nil
        tabNavDelegate = nil

        webView = nil
        popupWebView = nil
        navDelegate = nil
        popupNavDelegate = nil
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

    // MARK: - chrome.tabs

    func testTabsNamespaceExists() {
        let result = evalSync("typeof chrome.tabs")
        XCTAssertEqual(result as? String, "object")
    }

    func testTabsQueryIsFunction() {
        let result = evalSync("typeof chrome.tabs.query")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsCreateIsFunction() {
        let result = evalSync("typeof chrome.tabs.create")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsUpdateIsFunction() {
        let result = evalSync("typeof chrome.tabs.update")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsRemoveIsFunction() {
        let result = evalSync("typeof chrome.tabs.remove")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsGetIsFunction() {
        let result = evalSync("typeof chrome.tabs.get")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsSendMessageIsFunction() {
        let result = evalSync("typeof chrome.tabs.sendMessage")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsOnCreatedEventEmitter() {
        let result = evalSync("""
            typeof chrome.tabs.onCreated.addListener === 'function' &&
            typeof chrome.tabs.onCreated.removeListener === 'function' &&
            typeof chrome.tabs.onCreated.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsOnRemovedEventEmitter() {
        let result = evalSync("""
            typeof chrome.tabs.onRemoved.addListener === 'function' &&
            typeof chrome.tabs.onRemoved.removeListener === 'function' &&
            typeof chrome.tabs.onRemoved.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsOnUpdatedEventEmitter() {
        let result = evalSync("""
            typeof chrome.tabs.onUpdated.addListener === 'function' &&
            typeof chrome.tabs.onUpdated.removeListener === 'function' &&
            typeof chrome.tabs.onUpdated.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsOnActivatedEventEmitter() {
        let result = evalSync("""
            typeof chrome.tabs.onActivated.addListener === 'function' &&
            typeof chrome.tabs.onActivated.removeListener === 'function' &&
            typeof chrome.tabs.onActivated.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsQueryReturnsPromise() {
        let result = evalSync("chrome.tabs.query({}) instanceof Promise")
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsCreateReturnsPromise() {
        let result = evalSync("chrome.tabs.create({}) instanceof Promise")
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsEventListenerAddAndHas() {
        let result = evalSync("""
            (function() {
                var listener = function() {};
                chrome.tabs.onCreated.addListener(listener);
                var has = chrome.tabs.onCreated.hasListener(listener);
                chrome.tabs.onCreated.removeListener(listener);
                var hasAfter = chrome.tabs.onCreated.hasListener(listener);
                return has && !hasAfter;
            })()
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsDispatchEventFunctionExists() {
        let result = evalSync("typeof window.__extensionDispatchTabEvent")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsDispatchEventFiresOnCreated() {
        let result = evalSync("""
            (function() {
                var received = null;
                chrome.tabs.onCreated.addListener(function(tab) { received = tab; });
                window.__extensionDispatchTabEvent('onCreated', { tab: { id: 42, url: 'https://example.com' } });
                return received ? received.id : null;
            })()
        """)
        XCTAssertEqual(result as? Int, 42)
    }

    func testTabsDispatchEventFiresOnRemoved() {
        let result = evalSync("""
            (function() {
                var receivedId = null;
                var receivedInfo = null;
                chrome.tabs.onRemoved.addListener(function(tabId, removeInfo) {
                    receivedId = tabId;
                    receivedInfo = removeInfo;
                });
                window.__extensionDispatchTabEvent('onRemoved', { tabId: 7, removeInfo: { windowId: 1, isWindowClosing: false } });
                return receivedId === 7 && receivedInfo.windowId === 1;
            })()
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsDispatchEventFiresOnUpdated() {
        let result = evalSync("""
            (function() {
                var receivedTabId = null;
                var receivedChangeInfo = null;
                var receivedTab = null;
                chrome.tabs.onUpdated.addListener(function(tabId, changeInfo, tab) {
                    receivedTabId = tabId;
                    receivedChangeInfo = changeInfo;
                    receivedTab = tab;
                });
                window.__extensionDispatchTabEvent('onUpdated', {
                    tabId: 5,
                    changeInfo: { status: 'complete', url: 'https://example.com' },
                    tab: { id: 5, url: 'https://example.com' }
                });
                return receivedTabId === 5 && receivedChangeInfo.status === 'complete' && receivedTab.id === 5;
            })()
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsDispatchEventFiresOnActivated() {
        let result = evalSync("""
            (function() {
                var receivedInfo = null;
                chrome.tabs.onActivated.addListener(function(activeInfo) {
                    receivedInfo = activeInfo;
                });
                window.__extensionDispatchTabEvent('onActivated', { activeInfo: { tabId: 3, windowId: 1 } });
                return receivedInfo.tabId === 3 && receivedInfo.windowId === 1;
            })()
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - chrome.scripting

    func testScriptingNamespaceExists() {
        let result = evalSync("typeof chrome.scripting")
        XCTAssertEqual(result as? String, "object")
    }

    func testScriptingExecuteScriptIsFunction() {
        let result = evalSync("typeof chrome.scripting.executeScript")
        XCTAssertEqual(result as? String, "function")
    }

    func testScriptingInsertCSSIsFunction() {
        let result = evalSync("typeof chrome.scripting.insertCSS")
        XCTAssertEqual(result as? String, "function")
    }

    func testScriptingRemoveCSSIsFunction() {
        let result = evalSync("typeof chrome.scripting.removeCSS")
        XCTAssertEqual(result as? String, "function")
    }

    func testScriptingExecuteScriptReturnsPromise() {
        let result = evalSync("chrome.scripting.executeScript({ target: { tabId: 1 } }) instanceof Promise")
        XCTAssertEqual(result as? Bool, true)
    }

    func testScriptingInsertCSSReturnsPromise() {
        let result = evalSync("chrome.scripting.insertCSS({ target: { tabId: 1 } }) instanceof Promise")
        XCTAssertEqual(result as? Bool, true)
    }

    func testScriptingRemoveCSSReturnsResolvedPromise() {
        // removeCSS is a no-op stub that resolves immediately
        let result = callAsync("await chrome.scripting.removeCSS({ target: { tabId: 1 } }); return true;")
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - chrome.webNavigation

    func testWebNavigationNamespaceExists() {
        let result = evalSync("typeof chrome.webNavigation")
        XCTAssertEqual(result as? String, "object")
    }

    func testWebNavigationOnBeforeNavigateEventEmitter() {
        let result = evalSync("""
            typeof chrome.webNavigation.onBeforeNavigate.addListener === 'function' &&
            typeof chrome.webNavigation.onBeforeNavigate.removeListener === 'function' &&
            typeof chrome.webNavigation.onBeforeNavigate.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWebNavigationOnCommittedEventEmitter() {
        let result = evalSync("""
            typeof chrome.webNavigation.onCommitted.addListener === 'function' &&
            typeof chrome.webNavigation.onCommitted.removeListener === 'function' &&
            typeof chrome.webNavigation.onCommitted.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWebNavigationOnCompletedEventEmitter() {
        let result = evalSync("""
            typeof chrome.webNavigation.onCompleted.addListener === 'function' &&
            typeof chrome.webNavigation.onCompleted.removeListener === 'function' &&
            typeof chrome.webNavigation.onCompleted.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWebNavigationOnErrorOccurredEventEmitter() {
        let result = evalSync("""
            typeof chrome.webNavigation.onErrorOccurred.addListener === 'function' &&
            typeof chrome.webNavigation.onErrorOccurred.removeListener === 'function' &&
            typeof chrome.webNavigation.onErrorOccurred.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWebNavigationDispatchEventFunctionExists() {
        let result = evalSync("typeof window.__extensionDispatchWebNavEvent")
        XCTAssertEqual(result as? String, "function")
    }

    func testWebNavigationDispatchEventFiresOnCommitted() {
        let result = evalSync("""
            (function() {
                var received = null;
                chrome.webNavigation.onCommitted.addListener(function(details) { received = details; });
                window.__extensionDispatchWebNavEvent('onCommitted', { tabId: 10, url: 'https://example.com', frameId: 0 });
                return received ? received.tabId === 10 && received.url === 'https://example.com' : false;
            })()
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWebNavigationDispatchEventFiresOnCompleted() {
        let result = evalSync("""
            (function() {
                var received = null;
                chrome.webNavigation.onCompleted.addListener(function(details) { received = details; });
                window.__extensionDispatchWebNavEvent('onCompleted', { tabId: 11, url: 'https://test.com', frameId: 0 });
                return received ? received.tabId === 11 : false;
            })()
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWebNavigationListenerAddAndRemove() {
        let result = evalSync("""
            (function() {
                var listener = function() {};
                chrome.webNavigation.onCommitted.addListener(listener);
                var has = chrome.webNavigation.onCommitted.hasListener(listener);
                chrome.webNavigation.onCommitted.removeListener(listener);
                var hasAfter = chrome.webNavigation.onCommitted.hasListener(listener);
                return has && !hasAfter;
            })()
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - chrome.webRequest (stubs)

    func testWebRequestNamespaceExists() {
        let result = evalSync("typeof chrome.webRequest")
        XCTAssertEqual(result as? String, "object")
    }

    func testWebRequestOnBeforeRequestExists() {
        let result = evalSync("""
            typeof chrome.webRequest.onBeforeRequest.addListener === 'function' &&
            typeof chrome.webRequest.onBeforeRequest.removeListener === 'function' &&
            typeof chrome.webRequest.onBeforeRequest.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWebRequestOnHeadersReceivedExists() {
        let result = evalSync("""
            typeof chrome.webRequest.onHeadersReceived.addListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWebRequestStubDoesNotCrash() {
        // Calling addListener should succeed without error
        let result = evalSync("""
            (function() {
                chrome.webRequest.onBeforeRequest.addListener(function() {}, { urls: ['<all_urls>'] });
                chrome.webRequest.onBeforeSendHeaders.addListener(function() {}, { urls: ['<all_urls>'] });
                chrome.webRequest.onCompleted.addListener(function() {}, { urls: ['<all_urls>'] });
                return true;
            })()
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWebRequestHasListenerReturnsFalse() {
        // Since listeners are no-ops, hasListener always returns false
        let result = evalSync("""
            (function() {
                var fn = function() {};
                chrome.webRequest.onBeforeRequest.addListener(fn, { urls: ['<all_urls>'] });
                return chrome.webRequest.onBeforeRequest.hasListener(fn);
            })()
        """)
        XCTAssertEqual(result as? Bool, false)
    }

    func testWebRequestAllEventsExist() {
        let result = evalSync("""
            typeof chrome.webRequest.onBeforeRequest === 'object' &&
            typeof chrome.webRequest.onBeforeSendHeaders === 'object' &&
            typeof chrome.webRequest.onSendHeaders === 'object' &&
            typeof chrome.webRequest.onHeadersReceived === 'object' &&
            typeof chrome.webRequest.onAuthRequired === 'object' &&
            typeof chrome.webRequest.onResponseStarted === 'object' &&
            typeof chrome.webRequest.onBeforeRedirect === 'object' &&
            typeof chrome.webRequest.onCompleted === 'object' &&
            typeof chrome.webRequest.onErrorOccurred === 'object'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - chrome.tabs.query end-to-end (via message bridge)

    func testTabsQueryReturnsArray() {
        let result = callAsync("var tabs = await chrome.tabs.query({}); return Array.isArray(tabs);")
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsQueryResultHasExpectedShape() {
        // Query returns an array; each element (if any) should have at least an 'id' field
        let result = callAsync("""
            var tabs = await chrome.tabs.query({});
            if (tabs.length === 0) return true;
            var first = tabs[0];
            return typeof first.id === 'number' && typeof first.windowId === 'number' &&
                   typeof first.active === 'boolean' && typeof first.incognito === 'boolean';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - Background host dispatch functions

    func testBackgroundTabEventDispatchExists() {
        let exp = expectation(description: "BG eval")
        var result: Any?
        backgroundHost.evaluateJavaScript("typeof window.__extensionDispatchTabEvent") { val, _ in
            result = val
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(result as? String, "function")
    }

    func testBackgroundWebNavEventDispatchExists() {
        let exp = expectation(description: "BG eval")
        var result: Any?
        backgroundHost.evaluateJavaScript("typeof window.__extensionDispatchWebNavEvent") { val, _ in
            result = val
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(result as? String, "function")
    }

    func testBackgroundTabsNamespaceExists() {
        let exp = expectation(description: "BG eval")
        var result: Any?
        backgroundHost.evaluateJavaScript("typeof chrome.tabs") { val, _ in
            result = val
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(result as? String, "object")
    }

    func testBackgroundTabsQueryExists() {
        let exp = expectation(description: "BG eval")
        var result: Any?
        backgroundHost.evaluateJavaScript("typeof chrome.tabs.query") { val, _ in
            result = val
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(result as? String, "function")
    }

    func testBackgroundScriptingNamespaceExists() {
        let exp = expectation(description: "BG eval")
        var result: Any?
        backgroundHost.evaluateJavaScript("typeof chrome.scripting") { val, _ in
            result = val
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(result as? String, "object")
    }

    func testBackgroundWebNavigationExists() {
        let exp = expectation(description: "BG eval")
        var result: Any?
        backgroundHost.evaluateJavaScript("typeof chrome.webNavigation") { val, _ in
            result = val
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(result as? String, "object")
    }

    func testBackgroundWebRequestExists() {
        let exp = expectation(description: "BG eval")
        var result: Any?
        backgroundHost.evaluateJavaScript("typeof chrome.webRequest") { val, _ in
            result = val
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(result as? String, "object")
    }

    func testBackgroundTabEventListenerReceivesOnCreated() {
        // Register a listener in background and dispatch an event
        let setupExp = expectation(description: "Setup listener")
        backgroundHost.evaluateJavaScript("""
            window.__testOnCreatedTab = null;
            chrome.tabs.onCreated.addListener(function(tab) { window.__testOnCreatedTab = tab; });
        """) { _, _ in setupExp.fulfill() }
        wait(for: [setupExp], timeout: 5.0)

        // Dispatch event
        let dispatchExp = expectation(description: "Dispatch event")
        backgroundHost.evaluateJavaScript("""
            window.__extensionDispatchTabEvent('onCreated', { tab: { id: 99, url: 'https://dispatched.test' } });
        """) { _, _ in dispatchExp.fulfill() }
        wait(for: [dispatchExp], timeout: 5.0)

        // Verify
        let checkExp = expectation(description: "Check")
        var result: Any?
        backgroundHost.evaluateJavaScript("window.__testOnCreatedTab ? window.__testOnCreatedTab.id : null") { val, _ in
            result = val
            checkExp.fulfill()
        }
        wait(for: [checkExp], timeout: 5.0)
        XCTAssertEqual(result as? Int, 99)
    }

    // MARK: - tabs.query E2E with filters

    func testTabsQueryReturnsTestTab() {
        let result = popupCallAsync("""
            var tabs = await chrome.tabs.query({});
            return tabs.some(function(t) { return t.id === \(testTabIntID!); });
        """)
        XCTAssertEqual(result as? Bool, true, "Query should return the test tab")
    }

    func testTabsQueryActiveFilter() {
        let result = popupCallAsync("""
            var tabs = await chrome.tabs.query({ active: true });
            return tabs.length > 0 && tabs.every(function(t) { return t.active === true; });
        """)
        XCTAssertEqual(result as? Bool, true, "Active filter should only return active tabs")
    }

    func testTabsQueryActiveFilterIncludesTestTab() {
        // testBrowserTab is the selectedTabID, so it should be active
        let result = popupCallAsync("""
            var tabs = await chrome.tabs.query({ active: true });
            return tabs.some(function(t) { return t.id === \(testTabIntID!); });
        """)
        XCTAssertEqual(result as? Bool, true, "Active filter should include the selected test tab")
    }

    func testTabsQueryCurrentWindowFilter() {
        let result = popupCallAsync("""
            var tabs = await chrome.tabs.query({ currentWindow: true });
            return tabs.some(function(t) { return t.id === \(testTabIntID!); });
        """)
        XCTAssertEqual(result as? Bool, true, "currentWindow filter should include test tab")
    }

    func testTabsQueryTitleFilter() {
        let result = popupCallAsync("""
            var tabs = await chrome.tabs.query({ title: 'Test Tab Page' });
            return tabs.some(function(t) { return t.id === \(testTabIntID!); });
        """)
        XCTAssertEqual(result as? Bool, true, "Title filter should match test tab")
    }

    // MARK: - tabs.get E2E

    func testTabsGetE2E() {
        let result = popupCallAsync("""
            var tab = await chrome.tabs.get(\(testTabIntID!));
            return typeof tab.id === 'number' && tab.id === \(testTabIntID!) &&
                   typeof tab.active === 'boolean' && typeof tab.windowId === 'number';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsGetInvalidIDRejects() {
        let result = popupCallAsync("""
            try {
                await chrome.tabs.get(999999);
                return 'resolved';
            } catch (e) {
                return 'rejected: ' + e.message;
            }
        """)
        let str = result as? String ?? ""
        XCTAssertTrue(str.hasPrefix("rejected:"), "tabs.get with invalid ID should reject")
    }

    // MARK: - tabs.create E2E

    func testTabsCreateE2E() {
        let initialCount = testSpace.tabs.count
        let result = popupCallAsync("""
            var tab = await chrome.tabs.create({ url: 'https://created.test.example.com' });
            return typeof tab.id === 'number' && typeof tab.windowId === 'number';
        """)
        XCTAssertEqual(result as? Bool, true)
        XCTAssertEqual(testSpace.tabs.count, initialCount + 1, "Tab should be added to the space")
    }

    // MARK: - tabs.remove E2E

    func testTabsRemoveE2E() {
        // First create a tab to remove
        let createResult = popupCallAsync("""
            var tab = await chrome.tabs.create({ url: 'https://removeme.test' });
            return tab.id;
        """)
        guard let createdID = createResult as? Int else {
            XCTFail("Failed to create tab for removal test")
            return
        }
        let countBefore = testSpace.tabs.count
        let result = popupCallAsync("""
            await chrome.tabs.remove(\(createdID));
            return true;
        """)
        XCTAssertEqual(result as? Bool, true)
        XCTAssertEqual(testSpace.tabs.count, countBefore - 1, "Tab should be removed from the space")
    }

    func testTabsRemoveInvalidIDDoesNotCrash() {
        let result = popupCallAsync("""
            await chrome.tabs.remove(999999);
            return true;
        """)
        XCTAssertEqual(result as? Bool, true, "Removing a non-existent tab should resolve gracefully")
    }

    // MARK: - tabs.sendMessage E2E (popup → content script → sendResponse → popup)

    func testTabsSendMessageE2E() {
        // Register a listener in the tab's content world
        tabCallAsyncVoid("""
            chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
                if (message.type === 'test-msg') {
                    sendResponse({ reply: 'received', data: message.data });
                }
                return true;
            });
        """)

        // Send from popup via chrome.tabs.sendMessage
        let result = popupCallAsync("""
            var response = await chrome.tabs.sendMessage(\(testTabIntID!), { type: 'test-msg', data: 42 });
            return JSON.stringify(response);
        """)

        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse tabs.sendMessage response: \(String(describing: result))")
            return
        }
        XCTAssertEqual(json["reply"] as? String, "received")
        XCTAssertEqual(json["data"] as? Int, 42)
    }

    // MARK: - scripting.executeScript E2E

    func testScriptingExecuteScriptWithFiles() {
        let result = popupCallAsync("""
            var results = await chrome.scripting.executeScript({
                target: { tabId: \(testTabIntID!) },
                files: ['inject.js']
            });
            return JSON.stringify(results);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Failed to parse executeScript result: \(String(describing: result))")
            return
        }
        XCTAssertEqual(arr.count, 1)
        // inject.js evaluates `document.title;` — should return the tab's page title
        XCTAssertEqual(arr[0]["result"] as? String, "Test Tab Page")
    }

    // MARK: - scripting.insertCSS E2E

    func testScriptingInsertCSSWithFiles() {
        let result = popupCallAsync("""
            await chrome.scripting.insertCSS({
                target: { tabId: \(testTabIntID!) },
                files: ['inject.css']
            });
            return true;
        """)
        XCTAssertEqual(result as? Bool, true, "insertCSS should resolve without error")
    }

    // MARK: - Cross-context storage

    func testCrossContextStorageContentToPopup() {
        // Content script writes a value
        callAsyncVoid("await chrome.storage.local.set({ crossCtx: 'from-content' })")
        // Popup reads it
        let result = popupCallAsync("var r = await chrome.storage.local.get('crossCtx'); return r.crossCtx;")
        XCTAssertEqual(result as? String, "from-content")
    }

    func testCrossContextStoragePopupToContent() {
        // Popup writes a value
        popupCallAsyncVoid("await chrome.storage.local.set({ crossCtx2: 'from-popup' })")
        // Content script reads it
        let result = callAsync("var r = await chrome.storage.local.get('crossCtx2'); return r.crossCtx2;")
        XCTAssertEqual(result as? String, "from-popup")
    }

    // MARK: - Popup sendMessage → background sendResponse

    func testPopupSendMessageToBackground() {
        // This is the exact scenario that was broken: popup (.page world) sends a message
        // to background, background calls sendResponse, response must route back to .page world.
        let result = popupCallAsync("""
            var response = await chrome.runtime.sendMessage({ type: 'ping' });
            return JSON.stringify(response);
        """)
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

    func testPopupSendMessageCallback() {
        // Verify the callback-style API also works from popup context
        let result = popupCallAsync("""
            return await new Promise(function(resolve) {
                chrome.runtime.sendMessage({ type: 'ping' }, function(response) {
                    resolve(response.type);
                });
            });
        """)
        XCTAssertEqual(result as? String, "pong")
    }

    // MARK: - Popup direct chrome.tabs calls

    func testPopupTabsQueryDirect() {
        let result = popupCallAsync("var tabs = await chrome.tabs.query({}); return Array.isArray(tabs);")
        XCTAssertEqual(result as? Bool, true)
    }

    func testPopupTabsQueryResultShape() {
        let result = popupCallAsync("""
            var tabs = await chrome.tabs.query({});
            if (tabs.length === 0) return true;
            var first = tabs[0];
            return typeof first.id === 'number' && typeof first.windowId === 'number' &&
                   typeof first.active === 'boolean';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testPopupStorageDirect() {
        popupCallAsyncVoid("await chrome.storage.local.set({ popupKey: 'popupVal' })")
        let result = popupCallAsync("var r = await chrome.storage.local.get('popupKey'); return r.popupKey;")
        XCTAssertEqual(result as? String, "popupVal")
    }

    func testPopupChromeAPIsInPageWorld() {
        // Popup APIs should be accessible in .page world (no content world needed)
        let exp = expectation(description: "Popup page world eval")
        var result: Any?
        popupWebView.evaluateJavaScript("typeof chrome.runtime.id") { value, _ in
            result = value
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(result as? String, "string",
                       "chrome.* APIs should be available in .page world for popup webViews")
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

    /// Evaluate async JavaScript in the popup webView (.page world).
    private func popupCallAsync(_ js: String) -> Any? {
        let exp = expectation(description: "Popup async JS eval")
        var result: Any?
        var evalError: Error?
        popupWebView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { res in
            switch res {
            case .success(let value): result = value
            case .failure(let error): evalError = error
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        if let evalError {
            XCTFail("Popup async JS evaluation error: \(evalError)")
        }
        return result
    }

    /// Fire-and-forget async JS evaluation in the popup webView.
    private func popupCallAsyncVoid(_ js: String) {
        _ = popupCallAsync(js)
    }

    /// Evaluate async JavaScript in the test tab's content world.
    private func tabCallAsync(_ js: String) -> Any? {
        guard let wv = testBrowserTab.webView else { XCTFail("Tab webView is nil"); return nil }
        let exp = expectation(description: "Tab async JS eval")
        var result: Any?
        var evalError: Error?
        wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: ext.contentWorld) { res in
            switch res {
            case .success(let value): result = value
            case .failure(let error): evalError = error
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        if let evalError {
            XCTFail("Tab async JS evaluation error: \(evalError)")
        }
        return result
    }

    /// Fire-and-forget async JS evaluation in the test tab's content world.
    private func tabCallAsyncVoid(_ js: String) {
        _ = tabCallAsync(js)
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
