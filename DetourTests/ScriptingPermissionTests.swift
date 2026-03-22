import XCTest
import WebKit
@testable import Detour

/// Integration tests verifying that the scripting permission gate in ExtensionMessageBridge
/// correctly allows/denies chrome.scripting.* calls based on manifest permissions,
/// and that host permission checks gate executeScript/insertCSS on the target tab URL.
@MainActor
final class ScriptingPermissionTests: XCTestCase {

    // Extension WITH scripting + <all_urls>
    private var allowedExt: WebExtension!
    private var allowedWebView: WKWebView!

    // Extension WITHOUT scripting
    private var deniedExt: WebExtension!
    private var deniedWebView: WKWebView!

    // Extension WITH scripting + narrow host
    private var narrowExt: WebExtension!
    private var narrowWebView: WKWebView!

    // Tab infrastructure
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

    private static let allowedID = "test-scripting-perm-allowed"
    private static let deniedID = "test-scripting-perm-denied"
    private static let narrowID = "test-scripting-perm-narrow"

    private struct SharedState {
        let allowedDir: URL
        let allowedExt: WebExtension
        let allowedWebView: WKWebView
        let allowedNavDelegate: TestScriptingNavDelegate

        let deniedDir: URL
        let deniedExt: WebExtension
        let deniedWebView: WKWebView
        let deniedNavDelegate: TestScriptingNavDelegate

        let narrowDir: URL
        let narrowExt: WebExtension
        let narrowWebView: WKWebView
        let narrowNavDelegate: TestScriptingNavDelegate

        let testProfile: Profile
        let testSpace: Space
        let testBrowserTab: BrowserTab
        let testTabIntID: Int
        let tabNavDelegate: TestScriptingNavDelegate

        let allowedHostTab: BrowserTab
        let allowedHostTabIntID: Int
        let allowedHostNavDelegate: TestScriptingNavDelegate
        let deniedHostTab: BrowserTab
        let deniedHostTabIntID: Int
        let deniedHostNavDelegate: TestScriptingNavDelegate
    }

    private nonisolated(unsafe) static var shared: SharedState?

