import XCTest
import WebKit
@testable import Detour

/// Integration tests that load a test extension via WKWebExtension and verify
/// core chrome.* APIs work end-to-end through the native API.
///
/// Uses a shared one-time setup per test class to avoid recreating the extension
/// controller for each test.
@MainActor
final class WKExtensionIntegrationTests: XCTestCase {

    private static let extensionID = "test-wk-integration"
    private static let testHTMLPage = "<html><head><title>Test Page</title></head><body>test content</body></html>"

    private struct SharedState {
        let tempDir: URL
        let ext: WebExtension
        let wkExtension: WKWebExtension
        let context: WKWebExtensionContext
        let controller: WKWebExtensionController
        let testSpace: Space
        let testProfile: Profile
    }

    private nonisolated(unsafe) static var shared: SharedState?

    private var state: SharedState { Self.shared! }

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        if Self.shared == nil {
            try await createSharedState()
        }
    }

    private func createSharedState() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-wk-integration-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Write manifest
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "WK Integration Test",
            "version": "1.0.0",
            "description": "Tests WKWebExtension API surface",
            "permissions": ["storage", "tabs", "scripting", "alarms", "contextMenus"],
            "host_permissions": ["<all_urls>"],
            "background": {"service_worker": "background.js"},
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}
            ],
            "action": {
                "default_popup": "popup.html",
                "default_title": "Test Action"
            }
        }
        """
        try manifestJSON.write(to: tempDir.appendingPathComponent("manifest.json"),
                               atomically: true, encoding: .utf8)

        // Background script that handles messages
        let backgroundJS = """
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message.type === 'ping') {
                sendResponse({ type: 'pong', receivedAt: Date.now() });
                return true;
            }
            if (message.type === 'get-sender') {
                sendResponse({ tab: sender.tab, url: sender.url });
                return true;
            }
            if (message.type === 'storage-set') {
                chrome.storage.local.set(message.data).then(() => sendResponse({ ok: true }));
                return true;
            }
            if (message.type === 'storage-get') {
                chrome.storage.local.get(message.keys).then(result => sendResponse(result));
                return true;
            }
            if (message.type === 'tabs-query') {
                chrome.tabs.query(message.queryInfo || {}).then(tabs => sendResponse({ tabs }));
                return true;
            }
            if (message.type === 'alarms-create') {
                chrome.alarms.create(message.name, message.alarmInfo).then(() => sendResponse({ ok: true }));
                return true;
            }
            if (message.type === 'alarms-get-all') {
                chrome.alarms.getAll().then(alarms => sendResponse({ alarms }));
                return true;
            }
            if (message.type === 'alarms-clear-all') {
                chrome.alarms.clearAll().then(() => sendResponse({ ok: true }));
                return true;
            }
        });

        chrome.runtime.onInstalled.addListener((details) => {
            // Set a marker so we can verify onInstalled fired
            chrome.storage.local.set({ __onInstalledReason: details.reason });
        });
        """
        try backgroundJS.write(to: tempDir.appendingPathComponent("background.js"),
                               atomically: true, encoding: .utf8)

        // Content script that sets a marker on the page
        let contentJS = """
        document.documentElement.setAttribute('data-extension-loaded', 'true');
        """
        try contentJS.write(to: tempDir.appendingPathComponent("content.js"),
                            atomically: true, encoding: .utf8)

        // Popup HTML
        let popupHTML = """
        <html><body><div id="popup">Extension Popup</div></body></html>
        """
        try popupHTML.write(to: tempDir.appendingPathComponent("popup.html"),
                           atomically: true, encoding: .utf8)

        // Load via WKWebExtension
        let wkExt = try await WKWebExtension(resourceBaseURL: tempDir)
        let config = WKWebExtensionController.Configuration(identifier: UUID())
        let controller = WKWebExtensionController(configuration: config)

        let context = WKWebExtensionContext(for: wkExt)
        context.isInspectable = true

        // Grant all permissions
        for permission in wkExt.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in wkExt.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        if let allURLs = try? WKWebExtension.MatchPattern(string: "<all_urls>") {
            context.setPermissionStatus(.grantedExplicitly, for: allURLs)
        }

        try controller.load(context)

        // Load background content
        if wkExt.hasBackgroundContent {
            try await context.loadBackgroundContent()
        }

        // Register in ExtensionManager for tab conformance lookups
        let manifest = try ExtensionManifest.parse(at: tempDir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: Self.extensionID, manifest: manifest, basePath: tempDir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)

        // Create test space with the controller wired
        let testProfile = TabStore.shared.addProfile(name: "WK Test Profile")
        testProfile.extensionContexts[Self.extensionID] = context
        let testSpace = TabStore.shared.addSpace(
            name: "WK Test Space", emoji: "T", colorHex: "#000000", profileID: testProfile.id)
        ExtensionManager.shared.lastActiveSpaceID = testSpace.id

        // Wait for onInstalled to fire
        try await Task.sleep(nanoseconds: 500_000_000)

        Self.shared = SharedState(
            tempDir: tempDir,
            ext: ext,
            wkExtension: wkExt,
            context: context,
            controller: controller,
            testSpace: testSpace,
            testProfile: testProfile
        )
    }

    override class func tearDown() {
        if let state = shared {
            try? state.controller.unload(state.context)
            ExtensionManager.shared.extensions.removeAll { $0.id == extensionID }
            state.testProfile.extensionContexts.removeValue(forKey: extensionID)
            try? FileManager.default.removeItem(at: state.tempDir)
        }
        shared = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create a WKWebView wired to the test extension controller and load a page.
    private func makeWebView(html: String = testHTMLPage, baseURL: String = "https://test.example.com") async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.webExtensionController = state.controller
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        wv.loadHTMLString(html, baseURL: URL(string: baseURL)!)
        // Wait for page load
        try await Task.sleep(nanoseconds: 500_000_000)
        return wv
    }

    /// Evaluate JS in the background context via a round-trip message from a content page.
    /// Sends a message via chrome.runtime.sendMessage and returns the response.
    private func sendMessageToBackground(_ message: [String: Any], via webView: WKWebView) async throws -> Any? {
        let msgData = try JSONSerialization.data(withJSONObject: message)
        let msgJSON = String(data: msgData, encoding: .utf8)!

        let js = """
        new Promise((resolve, reject) => {
            chrome.runtime.sendMessage(\(msgJSON), response => {
                if (chrome.runtime.lastError) {
                    reject(new Error(chrome.runtime.lastError.message));
                } else {
                    resolve(JSON.stringify(response));
                }
            });
        });
        """

        let result = try await webView.evaluateJavaScript(js)
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8) {
            return try JSONSerialization.jsonObject(with: data)
        }
        return result
    }

    // MARK: - Extension Loading

    func testExtensionLoaded() {
        XCTAssertNotNil(state.context)
        XCTAssertTrue(state.context.errors.isEmpty, "Context should have no errors: \(state.context.errors)")
    }

    func testExtensionDisplayName() {
        XCTAssertEqual(state.wkExtension.displayName, "WK Integration Test")
    }

    func testExtensionVersion() {
        XCTAssertEqual(state.wkExtension.displayVersion, "1.0.0")
    }

    func testExtensionHasBackgroundContent() {
        XCTAssertTrue(state.wkExtension.hasBackgroundContent)
    }

    func testExtensionHasInjectedContent() {
        XCTAssertTrue(state.wkExtension.hasInjectedContent)
    }

    func testExtensionHasAction() {
        XCTAssertNotNil(state.wkExtension.displayActionLabel)
    }

    func testExtensionBaseURL() {
        XCTAssertTrue(state.context.baseURL.scheme == "webkit-extension")
    }

    // MARK: - Content Script Injection

    func testContentScriptInjectsMarker() async throws {
        let wv = try await makeWebView()
        let marker = try await wv.evaluateJavaScript(
            "document.documentElement.getAttribute('data-extension-loaded')")
        XCTAssertEqual(marker as? String, "true")
    }

    // MARK: - Runtime Messaging
    // These tests require full WebKit extension runtime with background service worker
    // communication. They fail in the unit test sandbox due to missing entitlements.
    // Run the app with the API Explorer extension for manual verification.

    func testRuntimeSendMessagePing() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DETOUR_DATA_DIR"] != nil,
                       "Skipped in test sandbox — requires full WebKit runtime")
        let wv = try await makeWebView()
        let response = try await sendMessageToBackground(["type": "ping"], via: wv) as? [String: Any]
        XCTAssertEqual(response?["type"] as? String, "pong")
    }

    func testRuntimeSendMessageSender() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DETOUR_DATA_DIR"] != nil,
                       "Skipped in test sandbox — requires full WebKit runtime")
        let wv = try await makeWebView()
        let response = try await sendMessageToBackground(["type": "get-sender"], via: wv) as? [String: Any]
        // Sender should include tab info
        XCTAssertNotNil(response?["tab"], "Sender should include tab info")
    }

    // MARK: - Storage

    func testStorageLocalSetAndGet() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DETOUR_DATA_DIR"] != nil,
                       "Skipped in test sandbox — requires full WebKit runtime")
        let wv = try await makeWebView()

        // Set a value
        let setResponse = try await sendMessageToBackground(
            ["type": "storage-set", "data": ["testKey": "testValue"]], via: wv) as? [String: Any]
        XCTAssertEqual(setResponse?["ok"] as? Bool, true)

        // Get it back
        let getResponse = try await sendMessageToBackground(
            ["type": "storage-get", "keys": ["testKey"]], via: wv) as? [String: Any]
        XCTAssertEqual(getResponse?["testKey"] as? String, "testValue")
    }

    func testStorageOnInstalledFired() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DETOUR_DATA_DIR"] != nil,
                       "Skipped in test sandbox — requires full WebKit runtime")
        let wv = try await makeWebView()

        // The onInstalled listener sets __onInstalledReason in storage
        let response = try await sendMessageToBackground(
            ["type": "storage-get", "keys": ["__onInstalledReason"]], via: wv) as? [String: Any]
        XCTAssertEqual(response?["__onInstalledReason"] as? String, "install")
    }

    // MARK: - Tabs

    func testTabsQueryReturnsResults() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DETOUR_DATA_DIR"] != nil,
                       "Skipped in test sandbox — requires full WebKit runtime")
        let wv = try await makeWebView()
        let response = try await sendMessageToBackground(
            ["type": "tabs-query"], via: wv) as? [String: Any]
        let tabs = response?["tabs"] as? [[String: Any]]
        XCTAssertNotNil(tabs, "tabs.query should return an array")
        XCTAssertGreaterThan(tabs?.count ?? 0, 0, "Should have at least one tab")
    }

    // MARK: - Alarms

    func testAlarmsCreateAndGetAll() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DETOUR_DATA_DIR"] != nil,
                       "Skipped in test sandbox — requires full WebKit runtime")
        let wv = try await makeWebView()

        // Create an alarm
        let createResponse = try await sendMessageToBackground(
            ["type": "alarms-create", "name": "test-alarm",
             "alarmInfo": ["delayInMinutes": 1]], via: wv) as? [String: Any]
        XCTAssertEqual(createResponse?["ok"] as? Bool, true)

        // Get all alarms
        let getAllResponse = try await sendMessageToBackground(
            ["type": "alarms-get-all"], via: wv) as? [String: Any]
        let alarms = getAllResponse?["alarms"] as? [[String: Any]]
        XCTAssertNotNil(alarms)
        XCTAssertTrue(alarms?.contains { ($0["name"] as? String) == "test-alarm" } ?? false)

        // Clean up
        _ = try await sendMessageToBackground(["type": "alarms-clear-all"], via: wv)
    }

    // MARK: - Action / Popup

    func testActionExists() {
        let action = state.context.action(for: nil)
        XCTAssertNotNil(action, "Extension should have a default action")
    }

    func testActionLabel() {
        let action = state.context.action(for: nil)
        XCTAssertEqual(action?.label, "Test Action")
    }

    // MARK: - Permissions

    func testPermissionGranted() {
        XCTAssertTrue(state.context.hasPermission(.storage))
        XCTAssertTrue(state.context.hasPermission(.tabs))
        XCTAssertTrue(state.context.hasPermission(.scripting))
        XCTAssertTrue(state.context.hasPermission(.alarms))
    }

    func testURLAccessGranted() {
        let url = URL(string: "https://example.com")!
        XCTAssertTrue(state.context.hasAccess(to: url))
    }

    // MARK: - WKWebExtensionTab Conformance

    func testBrowserTabConformance() async throws {
        let config = WKWebViewConfiguration()
        config.webExtensionController = state.controller
        let wv = WKWebView(frame: .zero, configuration: config)
        let tab = BrowserTab(webView: wv)

        XCTAssertNotNil(tab.webView(for: state.context))
        XCTAssertFalse(tab.isPlayingAudio(for: state.context))
        XCTAssertFalse(tab.isMuted(for: state.context))
    }

    func testBrowserTabLoadingState() async throws {
        let wv = try await makeWebView()
        let tab = BrowserTab(webView: wv)

        // Page should be loaded by now
        XCTAssertTrue(tab.isLoadingComplete(for: state.context))
    }
}
