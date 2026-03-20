import XCTest
import WebKit
@testable import Detour

/// Integration tests verifying that the tabs permission gate in ExtensionMessageBridge
/// correctly allows/denies chrome.tabs.* calls based on manifest permissions,
/// and that host permission checks gate tabs.sendMessage on the target tab URL.
@MainActor
final class TabsPermissionTests: XCTestCase {

    // Extension WITH tabs permission + <all_urls>
    private var allowedDir: URL!
    private var allowedExt: WebExtension!
    private var allowedWebView: WKWebView!
    private var allowedNavDelegate: TestTabsNavDelegate!
    private var allowedBgHost: BackgroundHost!

    // Extension WITHOUT tabs permission
    private var deniedDir: URL!
    private var deniedExt: WebExtension!
    private var deniedWebView: WKWebView!
    private var deniedNavDelegate: TestTabsNavDelegate!

    // Extension WITH tabs permission + narrow host_permissions
    private var narrowDir: URL!
    private var narrowExt: WebExtension!
    private var narrowWebView: WKWebView!
    private var narrowNavDelegate: TestTabsNavDelegate!
    private var narrowBgHost: BackgroundHost!

    // Shared tab infrastructure
    private var testProfile: Profile!
    private var testSpace: Space!
    private var testBrowserTab: BrowserTab!
    private var testTabIntID: Int!
    private var tabNavDelegate: TestTabsNavDelegate!

    // Host permission test tabs
    private var allowedHostTab: BrowserTab!
    private var allowedHostTabIntID: Int!
    private var allowedHostNavDelegate: TestTabsNavDelegate!
    private var deniedHostTab: BrowserTab!
    private var deniedHostTabIntID: Int!
    private var deniedHostNavDelegate: TestTabsNavDelegate!

    @MainActor
    override func setUp() {
        super.setUp()

        // --- Extension with tabs + <all_urls> ---
        allowedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-tabs-allowed-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)

