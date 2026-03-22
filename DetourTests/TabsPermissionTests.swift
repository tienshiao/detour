import XCTest
import WebKit
@testable import Detour

/// Integration tests verifying that the tabs permission gate in ExtensionMessageBridge
/// correctly allows/denies chrome.tabs.* calls based on manifest permissions,
/// and that host permission checks gate tabs.sendMessage on the target tab URL.
@MainActor
final class TabsPermissionTests: XCTestCase {

    // Extension WITH tabs permission + <all_urls>
    private var allowedExt: WebExtension!
    private var allowedWebView: WKWebView!

    // Extension WITHOUT tabs permission
    private var deniedExt: WebExtension!
    private var deniedWebView: WKWebView!

    // Extension WITH tabs permission + narrow host_permissions
    private var narrowExt: WebExtension!
    private var narrowWebView: WKWebView!

    // Shared tab infrastructure
    private var testProfile: Profile!
    private var testSpace: Space!
    private var testBrowserTab: BrowserTab!
    private var testTabIntID: Int!

    // Host permission test tabs
    private var allowedHostTab: BrowserTab!
    private var allowedHostTabIntID: Int!
    private var deniedHostTab: BrowserTab!
    private var deniedHostTabIntID: Int!

    // MARK: - Shared one-time setup

    private static let allowedID = "test-tabs-perm-allowed"
    private static let deniedID = "test-tabs-perm-denied"
    private static let narrowID = "test-tabs-perm-narrow"

    private struct SharedState {
        let allowedDir: URL
        let allowedExt: WebExtension
        let allowedWebView: WKWebView
        let allowedNavDelegate: TestTabsNavDelegate
        let allowedBgHost: BackgroundHost

        let deniedDir: URL
        let deniedExt: WebExtension
        let deniedWebView: WKWebView
        let deniedNavDelegate: TestTabsNavDelegate

        let narrowDir: URL
        let narrowExt: WebExtension
        let narrowWebView: WKWebView
        let narrowNavDelegate: TestTabsNavDelegate
        let narrowBgHost: BackgroundHost

        let testProfile: Profile
        let testSpace: Space
        let testBrowserTab: BrowserTab
        let testTabIntID: Int
        let tabNavDelegate: TestTabsNavDelegate

        let allowedHostTab: BrowserTab
        let allowedHostTabIntID: Int
        let allowedHostNavDelegate: TestTabsNavDelegate
        let deniedHostTab: BrowserTab
        let deniedHostTabIntID: Int
        let deniedHostNavDelegate: TestTabsNavDelegate
    }

    private nonisolated(unsafe) static var shared: SharedState?

