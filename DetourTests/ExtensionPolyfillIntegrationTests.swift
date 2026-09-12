import XCTest
import WebKit
@testable import Detour

/// Integration tests that verify the polyfill bridge works alongside a real
/// WKWebExtensionController with native Chrome APIs. Unlike `ExtensionPolyfillTests`
/// (which tests the bridge in a bare WKWebView), these tests prove that:
///   1. The polyfill JS and native APIs coexist without conflicts
///   2. Native APIs (runtime, storage, tabs) remain functional
///   3. Polyfilled APIs (idle, notifications, history, etc.) work in an
///      extension controller context
///   4. The extension context loads without errors from polyfilled permissions
///
/// We test in a web view configured with the extension controller rather than
/// messaging through a service worker, because the test sandbox doesn't support
/// the cross-process IPC that service worker messaging requires.
@MainActor
final class ExtensionPolyfillIntegrationTests: XCTestCase {

    private static let extensionID = "test-polyfill-integration"

    private struct SharedState {
        let tempDir: URL
        let ext: WebExtension
        let context: WKWebExtensionContext
        let controller: WKWebExtensionController
        let polyfillHandler: ExtensionPolyfillHandler
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
            .appendingPathComponent("detour-test-polyfill-int-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Manifest with both native and polyfilled permissions
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Polyfill Integration Test",
            "version": "1.0.0",
            "permissions": ["storage", "tabs", "idle", "notifications", "history",
                             "sessions", "search", "offscreen", "fontSettings", "nativeMessaging"],
            "host_permissions": ["<all_urls>"],
            "background": {"service_worker": "background.js", "type": "module"},
            "action": {"default_title": "Polyfill Test"}
        }
        """
        try manifestJSON.write(to: tempDir.appendingPathComponent("manifest.json"),
                               atomically: true, encoding: .utf8)

        // The worker runs the real polyfill (as ExtensionManager injects it into
        // installed extensions) plus a ping listener, so page->worker messaging is
        // exercised in a real module service worker with nativeMessaging, the
        // shape 1Password's worker has (TASK-15).
        let backgroundJS = ExtensionAPIPolyfill.polyfillJS + """

        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message && message.type === 'ping') {
                sendResponse({
                    type: 'pong',
                    chromeIsNamespace: Object.prototype.toString.call(globalThis.chrome),
                    installMode: globalThis.__detourNativePortKeepAlive ? globalThis.__detourNativePortKeepAlive.installMode : 'missing',
                    installDetail: globalThis.__detourNativePortKeepAlive ? globalThis.__detourNativePortKeepAlive.installDetail : 'missing',
                    connectNativeType: typeof chrome.runtime.connectNative
                });
                return true;
            }
            // Forward an arbitrary payload to the polyfill host via the real
            // sendNativeMessage, so the page can probe the delegate's gate with
            // shapes the polyfill itself never sends.
            if (message && message.type === 'rawPolyfillNative') {
                Promise.resolve()
                    .then(() => chrome.runtime.sendNativeMessage('detourPolyfill', message.payload))
                    .then((r) => sendResponse({ ok: true, reply: r === undefined ? null : r }),
                          (e) => sendResponse({ ok: false, error: String(e && e.message ? e.message : e) }));
                return true;
            }
        });
        """
        try backgroundJS.write(to: tempDir.appendingPathComponent("background.js"),
                               atomically: true, encoding: .utf8)

        // A test page we can load in an extension context web view
        let testHTML = "<html><body><div id=\"test\">Extension Context Page</div></body></html>"
        try testHTML.write(to: tempDir.appendingPathComponent("test.html"),
                           atomically: true, encoding: .utf8)

        // --- Set up controller with polyfill handler ---

        let wkExt = try await WKWebExtension(resourceBaseURL: tempDir)
        let config = WKWebExtensionController.Configuration(identifier: UUID())

        // Wire the polyfill handler onto the controller's webViewConfiguration
        let polyfillHandler = ExtensionPolyfillHandler()
        let ucc = config.webViewConfiguration.userContentController
        ucc.addScriptMessageHandler(
            polyfillHandler, contentWorld: .page,
            name: ExtensionPolyfillHandler.handlerName
        )
        let polyfillScript = WKUserScript(
            source: ExtensionAPIPolyfill.polyfillJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        ucc.addUserScript(polyfillScript)

        let controller = WKWebExtensionController(configuration: config)
        controller.delegate = ExtensionManager.shared

        let context = WKWebExtensionContext(for: wkExt)
        context.isInspectable = true
        // Mirror Profile.loadExtension. Note the uniqueIdentifier is NOT the
        // page origin: WebKit gives the context a fresh webkit-extension://<UUID>/
        // base URL, and the polyfill dispatcher attributes pages to extensions
        // by resolving that origin against the profile's loaded contexts (wired
        // below once the test profile exists).
        context.uniqueIdentifier = Self.extensionID

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

        // Register in ExtensionManager so the polyfill handler can look up extensions
        let manifest = try ExtensionManifest.parse(at: tempDir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: Self.extensionID, manifest: manifest, basePath: tempDir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)

        let testProfile = TabStore.shared.addProfile(name: "Polyfill Int Profile")
        testProfile.extensionContexts[Self.extensionID] = context
        // Strong capture on purpose: the profile lives for the whole suite (pinned
        // by SharedState), and a weakly captured, released profile would turn every
        // later test into an "Unrecognized extension origin" rejection.
        polyfillHandler.extensionOriginResolver = { scheme, host in
            testProfile.extensionID(forOriginScheme: scheme, host: host)
        }
        let testSpace = TabStore.shared.addSpace(
            name: "Polyfill Int Space", emoji: "P", colorHex: "#000000", profileID: testProfile.id)
        ExtensionManager.shared.lastActiveSpaceID = testSpace.id

        Self.shared = SharedState(
            tempDir: tempDir, ext: ext, context: context, controller: controller,
            polyfillHandler: polyfillHandler, testProfile: testProfile
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

    /// Create a WKWebView using the extension context's webViewConfiguration.
    /// This is the same configuration path that popup and options pages use —
    /// it inherits from the controller's config.webViewConfiguration where we
    /// registered the polyfill handler and script.
    private func makeExtensionWebView() async throws -> WKWebView {
        guard let config = state.context.webViewConfiguration else {
            throw XCTSkip("webViewConfiguration is nil — context not loaded in controller")
        }

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)

        // Load a page from the extension's base URL (required by WKWebExtensionContext)
        let testURL = state.context.baseURL.appendingPathComponent("test.html")
        wv.load(URLRequest(url: testURL))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return wv
    }

    /// Evaluate JS using callAsyncJavaScript so Promises are awaited.
    private func eval(_ js: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
    }

    private func evalJSON(_ js: String, in webView: WKWebView) async throws -> Any? {
        let result = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8) {
            return try JSONSerialization.jsonObject(with: data)
        }
        return result
    }

    // MARK: - Extension Loading

    func testContextLoaded() {
        XCTAssertTrue(state.context.isLoaded, "Extension context should be loaded")
    }

    func testExtensionDisplayName() {
        XCTAssertEqual(state.context.webExtension.displayName, "Polyfill Integration Test")
    }

    // MARK: - Polyfilled APIs Work in Extension Controller Context
    // Note: Native WKWebExtension APIs (runtime, storage, tabs) are only injected
    // into extension context web views (background, popup), not regular WKWebViews.
    // These tests verify polyfilled APIs work correctly in a WKWebView that has
    // the extension controller set.

    func testAllPolyfillNamespacesExist() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            return JSON.stringify({
                idle: typeof chrome.idle === 'object',
                notifications: typeof chrome.notifications === 'object',
                history: typeof chrome.history === 'object',
                management: typeof chrome.management === 'object',
                fontSettings: typeof chrome.fontSettings === 'object',
                sessions: typeof chrome.sessions === 'object',
                search: typeof chrome.search === 'object',
                offscreen: typeof chrome.offscreen === 'object',
            })
        """, in: wv) as? [String: Any]

        for (api, exists) in result ?? [:] {
            XCTAssertEqual(exists as? Bool, true, "chrome.\(api) should exist")
        }
    }

    // MARK: - Polyfill Bridge Works in Extension Controller Context

    func testIdleQueryStateWithController() async throws {
        let wv = try await makeExtensionWebView()
        let state = try await eval("return await chrome.idle.queryState(60)", in: wv) as? String
        XCTAssertTrue(["active", "idle", "locked"].contains(state ?? ""),
                       "Should return valid idle state, got: \(state ?? "nil")")
    }

    func testNotificationsCreateWithController() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            var id = await chrome.notifications.create('controller-test', {
                type: 'basic', title: 'Test', message: 'From controller context'
            });
            return JSON.stringify({ notificationId: id });
        """, in: wv) as? [String: Any]
        XCTAssertNotNil(result?["notificationId"] as? String)
    }

    func testHistorySearchWithController() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            var items = await chrome.history.search({ text: '' });
            return JSON.stringify({ isArray: Array.isArray(items) });
        """, in: wv) as? [String: Any]
        XCTAssertEqual(result?["isArray"] as? Bool, true)
    }

    func testFontSettingsWithController() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            var fonts = await chrome.fontSettings.getFontList();
            return JSON.stringify({
                hasItems: fonts.length > 0,
                hasFontId: fonts.length > 0 && 'fontId' in fonts[0]
            });
        """, in: wv) as? [String: Any]
        XCTAssertEqual(result?["hasItems"] as? Bool, true, "Should return system fonts")
        XCTAssertEqual(result?["hasFontId"] as? Bool, true)
    }

    func testManagementGetSelfWithController() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            var info = await chrome.management.getSelf();
            return JSON.stringify({ type: info.type });
        """, in: wv) as? [String: Any]
        // In this context chrome.runtime.id is empty so the handler returns a
        // minimal object. Verify it at least has the correct type field.
        XCTAssertEqual(result?["type"] as? String, "extension")
    }

    func testOffscreenHasDocumentWithController() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await eval("return await chrome.offscreen.hasDocument()", in: wv) as? Bool
        XCTAssertEqual(result, false)
    }



    func testSessionsGetRecentlyClosedWithController() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            var sessions = await chrome.sessions.getRecentlyClosed();
            return JSON.stringify({ count: sessions.length });
        """, in: wv) as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, 0)
    }

    func testEventEmittersWorkWithController() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await eval("""
            var fn = function() {};
            chrome.idle.onStateChanged.addListener(fn);
            var has = chrome.idle.onStateChanged.hasListener(fn);
            chrome.idle.onStateChanged.removeListener(fn);
            var removed = !chrome.idle.onStateChanged.hasListener(fn);
            return has && removed;
        """, in: wv) as? Bool
        XCTAssertEqual(result, true)
    }

    // MARK: - Polyfill Guards

    func testPolyfillCanBeRerunWithoutBreaking() async throws {
        // Running the polyfill a second time should not crash and APIs should still work
        let wv = try await makeExtensionWebView()
        let result = try await eval("""
            \(ExtensionAPIPolyfill.polyfillJS)
            return typeof chrome.idle.queryState === 'function';
        """, in: wv) as? Bool
        XCTAssertEqual(result, true, "Re-running polyfill should leave APIs functional")
    }

    // MARK: - Page -> service worker messaging with the polyfill in the worker

    /// WebKit answers runtime.sendMessage with an empty reply when it cannot unwrap
    /// the worker's `browser`/`chrome` global to the native namespace. The worker
    /// here is a module worker with nativeMessaging, running the real polyfill,
    /// i.e. shaped like 1Password's; this fails with an empty reply if the polyfill
    /// ever replaces those globals again (TASK-15, verified 2026-09-11 by grafting
    /// the old global-swapping fallback back in: reply nil, lastError nil).
    func testRuntimeSendMessageReachesWorkerRunningThePolyfill() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            const reply = await new Promise((resolve) => {
                let settled = false;
                chrome.runtime.sendMessage({ type: 'ping' }, (r) => {
                    settled = true;
                    resolve({ reply: r === undefined ? null : r,
                              lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
                });
                setTimeout(() => { if (!settled) resolve({ reply: 'timeout', lastError: null }); }, 8000);
            });
            return JSON.stringify(reply);
        """, in: wv) as? [String: Any]
        XCTAssertNil(result?["lastError"] as? String, "sendMessage reported lastError")
        let reply = result?["reply"] as? [String: Any]
        XCTAssertEqual(reply?["type"] as? String, "pong",
                       "the worker must answer; an empty reply means WebKit skipped the worker (globals not native?). Got: \(String(describing: result))")
        XCTAssertEqual(reply?["chromeIsNamespace"] as? String, "[object Namespace]",
                       "the worker's chrome global must still be WebKit's native namespace object")
        // WebKit re-materializes `runtime.connectNative` on every read, so a patch
        // never takes there (probed 2026-09-11: assignment and defineProperty do not
        // throw, the read-back equals neither the written function nor a previous
        // read). The keep-alive therefore reports 'none'; if this ever flips to
        // 'direct', WebKit changed and the keep-alive is live in workers again.
        XCTAssertEqual(reply?["connectNativeType"] as? String, "function", "nativeMessaging is granted, connectNative must exist")
        XCTAssertEqual(reply?["installMode"] as? String, "none")
        XCTAssertEqual(reply?["installDetail"] as? String, "patch-rejected",
                       "the keep-alive must have tried the direct patch and been rejected by WebKit, and then done nothing else")
    }

    /// NEGATIVE: a non-object payload addressed to the polyfill host must be
    /// rejected by the delegate, not routed to the real native-host path (where
    /// `nativeHostAccess` exempts that host name from the manifest permission and
    /// a host manifest named "detourPolyfill" would be searched for and spawned).
    func testNonObjectPolyfillNativeMessageIsRejected() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            const reply = await new Promise((resolve) => {
                chrome.runtime.sendMessage({ type: 'rawPolyfillNative', payload: 'not-an-envelope' },
                                           (r) => resolve(r === undefined ? null : r));
                setTimeout(() => resolve({ ok: false, error: 'timeout' }), 8000);
            });
            return JSON.stringify(reply);
        """, in: wv) as? [String: Any]
        XCTAssertEqual(result?["ok"] as? Bool, false, "a string payload must not be accepted, got: \(String(describing: result))")
        let error = result?["error"] as? String ?? ""
        XCTAssertTrue(error.contains("Invalid polyfill message format"),
                      "expected the delegate's format rejection, got: \(error)")
    }

    // MARK: - Origin Verification Against a Real Extension Context

    /// The page's origin is the context's random webkit-extension://<UUID>/,
    /// not the uniqueIdentifier; the profile resolves it to the extension id.
    func testExtensionPageOriginResolvesToExtensionID() async throws {
        let wv = try await makeExtensionWebView()
        let originJSON = try await evalJSON(
            "return JSON.stringify({ scheme: location.protocol.slice(0, -1), host: location.host })", in: wv
        )
        let origin = try XCTUnwrap(originJSON as? [String: String])
        let scheme = try XCTUnwrap(origin["scheme"])
        let host = try XCTUnwrap(origin["host"])
        XCTAssertEqual(scheme, "webkit-extension")
        XCTAssertNotEqual(host, Self.extensionID, "origin host must not be the uniqueIdentifier")
        XCTAssertEqual(state.testProfile.extensionID(forOriginScheme: scheme, host: host), Self.extensionID)
        XCTAssertNil(state.testProfile.extensionID(forOriginScheme: "https", host: host),
                     "same host under another scheme is not an extension page")
        XCTAssertNil(state.testProfile.extensionID(forOriginScheme: scheme, host: Self.extensionID),
                     "the uniqueIdentifier is not an origin")
    }

    /// NEGATIVE: from a real extension page, a body that names another
    /// extension is rejected because the origin-verified id disagrees.
    func testExtensionPageCannotClaimAnotherExtensionID() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            try {
                await webkit.messageHandlers.detourPolyfill.postMessage({
                    type: 'idle.queryState', extensionID: 'another-extension',
                    params: { detectionIntervalInSeconds: 60 }
                });
                return JSON.stringify({ error: null });
            } catch (e) {
                return JSON.stringify({ error: String(e && e.message ? e.message : e) });
            }
        """, in: wv) as? [String: Any]
        XCTAssertEqual(result?["error"] as? String, "Extension identity mismatch")
    }
}