        let allowedManifestJSON = """
        {
            "manifest_version": 3,
            "name": "Tabs Allowed",
            "version": "1.0",
            "permissions": ["tabs"],
            "host_permissions": ["<all_urls>"],
            "background": {"service_worker": "background.js"},
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}
            ]
        }
        """
        try! allowedManifestJSON.write(to: allowedDir.appendingPathComponent("manifest.json"),
                                       atomically: true, encoding: .utf8)
        try! "chrome.runtime.onMessage.addListener(function(m,s,sr){ sr({echo:true}); return true; });".write(
            to: allowedDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try! "".write(to: allowedDir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let allowedManifest = try! ExtensionManifest.parse(at: allowedDir.appendingPathComponent("manifest.json"))
        let allowedID = "tabs-allowed-\(UUID().uuidString)"
        allowedExt = WebExtension(id: allowedID, manifest: allowedManifest, basePath: allowedDir)
        ExtensionManager.shared.extensions.append(allowedExt)

        let allowedRecord = ExtensionRecord(
            id: allowedID, name: allowedManifest.name, version: allowedManifest.version,
            manifestJSON: try! allowedManifest.toJSONData(), basePath: allowedDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(allowedRecord)

        let allowedConfig = WKWebViewConfiguration()
        let allowedBundle = ChromeAPIBundle.generateBundle(for: allowedExt, isContentScript: false)
        allowedConfig.userContentController.addUserScript(
            WKUserScript(source: allowedBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ExtensionMessageBridge.shared.register(on: allowedConfig.userContentController)
        allowedWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: allowedConfig)

        allowedBgHost = BackgroundHost(extension: allowedExt)
        ExtensionManager.shared.backgroundHosts[allowedID] = allowedBgHost
        allowedBgHost.start()

        // --- Extension without tabs ---
        deniedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-tabs-denied-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: deniedDir, withIntermediateDirectories: true)

        let deniedManifestJSON = """
        {
            "manifest_version": 3,
            "name": "Tabs Denied",
            "version": "1.0",
            "permissions": ["storage"]
        }
        """
        try! deniedManifestJSON.write(to: deniedDir.appendingPathComponent("manifest.json"),
                                      atomically: true, encoding: .utf8)

        let deniedManifest = try! ExtensionManifest.parse(at: deniedDir.appendingPathComponent("manifest.json"))
        let deniedID = "tabs-denied-\(UUID().uuidString)"
        deniedExt = WebExtension(id: deniedID, manifest: deniedManifest, basePath: deniedDir)
        ExtensionManager.shared.extensions.append(deniedExt)

        let deniedRecord = ExtensionRecord(
            id: deniedID, name: deniedManifest.name, version: deniedManifest.version,
            manifestJSON: try! deniedManifest.toJSONData(), basePath: deniedDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(deniedRecord)

        let deniedConfig = WKWebViewConfiguration()
        let deniedBundle = ChromeAPIBundle.generateBundle(for: deniedExt, isContentScript: false)
        deniedConfig.userContentController.addUserScript(
            WKUserScript(source: deniedBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ExtensionMessageBridge.shared.register(on: deniedConfig.userContentController)
        deniedWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: deniedConfig)

        // --- Extension with tabs + narrow host ---
        narrowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-tabs-narrow-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: narrowDir, withIntermediateDirectories: true)

        let narrowManifestJSON = """
        {
            "manifest_version": 3,
            "name": "Tabs Narrow Host",
            "version": "1.0",
            "permissions": ["tabs"],
            "host_permissions": ["https://*.allowed.test/*"],
            "background": {"service_worker": "background.js"},
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}
            ]
        }
        """
        try! narrowManifestJSON.write(to: narrowDir.appendingPathComponent("manifest.json"),
                                      atomically: true, encoding: .utf8)
        try! "chrome.runtime.onMessage.addListener(function(m,s,sr){ sr({echo:true}); return true; });".write(
            to: narrowDir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try! "".write(to: narrowDir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let narrowManifest = try! ExtensionManifest.parse(at: narrowDir.appendingPathComponent("manifest.json"))
        let narrowID = "tabs-narrow-\(UUID().uuidString)"
        narrowExt = WebExtension(id: narrowID, manifest: narrowManifest, basePath: narrowDir)
        ExtensionManager.shared.extensions.append(narrowExt)

        let narrowRecord = ExtensionRecord(
            id: narrowID, name: narrowManifest.name, version: narrowManifest.version,
            manifestJSON: try! narrowManifest.toJSONData(), basePath: narrowDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(narrowRecord)

        let narrowConfig = WKWebViewConfiguration()
        let narrowBundle = ChromeAPIBundle.generateBundle(for: narrowExt, isContentScript: false)
        narrowConfig.userContentController.addUserScript(
            WKUserScript(source: narrowBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ExtensionMessageBridge.shared.register(on: narrowConfig.userContentController)
        narrowWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: narrowConfig)

        narrowBgHost = BackgroundHost(extension: narrowExt)
        ExtensionManager.shared.backgroundHosts[narrowID] = narrowBgHost
        narrowBgHost.start()

        // --- Shared Tab Infrastructure ---
        testProfile = TabStore.shared.addProfile(name: "Tabs Test Profile")
        testSpace = TabStore.shared.addSpace(name: "Tabs Test Space", emoji: "T", colorHex: "#000000", profileID: testProfile.id)
        ExtensionManager.shared.lastActiveSpaceID = testSpace.id

        // Main test tab (used by allowed/denied tests)
        let tabConfig = WKWebViewConfiguration()
        for ext in [allowedExt!, deniedExt!] {
            let bundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: true)
            tabConfig.userContentController.addUserScript(
                WKUserScript(source: bundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: ext.contentWorld))
            ExtensionMessageBridge.shared.register(on: tabConfig.userContentController, contentWorld: ext.contentWorld)
        }
        let tabWV = WKWebView(frame: .zero, configuration: tabConfig)
        testBrowserTab = BrowserTab(webView: tabWV)
        testSpace.tabs.append(testBrowserTab)
        testSpace.selectedTabID = testBrowserTab.id
        testTabIntID = ExtensionManager.shared.tabIDMap.intID(for: testBrowserTab.id)

        // Host permission test tabs
        let allowedHostConfig = WKWebViewConfiguration()
        let ahBundle = ChromeAPIBundle.generateBundle(for: narrowExt, isContentScript: true)
        allowedHostConfig.userContentController.addUserScript(
            WKUserScript(source: ahBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: narrowExt.contentWorld))
        ExtensionMessageBridge.shared.register(on: allowedHostConfig.userContentController, contentWorld: narrowExt.contentWorld)
        let ahWV = WKWebView(frame: .zero, configuration: allowedHostConfig)
        allowedHostTab = BrowserTab(webView: ahWV)
        testSpace.tabs.append(allowedHostTab)
        allowedHostTabIntID = ExtensionManager.shared.tabIDMap.intID(for: allowedHostTab.id)

        let deniedHostConfig = WKWebViewConfiguration()
        let dhBundle = ChromeAPIBundle.generateBundle(for: narrowExt, isContentScript: true)
        deniedHostConfig.userContentController.addUserScript(
            WKUserScript(source: dhBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: narrowExt.contentWorld))
        ExtensionMessageBridge.shared.register(on: deniedHostConfig.userContentController, contentWorld: narrowExt.contentWorld)
        let dhWV = WKWebView(frame: .zero, configuration: deniedHostConfig)
        deniedHostTab = BrowserTab(webView: dhWV)
        testSpace.tabs.append(deniedHostTab)
        deniedHostTabIntID = ExtensionManager.shared.tabIDMap.intID(for: deniedHostTab.id)

        // Load all pages
        let html = "<html><body>test</body></html>"

        let allowedNavExp = expectation(description: "Allowed page loaded")
        allowedNavDelegate = TestTabsNavDelegate { allowedNavExp.fulfill() }
        allowedWebView.navigationDelegate = allowedNavDelegate
        allowedWebView.loadHTMLString(html, baseURL: URL(string: "https://tabs-test.example.com")!)

        let deniedNavExp = expectation(description: "Denied page loaded")
        deniedNavDelegate = TestTabsNavDelegate { deniedNavExp.fulfill() }
        deniedWebView.navigationDelegate = deniedNavDelegate
        deniedWebView.loadHTMLString(html, baseURL: URL(string: "https://tabs-test.example.com")!)

        let narrowNavExp = expectation(description: "Narrow page loaded")
        narrowNavDelegate = TestTabsNavDelegate { narrowNavExp.fulfill() }
        narrowWebView.navigationDelegate = narrowNavDelegate
        narrowWebView.loadHTMLString(html, baseURL: URL(string: "https://tabs-test.example.com")!)

        let tabNavExp = expectation(description: "Tab page loaded")
        tabNavDelegate = TestTabsNavDelegate { tabNavExp.fulfill() }
        tabWV.navigationDelegate = tabNavDelegate
        tabWV.loadHTMLString("<html><head><title>Test Tab</title></head><body>tab</body></html>",
                             baseURL: URL(string: "https://tab.test.example.com")!)

        let ahNavExp = expectation(description: "Allowed host tab loaded")
        allowedHostNavDelegate = TestTabsNavDelegate { ahNavExp.fulfill() }
        ahWV.navigationDelegate = allowedHostNavDelegate
        ahWV.loadHTMLString("<html><body>allowed host</body></html>",
                            baseURL: URL(string: "https://sub.allowed.test/page")!)

        let dhNavExp = expectation(description: "Denied host tab loaded")
        deniedHostNavDelegate = TestTabsNavDelegate { dhNavExp.fulfill() }
        dhWV.navigationDelegate = deniedHostNavDelegate
        dhWV.loadHTMLString("<html><body>denied host</body></html>",
                            baseURL: URL(string: "https://denied.test/page")!)

        wait(for: [allowedNavExp, deniedNavExp, narrowNavExp, tabNavExp, ahNavExp, dhNavExp], timeout: 10.0)

        // Give background hosts time to initialize
        let bgExp = expectation(description: "BG ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { bgExp.fulfill() }
        wait(for: [bgExp], timeout: 5.0)
    }

    @MainActor
    override func tearDown() {
        allowedBgHost?.stop()
        narrowBgHost?.stop()

        for ext in [allowedExt, deniedExt, narrowExt].compactMap({ $0 }) {
            ExtensionManager.shared.extensions.removeAll { $0.id == ext.id }
            ExtensionManager.shared.backgroundHosts.removeValue(forKey: ext.id)
            AppDatabase.shared.storageClear(extensionID: ext.id)
            AppDatabase.shared.deleteExtension(id: ext.id)
        }

        // Clean up tabs
        for tab in [testBrowserTab, allowedHostTab, deniedHostTab].compactMap({ $0 }) {
            ExtensionManager.shared.tabIDMap.remove(uuid: tab.id)
        }
        if let spaceID = testSpace?.id {
            TabStore.shared.deleteSpace(id: spaceID)
            ExtensionManager.shared.spaceIDMap.remove(uuid: spaceID)
        }
        if let profileID = testProfile?.id {
            TabStore.shared.deleteProfile(id: profileID)
        }
        ExtensionManager.shared.lastActiveSpaceID = nil

        allowedWebView = nil; deniedWebView = nil; narrowWebView = nil
        allowedNavDelegate = nil; deniedNavDelegate = nil; narrowNavDelegate = nil
        tabNavDelegate = nil; allowedHostNavDelegate = nil; deniedHostNavDelegate = nil
        allowedExt = nil; deniedExt = nil; narrowExt = nil
        testBrowserTab = nil; allowedHostTab = nil; deniedHostTab = nil
        testSpace = nil; testProfile = nil

        for d in [allowedDir, deniedDir, narrowDir].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: d)
        }
        super.tearDown()
    }

    // MARK: - Allowed

    func testTabsQueryAllowed() {
        let result = callAsync(allowedWebView, "var tabs = await chrome.tabs.query({}); return Array.isArray(tabs);")
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsGetAllowed() {
        let result = callAsync(allowedWebView, """
            var tab = await chrome.tabs.get(\(testTabIntID!));
            return typeof tab.id === 'number' && tab.id === \(testTabIntID!);
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsCreateAllowed() {
        let countBefore = testSpace.tabs.count
        let result = callAsync(allowedWebView, """
            var tab = await chrome.tabs.create({ url: 'https://new.test' });
            return typeof tab.id === 'number';
        """)
        XCTAssertEqual(result as? Bool, true)
        XCTAssertEqual(testSpace.tabs.count, countBefore + 1)
    }

    func testTabsUpdateAllowed() {
        let result = callAsync(allowedWebView, """
            var tab = await chrome.tabs.update(\(testTabIntID!), { url: 'https://updated.test' });
            return typeof tab.id === 'number';
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTabsRemoveAllowed() {
        // Create a tab first, then remove it
        let createResult = callAsync(allowedWebView, "var t = await chrome.tabs.create({ url: 'https://rm.test' }); return t.id;")
        guard let createdID = createResult as? Int else { XCTFail("Failed to create tab"); return }
        let countBefore = testSpace.tabs.count
        callVoid(allowedWebView, "await chrome.tabs.remove(\(createdID));")
        XCTAssertEqual(testSpace.tabs.count, countBefore - 1)
    }

    func testTabsSendMessageAllowed() {
        // Register listener in the tab's content world
        let wv = testBrowserTab.webView!
        let setupExp = expectation(description: "Setup listener")
        wv.callAsyncJavaScript("""
            chrome.runtime.onMessage.addListener(function(m, s, sr) {
                sr({ got: m.data });
                return true;
            });
        """, arguments: [:], in: nil, in: allowedExt.contentWorld) { _ in setupExp.fulfill() }
        wait(for: [setupExp], timeout: 5.0)

        let result = callAsync(allowedWebView, """
            var r = await chrome.tabs.sendMessage(\(testTabIntID!), { data: 'hello' });
            return JSON.stringify(r);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse sendMessage response"); return
        }
        XCTAssertEqual(json["got"] as? String, "hello")
    }

    // MARK: - Without tabs permission (should still work per Chrome behavior)
    // Chrome does not require the "tabs" permission for tabs.create/query/update/remove/get.
    // The permission only controls whether url/title/favIconUrl are populated in Tab objects.

    func testTabsQueryWorksWithoutTabsPermission() {
        let result = callAsync(deniedWebView, """
            try { var tabs = await chrome.tabs.query({}); return 'resolved:' + tabs.length; }
            catch (e) { return 'error:' + e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.hasPrefix("resolved"), "tabs.query should work without tabs permission: \(msg)")
    }

    func testTabsCreateWorksWithoutTabsPermission() {
        let result = callAsync(deniedWebView, """
            try { var tab = await chrome.tabs.create({ url: 'https://x.test' }); return 'resolved'; }
            catch (e) { return 'error:' + e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertEqual(msg, "resolved")
    }

    func testTabsSendMessageWorksWithoutTabsPermission() {
        // tabs.sendMessage doesn't require "tabs" permission in Chrome
        let result = callAsync(deniedWebView, """
            try { await chrome.tabs.sendMessage(\(testTabIntID!), { data: 'x' }); return 'resolved'; }
            catch (e) { return 'error:' + e.message; }
        """)
        let msg = result as? String ?? ""
        // Should resolve (not error about missing permission)
        XCTAssertFalse(msg.contains("tabs"), "Should not require tabs permission: \(msg)")
    }

    // MARK: - Tab info field visibility

    /// When an extension HAS the "tabs" permission, chrome.tabs.query should return
    /// Tab objects with `url`, `title`, and `favIconUrl` populated.
    func testTabsQueryReturnsURLAndTitleWithTabsPermission() {
        let result = callAsync(allowedWebView, """
            var tabs = await chrome.tabs.query({});
            var tab = tabs.find(t => t.id === \(testTabIntID!));
            if (!tab) return JSON.stringify({ error: 'tab not found' });
            return JSON.stringify({ url: tab.url, title: tab.title, favIconUrl: tab.favIconUrl });
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse tabs.query response"); return
        }

        XCTAssertNil(json["error"], "Test tab should be found in query results")

        // With "tabs" permission, url and title MUST be present
        XCTAssertNotNil(json["url"] as? String, "url should be populated when extension has tabs permission")
        XCTAssertFalse((json["url"] as? String ?? "").isEmpty, "url should not be empty")
        XCTAssertNotNil(json["title"] as? String, "title should be populated when extension has tabs permission")
        // favIconUrl may be nil for test pages that have no favicon, so we only check it is not actively stripped
        // (i.e. it should be present if the tab has a favicon, but absence is okay for test HTML)
    }

    /// When an extension does NOT have the "tabs" permission, chrome.tabs.query should return
    /// Tab objects where `url`, `title`, and `favIconUrl` are stripped/absent (Chrome-compatible behavior).
    func testTabsQueryStripsURLAndTitleWithoutTabsPermission() {
        let result = callAsync(deniedWebView, """
            var tabs = await chrome.tabs.query({});
            var tab = tabs.find(t => t.id === \(testTabIntID!));
            if (!tab) return JSON.stringify({ error: 'tab not found', count: tabs.length });
            return JSON.stringify({
                hasUrl: (typeof tab.url !== 'undefined' && tab.url !== undefined),
                hasTitle: (typeof tab.title !== 'undefined' && tab.title !== undefined),
                hasFavIconUrl: (typeof tab.favIconUrl !== 'undefined' && tab.favIconUrl !== undefined),
                id: tab.id
            });
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse tabs.query response"); return
        }

        XCTAssertNil(json["error"], "Test tab should be found in query results: \(json)")

        // Chrome-compatible behavior: without "tabs" permission, url/title/favIconUrl should be absent
        XCTAssertEqual(json["hasUrl"] as? Bool, false,
                       "url should be stripped when extension lacks tabs permission")
        XCTAssertEqual(json["hasTitle"] as? Bool, false,
                       "title should be stripped when extension lacks tabs permission")
        XCTAssertEqual(json["hasFavIconUrl"] as? Bool, false,
                       "favIconUrl should be stripped when extension lacks tabs permission")
    }

    // MARK: - Host Permission (tabs.sendMessage)

    func testTabsSendMessageHostAllowed() {
        // Register listener in the allowed host tab
        let wv = allowedHostTab.webView!
        let setupExp = expectation(description: "Setup listener")
        wv.callAsyncJavaScript("""
            chrome.runtime.onMessage.addListener(function(m, s, sr) {
                sr({ ok: true });
                return true;
            });
        """, arguments: [:], in: nil, in: narrowExt.contentWorld) { _ in setupExp.fulfill() }
        wait(for: [setupExp], timeout: 5.0)

        let result = callAsync(narrowWebView, """
            var r = await chrome.tabs.sendMessage(\(allowedHostTabIntID!), { ping: 1 });
            return JSON.stringify(r);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Failed to parse response"); return
        }
        XCTAssertEqual(json["ok"] as? Bool, true)
    }

    func testTabsSendMessageHostDenied() {
        let result = callAsync(narrowWebView, """
            try {
                await chrome.tabs.sendMessage(\(deniedHostTabIntID!), { ping: 1 });
                return 'resolved';
            } catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("access") || msg.contains("host") || msg.contains("denied.test"),
                      "Error should indicate host permission denial: \(msg)")
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

private class TestTabsNavDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