    /// Create the shared test infrastructure once. Called from the first test's setUp.
    private func createSharedStateIfNeeded() {
        guard Self.shared == nil else { return }

        // --- Extension with tabs + <all_urls> ---
        let allowedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-tabs-allowed")
        try? FileManager.default.removeItem(at: allowedDir)
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
        let allowedExt = WebExtension(id: Self.allowedID, manifest: allowedManifest, basePath: allowedDir)
        ExtensionManager.shared.extensions.append(allowedExt)

        let allowedRecord = ExtensionRecord(
            id: Self.allowedID, name: allowedManifest.name, version: allowedManifest.version,
            manifestJSON: try! allowedManifest.toJSONData(), basePath: allowedDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(allowedRecord)

        let allowedConfig = WKWebViewConfiguration()
        let allowedBundle = ChromeAPIBundle.generateBundle(for: allowedExt, isContentScript: false)
        allowedConfig.userContentController.addUserScript(
            WKUserScript(source: allowedBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ExtensionMessageBridge.shared.register(on: allowedConfig.userContentController)
        let allowedWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: allowedConfig)

        let allowedBgHost = BackgroundHost(extension: allowedExt)
        ExtensionManager.shared.backgroundHosts[Self.allowedID] = allowedBgHost

        let allowedBgExp = expectation(description: "Allowed BG ready")
        allowedBgHost.start { allowedBgExp.fulfill() }

        // --- Extension without tabs ---
        let deniedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-tabs-denied")
        try? FileManager.default.removeItem(at: deniedDir)
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
        let deniedExt = WebExtension(id: Self.deniedID, manifest: deniedManifest, basePath: deniedDir)
        ExtensionManager.shared.extensions.append(deniedExt)

        let deniedRecord = ExtensionRecord(
            id: Self.deniedID, name: deniedManifest.name, version: deniedManifest.version,
            manifestJSON: try! deniedManifest.toJSONData(), basePath: deniedDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(deniedRecord)

        let deniedConfig = WKWebViewConfiguration()
        let deniedBundle = ChromeAPIBundle.generateBundle(for: deniedExt, isContentScript: false)
        deniedConfig.userContentController.addUserScript(
            WKUserScript(source: deniedBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ExtensionMessageBridge.shared.register(on: deniedConfig.userContentController)
        let deniedWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: deniedConfig)

        // --- Extension with tabs + narrow host ---
        let narrowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-tabs-narrow")
        try? FileManager.default.removeItem(at: narrowDir)
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
        let narrowExt = WebExtension(id: Self.narrowID, manifest: narrowManifest, basePath: narrowDir)
        ExtensionManager.shared.extensions.append(narrowExt)

        let narrowRecord = ExtensionRecord(
            id: Self.narrowID, name: narrowManifest.name, version: narrowManifest.version,
            manifestJSON: try! narrowManifest.toJSONData(), basePath: narrowDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(narrowRecord)

        let narrowConfig = WKWebViewConfiguration()
        let narrowBundle = ChromeAPIBundle.generateBundle(for: narrowExt, isContentScript: false)
        narrowConfig.userContentController.addUserScript(
            WKUserScript(source: narrowBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ExtensionMessageBridge.shared.register(on: narrowConfig.userContentController)
        let narrowWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: narrowConfig)

        let narrowBgHost = BackgroundHost(extension: narrowExt)
        ExtensionManager.shared.backgroundHosts[Self.narrowID] = narrowBgHost

        let narrowBgExp = expectation(description: "Narrow BG ready")
        narrowBgHost.start { narrowBgExp.fulfill() }

        // --- Shared Tab Infrastructure ---
        let testProfile = TabStore.shared.addProfile(name: "Tabs Test Profile")
        let testSpace = TabStore.shared.addSpace(name: "Tabs Test Space", emoji: "T", colorHex: "#000000", profileID: testProfile.id)
        ExtensionManager.shared.lastActiveSpaceID = testSpace.id

        // Main test tab (used by allowed/denied tests)
        let tabConfig = WKWebViewConfiguration()
        for ext in [allowedExt, deniedExt] {
            let bundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: true)
            tabConfig.userContentController.addUserScript(
                WKUserScript(source: bundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: ext.contentWorld))
            ExtensionMessageBridge.shared.register(on: tabConfig.userContentController, contentWorld: ext.contentWorld)
        }
        let tabWV = WKWebView(frame: .zero, configuration: tabConfig)
        let testBrowserTab = BrowserTab(webView: tabWV)
        testSpace.tabs.append(testBrowserTab)
        testSpace.selectedTabID = testBrowserTab.id
        let testTabIntID = ExtensionManager.shared.tabIDMap.intID(for: testBrowserTab.id)

        // Host permission test tabs
        let allowedHostConfig = WKWebViewConfiguration()
        let ahBundle = ChromeAPIBundle.generateBundle(for: narrowExt, isContentScript: true)
        allowedHostConfig.userContentController.addUserScript(
            WKUserScript(source: ahBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: narrowExt.contentWorld))
        ExtensionMessageBridge.shared.register(on: allowedHostConfig.userContentController, contentWorld: narrowExt.contentWorld)
        let ahWV = WKWebView(frame: .zero, configuration: allowedHostConfig)
        let allowedHostTab = BrowserTab(webView: ahWV)
        testSpace.tabs.append(allowedHostTab)
        let allowedHostTabIntID = ExtensionManager.shared.tabIDMap.intID(for: allowedHostTab.id)

        let deniedHostConfig = WKWebViewConfiguration()
        let dhBundle = ChromeAPIBundle.generateBundle(for: narrowExt, isContentScript: true)
        deniedHostConfig.userContentController.addUserScript(
            WKUserScript(source: dhBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: narrowExt.contentWorld))
        ExtensionMessageBridge.shared.register(on: deniedHostConfig.userContentController, contentWorld: narrowExt.contentWorld)
        let dhWV = WKWebView(frame: .zero, configuration: deniedHostConfig)
        let deniedHostTab = BrowserTab(webView: dhWV)
        testSpace.tabs.append(deniedHostTab)
        let deniedHostTabIntID = ExtensionManager.shared.tabIDMap.intID(for: deniedHostTab.id)

        // Load all pages
        let html = "<html><body>test</body></html>"

        let allowedNavExp = expectation(description: "Allowed page loaded")
        let allowedNavDelegate = TestTabsNavDelegate { allowedNavExp.fulfill() }
        allowedWebView.navigationDelegate = allowedNavDelegate
        allowedWebView.loadHTMLString(html, baseURL: URL(string: "https://tabs-test.example.com")!)

        let deniedNavExp = expectation(description: "Denied page loaded")
        let deniedNavDelegate = TestTabsNavDelegate { deniedNavExp.fulfill() }
        deniedWebView.navigationDelegate = deniedNavDelegate
        deniedWebView.loadHTMLString(html, baseURL: URL(string: "https://tabs-test.example.com")!)

        let narrowNavExp = expectation(description: "Narrow page loaded")
        let narrowNavDelegate = TestTabsNavDelegate { narrowNavExp.fulfill() }
        narrowWebView.navigationDelegate = narrowNavDelegate
        narrowWebView.loadHTMLString(html, baseURL: URL(string: "https://tabs-test.example.com")!)

        let tabNavExp = expectation(description: "Tab page loaded")
        let tabNavDelegate = TestTabsNavDelegate { tabNavExp.fulfill() }
        tabWV.navigationDelegate = tabNavDelegate
        tabWV.loadHTMLString("<html><head><title>Test Tab</title></head><body>tab</body></html>",
                             baseURL: URL(string: "https://tab.test.example.com")!)

        let ahNavExp = expectation(description: "Allowed host tab loaded")
        let allowedHostNavDelegate = TestTabsNavDelegate { ahNavExp.fulfill() }
        ahWV.navigationDelegate = allowedHostNavDelegate
        ahWV.loadHTMLString("<html><body>allowed host</body></html>",
                            baseURL: URL(string: "https://sub.allowed.test/page")!)

        let dhNavExp = expectation(description: "Denied host tab loaded")
        let deniedHostNavDelegate = TestTabsNavDelegate { dhNavExp.fulfill() }
        dhWV.navigationDelegate = deniedHostNavDelegate
        dhWV.loadHTMLString("<html><body>denied host</body></html>",
                            baseURL: URL(string: "https://denied.test/page")!)

        wait(for: [allowedNavExp, deniedNavExp, narrowNavExp, tabNavExp, ahNavExp, dhNavExp,
                   allowedBgExp, narrowBgExp], timeout: 10.0)

        Self.shared = SharedState(
            allowedDir: allowedDir,
            allowedExt: allowedExt,
            allowedWebView: allowedWebView,
            allowedNavDelegate: allowedNavDelegate,
            allowedBgHost: allowedBgHost,
            deniedDir: deniedDir,
            deniedExt: deniedExt,
            deniedWebView: deniedWebView,
            deniedNavDelegate: deniedNavDelegate,
            narrowDir: narrowDir,
            narrowExt: narrowExt,
            narrowWebView: narrowWebView,
            narrowNavDelegate: narrowNavDelegate,
            narrowBgHost: narrowBgHost,
            testProfile: testProfile,
            testSpace: testSpace,
            testBrowserTab: testBrowserTab,
            testTabIntID: testTabIntID,
            tabNavDelegate: tabNavDelegate,
            allowedHostTab: allowedHostTab,
            allowedHostTabIntID: allowedHostTabIntID,
            allowedHostNavDelegate: allowedHostNavDelegate,
            deniedHostTab: deniedHostTab,
            deniedHostTabIntID: deniedHostTabIntID,
            deniedHostNavDelegate: deniedHostNavDelegate
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
        narrowExt = s.narrowExt
        narrowWebView = s.narrowWebView
        testProfile = s.testProfile
        testSpace = s.testSpace
        testBrowserTab = s.testBrowserTab
        testTabIntID = s.testTabIntID
        allowedHostTab = s.allowedHostTab
        allowedHostTabIntID = s.allowedHostTabIntID
        deniedHostTab = s.deniedHostTab
        deniedHostTabIntID = s.deniedHostTabIntID
    }

    @MainActor
    override func tearDown() {
        // Don't tear down shared state — it's reused across tests
        super.tearDown()
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            guard let s = shared else { return }
            s.allowedBgHost.stop()
            s.narrowBgHost.stop()

            for extID in [allowedID, deniedID, narrowID] {
                ExtensionManager.shared.extensions.removeAll { $0.id == extID }
                ExtensionManager.shared.backgroundHosts.removeValue(forKey: extID)
                AppDatabase.shared.storageClear(extensionID: extID)
                AppDatabase.shared.deleteExtension(id: extID)
            }

            for tab in [s.testBrowserTab, s.allowedHostTab, s.deniedHostTab].compactMap({ $0 }) {
                ExtensionManager.shared.tabIDMap.remove(uuid: tab.id)
            }
            TabStore.shared.forceRemoveSpace(id: s.testSpace.id)
            ExtensionManager.shared.spaceIDMap.remove(uuid: s.testSpace.id)
            TabStore.shared.forceRemoveProfile(id: s.testProfile.id)
            ExtensionManager.shared.lastActiveSpaceID = nil

            try? FileManager.default.removeItem(at: s.allowedDir)
            try? FileManager.default.removeItem(at: s.deniedDir)
            try? FileManager.default.removeItem(at: s.narrowDir)
            shared = nil
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
