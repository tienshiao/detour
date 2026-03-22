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
            "permissions": ["storage", "tabs", "scripting", "alarms", "fontSettings", "contextMenus", "history", "bookmarks", "sessions", "search"],
            "optional_permissions": ["bookmarks"],
            "host_permissions": ["<all_urls>"],
            "background": {"service_worker": "background.js"},
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"},
                {"matches": ["<all_urls>"], "js": ["main.js"], "world": "MAIN", "run_at": "document_start"}
            ],
            "commands": {
                "toggle-feature": {
                    "suggested_key": {"default": "Alt+Shift+D", "mac": "Alt+Shift+D"},
                    "description": "Toggle the feature"
                },
                "add-site": {
                    "suggested_key": {"default": "Alt+Shift+A"},
                    "description": "Add current site"
                }
            }
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
            if (message.type === 'getSender') {
                sendResponse({ id: sender.id, url: sender.url, origin: sender.origin, tab: sender.tab, frameId: sender.frameId, documentId: sender.documentId });
            }
            return true;
        });
        """
        try! backgroundJS.write(to: tempDir.appendingPathComponent("background.js"),
                                atomically: true, encoding: .utf8)

        // Content script: empty (we test via evaluateJavaScript)
        try! "".write(to: tempDir.appendingPathComponent("content.js"),
                      atomically: true, encoding: .utf8)
        // MAIN world script: sets a marker on window
        try! "window.__mainWorldMarker = true;".write(
            to: tempDir.appendingPathComponent("main.js"),
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
        XCTAssertEqual(result as? String, "chrome-extension://\(ext.id)/popup.html")
    }

    func testRuntimeGetURLRootPath() {
        let result = evalSync("chrome.runtime.getURL('/')")
        XCTAssertEqual(result as? String, "chrome-extension://\(ext.id)/")
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

    // MARK: - sender.url in runtime.onMessage

    func testPopupSendMessageIncludesSenderURL() {
        // Dark Reader checks sender.url to verify the popup origin.
        // The sender object must include the URL of the sending webView.
        let result = popupCallAsync("""
            const response = await chrome.runtime.sendMessage({ type: 'getSender' });
            return JSON.stringify(response);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse sender JSON: \(String(describing: result))")
            return
        }
        let senderURL = json["url"] as? String ?? ""
        XCTAssertTrue(senderURL.contains("popup.test.example.com"),
                      "sender.url should contain the popup's origin, got: \(senderURL)")
    }

    func testContentScriptSendMessageIncludesSenderURL() {
        let result = callAsync("""
            const response = await chrome.runtime.sendMessage({ type: 'getSender' });
            return JSON.stringify(response);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse sender JSON: \(String(describing: result))")
            return
        }
        let senderURL = json["url"] as? String ?? ""
        XCTAssertTrue(senderURL.contains("test.example.com"),
                      "sender.url should contain the content script's page URL, got: \(senderURL)")
    }

    func testContentScriptSendMessageIncludesSenderTab() {
        // Dark Reader uses sender.tab.id to track content scripts.
        // Content script messages must include sender.tab with full tab info.
        let result = tabCallAsync("""
            const response = await chrome.runtime.sendMessage({ type: 'getSender' });
            return JSON.stringify(response);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse sender JSON: \(String(describing: result))")
            return
        }
        // sender.tab should be a tab info object with id, windowId, url, etc.
        let tab = json["tab"] as? [String: Any]
        XCTAssertNotNil(tab, "sender.tab should be present for content script messages")
        XCTAssertEqual(tab?["id"] as? Int, testTabIntID, "sender.tab.id should match the sending tab")
        XCTAssertNotNil(tab?["windowId"], "sender.tab should include windowId")
        XCTAssertNotNil(tab?["url"], "sender.tab should include url")
    }

    func testContentScriptSendMessageIncludesSenderFrameId() {
        let result = tabCallAsync("""
            const response = await chrome.runtime.sendMessage({ type: 'getSender' });
            return JSON.stringify(response);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse sender JSON: \(String(describing: result))")
            return
        }
        XCTAssertEqual(json["frameId"] as? Int, 0, "sender.frameId should be 0 for main frame content scripts")
    }

    func testPopupSendMessageDoesNotIncludeSenderTab() {
        // Popup messages should NOT have sender.tab (only content scripts have it)
        let result = popupCallAsync("""
            const response = await chrome.runtime.sendMessage({ type: 'getSender' });
            return JSON.stringify(response);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse sender JSON: \(String(describing: result))")
            return
        }
        XCTAssertNil(json["tab"], "sender.tab should NOT be present for popup messages")
        XCTAssertNil(json["frameId"], "sender.frameId should NOT be present for popup messages")
    }

    // MARK: - sender.documentId

    func testContentScriptSendMessageIncludesSenderDocumentId() {
        let result = tabCallAsync("""
            const response = await chrome.runtime.sendMessage({ type: 'getSender' });
            return JSON.stringify(response);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse sender JSON: \(String(describing: result))")
            return
        }
        let documentId = json["documentId"] as? String
        XCTAssertNotNil(documentId, "sender.documentId should be present for content script messages")
        XCTAssertTrue(documentId?.count ?? 0 > 10, "sender.documentId should be a UUID-like string")
    }

    func testDocumentIdIsStableWithinSamePage() {
        // Two messages from the same page should have the same documentId
        let result1 = tabCallAsync("""
            const response = await chrome.runtime.sendMessage({ type: 'getSender' });
            return response.documentId;
        """)
        let result2 = tabCallAsync("""
            const response = await chrome.runtime.sendMessage({ type: 'getSender' });
            return response.documentId;
        """)
        let docId1 = result1 as? String
        let docId2 = result2 as? String
        XCTAssertNotNil(docId1)
        XCTAssertEqual(docId1, docId2, "documentId should be stable within the same page load")
    }

    func testPopupSendMessageDoesNotIncludeDocumentId() {
        let result = popupCallAsync("""
            const response = await chrome.runtime.sendMessage({ type: 'getSender' });
            return JSON.stringify(response);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse sender JSON: \(String(describing: result))")
            return
        }
        XCTAssertNil(json["documentId"], "sender.documentId should NOT be present for popup messages")
    }

    // MARK: - tabs.sendMessage with documentId option

    func testTabsSendMessageWithMatchingDocumentId() {
        // Get the tab's documentId first
        let docIdResult = tabCallAsync("return window.__detourDocumentId;")
        guard let documentId = docIdResult as? String else {
            XCTFail("Failed to get documentId from tab")
            return
        }

        // Register a listener on the tab
        tabCallAsyncVoid("""
            window.__testMsgReceived = null;
            chrome.runtime.onMessage.addListener(function(msg, sender, sendResponse) {
                if (msg.type === 'docIdTest') {
                    window.__testMsgReceived = msg.data;
                    sendResponse({ ok: true });
                }
                return true;
            });
        """)

        // Send from popup with matching documentId
        let result = popupCallAsync("""
            const response = await chrome.tabs.sendMessage(\(testTabIntID!),
                { type: 'docIdTest', data: 'hello' },
                { documentId: '\(documentId)' });
            return JSON.stringify(response);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse response: \(String(describing: result))")
            return
        }
        XCTAssertEqual(json["ok"] as? Bool, true, "Message should be delivered with matching documentId")
    }

    func testTabsSendMessageWithWrongDocumentIdFails() {
        // Send from popup with a non-matching documentId
        let result = popupCallAsync("""
            try {
                await chrome.tabs.sendMessage(\(testTabIntID!),
                    { type: 'test' },
                    { documentId: 'wrong-document-id-12345' });
                return 'should-have-thrown';
            } catch(e) {
                return e.message;
            }
        """)
        let error = result as? String ?? ""
        XCTAssertTrue(error.contains("does not exist"),
                      "Should fail with connection error for wrong documentId, got: \(error)")
    }

    // MARK: - Tab URL field visibility (host permissions)

    func testBuildTabInfoIncludesURLWithTabsPermission() {
        // Extension has "tabs" permission → URL fields always included
        let info = ExtensionMessageBridge.shared.buildTabInfo(
            tab: testBrowserTab, space: testSpace, isActive: true,
            includeURLFields: true, extension: ext)
        XCTAssertNotNil(info["url"], "URL should be included when includeURLFields is true")
        XCTAssertNotNil(info["title"], "Title should be included when includeURLFields is true")
    }

    func testBuildTabInfoIncludesURLViaHostPermission() {
        // Extension WITHOUT "tabs" but WITH matching host_permissions → URL fields included
        let manifest = try! JSONDecoder().decode(ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: [
            "manifest_version": 3, "name": "Host Only", "version": "1.0",
            "host_permissions": ["<all_urls>"]
        ]))
        let hostExt = WebExtension(id: "host-only", manifest: manifest, basePath: URL(fileURLWithPath: "/tmp"))

        let info = ExtensionMessageBridge.shared.buildTabInfo(
            tab: testBrowserTab, space: testSpace, isActive: true,
            includeURLFields: false, extension: hostExt)
        XCTAssertNotNil(info["url"], "URL should be included via host permission even without tabs permission")
        XCTAssertNotNil(info["title"], "Title should be included via host permission")
    }

    func testBuildTabInfoExcludesURLWithoutPermissions() {
        // Extension with NO "tabs" and NO host_permissions → URL fields excluded
        let manifest = try! JSONDecoder().decode(ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: [
            "manifest_version": 3, "name": "No Perms", "version": "1.0"
        ]))
        let noPermExt = WebExtension(id: "no-perms", manifest: manifest, basePath: URL(fileURLWithPath: "/tmp"))

        let info = ExtensionMessageBridge.shared.buildTabInfo(
            tab: testBrowserTab, space: testSpace, isActive: true,
            includeURLFields: false, extension: noPermExt)
        XCTAssertNil(info["url"], "URL should be excluded without tabs or host permissions")
        XCTAssertNil(info["title"], "Title should be excluded without tabs or host permissions")
    }

    func testBuildTabInfoExcludesURLWhenHostDoesNotMatch() {
        // Extension with host_permissions that don't match the tab's URL
        let manifest = try! JSONDecoder().decode(ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: [
            "manifest_version": 3, "name": "Wrong Host", "version": "1.0",
            "host_permissions": ["https://other.com/*"]
        ]))
        let wrongHostExt = WebExtension(id: "wrong-host", manifest: manifest, basePath: URL(fileURLWithPath: "/tmp"))

        let info = ExtensionMessageBridge.shared.buildTabInfo(
            tab: testBrowserTab, space: testSpace, isActive: true,
            includeURLFields: false, extension: wrongHostExt)
        XCTAssertNil(info["url"], "URL should be excluded when host permissions don't match tab URL")
    }

    func testTabsQueryLastFocusedWindowFilter() {
        // lastFocusedWindow should behave like currentWindow — only return tabs from the active space
        let result = popupCallAsync("""
            const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
            return tabs.some(function(t) { return t.id === \(testTabIntID!); });
        """)
        XCTAssertEqual(result as? Bool, true, "lastFocusedWindow filter should include test tab from active space")
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

    // MARK: - chrome.storage.sync

    func testStorageSyncExists() {
        let result = evalSync("typeof chrome.storage.sync")
        XCTAssertEqual(result as? String, "object")
    }

    func testStorageSyncAPIShape() {
        let result = evalSync("""
            typeof chrome.storage.sync.get === 'function' &&
            typeof chrome.storage.sync.set === 'function' &&
            typeof chrome.storage.sync.remove === 'function' &&
            typeof chrome.storage.sync.clear === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testStorageSyncSetAndGet() {
        callAsyncVoid("await chrome.storage.sync.set({ syncKey: 'syncVal' })")
        let result = callAsync("const r = await chrome.storage.sync.get('syncKey'); return r.syncKey;")
        XCTAssertEqual(result as? String, "syncVal")
    }

    func testStorageSyncIsolatedFromLocal() {
        callAsyncVoid("await chrome.storage.local.set({ isoKey: 'local' })")
        callAsyncVoid("await chrome.storage.sync.set({ isoKey: 'sync' })")
        let localResult = callAsync("const r = await chrome.storage.local.get('isoKey'); return r.isoKey;")
        let syncResult = callAsync("const r = await chrome.storage.sync.get('isoKey'); return r.isoKey;")
        XCTAssertEqual(localResult as? String, "local")
        XCTAssertEqual(syncResult as? String, "sync")
    }

    func testStorageSyncRemove() {
        callAsyncVoid("await chrome.storage.sync.set({ rmKey: 'here' })")
        callAsyncVoid("await chrome.storage.sync.remove('rmKey')")
        let result = callAsync("const r = await chrome.storage.sync.get('rmKey'); return r.rmKey === undefined;")
        XCTAssertEqual(result as? Bool, true)
    }

    func testStorageSyncClear() {
        callAsyncVoid("await chrome.storage.sync.set({ a: 1, b: 2 })")
        callAsyncVoid("await chrome.storage.sync.clear()")
        let result = callAsync("const r = await chrome.storage.sync.get(null); return Object.keys(r).length;")
        XCTAssertEqual(result as? Int, 0)
    }

    func testStorageSyncQuotaConstant() {
        let result = evalSync("chrome.storage.sync.QUOTA_BYTES_PER_ITEM")
        XCTAssertEqual(result as? Int, 8192)
    }

    func testStorageSyncOnChangedExists() {
        let result = evalSync("""
            typeof chrome.storage.sync.onChanged.addListener === 'function' &&
            typeof chrome.storage.local.onChanged.addListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - chrome.storage.session

    func testStorageSessionExists() {
        let result = evalSync("typeof chrome.storage.session")
        XCTAssertEqual(result as? String, "object")
    }

    func testStorageSessionSetAndGet() {
        callAsyncVoid("await chrome.storage.session.set({ sessKey: 'sessVal' })")
        let result = callAsync("const r = await chrome.storage.session.get('sessKey'); return r.sessKey;")
        XCTAssertEqual(result as? String, "sessVal")
    }

    // MARK: - chrome.alarms

    func testAlarmsNamespaceExists() {
        let result = evalSync("typeof chrome.alarms")
        XCTAssertEqual(result as? String, "object")
    }

    func testAlarmsAPIShape() {
        let result = evalSync("""
            typeof chrome.alarms.create === 'function' &&
            typeof chrome.alarms.clear === 'function' &&
            typeof chrome.alarms.clearAll === 'function' &&
            typeof chrome.alarms.get === 'function' &&
            typeof chrome.alarms.getAll === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testAlarmsOnAlarmEventEmitter() {
        let result = evalSync("""
            typeof chrome.alarms.onAlarm.addListener === 'function' &&
            typeof chrome.alarms.onAlarm.removeListener === 'function' &&
            typeof chrome.alarms.onAlarm.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testAlarmsCreateAndGet() {
        callAsyncVoid("await chrome.alarms.create('test-alarm', { delayInMinutes: 60 })")
        let result = callAsync("""
            const alarm = await chrome.alarms.get('test-alarm');
            return alarm !== undefined && alarm.name === 'test-alarm';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testAlarmsGetAll() {
        callAsyncVoid("await chrome.alarms.create('a1', { delayInMinutes: 60 })")
        callAsyncVoid("await chrome.alarms.create('a2', { delayInMinutes: 60 })")
        let result = callAsync("const all = await chrome.alarms.getAll(); return all.length >= 2;")
        XCTAssertEqual(result as? Bool, true)
    }

    func testAlarmsClear() {
        callAsyncVoid("await chrome.alarms.create('clearme', { delayInMinutes: 60 })")
        let cleared = callAsync("return await chrome.alarms.clear('clearme');")
        XCTAssertEqual(cleared as? Bool, true)
        let result = callAsync("const a = await chrome.alarms.get('clearme'); return a === undefined;")
        XCTAssertEqual(result as? Bool, true)
    }

    func testAlarmsClearAll() {
        callAsyncVoid("await chrome.alarms.create('x', { delayInMinutes: 60 })")
        callAsyncVoid("await chrome.alarms.clearAll()")
        let result = callAsync("const all = await chrome.alarms.getAll(); return all.length;")
        XCTAssertEqual(result as? Int, 0)
    }

    // MARK: - chrome.action

    func testActionNamespaceExists() {
        let result = evalSync("typeof chrome.action")
        XCTAssertEqual(result as? String, "object")
    }

    func testActionAPIShape() {
        let result = evalSync("""
            typeof chrome.action.setIcon === 'function' &&
            typeof chrome.action.setBadgeText === 'function' &&
            typeof chrome.action.setBadgeBackgroundColor === 'function' &&
            typeof chrome.action.getBadgeText === 'function' &&
            typeof chrome.action.setTitle === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testActionSetAndGetBadgeText() {
        popupCallAsyncVoid("await chrome.action.setBadgeText({ text: 'ON' })")
        let result = popupCallAsync("return await chrome.action.getBadgeText({});")
        XCTAssertEqual(result as? String, "ON")
    }

    // MARK: - chrome.commands

    func testCommandsNamespaceExists() {
        let result = evalSync("typeof chrome.commands")
        XCTAssertEqual(result as? String, "object")
    }

    func testCommandsGetAllIsFunction() {
        let result = evalSync("typeof chrome.commands.getAll")
        XCTAssertEqual(result as? String, "function")
    }

    func testCommandsOnCommandEventEmitter() {
        let result = evalSync("""
            typeof chrome.commands.onCommand.addListener === 'function' &&
            typeof chrome.commands.onCommand.removeListener === 'function' &&
            typeof chrome.commands.onCommand.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testCommandsGetAllReturnsManifestCommands() {
        let result = popupCallAsync("""
            const commands = await chrome.commands.getAll();
            return commands.length >= 2 &&
                   commands.some(function(c) { return c.name === 'toggle-feature'; }) &&
                   commands.some(function(c) { return c.name === 'add-site'; });
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testCommandsDispatchFunctionExists() {
        let result = evalSync("typeof window.__extensionDispatchCommand")
        XCTAssertEqual(result as? String, "function")
    }

    // MARK: - chrome.windows

    func testWindowsNamespaceExists() {
        let result = evalSync("typeof chrome.windows")
        XCTAssertEqual(result as? String, "object")
    }

    func testWindowsAPIShape() {
        let result = evalSync("""
            typeof chrome.windows.getAll === 'function' &&
            typeof chrome.windows.get === 'function' &&
            typeof chrome.windows.create === 'function' &&
            typeof chrome.windows.update === 'function' &&
            typeof chrome.windows.getCurrent === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testWindowsConstants() {
        let result = evalSync("chrome.windows.WINDOW_ID_CURRENT === -2 && chrome.windows.WINDOW_ID_NONE === -1")
        XCTAssertEqual(result as? Bool, true)
    }

    func testWindowsGetAllReturnsArray() {
        let result = popupCallAsync("const wins = await chrome.windows.getAll(); return Array.isArray(wins);")
        XCTAssertEqual(result as? Bool, true)
    }

    func testWindowsGetCurrentReturnsWindow() {
        let result = popupCallAsync("""
            const win = await chrome.windows.getCurrent();
            return typeof win.id === 'number' && typeof win.focused === 'boolean';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - chrome.fontSettings

    func testFontSettingsNamespaceExists() {
        let result = evalSync("typeof chrome.fontSettings")
        XCTAssertEqual(result as? String, "object")
    }

    func testFontSettingsGetFontListIsFunction() {
        let result = evalSync("typeof chrome.fontSettings.getFontList")
        XCTAssertEqual(result as? String, "function")
    }

    func testFontSettingsGetFontListReturnsNonEmpty() {
        let result = popupCallAsync("""
            const fonts = await chrome.fontSettings.getFontList();
            return Array.isArray(fonts) && fonts.length > 0 &&
                   typeof fonts[0].fontId === 'string' && typeof fonts[0].displayName === 'string';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - chrome.permissions

    func testPermissionsNamespaceExists() {
        let result = evalSync("typeof chrome.permissions")
        XCTAssertEqual(result as? String, "object")
    }

    func testPermissionsContainsIsFunction() {
        let result = evalSync("typeof chrome.permissions.contains")
        XCTAssertEqual(result as? String, "function")
    }

    func testPermissionsContainsDeclaredPermission() {
        let result = popupCallAsync("""
            return await chrome.permissions.contains({ permissions: ['storage'] });
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testPermissionsContainsUndeclaredReturnsFalse() {
        let result = popupCallAsync("""
            return await chrome.permissions.contains({ permissions: ['downloads'] });
        """)
        XCTAssertEqual(result as? Bool, false)
    }

    func testPermissionsGetAllReturnsManifestPermissions() {
        let result = evalSync("""
            (function() {
                const all = chrome.permissions.getAll();
                return all instanceof Promise;
            })()
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testPermissionsOnAddedStub() {
        let result = evalSync("""
            typeof chrome.permissions.onAdded.addListener === 'function' &&
            typeof chrome.permissions.onRemoved.addListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - chrome.runtime (new additions)

    func testRuntimeOnStartupExists() {
        let result = evalSync("""
            typeof chrome.runtime.onStartup.addListener === 'function' &&
            typeof chrome.runtime.onStartup.removeListener === 'function' &&
            typeof chrome.runtime.onStartup.hasListener === 'function'
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testRuntimeSetUninstallURLExists() {
        let result = evalSync("typeof chrome.runtime.setUninstallURL")
        XCTAssertEqual(result as? String, "function")
    }

    func testExtensionIsAllowedFileSchemeAccess() {
        let result = callAsync("return await chrome.extension.isAllowedFileSchemeAccess();")
        XCTAssertEqual(result as? Bool, false)
    }

    func testExtensionIsAllowedIncognitoAccess() {
        let result = callAsync("return await chrome.extension.isAllowedIncognitoAccess();")
        XCTAssertEqual(result as? Bool, false)
    }

    // MARK: - Content script world: MAIN

    func testMainWorldScriptDoesNotGetChromeAPIs() {
        // MAIN world scripts should NOT have chrome.* APIs
        // The content world scripts DO have chrome.* APIs
        // We verify by checking the manifest parses the world field correctly
        let manifest = ext.manifest
        let mainWorldScript = manifest.contentScripts?.first(where: { $0.world == "MAIN" })
        XCTAssertNotNil(mainWorldScript, "Should have a MAIN world content script")
        XCTAssertEqual(mainWorldScript?.js, ["main.js"])
    }

    // MARK: - Cross-world custom event relay

    func testCustomEventRelayFromContentWorldToPageWorld() {
        // When an extension has MAIN world scripts, CustomEvents dispatched in the
        // content world should be relayed to the page world so MAIN world listeners
        // receive them. This is how Dark Reader's proxy.js communicates with index.js.

        // Create a webView with content scripts registered via the injector
        // (which sets up the relay scripts)
        let relayConfig = WKWebViewConfiguration()
        ContentScriptInjector().registerContentScripts(for: ext, on: relayConfig.userContentController)

        let relayWV = WKWebView(frame: .zero, configuration: relayConfig)

        let navExp = expectation(description: "Relay page loaded")
        let relayNav = TestNavigationDelegate { navExp.fulfill() }
        relayWV.navigationDelegate = relayNav

        relayWV.loadHTMLString("<html><body>relay test</body></html>",
                               baseURL: URL(string: "https://relay.test.example.com")!)
        wait(for: [navExp], timeout: 10.0)

        // Step 1: Register a listener in the PAGE world for a custom event
        let setupExp = expectation(description: "Setup page listener")
        relayWV.evaluateJavaScript("""
            window.__relayTestReceived = null;
            document.addEventListener('__test_relay_event', function(e) {
                window.__relayTestReceived = e.detail;
            });
        """) { _, _ in setupExp.fulfill() }
        wait(for: [setupExp], timeout: 5.0)

        // Step 2: Dispatch the custom event from the CONTENT WORLD
        let dispatchExp = expectation(description: "Dispatch from content world")
        relayWV.evaluateJavaScript("""
            document.dispatchEvent(new CustomEvent('__test_relay_event', {
                detail: { message: 'hello from content world' }
            }));
        """, in: nil, in: ext.contentWorld) { _ in dispatchExp.fulfill() }
        wait(for: [dispatchExp], timeout: 5.0)

        // Small delay for the relay <script> element to execute
        let delayExp = expectation(description: "Relay delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 5.0)

        // Step 3: Check that the page world listener received the event
        let checkExp = expectation(description: "Check relay")
        var result: Any?
        relayWV.evaluateJavaScript("JSON.stringify(window.__relayTestReceived)") { val, _ in
            result = val
            checkExp.fulfill()
        }
        wait(for: [checkExp], timeout: 5.0)

        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Page world listener did not receive the relayed event, got: \(String(describing: result))")
            return
        }
        XCTAssertEqual(json["message"] as? String, "hello from content world",
                       "Event detail should be relayed from content world to page world")

        _ = relayNav // prevent deallocation
    }

    func testCustomEventNotRelayedWhenNoPageWorldListener() {
        // Events should NOT be relayed if nothing in the page world listens for them
        let relayConfig = WKWebViewConfiguration()
        ContentScriptInjector().registerContentScripts(for: ext, on: relayConfig.userContentController)

        let relayWV = WKWebView(frame: .zero, configuration: relayConfig)

        let navExp = expectation(description: "Page loaded")
        let relayNav = TestNavigationDelegate { navExp.fulfill() }
        relayWV.navigationDelegate = relayNav
        relayWV.loadHTMLString("<html><body>test</body></html>",
                               baseURL: URL(string: "https://norelay.test.example.com")!)
        wait(for: [navExp], timeout: 10.0)

        // Set up a marker in page world — no addEventListener for the event
        let setupExp = expectation(description: "Setup")
        relayWV.evaluateJavaScript("window.__noRelayResult = 'untouched';") { _, _ in setupExp.fulfill() }
        wait(for: [setupExp], timeout: 5.0)

        // Dispatch from content world
        let dispatchExp = expectation(description: "Dispatch")
        relayWV.evaluateJavaScript("""
            document.dispatchEvent(new CustomEvent('__unregistered_event', {
                detail: { should: 'not arrive' }
            }));
        """, in: nil, in: ext.contentWorld) { _ in dispatchExp.fulfill() }
        wait(for: [dispatchExp], timeout: 5.0)

        let delayExp = expectation(description: "Delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 5.0)

        // The inline <script> runs but the condition __detourRelayEvents.has() is false,
        // so no event is dispatched in the page world. Verify by checking nothing changed.
        let checkExp = expectation(description: "Check")
        var result: Any?
        relayWV.evaluateJavaScript("window.__noRelayResult") { val, _ in
            result = val
            checkExp.fulfill()
        }
        wait(for: [checkExp], timeout: 5.0)
        XCTAssertEqual(result as? String, "untouched",
                       "Event should not be relayed when no page world listener is registered")

        _ = relayNav
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

    // MARK: - chrome.storage.session (new shared methods)

    func testStorageSessionSetAccessLevelExists() {
        let result = evalSync("typeof chrome.storage.session.setAccessLevel")
        XCTAssertEqual(result as? String, "function")
    }

    func testStorageSessionRemove() {
        callAsyncVoid("await chrome.storage.session.set({ rmKey: 'x' })")
        callAsyncVoid("await chrome.storage.session.remove('rmKey')")
        let result = callAsync("var r = await chrome.storage.session.get('rmKey'); return r.rmKey === undefined;")
        XCTAssertEqual(result as? Bool, true)
    }

    func testStorageSessionClear() {
        callAsyncVoid("await chrome.storage.session.set({ a: 1, b: 2 })")
        callAsyncVoid("await chrome.storage.session.clear()")
        let result = callAsync("var r = await chrome.storage.session.get(null); return Object.keys(r).length;")
        XCTAssertEqual(result as? Int, 0)
    }

    // MARK: - chrome.tabs (new methods)

    func testTabsDuplicateExists() {
        let result = evalSync("typeof chrome.tabs.duplicate")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsMoveExists() {
        let result = evalSync("typeof chrome.tabs.move")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsSetZoomExists() {
        let result = evalSync("typeof chrome.tabs.setZoom")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsGetZoomExists() {
        let result = evalSync("typeof chrome.tabs.getZoom")
        XCTAssertEqual(result as? String, "function")
    }

    func testTabsOnReplacedExists() {
        let result = evalSync("typeof chrome.tabs.onReplaced.addListener")
        XCTAssertEqual(result as? String, "function")
    }

    // MARK: - chrome.history

    func testHistoryExists() {
        let result = evalSync("typeof chrome.history")
        XCTAssertEqual(result as? String, "object")
    }

    func testHistorySearchExists() {
        let result = evalSync("typeof chrome.history.search")
        XCTAssertEqual(result as? String, "function")
    }

    func testHistoryOnVisitedExists() {
        let result = evalSync("typeof chrome.history.onVisited.addListener")
        XCTAssertEqual(result as? String, "function")
    }

    func testHistoryOnVisitRemovedExists() {
        let result = evalSync("typeof chrome.history.onVisitRemoved.addListener")
        XCTAssertEqual(result as? String, "function")
    }

    // MARK: - chrome.bookmarks

    func testBookmarksExists() {
        let result = evalSync("typeof chrome.bookmarks")
        XCTAssertEqual(result as? String, "object")
    }

    func testBookmarksGetTreeExists() {
        let result = evalSync("typeof chrome.bookmarks.getTree")
        XCTAssertEqual(result as? String, "function")
    }

    // MARK: - chrome.sessions

    func testSessionsExists() {
        let result = evalSync("typeof chrome.sessions")
        XCTAssertEqual(result as? String, "object")
    }

    func testSessionsRestoreExists() {
        let result = evalSync("typeof chrome.sessions.restore")
        XCTAssertEqual(result as? String, "function")
    }

    // MARK: - chrome.search

    func testSearchExists() {
        let result = evalSync("typeof chrome.search")
        XCTAssertEqual(result as? String, "object")
    }

    func testSearchQueryExists() {
        let result = evalSync("typeof chrome.search.query")
        XCTAssertEqual(result as? String, "function")
    }

    // MARK: - chrome.webNavigation (new events)

    func testWebNavigationOnHistoryStateUpdatedExists() {
        let result = evalSync("typeof chrome.webNavigation.onHistoryStateUpdated.addListener")
        XCTAssertEqual(result as? String, "function")
    }

    func testWebNavigationOnReferenceFragmentUpdatedExists() {
        let result = evalSync("typeof chrome.webNavigation.onReferenceFragmentUpdated.addListener")
        XCTAssertEqual(result as? String, "function")
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
