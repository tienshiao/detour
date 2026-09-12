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

        // Background script that handles messages. Every handler is awaited
        // through one dispatcher and its throw or rejection is answered as
        // `{ error }`: a listener that dies mid-way simply never calls
        // sendResponse, which reaches the test as an empty reply — indistinguishable
        // from a message that never arrived (and from a return value that is not a
        // promise, which is how `chrome.alarms.create(...).then(...)` used to fail
        // here). Every handler answers explicitly; one that returned undefined
        // would answer nothing, which the test reports as an empty reply.
        let backgroundJS = """
        const handlers = {
            'ping': () => ({ type: 'pong', receivedAt: Date.now() }),
            'get-sender': (message, sender) => ({ tab: sender.tab, url: sender.url }),
            'storage-set': async (message) => {
                await chrome.storage.local.set(message.data);
                return { ok: true };
            },
            'storage-get': (message) => chrome.storage.local.get(message.keys),
            'storage-dump': () => chrome.storage.local.get(null),
            'tabs-query': async (message) => ({ tabs: await chrome.tabs.query(message.queryInfo || {}) }),
            'alarms-create': async (message) => {
                await chrome.alarms.create(message.name, message.alarmInfo);
                return { ok: true };
            },
            'alarms-get-all': async () => ({ alarms: await chrome.alarms.getAll() }),
            'alarms-clear-all': async () => {
                await chrome.alarms.clearAll();
                return { ok: true };
            },
            'install-events': () => ({ events: globalThis.__installEvents })
        };

        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            const handler = handlers[message && message.type];
            if (!handler) { return false; }
            (async () => handler(message, sender))()
                .then(sendResponse, (error) => sendResponse({ error: String(error && error.message ? error.message : error) }));
            return true;
        });

        // Record the install event twice over: in a worker global, which says the
        // listener ran in *this* worker instance, and in storage, which survives the
        // worker being restarted. A test can then tell "the event never fired" from
        // "the event fired for an instance that is gone".
        globalThis.__installEvents = [];
        chrome.runtime.onInstalled.addListener((details) => {
            globalThis.__installEvents.push(details.reason);
            chrome.storage.local.set({ __onInstalledReason: details.reason });
        });
        """
        try backgroundJS.write(to: tempDir.appendingPathComponent("background.js"),
                               atomically: true, encoding: .utf8)

        // Content script: marks the page, and relays the tests' messages to the
        // background worker. The relay is needed because only the content script
        // can talk to the worker — a plain https page has no `chrome` of its own
        // ("Can't find variable: chrome"), and a test cannot evaluate JS in the
        // content script's world — so `askWorker(via: .contentScriptRelay)` posts
        // a request on `window` from the page and the answer comes back the same
        // way.
        let contentJS = """
        document.documentElement.setAttribute('data-extension-loaded', 'true');

        window.addEventListener('message', (event) => {
            const request = event.data;
            if (!request || request.__detourTest !== 'ask') { return; }
            chrome.runtime.sendMessage(request.message, (reply) => {
                window.postMessage({
                    __detourTest: 'answer',
                    id: request.id,
                    reply: reply === undefined ? null : reply,
                    lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
                }, '*');
            });
        });
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

    /// Probe tabs registered by `makeWebView`, closed again after each test so a
    /// case never sees the tabs of the ones before it (`chrome.tabs.query` would
    /// count them).
    private var registeredProbes: [(window: ProbeExtensionWindow, tab: ProbeExtensionTab)] = []

    override func tearDown() async throws {
        for probe in registeredProbes.reversed() {
            unregisterProbeTab(probe, in: state.context)
        }
        registeredProbes.removeAll()
        try await super.tearDown()
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

    /// Create a WKWebView wired to the test extension controller, register it as
    /// a tab of the extension context, and load a page in it.
    ///
    /// The registration is what makes the extension side of the web view work at
    /// all: content scripts only reach the background worker, and
    /// `chrome.tabs.query` only sees anything, once the web view is a tab the
    /// context knows about (established in TASK-4 Phase A). It has to happen
    /// before the load, and it is undone in `tearDown`.
    private func makeWebView(html: String = testHTMLPage, baseURL: String = "https://test.example.com") async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.webExtensionController = state.controller
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)

        registeredProbes.append(registerProbeTab(for: wv, in: state.context))

        try await loadHTMLStringAndWait(wv, html: html, baseURL: URL(string: baseURL)!)
        return wv
    }

    /// Round-trip one message to the background worker from a content page and
    /// return the worker's response.
    ///
    /// The worker is woken first: a message sent while the service worker sleeps
    /// is silently dropped — the callback fires with no response and no
    /// `lastError` (observed in TASK-4 Phase A) — so `loadBackgroundContent()`
    /// runs before the send, and an empty reply is retried once before it counts
    /// as a failure.
    ///
    /// The page is a plain https page, so the round trip goes through the content
    /// script's relay (`askWorker(via: .contentScriptRelay)`).
    private func sendMessageToBackground(_ message: [String: Any], via webView: WKWebView) async throws -> Any? {
        try? await state.context.loadBackgroundContent()
        var envelope = try await askWorker(from: webView, message: message, via: .contentScriptRelay)
        if workerReplyIsEmpty(envelope) {
            try? await state.context.loadBackgroundContent()
            try await Task.sleep(nanoseconds: 250_000_000)
            envelope = try await askWorker(from: webView, message: message, via: .contentScriptRelay)
        }
        guard !workerReplyIsEmpty(envelope) else {
            XCTFail("""
                the background worker did not answer \(message["type"] ?? message), twice over: \
                reply=\(envelope["reply"] ?? "nil") \
                lastError=\(envelope["lastError"] ?? "nil")
                """)
            return nil
        }
        // The worker answers a handler that threw as `{ error }` — say so here
        // rather than leaving the caller's assertion to report a bare nil.
        if let reply = envelope["reply"] as? [String: Any], let error = reply["error"] as? String {
            XCTFail("the worker failed to handle \(message["type"] ?? message): \(error)")
        }
        return envelope["reply"]
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
    // These need the web view to be a registered tab of the extension context,
    // which `makeWebView` does — a content script in an unregistered web view
    // cannot reach the background worker at all.

    func testRuntimeSendMessagePing() async throws {
        let wv = try await makeWebView()
        let response = try await sendMessageToBackground(["type": "ping"], via: wv) as? [String: Any]
        XCTAssertEqual(response?["type"] as? String, "pong")
    }

    func testRuntimeSendMessageSender() async throws {
        let wv = try await makeWebView()
        let response = try await sendMessageToBackground(["type": "get-sender"], via: wv) as? [String: Any]
        // Sender should include tab info
        XCTAssertNotNil(response?["tab"], "Sender should include tab info")
    }

    // MARK: - Storage

    func testStorageLocalSetAndGet() async throws {
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

    /// `chrome.runtime.onInstalled` is *not* delivered in this harness — measured
    /// 2026-09-12 on macOS 26, and the reason the storage marker this test used to
    /// wait for never appeared.
    ///
    /// A context loaded programmatically (`controller.load(context)` plus
    /// `loadBackgroundContent()`) runs its worker — the same worker answers every
    /// message in this suite — but the worker's `onInstalled` listener never fires:
    /// neither its in-worker record nor the storage marker shows up, while a value
    /// another test wrote is still in `storage.local`, so storage persists across
    /// worker instances and the write was not merely lost with one.
    ///
    /// The worker has been running since `createSharedState`, which awaited
    /// `loadBackgroundContent()`, and the listener writes both records
    /// synchronously at dispatch — so there is nothing to wait for: if the event
    /// were delivered, the records would already be there. What makes an empty
    /// dump mean something is the positive control: a value written through the
    /// very same message path has to come back out of `storage-dump`, or an
    /// absent marker would prove only that the probe is broken.
    ///
    /// What is pinned here is that measurement, not Chrome parity. Unlike the tab
    /// registration this file depends on (TASK-20), there is nothing a test can
    /// register to make the event arrive, and this says nothing about whether the
    /// app sees onInstalled when it installs an extension for real. If WebKit
    /// starts delivering it, this test fails — which is the point: flip it to the
    /// Chrome expectation (`reason == "install"`) and re-check what in Detour
    /// depends on onInstalled.
    func testRuntimeOnInstalledIsNotDelivered() async throws {
        let wv = try await makeWebView()

        // Positive control: write a marker through the same message path the
        // onInstalled listener would have used, so the dump below is known to see
        // values that really are in storage.local.
        _ = try await sendMessageToBackground(
            ["type": "storage-set", "data": ["__probeMarker": "live"]], via: wv)
        let dumpReply = try await sendMessageToBackground(["type": "storage-dump"], via: wv)
        let dump = try XCTUnwrap(dumpReply as? [String: Any], "storage-dump probe returned no dictionary")
        XCTAssertEqual(dump["__probeMarker"] as? String, "live",
                       "storage-dump does not see a value written through the same path, "
                       + "so an absent onInstalled marker would prove nothing")

        let eventsReply = try await sendMessageToBackground(["type": "install-events"], via: wv)
        let events = try XCTUnwrap((eventsReply as? [String: Any])?["events"] as? [Any],
                                   "install-events probe returned no array")

        let evidence = "storage.local holds \(dump), the worker recorded install events \(events)"
        XCTAssertNil(dump["__onInstalledReason"], evidence)
        XCTAssertTrue(events.isEmpty, evidence)
    }

    // MARK: - Tabs

    func testTabsQueryReturnsResults() async throws {
        let wv = try await makeWebView()
        let response = try await sendMessageToBackground(
            ["type": "tabs-query"], via: wv) as? [String: Any]
        let tabs = response?["tabs"] as? [[String: Any]]
        XCTAssertNotNil(tabs, "tabs.query should return an array")
        XCTAssertGreaterThan(tabs?.count ?? 0, 0, "Should have at least one tab")
    }

    // MARK: - Alarms

    func testAlarmsCreateAndGetAll() async throws {
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