    /// Create the shared test infrastructure once. Called from the first test's setUp.
    private func createSharedStateIfNeeded() {
        guard Self.shared == nil else { return }

        // --- Extension with scripting + <all_urls> ---
        let allowedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-scripting-allowed")
        try? FileManager.default.removeItem(at: allowedDir)
        try! FileManager.default.createDirectory(at: allowedDir, withIntermediateDirectories: true)

        let allowedManifestJSON = """
        {
            "manifest_version": 3,
            "name": "Scripting Allowed",
            "version": "1.0",
            "permissions": ["scripting"],
            "host_permissions": ["<all_urls>"]
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
        allowedConfig.userContentController.addUserScript(
            WKUserScript(source: allowedBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ExtensionMessageBridge.shared.register(on: allowedConfig.userContentController)
        let allowedWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: allowedConfig)

        // --- Extension without scripting ---
        let deniedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-scripting-denied")
        try? FileManager.default.removeItem(at: deniedDir)
        try! FileManager.default.createDirectory(at: deniedDir, withIntermediateDirectories: true)

        let deniedManifestJSON = """
        {
            "manifest_version": 3,
            "name": "Scripting Denied",
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

        // --- Extension with scripting + narrow host ---
        let narrowDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-scripting-narrow")
        try? FileManager.default.removeItem(at: narrowDir)
        try! FileManager.default.createDirectory(at: narrowDir, withIntermediateDirectories: true)

        let narrowManifestJSON = """
        {
            "manifest_version": 3,
            "name": "Scripting Narrow Host",
            "version": "1.0",
            "permissions": ["scripting"],
            "host_permissions": ["https://*.allowed.test/*"]
        }
        """
        try! narrowManifestJSON.write(to: narrowDir.appendingPathComponent("manifest.json"),
                                      atomically: true, encoding: .utf8)

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

        // --- Tab Infrastructure ---
        let testProfile = TabStore.shared.addProfile(name: "Scripting Test Profile")
        let testSpace = TabStore.shared.addSpace(name: "Scripting Test Space", emoji: "S", colorHex: "#000000", profileID: testProfile.id)
        ExtensionManager.shared.lastActiveSpaceID = testSpace.id

        // Main test tab for allowed/denied tests
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
        let ahConfig = WKWebViewConfiguration()
        let ahBundle = ChromeAPIBundle.generateBundle(for: narrowExt, isContentScript: true)
        ahConfig.userContentController.addUserScript(
            WKUserScript(source: ahBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: narrowExt.contentWorld))
        ExtensionMessageBridge.shared.register(on: ahConfig.userContentController, contentWorld: narrowExt.contentWorld)
        let ahWV = WKWebView(frame: .zero, configuration: ahConfig)
        let allowedHostTab = BrowserTab(webView: ahWV)
        testSpace.tabs.append(allowedHostTab)
        let allowedHostTabIntID = ExtensionManager.shared.tabIDMap.intID(for: allowedHostTab.id)

        let dhConfig = WKWebViewConfiguration()
        let dhBundle = ChromeAPIBundle.generateBundle(for: narrowExt, isContentScript: true)
        dhConfig.userContentController.addUserScript(
            WKUserScript(source: dhBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: narrowExt.contentWorld))
        ExtensionMessageBridge.shared.register(on: dhConfig.userContentController, contentWorld: narrowExt.contentWorld)
        let dhWV = WKWebView(frame: .zero, configuration: dhConfig)
        let deniedHostTab = BrowserTab(webView: dhWV)
        testSpace.tabs.append(deniedHostTab)
        let deniedHostTabIntID = ExtensionManager.shared.tabIDMap.intID(for: deniedHostTab.id)

        // Write injectable files
        try! "document.title;".write(to: allowedDir.appendingPathComponent("inject.js"), atomically: true, encoding: .utf8)
        try! "document.title;".write(to: narrowDir.appendingPathComponent("inject.js"), atomically: true, encoding: .utf8)

        // Load all pages
        let html = "<html><body>test</body></html>"

        let allowedNavExp = expectation(description: "Allowed page loaded")
        let allowedNavDelegate = TestScriptingNavDelegate { allowedNavExp.fulfill() }
        allowedWebView.navigationDelegate = allowedNavDelegate
        allowedWebView.loadHTMLString(html, baseURL: URL(string: "https://scripting-test.example.com")!)

        let deniedNavExp = expectation(description: "Denied page loaded")
        let deniedNavDelegate = TestScriptingNavDelegate { deniedNavExp.fulfill() }
        deniedWebView.navigationDelegate = deniedNavDelegate
        deniedWebView.loadHTMLString(html, baseURL: URL(string: "https://scripting-test.example.com")!)

        let narrowNavExp = expectation(description: "Narrow page loaded")
        let narrowNavDelegate = TestScriptingNavDelegate { narrowNavExp.fulfill() }
        narrowWebView.navigationDelegate = narrowNavDelegate
        narrowWebView.loadHTMLString(html, baseURL: URL(string: "https://scripting-test.example.com")!)

        let tabNavExp = expectation(description: "Tab page loaded")
        let tabNavDelegate = TestScriptingNavDelegate { tabNavExp.fulfill() }
        tabWV.navigationDelegate = tabNavDelegate
        tabWV.loadHTMLString("<html><head><title>Scripting Tab</title></head><body>content</body></html>",
                             baseURL: URL(string: "https://tab.test.example.com")!)

        let ahNavExp = expectation(description: "Allowed host tab loaded")
        let allowedHostNavDelegate = TestScriptingNavDelegate { ahNavExp.fulfill() }
        ahWV.navigationDelegate = allowedHostNavDelegate
        ahWV.loadHTMLString("<html><head><title>Allowed Host Page</title></head><body>allowed</body></html>",
                            baseURL: URL(string: "https://sub.allowed.test/page")!)

        let dhNavExp = expectation(description: "Denied host tab loaded")
        let deniedHostNavDelegate = TestScriptingNavDelegate { dhNavExp.fulfill() }
        dhWV.navigationDelegate = deniedHostNavDelegate
        dhWV.loadHTMLString("<html><head><title>Denied Host Page</title></head><body>denied</body></html>",
                            baseURL: URL(string: "https://denied.test/page")!)

        wait(for: [allowedNavExp, deniedNavExp, narrowNavExp, tabNavExp, ahNavExp, dhNavExp], timeout: 10.0)

        Self.shared = SharedState(
            allowedDir: allowedDir,
            allowedExt: allowedExt,
            allowedWebView: allowedWebView,
            allowedNavDelegate: allowedNavDelegate,
            deniedDir: deniedDir,
            deniedExt: deniedExt,
            deniedWebView: deniedWebView,
            deniedNavDelegate: deniedNavDelegate,
            narrowDir: narrowDir,
            narrowExt: narrowExt,
            narrowWebView: narrowWebView,
            narrowNavDelegate: narrowNavDelegate,
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

    func testExecuteScriptAllowed() {
        let result = callAsync(allowedWebView, """
            var results = await chrome.scripting.executeScript({
                target: { tabId: \(testTabIntID!) },
                files: ['inject.js']
            });
            return JSON.stringify(results);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Failed to parse executeScript result: \(String(describing: result))"); return
        }
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0]["result"] as? String, "Scripting Tab")
    }

    func testInsertCSSAllowed() {
        let result = callAsync(allowedWebView, """
            await chrome.scripting.insertCSS({
                target: { tabId: \(testTabIntID!) },
                css: 'body { color: red; }'
            });
            return true;
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    // MARK: - Denied

    func testExecuteScriptDenied() {
        let result = callAsync(deniedWebView, """
            try {
                await chrome.scripting.executeScript({
                    target: { tabId: \(testTabIntID!) },
                    files: ['inject.js']
                });
                return 'resolved';
            } catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("scripting"), "Error should mention 'scripting': \(msg)")
    }

    func testInsertCSSDenied() {
        let result = callAsync(deniedWebView, """
            try {
                await chrome.scripting.insertCSS({
                    target: { tabId: \(testTabIntID!) },
                    css: 'body { color: red; }'
                });
                return 'resolved';
            } catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("scripting"), "Error should mention 'scripting': \(msg)")
    }

    // MARK: - Host Permission (executeScript)

    func testExecuteScriptHostAllowed() {
        let result = callAsync(narrowWebView, """
            var results = await chrome.scripting.executeScript({
                target: { tabId: \(allowedHostTabIntID!) },
                files: ['inject.js']
            });
            return JSON.stringify(results);
        """)
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Failed to parse result: \(String(describing: result))"); return
        }
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr[0]["result"] as? String, "Allowed Host Page")
    }

    func testExecuteScriptHostDenied() {
        let result = callAsync(narrowWebView, """
            try {
                await chrome.scripting.executeScript({
                    target: { tabId: \(deniedHostTabIntID!) },
                    files: ['inject.js']
                });
                return 'resolved';
            } catch (e) { return e.message; }
        """)
        let msg = result as? String ?? ""
        XCTAssertTrue(msg.contains("access") || msg.contains("host") || msg.contains("denied.test"),
                      "Error should indicate host permission denial: \(msg)")
    }

    // MARK: - Host Permission (insertCSS)

    func testInsertCSSHostAllowed() {
        let result = callAsync(narrowWebView, """
            await chrome.scripting.insertCSS({
                target: { tabId: \(allowedHostTabIntID!) },
                css: 'body { color: green; }'
            });
            return true;
        """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testInsertCSSHostDenied() {
        let result = callAsync(narrowWebView, """
            try {
                await chrome.scripting.insertCSS({
                    target: { tabId: \(deniedHostTabIntID!) },
                    css: 'body { color: red; }'
                });
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
}

private class TestScriptingNavDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
