import XCTest
import WebKit
@testable import Detour

/// A Profile whose origin attribution is driven by the test. The bare WKWebView
/// these tests use cannot serve a `webkit-extension://` origin (that needs a
/// loaded WKWebExtensionContext), so this stands in for a loaded context: it
/// maps the page's real origin to an extension id the way a profile maps a
/// context's base URL. The production wiring itself is covered end-to-end in
/// `ExtensionPolyfillProfileWiringTests`.
private final class OriginMappingProfile: Profile {
    var originMap: ((_ scheme: String, _ host: String) -> String?)?

    override func extensionID(forOriginScheme scheme: String, host: String) -> String? {
        originMap?(scheme, host)
    }
}

/// Tests for the extension API polyfill bridge.
/// Verifies that the JS polyfills can communicate with the native
/// `ExtensionPolyfillHandler` and receive correct responses.
@MainActor
final class ExtensionPolyfillTests: XCTestCase {

    private var webView: WKWebView!
    private var handler: ExtensionPolyfillHandler!
    /// The handler holds its profile weakly, so the test owns it.
    private var profile: OriginMappingProfile!

    /// Extension ids registered in ExtensionManager during a test, torn down after.
    private var registeredExtensionIDs: [String] = []

    /// Every web view `makeWebView` handed out, so tearDown can unregister the
    /// script message handler each of them holds (the handler is shared).
    private var createdWebViews: [WKWebView] = []

    override func setUp() async throws {
        try await super.setUp()

        // The bare web view loads from https://test.example.com; attribute that
        // origin to the shim's extension id the way Profile attributes a
        // context's webkit-extension:// origin to its extension.
        profile = OriginMappingProfile(name: "polyfill-test")
        profile.originMap = { scheme, host in
            scheme == "https" && host == "test.example.com" ? "test-polyfill-extension" : nil
        }
        handler = ExtensionPolyfillHandler(profile: profile)

        // The injected shim sets chrome.runtime.id = 'test-polyfill-extension'.
        // Register a matching extension declaring the permission-gated APIs
        // (history, management, privacy) so the JS-path tests exercise the happy
        // path; dedicated positive/negative gate tests live further below.
        try registerExtension(id: "test-polyfill-extension", permissions: ["history", "management", "privacy"])

        // The manifest the shim reports also declares `webRequest`, the other
        // permission-gated polyfill module, so the default web view exercises
        // both stubs; the absent-without-permission cases build their own view.
        webView = try await makeWebView(manifestPermissions: ["history", "management", "privacy", "webRequest"])
    }

    /// Build a web view configured the way an extension context is: the shared
    /// polyfill message handler, a shim for the pieces of the extension
    /// environment a plain WKWebView lacks, then the polyfill itself.
    ///
    /// `manifestPermissions` is what the shim's `chrome.runtime.getManifest()`
    /// reports, so permission-gated polyfill modules (chrome.privacy,
    /// chrome.webRequest) can be exercised with and without their permission. `shimExtras` is appended to
    /// the shim — i.e. it runs *before* the polyfill — for tests that need a
    /// different starting environment (e.g. a native `chrome.action`).
    ///
    /// Every view is tracked in `createdWebViews` and unregistered in tearDown.
    private func makeWebView(manifestPermissions: [String], shimExtras: String = "") async throws -> WKWebView {
        let permissionsJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: manifestPermissions), as: UTF8.self
        )

        let config = WKWebViewConfiguration()
        let ucc = config.userContentController

        // Register the polyfill message handler
        ucc.addScriptMessageHandler(handler, contentWorld: .page, name: ExtensionPolyfillHandler.handlerName)

        // Inject a shim for the pieces of the extension environment that a plain
        // WKWebView lacks: chrome.runtime.id, chrome.runtime.getManifest, and a
        // fake connectNative that records every port it hands out (see
        // `__fakeNativePorts`) so the native port keep-alive can be exercised
        // without a real native host. The keep-alive ping interval is shortened
        // so tests need not wait 45 s.
        let shimScript = WKUserScript(
            source: """
            if (!globalThis.chrome) globalThis.chrome = {};
            if (!globalThis.chrome.runtime) globalThis.chrome.runtime = {};
            if (!globalThis.chrome.runtime.id) globalThis.chrome.runtime.id = 'test-polyfill-extension';
            globalThis.chrome.runtime.getManifest = () => ({ manifest_version: 3, permissions: \(permissionsJSON) });

            globalThis.__detourKeepAlivePingIntervalMs = 50;
            // Install the service-worker-only WebSocket guard and native port
            // keep-alive in this page context so they can be exercised without a
            // real service worker.
            globalThis.__detourForceWebSocketGuard = true;
            globalThis.__detourForceNativePortKeepAlive = true;
            globalThis.__fakeNativePorts = [];
            // Opt-in: make each fake port's `disconnect` non-writable so the
            // keep-alive cannot patch it in place and must fall back to its proxy,
            // the way WebKit's own port objects behave. Left configurable: a
            // non-configurable non-writable own property would make the Proxy's
            // get trap violate an ES invariant, which is a JS-engine rule rather
            // than anything the keep-alive controls.
            globalThis.__fakePortsFreezeDisconnect = false;
            globalThis.chrome.runtime.connectNative = function(application) {
                const disconnectListeners = [];
                const port = {
                    name: application,
                    application: application,
                    posted: [],
                    disconnectedLocally: false,
                    onDisconnect: { addListener(fn) { disconnectListeners.push(fn); } },
                    onMessage: { addListener() {} },
                    postMessage(m) { this.posted.push(m); },
                    disconnect() { this.disconnectedLocally = true; },
                    // Test helper: simulate the other side closing the port.
                    __simulateRemoteDisconnect() { disconnectListeners.slice().forEach(fn => fn()); }
                };
                if (globalThis.__fakePortsFreezeDisconnect) {
                    Object.defineProperty(port, 'disconnect', {
                        value: port.disconnect, writable: false, configurable: true, enumerable: true
                    });
                }
                globalThis.__fakeNativePorts.push(port);
                return port;
            };
            \(shimExtras)
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        // Inject before the polyfill: it reads the ping interval and wraps
        // chrome.runtime.connectNative while it installs.
        ucc.addUserScript(shimScript)

        // Inject polyfill JS at document start
        let polyfillScript = WKUserScript(
            source: ExtensionAPIPolyfill.polyfillJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        ucc.addUserScript(polyfillScript)

        let created = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        createdWebViews.append(created)
        try await loadHTMLStringAndWait(created, html: "<html><body>test</body></html>",
                                        baseURL: URL(string: "https://test.example.com")!)
        return created
    }

    override func tearDown() {
        for created in createdWebViews {
            created.configuration.userContentController.removeAllScriptMessageHandlers()
        }
        createdWebViews.removeAll()
        webView = nil
        handler = nil
        profile = nil
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
        }
        registeredExtensionIDs.removeAll()
        super.tearDown()
    }

    /// Register a synthetic extension in ExtensionManager whose manifest declares
    /// the given permissions, so permission-gated polyfill APIs (history,
    /// management) can be exercised. Tracked in `registeredExtensionIDs` and
    /// removed in tearDown. Mirrors the WebExtension construction used by
    /// WKExtensionIntegrationTests, but builds the manifest in-memory.
    @discardableResult
    private func registerExtension(id: String, permissions: [String]) throws -> WebExtension {
        let manifestDict: [String: Any] = [
            "manifest_version": 3,
            "name": "Polyfill Permission Test",
            "version": "1.0.0",
            "permissions": permissions
        ]
        let data = try JSONSerialization.data(withJSONObject: manifestDict)
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        let ext = WebExtension(id: id, manifest: manifest,
                               basePath: FileManager.default.temporaryDirectory)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    /// Evaluate JS that returns a JSON-serializable value, parsed back to Swift.
    /// Uses callAsyncJavaScript so Promises are automatically awaited.
    /// `on` defaults to the suite's own web view; pass one from `makeWebView`
    /// to evaluate in a differently-shimmed context.
    private func evalJSON(_ js: String, arguments: [String: Any] = [:], on target: WKWebView? = nil) async throws -> Any? {
        let result = try await (target ?? webView!).callAsyncJavaScript(
            js, arguments: arguments, contentWorld: .page
        )
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8) {
            return try JSONSerialization.jsonObject(with: data)
        }
        return result
    }

    /// Evaluate a JS expression that may return a Promise.
    /// Uses callAsyncJavaScript so Promises are automatically awaited.
    private func eval(_ js: String, on target: WKWebView? = nil) async throws -> Any? {
        try await (target ?? webView!).callAsyncJavaScript(
            js, arguments: [:], contentWorld: .page
        )
    }

    // MARK: - Polyfill Namespace Existence

    func testIdleNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.idle") as? String
        XCTAssertEqual(exists, "object")
    }

    func testNotificationsNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.notifications") as? String
        XCTAssertEqual(exists, "object")
    }

    func testHistoryNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.history") as? String
        XCTAssertEqual(exists, "object")
    }

    func testManagementNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.management") as? String
        XCTAssertEqual(exists, "object")
    }

    func testFontSettingsNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.fontSettings") as? String
        XCTAssertEqual(exists, "object")
    }

    func testSessionsNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.sessions") as? String
        XCTAssertEqual(exists, "object")
    }

    func testSearchNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.search") as? String
        XCTAssertEqual(exists, "object")
    }

    func testOffscreenNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.offscreen") as? String
        XCTAssertEqual(exists, "object")
    }


    // MARK: - chrome.idle

    func testIdleQueryState() async throws {
        let state = try await eval("return await chrome.idle.queryState(60)") as? String
        XCTAssertNotNil(state)
        XCTAssertTrue(["active", "idle", "locked"].contains(state!),
                       "idle.queryState should return active, idle, or locked but got: \(state!)")
    }

    func testIdleSetDetectionInterval() async throws {
        // Should not throw — setDetectionInterval is fire-and-forget
        _ = try await eval("chrome.idle.setDetectionInterval(30)")
    }

    func testIdleOnStateChangedIsEventEmitter() async throws {
        let hasAddListener = try await eval("return typeof chrome.idle.onStateChanged.addListener") as? String
        XCTAssertEqual(hasAddListener, "function")
        let hasRemoveListener = try await eval("return typeof chrome.idle.onStateChanged.removeListener") as? String
        XCTAssertEqual(hasRemoveListener, "function")
    }

    func testIdleStateConstants() async throws {
        let active = try await eval("return chrome.idle.IdleState.ACTIVE") as? String
        XCTAssertEqual(active, "active")
        let idle = try await eval("return chrome.idle.IdleState.IDLE") as? String
        XCTAssertEqual(idle, "idle")
        let locked = try await eval("return chrome.idle.IdleState.LOCKED") as? String
        XCTAssertEqual(locked, "locked")
    }

    // MARK: - chrome.notifications

    func testNotificationsCreate() async throws {
        let result = try await evalJSON("""
            var id = await chrome.notifications.create('test-notif', {
                type: 'basic', title: 'Test', message: 'Hello'
            });
            return JSON.stringify({ notificationId: id });
        """) as? [String: Any]
        let notifId = result?["notificationId"] as? String
        XCTAssertNotNil(notifId, "notifications.create should return a notification ID")
        XCTAssertFalse(notifId?.isEmpty ?? true)
    }

    func testNotificationsGetAll() async throws {
        _ = try await eval("""
            await chrome.notifications.create('getall-test', {
                type: 'basic', title: 'Test', message: 'Hello'
            })
        """)

        let result = try await evalJSON("""
            var all = await chrome.notifications.getAll();
            return JSON.stringify(all);
        """) as? [String: Any]
        XCTAssertNotNil(result)
    }

    func testNotificationsClear() async throws {
        _ = try await eval("""
            await chrome.notifications.create('clear-test', {
                type: 'basic', title: 'Test', message: 'Hello'
            })
        """)

        let result = try await evalJSON("""
            var cleared = await chrome.notifications.clear('clear-test');
            return JSON.stringify({ cleared: cleared });
        """) as? [String: Any]
        XCTAssertEqual(result?["cleared"] as? Bool, true)
    }

    func testNotificationsEventEmitters() async throws {
        let onClicked = try await eval("return typeof chrome.notifications.onClicked.addListener") as? String
        XCTAssertEqual(onClicked, "function")
        let onClosed = try await eval("return typeof chrome.notifications.onClosed.addListener") as? String
        XCTAssertEqual(onClosed, "function")
    }

    // MARK: - chrome.history

    func testHistorySearchReturnsArray() async throws {
        let result = try await evalJSON("""
            var items = await chrome.history.search({ text: '' });
            return JSON.stringify({ count: items.length, isArray: Array.isArray(items) });
        """) as? [String: Any]
        XCTAssertEqual(result?["isArray"] as? Bool, true)
    }

    func testHistoryGetVisitsStub() async throws {
        let result = try await evalJSON("""
            var visits = await chrome.history.getVisits({ url: 'https://example.com' });
            return JSON.stringify({ count: visits.length });
        """) as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, 0)
    }

    func testHistoryEventEmitters() async throws {
        let onVisited = try await eval("return typeof chrome.history.onVisited.addListener") as? String
        XCTAssertEqual(onVisited, "function")
    }

    // MARK: - chrome.fontSettings

    func testFontSettingsGetFontList() async throws {
        let result = try await evalJSON("""
            var fonts = await chrome.fontSettings.getFontList();
            return JSON.stringify({ count: fonts.length, hasItems: fonts.length > 0 });
        """) as? [String: Any]
        XCTAssertEqual(result?["hasItems"] as? Bool, true, "Should return system fonts")
    }

    func testFontSettingsGetFontListFormat() async throws {
        let result = try await evalJSON("""
            var fonts = await chrome.fontSettings.getFontList();
            var first = fonts[0];
            return JSON.stringify({ hasFontId: 'fontId' in first, hasDisplayName: 'displayName' in first });
        """) as? [String: Any]
        XCTAssertEqual(result?["hasFontId"] as? Bool, true)
        XCTAssertEqual(result?["hasDisplayName"] as? Bool, true)
    }

    // MARK: - chrome.management

    func testManagementGetSelf() async throws {
        let result = try await evalJSON("""
            var info = await chrome.management.getSelf();
            return JSON.stringify(info);
        """) as? [String: Any]
        XCTAssertNotNil(result?["id"])
        XCTAssertNotNil(result?["type"])
    }

    func testManagementGetAll() async throws {
        let result = try await evalJSON("""
            var all = await chrome.management.getAll();
            return JSON.stringify({ isArray: Array.isArray(all) });
        """) as? [String: Any]
        XCTAssertEqual(result?["isArray"] as? Bool, true)
    }

    /// setEnabled is a no-op on the native side, but it must resolve rather than
    /// reject: 1Password calls it to disable its sibling channel builds and an
    /// "Unknown polyfill message type" rejection surfaces as a setup failure.
    func testManagementSetEnabledResolves() async throws {
        let result = try await evalDictionary("""
        let rejection = null;
        let value = '(not settled)';
        try {
            value = await chrome.management.setEnabled('some-other-id', false);
        } catch (e) {
            rejection = e && e.message ? e.message : String(e);
        }
        return JSON.stringify({ rejection: rejection, settled: value !== '(not settled)' });
        """)
        XCTAssertNil(result["rejection"] as? String,
                     "management.setEnabled must not reject: \(result["rejection"] ?? "")")
        XCTAssertEqual(result["settled"] as? Bool, true)
    }

    // MARK: - chrome.privacy

    /// With the `privacy` permission declared, the no-op ChromeSetting objects
    /// 1Password dereferences (`chrome.privacy.services.*`) must be present and
    /// answer in both the promise and callback styles.
    func testPrivacyServicesInstalledWithPermission() async throws {
        let result = try await evalDictionary("""
        const names = ['passwordSavingEnabled', 'autofillEnabled', 'autofillCreditCardEnabled', 'autofillAddressEnabled'];
        const getters = names.map(n => typeof chrome.privacy.services[n].get);
        const got = await chrome.privacy.services.autofillEnabled.get({});
        const setResult = await chrome.privacy.services.passwordSavingEnabled.set({ value: true });
        const clearResult = await chrome.privacy.services.passwordSavingEnabled.clear({});
        const viaCallback = await new Promise(resolve => {
            chrome.privacy.services.passwordSavingEnabled.get({}, resolve);
        });
        const onChange = chrome.privacy.services.passwordSavingEnabled.onChange;
        return JSON.stringify({
            getters: getters,
            got: got,
            setSettled: setResult === undefined,
            clearSettled: clearResult === undefined,
            viaCallback: viaCallback,
            events: ['addListener', 'removeListener', 'hasListener'].map(k => typeof onChange[k]),
            hasNetwork: typeof chrome.privacy.network === 'object',
            hasWebsites: typeof chrome.privacy.websites === 'object',
            diag: __detourPolyfillDiag.apis.privacy
        });
        """)

        XCTAssertEqual(result["getters"] as? [String], ["function", "function", "function", "function"])
        let got = try XCTUnwrap(result["got"] as? [String: Any])
        XCTAssertEqual(got["value"] as? Bool, false)
        XCTAssertEqual(got["levelOfControl"] as? String, "not_controllable")
        XCTAssertEqual(result["setSettled"] as? Bool, true, "set() must resolve")
        XCTAssertEqual(result["clearSettled"] as? Bool, true, "clear() must resolve")
        let viaCallback = try XCTUnwrap(result["viaCallback"] as? [String: Any])
        XCTAssertEqual(viaCallback["value"] as? Bool, false)
        XCTAssertEqual(viaCallback["levelOfControl"] as? String, "not_controllable")
        XCTAssertEqual(result["events"] as? [String], ["function", "function", "function"])
        XCTAssertEqual(result["hasNetwork"] as? Bool, true)
        XCTAssertEqual(result["hasWebsites"] as? Bool, true)
        XCTAssertEqual(result["diag"] as? String, "polyfill")
    }

    /// Without the permission the namespace must stay absent, the way Chrome
    /// leaves it out, so a feature detection on chrome.privacy is honest.
    func testPrivacyAbsentWithoutPermission() async throws {
        let unprivileged = try await makeWebView(manifestPermissions: ["history", "management"])
        let result = try await evalDictionary("""
        return JSON.stringify({
            type: typeof chrome.privacy,
            diag: __detourPolyfillDiag.apis.privacy
        });
        """, on: unprivileged)
        XCTAssertEqual(result["type"] as? String, "undefined")
        XCTAssertEqual(result["diag"] as? String, "absent")
    }

    // MARK: - chrome.webRequest

    /// 1Password registers onAuthRequired with Chrome's three-argument
    /// addListener in the same block as its webNavigation listeners; a missing
    /// event there throws and skips the rest of the block.
    func testWebRequestOnAuthRequiredStub() async throws {
        let result = try await evalDictionary("""
        const fn = function() {};
        let threw = null;
        try {
            chrome.webRequest.onAuthRequired.addListener(fn, { urls: ['<all_urls>'] }, ['asyncBlocking']);
        } catch (e) {
            threw = e && e.message ? e.message : String(e);
        }
        const added = chrome.webRequest.onAuthRequired.hasListener(fn);
        chrome.webRequest.onAuthRequired.removeListener(fn);
        const removed = chrome.webRequest.onAuthRequired.hasListener(fn);
        return JSON.stringify({
            threw: threw,
            added: added,
            stillThere: removed,
            onBeforeRequest: typeof chrome.webRequest.onBeforeRequest.addListener,
            maxCalls: chrome.webRequest.MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES,
            diag: __detourPolyfillDiag.apis.webRequest
        });
        """)

        XCTAssertNil(result["threw"] as? String,
                     "the three-argument addListener must not throw: \(result["threw"] ?? "")")
        XCTAssertEqual(result["added"] as? Bool, true)
        XCTAssertEqual(result["stillThere"] as? Bool, false)
        XCTAssertEqual(result["onBeforeRequest"] as? String, "function")
        XCTAssertEqual(result["maxCalls"] as? Int, 20)
        XCTAssertEqual(result["diag"] as? String, "polyfill",
                       "a bare WKWebView has no native chrome.webRequest")
    }

    /// Chrome exposes chrome.webRequest only to extensions that declared it, so
    /// an extension feature-testing the namespace (to choose between blocking
    /// listeners and declarativeNetRequest) must keep seeing `undefined`.
    func testWebRequestAbsentWithoutPermission() async throws {
        let unprivileged = try await makeWebView(manifestPermissions: ["history", "management"])
        let result = try await evalDictionary("""
        return JSON.stringify({
            type: typeof chrome.webRequest,
            diag: __detourPolyfillDiag.apis.webRequest
        });
        """, on: unprivileged)
        XCTAssertEqual(result["type"] as? String, "undefined")
        XCTAssertEqual(result["diag"] as? String, "absent")
    }

    // MARK: - chrome.action.getUserSettings

    func testActionGetUserSettingsStub() async throws {
        // A bare WKWebView has no chrome.action at all; give it the shape
        // WebKit provides (an action object without getUserSettings).
        let withAction = try await makeWebView(
            manifestPermissions: ["history", "management", "privacy"],
            shimExtras: "globalThis.chrome.action = {};"
        )
        let result = try await evalDictionary("""
        const viaPromise = await chrome.action.getUserSettings();
        const viaCallback = await new Promise(resolve => chrome.action.getUserSettings(resolve));
        return JSON.stringify({
            viaPromise: viaPromise,
            viaCallback: viaCallback,
            diag: __detourPolyfillDiag.apis.actionGetUserSettings
        });
        """, on: withAction)

        XCTAssertEqual((result["viaPromise"] as? [String: Any])?["isOnToolbar"] as? Bool, true)
        XCTAssertEqual((result["viaCallback"] as? [String: Any])?["isOnToolbar"] as? Bool, true)
        XCTAssertEqual(result["diag"] as? String, "polyfill")
    }

    func testActionGetUserSettingsNotReplacedWhenNative() async throws {
        let nativeAction = try await makeWebView(
            manifestPermissions: ["history", "management", "privacy"],
            shimExtras: """
            globalThis.chrome.action = {
                getUserSettings: () => Promise.resolve({ isOnToolbar: false, marker: 'native' })
            };
            """
        )
        let result = try await evalDictionary("""
        const settings = await chrome.action.getUserSettings();
        return JSON.stringify({ settings: settings, diag: __detourPolyfillDiag.apis.actionGetUserSettings });
        """, on: nativeAction)

        let settings = try XCTUnwrap(result["settings"] as? [String: Any])
        XCTAssertEqual(settings["marker"] as? String, "native",
                       "a native getUserSettings must survive the polyfill")
        XCTAssertEqual(settings["isOnToolbar"] as? Bool, false)
        XCTAssertEqual(result["diag"] as? String, "native")
    }

    // MARK: - chrome.sessions

    func testSessionsMaxSessionResults() async throws {
        let result = try await eval("return chrome.sessions.MAX_SESSION_RESULTS") as? Int
        XCTAssertEqual(result, 25)
    }

    func testSessionsGetRecentlyClosedStub() async throws {
        let result = try await evalJSON("""
            var sessions = await chrome.sessions.getRecentlyClosed();
            return JSON.stringify({ count: sessions.length });
        """) as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, 0)
    }

    // MARK: - chrome.offscreen

    func testOffscreenReasonConstants() async throws {
        let result = try await eval("return chrome.offscreen.Reason.DOM_PARSER") as? String
        XCTAssertEqual(result, "DOM_PARSER")
    }

    func testOffscreenHasDocumentInitiallyFalse() async throws {
        let result = try await eval("return await chrome.offscreen.hasDocument()")
        XCTAssertEqual(result as? Bool, false)
    }


    // MARK: - Event Emitter Utility

    func testEventEmitterAddAndHasListener() async throws {
        let result = try await eval("""
            var fn = function() {};
            chrome.idle.onStateChanged.addListener(fn);
            return chrome.idle.onStateChanged.hasListener(fn);
        """) as? Bool
        XCTAssertEqual(result, true)
    }

    func testEventEmitterRemoveListener() async throws {
        let result = try await eval("""
            var fn = function() {};
            chrome.idle.onStateChanged.addListener(fn);
            chrome.idle.onStateChanged.removeListener(fn);
            return chrome.idle.onStateChanged.hasListener(fn);
        """) as? Bool
        XCTAssertEqual(result, false)
    }

    // MARK: - chrome.search

    func testSearchQueryFunctionExists() async throws {
        let exists = try await eval("return typeof chrome.search.query") as? String
        XCTAssertEqual(exists, "function")
    }

    // MARK: - Native Message Bridge (service worker fallback)

    /// Test the handleNativeMessage path directly — this is the path used by
    /// service workers where webkit.messageHandlers is unavailable.
    func testNativeMessageBridgeIdleQueryState() {
        let expectation = expectation(description: "idle.queryState via native bridge")

        handler.handleNativeMessage(
            ["type": "idle.queryState", "extensionID": "test", "params": ["detectionIntervalInSeconds": 60]],
            verifiedExtensionID: "test"
        ) { result, error in
            XCTAssertNil(error)
            XCTAssertNotNil(result as? String)
            XCTAssertTrue(["active", "idle", "locked"].contains(result as? String ?? ""))
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testNativeMessageBridgeFontSettings() {
        let expectation = expectation(description: "fontSettings via native bridge")

        handler.handleNativeMessage(
            ["type": "fontSettings.getFontList", "extensionID": "test", "params": [:] as [String: Any]],
            verifiedExtensionID: "test"
        ) { result, error in
            XCTAssertNil(error)
            let fonts = result as? [[String: String]]
            XCTAssertNotNil(fonts)
            XCTAssertGreaterThan(fonts?.count ?? 0, 0, "Should return system fonts")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    /// history.search is gated behind the "history" manifest permission. With
    /// an unregistered/unknown extension id (no manifest, no permission) the
    /// bridge must refuse and surface the "history permission not declared" error.
    func testHistorySearchDeniedWithoutPermission() {
        let expectation = expectation(description: "history.search denied without permission")

        handler.handleNativeMessage(
            ["type": "history.search", "extensionID": "test",
             "params": ["query": ["text": "", "maxResults": 10]]],
            verifiedExtensionID: "test"
        ) { result, error in
            XCTAssertNil(result)
            XCTAssertEqual((error as NSError?)?.localizedDescription, "history permission not declared")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    /// management.setEnabled is honoured as a no-op success on the native side.
    /// The sender must declare `management` (see the negative test below), so
    /// this registers one rather than using the bare "test" id.
    func testNativeMessageBridgeManagementSetEnabled() throws {
        try registerExtension(id: "mgmt-setenabled-ext", permissions: ["management"])
        let expectation = expectation(description: "management.setEnabled via native bridge")

        handler.handleNativeMessage(
            ["type": "management.setEnabled", "extensionID": "mgmt-setenabled-ext",
             "params": ["id": "some-other-extension", "enabled": false]],
            verifiedExtensionID: "mgmt-setenabled-ext"
        ) { result, error in
            XCTAssertNil(error)
            XCTAssertEqual(result as? Bool, true)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testNativeMessageBridgeOffscreenHasDocument() {
        let expectation = expectation(description: "offscreen.hasDocument via native bridge")

        handler.handleNativeMessage(
            ["type": "offscreen.hasDocument", "extensionID": "test", "params": [:] as [String: Any]],
            verifiedExtensionID: "test"
        ) { result, error in
            XCTAssertNil(error)
            XCTAssertEqual(result as? Bool, false)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testNativeMessageBridgeInvalidType() {
        let expectation = expectation(description: "unknown type via native bridge")

        handler.handleNativeMessage(
            ["type": "nonexistent.api", "extensionID": "test", "params": [:] as [String: Any]],
            verifiedExtensionID: "test"
        ) { result, error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testNativeMessageBridgeMissingType() {
        let expectation = expectation(description: "missing type via native bridge")

        handler.handleNativeMessage(
            ["extensionID": "test"],
            verifiedExtensionID: "test"
        ) { result, error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Permission Gating (history / management)

    /// history.search POSITIVE: an extension that declared the "history"
    /// permission is allowed through and gets a results array.
    func testHistorySearchAllowedWithPermission() throws {
        try registerExtension(id: "histperm-ext", permissions: ["history"])
        let expectation = expectation(description: "history.search allowed with permission")

        handler.handleNativeMessage(
            ["type": "history.search", "extensionID": "histperm-ext",
             "params": ["query": ["text": "", "maxResults": 10]]],
            verifiedExtensionID: "histperm-ext"
        ) { result, error in
            XCTAssertNil(error)
            let dict = result as? [String: Any]
            XCTAssertNotNil(dict?["results"] as? [[String: Any]],
                            "history.search should return a results array")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    /// history.search NEGATIVE: a registered extension that did NOT declare the
    /// "history" permission is refused, even though it exists in ExtensionManager.
    func testHistorySearchDeniedWhenPermissionMissing() throws {
        try registerExtension(id: "nohistory-ext", permissions: ["storage"])
        let expectation = expectation(description: "history.search denied when permission missing")

        handler.handleNativeMessage(
            ["type": "history.search", "extensionID": "nohistory-ext",
             "params": ["query": ["text": "", "maxResults": 10]]],
            verifiedExtensionID: "nohistory-ext"
        ) { result, error in
            XCTAssertNil(result)
            XCTAssertEqual((error as NSError?)?.localizedDescription, "history permission not declared")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    /// management.getAll POSITIVE: an extension that declared the "management"
    /// permission gets the full extension list back.
    func testManagementGetAllAllowedWithPermission() throws {
        try registerExtension(id: "mgmtperm-ext", permissions: ["management"])
        let expectation = expectation(description: "management.getAll allowed with permission")

        handler.handleNativeMessage(
            ["type": "management.getAll", "extensionID": "mgmtperm-ext",
             "params": [:] as [String: Any]],
            verifiedExtensionID: "mgmtperm-ext"
        ) { result, error in
            XCTAssertNil(error)
            XCTAssertNotNil(result as? [[String: Any]],
                            "management.getAll should return an array of extension info")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    /// management.getAll NEGATIVE: a registered extension without the
    /// "management" permission is refused.
    func testManagementGetAllDeniedWithoutPermission() throws {
        try registerExtension(id: "nomgmt-ext", permissions: ["storage"])
        let expectation = expectation(description: "management.getAll denied without permission")

        handler.handleNativeMessage(
            ["type": "management.getAll", "extensionID": "nomgmt-ext",
             "params": [:] as [String: Any]],
            verifiedExtensionID: "nomgmt-ext"
        ) { result, error in
            XCTAssertNil(result)
            XCTAssertEqual((error as NSError?)?.localizedDescription, "management permission not declared")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    /// setEnabled is gated the same way getAll is: in Chrome only getSelf and
    /// uninstallSelf are permission-free, so an extension that never declared
    /// `management` must not be able to ask Detour to disable anything — even
    /// though the handler's answer is a no-op success when it may.
    func testManagementSetEnabledDeniedWithoutPermission() throws {
        try registerExtension(id: "nomgmt-setenabled-ext", permissions: ["storage"])
        let expectation = expectation(description: "management.setEnabled denied without permission")

        handler.handleNativeMessage(
            ["type": "management.setEnabled", "extensionID": "nomgmt-setenabled-ext",
             "params": ["id": "some-other-extension", "enabled": false]],
            verifiedExtensionID: "nomgmt-setenabled-ext"
        ) { result, error in
            XCTAssertNil(result)
            XCTAssertEqual((error as NSError?)?.localizedDescription, "management permission not declared")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Extension Identity Verification

    /// NEGATIVE: when the verified id (derived from the sending context/frame)
    /// disagrees with the self-reported body extensionID, the request is an
    /// impersonation attempt and must be rejected.
    func testIdentitySpoofingRejected() {
        let expectation = expectation(description: "identity spoofing rejected")

        handler.handleNativeMessage(
            ["type": "management.getSelf", "extensionID": "victim-id"],
            verifiedExtensionID: "attacker-id"
        ) { result, error in
            XCTAssertNil(result)
            XCTAssertEqual((error as NSError?)?.localizedDescription, "Extension identity mismatch")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    /// Happy path: when the verified id matches the claimed body id there is no
    /// identity mismatch and the request proceeds. Uses idle.queryState since it
    /// needs no manifest permission.
    func testIdentityVerifiedHappyPath() {
        let expectation = expectation(description: "verified identity proceeds")

        handler.handleNativeMessage(
            ["type": "idle.queryState", "extensionID": "same-id",
             "params": ["detectionIntervalInSeconds": 60]],
            verifiedExtensionID: "same-id"
        ) { result, error in
            XCTAssertNil(error)
            XCTAssertTrue(["active", "idle", "locked"].contains(result as? String ?? ""),
                          "idle.queryState should succeed for a verified identity")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Web View Origin Verification

    /// Send a raw envelope through webkit.messageHandlers from the test page,
    /// bypassing the polyfill's own `extensionID` stamping so the body can
    /// claim any id. Returns the bridge's reply or the error string.
    private func sendRawBridgeMessage(type: String, claimedID: String) async throws -> (result: Any?, error: String?) {
        try await postRawPolyfillEnvelope(from: webView, type: type, claimedID: claimedID)
    }

    /// POSITIVE: a message from a page whose origin resolves to an extension is
    /// attributed to that extension, and a matching body id proceeds.
    func testWebViewMessageAttributedByOrigin() async throws {
        let reply = try await sendRawBridgeMessage(type: "idle.queryState", claimedID: "test-polyfill-extension")
        XCTAssertNil(reply.error)
        XCTAssertTrue(["active", "idle", "locked"].contains(reply.result as? String ?? ""),
                      "origin-verified request should succeed, got \(String(describing: reply.result))")
    }

    /// POSITIVE: the polyfill stamps an empty id when `chrome.runtime.id` is
    /// unavailable in the sending frame; that is no claim at all, so the
    /// origin-verified identity is used and the request proceeds.
    func testWebViewMessageWithEmptyClaimedIDUsesVerifiedOrigin() async throws {
        let reply = try await sendRawBridgeMessage(type: "idle.queryState", claimedID: "")
        XCTAssertNil(reply.error)
        XCTAssertTrue(["active", "idle", "locked"].contains(reply.result as? String ?? ""))
    }

    /// NEGATIVE: the body claims another extension's id from a verified origin;
    /// the verified id wins and the request is rejected as impersonation.
    func testWebViewMessageClaimingOtherExtensionRejected() async throws {
        let reply = try await sendRawBridgeMessage(type: "idle.queryState", claimedID: "some-other-extension")
        XCTAssertNil(reply.result)
        XCTAssertEqual(reply.error, "Extension identity mismatch")
    }

    /// NEGATIVE: the origin resolves to no loaded extension (e.g. its context
    /// was unloaded, so its old UUID origin is stale); the body id is not a
    /// fallback on the web-view path, even when it names a real extension.
    func testWebViewMessageFromUnknownOriginRejected() async throws {
        profile.originMap = { _, _ in nil }
        let reply = try await sendRawBridgeMessage(type: "idle.queryState", claimedID: "test-polyfill-extension")
        XCTAssertNil(reply.result)
        XCTAssertEqual(reply.error, "Unrecognized extension origin")
    }

    /// NEGATIVE: a handler whose profile has been released trusts nothing —
    /// there is nothing left that could attribute the origin.
    func testWebViewMessageWithReleasedProfileRejected() async throws {
        // The handler's reference is weak and the web view's message handler
        // registration keeps only the handler alive, so dropping the test's
        // reference releases the profile.
        profile = nil
        XCTAssertNil(handler.profile, "the profile should be gone once the test releases it")
        let reply = try await sendRawBridgeMessage(type: "idle.queryState", claimedID: "test-polyfill-extension")
        XCTAssertNil(reply.result)
        XCTAssertEqual(reply.error, "Unrecognized extension origin")
    }

    /// The profile's origin lookup is handed the frame's real scheme and host,
    /// so a profile keyed on both (as the real one is) sees exactly the page's
    /// origin.
    func testWebViewOriginLookupReceivesFrameOrigin() async throws {
        var seen: (scheme: String, host: String)?
        profile.originMap = { scheme, host in
            seen = (scheme, host)
            return "test-polyfill-extension"
        }
        _ = try await sendRawBridgeMessage(type: "idle.queryState", claimedID: "test-polyfill-extension")
        XCTAssertEqual(seen?.scheme, "https")
        XCTAssertEqual(seen?.host, "test.example.com")
    }

    // MARK: - Service Worker Fallback Detection

    func testPolyfillUsesWebkitHandlerWhenAvailable() async throws {
        // In a WKWebView with the handler registered, the polyfill should work
        // via webkit.messageHandlers (already tested above). Verify the bridge
        // actually resolves — if it fell back to sendNativeMessage, idle.queryState
        // would fail since browser.runtime.sendNativeMessage isn't available here.
        let state = try await eval("return await chrome.idle.queryState(60)") as? String
        XCTAssertNotNil(state, "Polyfill should work via webkit.messageHandlers in WKWebView")
    }

    func testPolyfillFallsBackToNativeMessageWhenNoHandler() async throws {
        // Create a web view WITHOUT the webkit handler but WITH browser.runtime.sendNativeMessage stubbed.
        // This simulates the service worker environment.
        let config = WKWebViewConfiguration()
        let polyfillScript = WKUserScript(
            source: """
            if (!globalThis.chrome) globalThis.chrome = {};
            if (!globalThis.chrome.runtime) globalThis.chrome.runtime = {};
            globalThis.chrome.runtime.id = 'test';
            if (!globalThis.browser) globalThis.browser = {};
            if (!globalThis.browser.runtime) globalThis.browser.runtime = {};
            globalThis.browser.runtime.id = 'test';
            // Stub sendNativeMessage to capture the call
            globalThis.__nativeMessageCalls = [];
            globalThis.browser.runtime.sendNativeMessage = function(appId, msg) {
                globalThis.__nativeMessageCalls.push({ appId: appId, type: msg.type });
                return Promise.resolve('active');
            };
            """ + "\n" + ExtensionAPIPolyfill.polyfillJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(polyfillScript)

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        try await loadHTMLStringAndWait(wv, html: "<html><body>test</body></html>",
                                        baseURL: URL(string: "https://test.example.com")!)

        // Call a polyfill API — should fall back to sendNativeMessage since no handler is registered
        _ = try await wv.callAsyncJavaScript(
            "return await chrome.idle.queryState(60)",
            arguments: [:], contentWorld: .page
        )

        // Verify sendNativeMessage was called with the right appId
        let calls = try await wv.callAsyncJavaScript(
            "return JSON.stringify(globalThis.__nativeMessageCalls)",
            arguments: [:], contentWorld: .page
        ) as? String
        XCTAssertTrue(calls?.contains("detourPolyfill") ?? false,
                       "Should have called sendNativeMessage('detourPolyfill', ...), got: \(calls ?? "nil")")
        XCTAssertTrue(calls?.contains("idle.queryState") ?? false,
                       "Should have passed the message type, got: \(calls ?? "nil")")
    }

    // MARK: - Console bridge

    /// Run `statementJS` with the polyfill bridge stubbed out and return the level
    /// and message of the first 'log' request it produced. Covers both ways the
    /// console bridge is driven: calling `console.*` directly, and dispatching an
    /// `error` / `unhandledrejection` event that the bridge reports.
    private func bridgedLog(running statementJS: String) async throws -> (level: String, message: String) {
        let entry = try await evalDictionary("""
        const calls = [];
        const orig = globalThis.__detourPolyfillRequest;
        globalThis.__detourPolyfillRequest = function(type, params) { calls.push({ type: type, params: params }); return Promise.resolve(); };
        try { \(statementJS) } finally { globalThis.__detourPolyfillRequest = orig; }
        const entry = calls.find(c => c.type === 'log');
        return entry ? JSON.stringify({ level: entry.params.level, message: entry.params.message }) : null;
        """)
        return (try XCTUnwrap(entry["level"] as? String, "the bridged log carried no level"),
                try XCTUnwrap(entry["message"] as? String, "the bridged log carried no message"))
    }

    func testConsoleBridgeFormatsErrorAsNameMessageAndStack() async throws {
        let formatted = try await bridgedLog(running: "console.error(new TypeError('boom'));").message
        XCTAssertTrue(formatted.hasPrefix("TypeError: boom"),
                      "Expected 'TypeError: boom' prefix, got: \(formatted)")
        XCTAssertTrue(formatted.contains("\n"),
                      "Expected a stack appended after the header, got: \(formatted)")
    }

    func testConsoleBridgeFormatsErrorWithoutStack() async throws {
        let formatted = try await bridgedLog(
            running: "console.error(Object.assign(Object.create(Error.prototype), { name: 'Error', message: 'nostack' }));"
        ).message
        XCTAssertEqual(formatted, "Error: nostack")
    }

    func testConsoleBridgeDoesNotDuplicateV8StyleHeader() async throws {
        let formatted = try await bridgedLog(running: """
        console.error(Object.assign(Object.create(Error.prototype), {
            name: 'RangeError',
            message: 'bad',
            stack: 'RangeError: bad\\n    at foo (a.js:1:1)'
        }));
        """).message
        XCTAssertEqual(formatted, "RangeError: bad\n    at foo (a.js:1:1)")
    }

    func testConsoleBridgeKeepsHeaderWhenStackMerelyStartsWithName() async throws {
        // JSC stacks carry no "Name: message" header line, so it must be kept
        // even when the first frame happens to start with the error's name.
        let formatted = try await bridgedLog(running: """
        console.error(Object.assign(Object.create(Error.prototype), {
            name: 'Error',
            message: '',
            stack: 'ErrorReporter@app.js:3:9\\nglobal code@app.js:9:1'
        }));
        """).message
        XCTAssertEqual(formatted, "Error\nErrorReporter@app.js:3:9\nglobal code@app.js:9:1")
    }

    func testConsoleBridgeIncludesOwnPropertiesOfErrors() async throws {
        let formatted = try await bridgedLog(
            running: "console.error(Object.assign(new Error('boom'), { code: 'E_AUTH' }));"
        ).message
        XCTAssertTrue(formatted.hasPrefix("Error: boom {\"code\":\"E_AUTH\"}"),
                      "Expected own props after the header, got: \(formatted)")
    }

    func testConsoleBridgeSerializesNestedErrors() async throws {
        let formatted = try await bridgedLog(
            running: "console.error({ err: Object.assign(new Error('inner'), { code: 'E1' }), n: 1 });"
        ).message
        let data = try XCTUnwrap(formatted.data(using: .utf8))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   "Nested-error output should be a JSON object, got: \(formatted)")
        let err = try XCTUnwrap(parsed["err"] as? [String: Any])
        XCTAssertEqual(err["name"] as? String, "Error")
        XCTAssertEqual(err["message"] as? String, "inner")
        XCTAssertEqual(err["code"] as? String, "E1")
        XCTAssertEqual(parsed["n"] as? Int, 1)
    }

    func testConsoleBridgeFormatsDOMException() async throws {
        let formatted = try await bridgedLog(
            running: "console.error(new DOMException('denied', 'NotAllowedError'));"
        ).message
        XCTAssertTrue(formatted.hasPrefix("NotAllowedError: denied"),
                      "Expected 'NotAllowedError: denied' prefix, got: \(formatted)")
    }

    func testConsoleBridgeFormatsPlainValues() async throws {
        let bridged = try await bridgedLog(
            running: "console.log('a', 1, null, undefined, {k: 'v'});"
        )
        XCTAssertEqual(bridged.level, "info")
        XCTAssertEqual(bridged.message, "a 1 null undefined {\"k\":\"v\"}")
    }

    func testConsoleBridgeSurvivesThrowingErrorAccessors() async throws {
        let formatted = try await bridgedLog(running: """
        console.error((() => {
            const e = new Error('x');
            Object.defineProperty(e, 'message', { get() { throw new Error('nope'); } });
            return { ctx: 'save', err: e, id: 'abc' };
        })());
        """).message
        XCTAssertTrue(formatted.contains("\"ctx\":\"save\""),
                      "Sibling keys should survive a throwing accessor, got: \(formatted)")
        XCTAssertTrue(formatted.contains("\"id\":\"abc\""),
                      "Sibling keys should survive a throwing accessor, got: \(formatted)")
    }

    func testConsoleBridgeIsolatesUnserializableArguments() async throws {
        // Also proves console.* never throws: otherwise `eval` itself would reject.
        let formatted = try await bridgedLog(
            running: "console.error('before', new Proxy({}, { get() { throw new TypeError('get'); }, ownKeys() { throw new TypeError('keys'); }, getPrototypeOf() { throw new TypeError('gpo'); } }), 'after');"
        ).message
        XCTAssertEqual(formatted, "before [unserializable] after")
    }

    func testConsoleBridgeTruncatesLongMessages() async throws {
        let formatted = try await bridgedLog(running: "console.error('x'.repeat(20000));").message
        XCTAssertTrue(formatted.hasSuffix("…[truncated]"),
                      "Expected a truncation marker, got suffix: \(formatted.suffix(20))")
        XCTAssertEqual(formatted.count, 8192 + "…[truncated]".count)
    }

    func testConsoleErrorWithErrorObjectDoesNotThrow() async throws {
        let result = try await eval("""
        console.error('ctx', new Error('e2'));
        return 'ok';
        """) as? String
        XCTAssertEqual(result, "ok")
    }

    func testConsoleBridgeReportsUncaughtExceptions() async throws {
        let entry = try await bridgedLog(running: """
        globalThis.dispatchEvent(new ErrorEvent('error', { message: 'boom', error: new RangeError('boom'), filename: 'sw.js', lineno: 12, colno: 7 }));
        """)
        XCTAssertEqual(entry.level, "error")
        XCTAssertTrue(entry.message.hasPrefix("[uncaught exception] (sw.js:12:7) RangeError: boom"),
                      "Unexpected uncaught-exception line: \(entry.message)")
    }

    func testConsoleBridgeReportsUncaughtExceptionsWithoutErrorObject() async throws {
        let entry = try await bridgedLog(running: """
        globalThis.dispatchEvent(new ErrorEvent('error', { message: 'Script error.' }));
        """)
        XCTAssertEqual(entry.message, "[uncaught exception] Script error.")
    }

    func testConsoleBridgeReportsUnhandledRejections() async throws {
        let entry = try await bridgedLog(running: """
        globalThis.dispatchEvent(new PromiseRejectionEvent('unhandledrejection', { promise: Promise.resolve(), reason: new TypeError('rejected') }));
        """)
        XCTAssertEqual(entry.level, "error")
        XCTAssertTrue(entry.message.hasPrefix("[unhandled rejection] TypeError: rejected"),
                      "Unexpected unhandled-rejection line: \(entry.message)")
    }

    /// The bridge swallows its own rejection: an unhandledrejection reporter that
    /// logs through the same path must not turn one failed send into a loop.
    func testConsoleBridgeDoesNotFeedItselfWhenBridgeRejects() async throws {
        let result = try await evalDictionary("""
        const calls = [];
        const orig = globalThis.__detourPolyfillRequest;
        globalThis.__detourPolyfillRequest = function(type, params) {
            calls.push({ type: type, params: params });
            return Promise.reject(new Error('bridge down'));
        };
        try {
            console.error('x');
            // Let the rejection settle and any unhandledrejection event fire.
            await new Promise(r => setTimeout(r, 100));
            await new Promise(r => setTimeout(r, 100));
        } finally {
            globalThis.__detourPolyfillRequest = orig;
        }
        return JSON.stringify({
            logCalls: calls.filter(c => c.type === 'log').length,
            messages: calls.filter(c => c.type === 'log').map(c => c.params.message)
        });
        """)

        XCTAssertEqual(result["logCalls"] as? Int, 1,
                       "a rejected bridge send must not be reported back through the bridge, got: \(result["messages"] ?? "nil")")
    }

    // MARK: - Native port keep-alive

    /// Run JS that returns a JSON string and parse it into a dictionary.
    private func evalDictionary(_ js: String, on target: WKWebView? = nil) async throws -> [String: Any] {
        // Hoisted out of XCTUnwrap: its argument is an autoclosure and cannot await.
        let value = try await evalJSON(js, on: target)
        return try XCTUnwrap(value as? [String: Any],
                             "expected a JSON object from the page, got: \(value ?? "nil")")
    }

    /// `__detourNativePortKeepAlive` plus the applications every fake native port
    /// was opened with, in order.
    private func keepAliveStatus() async throws -> [String: Any] {
        try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        return JSON.stringify({
            livePorts: status.livePorts,
            active: status.active,
            pingIntervalMs: status.pingIntervalMs,
            installMode: status.installMode,
            applications: globalThis.__fakeNativePorts.map(p => p.application)
        });
        """)
    }

    func testKeepAliveStartsWithFirstRealNativePort() async throws {
        _ = try await eval("chrome.runtime.connectNative('com.example.host');")

        let status = try await keepAliveStatus()
        XCTAssertEqual(status["livePorts"] as? Int, 1)
        XCTAssertEqual(status["active"] as? Bool, true)
        XCTAssertEqual(status["pingIntervalMs"] as? Int, 50, "the test override should be honoured")
        XCTAssertEqual(status["installMode"] as? String, "direct", "connectNative was patched in place")
        XCTAssertEqual(status["applications"] as? [String], ["com.example.host", "detourPolyfill"],
                       "opening a real port should also open the keep-alive port")
    }

    func testKeepAliveIsNotStartedByItsOwnPort() async throws {
        _ = try await eval("chrome.runtime.connectNative('detourPolyfill');")

        let status = try await keepAliveStatus()
        XCTAssertEqual(status["livePorts"] as? Int, 0)
        XCTAssertEqual(status["active"] as? Bool, false)
        XCTAssertEqual(status["applications"] as? [String], ["detourPolyfill"],
                       "the keep-alive host must not be tracked as a real port")
    }

    func testKeepAlivePingsOnTheKeepAlivePort() async throws {
        let result = try await evalDictionary("""
        chrome.runtime.connectNative('com.example.host');
        await new Promise(r => setTimeout(r, 200));
        const keepAlive = globalThis.__fakeNativePorts.find(p => p.application === 'detourPolyfill');
        return JSON.stringify({ posted: keepAlive ? keepAlive.posted : null });
        """)

        let posted = try XCTUnwrap(result["posted"] as? [[String: String]],
                                   "the keep-alive port should have received pings")
        XCTAssertGreaterThanOrEqual(posted.count, 2,
                                    "expected repeated pings at a 50 ms interval, got \(posted.count)")
        for message in posted {
            XCTAssertEqual(message, ["type": "keepalive"])
        }
    }

    func testKeepAliveStopsWhenLastRealPortDisconnectsLocally() async throws {
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        const first = chrome.runtime.connectNative('com.example.first');
        const second = chrome.runtime.connectNative('com.example.second');

        first.disconnect();
        const afterFirst = { livePorts: status.livePorts, active: status.active };

        second.disconnect();
        const afterSecond = { livePorts: status.livePorts, active: status.active };

        const keepAlive = globalThis.__fakeNativePorts.find(p => p.application === 'detourPolyfill');
        const postedAtStop = keepAlive.posted.length;
        await new Promise(r => setTimeout(r, 200));

        return JSON.stringify({
            afterFirst: afterFirst,
            afterSecond: afterSecond,
            keepAliveDisconnectedLocally: keepAlive.disconnectedLocally,
            postedAtStop: postedAtStop,
            postedAfterWait: keepAlive.posted.length
        });
        """)

        let afterFirst = try XCTUnwrap(result["afterFirst"] as? [String: Any])
        XCTAssertEqual(afterFirst["livePorts"] as? Int, 1)
        XCTAssertEqual(afterFirst["active"] as? Bool, true,
                       "the keep-alive should survive while another real port is open")

        let afterSecond = try XCTUnwrap(result["afterSecond"] as? [String: Any])
        XCTAssertEqual(afterSecond["livePorts"] as? Int, 0)
        XCTAssertEqual(afterSecond["active"] as? Bool, false)
        XCTAssertEqual(result["keepAliveDisconnectedLocally"] as? Bool, true,
                       "the keep-alive port itself should be disconnected")
        XCTAssertEqual(result["postedAfterWait"] as? Int, result["postedAtStop"] as? Int,
                       "pings must stop once the last real port is released")
    }

    func testKeepAliveStopsWhenRealPortIsClosedRemotely() async throws {
        _ = try await eval("""
        const port = chrome.runtime.connectNative('com.example.host');
        port.__simulateRemoteDisconnect();
        """)

        let status = try await keepAliveStatus()
        XCTAssertEqual(status["livePorts"] as? Int, 0)
        XCTAssertEqual(status["active"] as? Bool, false)
    }

    func testKeepAliveReleaseIsIdempotent() async throws {
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        const port = chrome.runtime.connectNative('com.example.host');
        port.disconnect();
        port.disconnect();
        port.__simulateRemoteDisconnect();
        const afterRelease = { livePorts: status.livePorts, active: status.active };

        chrome.runtime.connectNative('com.example.second');
        return JSON.stringify({
            afterRelease: afterRelease,
            afterReopen: { livePorts: status.livePorts, active: status.active },
            keepAlivePortCount: globalThis.__fakeNativePorts.filter(p => p.application === 'detourPolyfill').length
        });
        """)

        let afterRelease = try XCTUnwrap(result["afterRelease"] as? [String: Any])
        XCTAssertEqual(afterRelease["livePorts"] as? Int, 0,
                       "repeated releases of one port must not drive the count negative")
        XCTAssertEqual(afterRelease["active"] as? Bool, false)

        let afterReopen = try XCTUnwrap(result["afterReopen"] as? [String: Any])
        XCTAssertEqual(afterReopen["livePorts"] as? Int, 1)
        XCTAssertEqual(afterReopen["active"] as? Bool, true,
                       "a later real port should start the keep-alive again")
        XCTAssertEqual(result["keepAlivePortCount"] as? Int, 2,
                       "restarting the keep-alive should open a fresh keep-alive port")
    }

    func testKeepAliveReconnectsIfDetourDropsThePort() async throws {
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        chrome.runtime.connectNative('com.example.host');
        const keepAlive = globalThis.__fakeNativePorts.find(p => p.application === 'detourPolyfill');
        keepAlive.__simulateRemoteDisconnect();
        await new Promise(r => setTimeout(r, 1300));
        return JSON.stringify({
            livePorts: status.livePorts,
            active: status.active,
            keepAlivePortCount: globalThis.__fakeNativePorts.filter(p => p.application === 'detourPolyfill').length
        });
        """)

        XCTAssertEqual(result["keepAlivePortCount"] as? Int, 2,
                       "a dropped keep-alive port should be reopened while a real port is live")
        XCTAssertEqual(result["active"] as? Bool, true)
        XCTAssertEqual(result["livePorts"] as? Int, 1)
    }

    /// When the port object refuses the `disconnect` patch (as WebKit's own does),
    /// the extension is handed a proxy that still releases the keep-alive on a
    /// local disconnect and forwards everything else to the real port.
    func testKeepAliveTracksLocalDisconnectOnUnpatchablePort() async throws {
        let result = try await evalDictionary("""
        globalThis.__fakePortsFreezeDisconnect = true;
        const status = globalThis.__detourNativePortKeepAlive;
        const returned = chrome.runtime.connectNative('com.example.host');
        const real = globalThis.__fakeNativePorts[0];

        const isProxy = returned !== real;
        const nameReadsThrough = returned.name;
        const afterConnect = { livePorts: status.livePorts, active: status.active };

        returned.disconnect();

        return JSON.stringify({
            isProxy: isProxy,
            nameReadsThrough: nameReadsThrough,
            afterConnect: afterConnect,
            livePorts: status.livePorts,
            active: status.active,
            disconnectedLocally: real.disconnectedLocally
        });
        """)

        XCTAssertEqual(result["isProxy"] as? Bool, true,
                       "an unpatchable port should be handed back wrapped in a proxy")
        XCTAssertEqual(result["nameReadsThrough"] as? String, "com.example.host",
                       "reads should forward to the real port")

        let afterConnect = try XCTUnwrap(result["afterConnect"] as? [String: Any])
        XCTAssertEqual(afterConnect["livePorts"] as? Int, 1)
        XCTAssertEqual(afterConnect["active"] as? Bool, true)

        XCTAssertEqual(result["livePorts"] as? Int, 0,
                       "disconnect() through the proxy must release the live-port count")
        XCTAssertEqual(result["active"] as? Bool, false)
        XCTAssertEqual(result["disconnectedLocally"] as? Bool, true,
                       "the real port's disconnect should still run with the right `this`")
    }

    /// The 1 s reconnect scheduled when Detour drops the keep-alive port must not
    /// resurrect it if the last real port closed in the meantime.
    func testKeepAliveReconnectDoesNotResurrectAfterLastPortCloses() async throws {
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        const real = chrome.runtime.connectNative('com.example.host');
        const keepAlive = globalThis.__fakeNativePorts.find(p => p.application === 'detourPolyfill');
        keepAlive.__simulateRemoteDisconnect();
        real.disconnect();
        await new Promise(r => setTimeout(r, 1300));
        return JSON.stringify({
            livePorts: status.livePorts,
            active: status.active,
            keepAlivePortCount: globalThis.__fakeNativePorts.filter(p => p.application === 'detourPolyfill').length
        });
        """)

        XCTAssertEqual(result["active"] as? Bool, false,
                       "the delayed reconnect must not restart the keep-alive with no real port left")
        XCTAssertEqual(result["livePorts"] as? Int, 0)
        XCTAssertEqual(result["keepAlivePortCount"] as? Int, 1,
                       "only the original keep-alive port should ever have been opened")
    }

    func testKeepAliveStatusIsReadOnly() async throws {
        // The callAsyncJavaScript body is sloppy mode, so the write to the frozen
        // status object silently no-ops rather than throwing.
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        status.livePorts = 99;
        return JSON.stringify({ livePorts: status.livePorts });
        """)

        XCTAssertEqual(result["livePorts"] as? Int, 0, "the status object must not be writable")
    }

    // MARK: - Keep-alive must never replace the chrome/browser globals

    /// Builds a page whose `chrome`/`browser` namespace is one shared object under
    /// both names, with a `runtime` whose `connectNative` cannot be patched: it is
    /// a getter-only accessor on the prototype (assignment cannot replace it) and
    /// the runtime is non-extensible (defineProperty cannot add an own override).
    /// This is the shape in which the keep-alive's direct patch fails and it is
    /// tempted to reach for a fallback.
    private func makeUnpatchableNamespaceWebView() async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        let shim = WKUserScript(
            source: """
            globalThis.__fakeNativePorts = [];
            const nativeConnectNative = function(application) {
                const port = {
                    name: application, application: application, posted: [],
                    onDisconnect: { addListener() {} }, onMessage: { addListener() {} },
                    postMessage(m) { this.posted.push(m); }, disconnect() {}
                };
                globalThis.__fakeNativePorts.push(port);
                return port;
            };
            const runtimeProto = {};
            Object.defineProperty(runtimeProto, 'connectNative', {
                get() { return nativeConnectNative; }, configurable: false, enumerable: true
            });
            const realRuntime = Object.create(runtimeProto);
            realRuntime.id = 'shadow-test-extension';
            realRuntime._listeners = [];
            realRuntime.onMessage = {
                addListener(fn) { realRuntime._listeners.push(fn); },
                removeListener(fn) { realRuntime._listeners = realRuntime._listeners.filter(f => f !== fn); },
                hasListener(fn) { return realRuntime._listeners.includes(fn); }
            };
            realRuntime.getURL = function(path) { return 'webkit-extension://0000/' + path; };
            realRuntime.sendNativeMessage = function() { return Promise.resolve(undefined); };
            Object.preventExtensions(realRuntime);
            const realChrome = { runtime: realRuntime };
            globalThis.chrome = realChrome;
            globalThis.browser = realChrome;
            globalThis.__realChrome = realChrome;
            globalThis.__realRuntime = realRuntime;
            globalThis.__detourKeepAlivePingIntervalMs = 50;
            globalThis.__detourForceNativePortKeepAlive = true;
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        config.userContentController.addUserScript(shim)
        config.userContentController.addUserScript(WKUserScript(
            source: ExtensionAPIPolyfill.polyfillJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        try await loadHTMLStringAndWait(wv, html: "<html><body>ns</body></html>",
                                        baseURL: URL(string: "https://test.example.com")!)
        return wv
    }

    /// WebKit's runtime-message dispatcher unwraps the worker's `browser`/`chrome`
    /// global to the native namespace to find its onMessage listeners; a Proxy or
    /// any other stand-in cannot be unwrapped, so the worker is skipped and every
    /// runtime.sendMessage to it gets an empty reply (TASK-15, 1Password popup).
    /// When connectNative cannot be patched in place there is no fallback: the
    /// globals, the runtime and connectNative must be left exactly as found.
    func testKeepAliveLeavesGlobalsUntouchedWhenConnectNativeIsNotPatchable() async throws {
        let wv = try await makeUnpatchableNamespaceWebView()
        let raw = try await wv.callAsyncJavaScript("""
            try {
                const fn = function() {};
                chrome.runtime.onMessage.addListener(fn);
                return JSON.stringify({
                    chromeIsReal: globalThis.chrome === globalThis.__realChrome,
                    browserIsReal: globalThis.browser === globalThis.__realChrome,
                    runtimeIsReal: chrome.runtime === globalThis.__realRuntime,
                    connectNativeIsNative: chrome.runtime.connectNative === globalThis.__realRuntime.connectNative,
                    installMode: globalThis.__detourNativePortKeepAlive.installMode,
                    listenerReachedRealEvent: globalThis.__realRuntime.onMessage.hasListener(fn),
                    getURL: chrome.runtime.getURL('x.html')
                });
            } catch (e) {
                return JSON.stringify({
                    error: (e && e.name ? e.name + ': ' : '') + String(e && e.message !== undefined ? e.message : e),
                    diag: typeof __detourPolyfillDiag !== 'undefined' ? __detourPolyfillDiag : null
                });
            }
        """, arguments: [:], contentWorld: .page) as? String
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(raw).utf8)) as? [String: Any])
        XCTAssertNil(result["error"], "test body threw: \(result["error"] ?? "") diag=\(result["diag"] ?? "")")

        XCTAssertEqual(result["chromeIsReal"] as? Bool, true, "globalThis.chrome must stay the object WebKit installed")
        XCTAssertEqual(result["browserIsReal"] as? Bool, true, "globalThis.browser must stay the object WebKit installed")
        XCTAssertEqual(result["runtimeIsReal"] as? Bool, true, "chrome.runtime must not be swapped for a stand-in")
        XCTAssertEqual(result["connectNativeIsNative"] as? Bool, true, "an unpatchable connectNative is left alone")
        XCTAssertEqual(result["installMode"] as? String, "none")
        XCTAssertEqual(result["listenerReachedRealEvent"] as? Bool, true, "onMessage.addListener must register on the real event object")
        XCTAssertEqual(result["getURL"] as? String, "webkit-extension://0000/x.html", "later polyfill patches (getURL) still work")
        withExtendedLifetime(wv) {}
    }

    // MARK: - WebSocket guard

    /// The guard normally installs only in service worker contexts; the test shim
    /// sets `__detourForceWebSocketGuard` before the polyfill loads so these run
    /// against the page context.

    func testWebSocketGuardInstalls() async throws {
        let result = try await evalDictionary("""
        const instance = new WebSocket('wss://example.invalid/');
        return JSON.stringify({
            guarded: WebSocket.__detourGuard === true,
            nativeType: typeof globalThis.__detourNativeWebSocket,
            nativeIsReplaced: globalThis.__detourNativeWebSocket !== WebSocket,
            statics: [WebSocket.CONNECTING, WebSocket.OPEN, WebSocket.CLOSING, WebSocket.CLOSED],
            onInstance: [instance.CONNECTING, instance.OPEN, instance.CLOSING, instance.CLOSED]
        });
        """)

        XCTAssertEqual(result["guarded"] as? Bool, true,
                       "globalThis.WebSocket should be the guard, not the native constructor")
        XCTAssertEqual(result["nativeType"] as? String, "function",
                       "the native constructor should be kept at __detourNativeWebSocket")
        XCTAssertEqual(result["nativeIsReplaced"] as? Bool, true)
        XCTAssertEqual(result["statics"] as? [Int], [0, 1, 2, 3])
        XCTAssertEqual(result["onInstance"] as? [Int], [0, 1, 2, 3],
                       "the ready-state constants should also be on the prototype")
    }

    func testWebSocketGuardFailsAsynchronously() async throws {
        let result = try await evalDictionary("""
        const events = [];
        const socket = new WebSocket('wss://example.invalid/notify');
        const stateAtConstruction = socket.readyState;
        let closeCode = null, closeWasClean = null;
        socket.addEventListener('error', e => events.push(e.type));
        socket.addEventListener('close', e => {
            events.push(e.type);
            closeCode = e.code;
            closeWasClean = e.wasClean;
        });
        await new Promise(r => setTimeout(r, 50));
        return JSON.stringify({
            url: socket.url,
            stateAtConstruction: stateAtConstruction,
            stateAfterWait: socket.readyState,
            events: events,
            closeCode: closeCode,
            closeWasClean: closeWasClean
        });
        """)

        XCTAssertEqual(result["url"] as? String, "wss://example.invalid/notify")
        XCTAssertEqual(result["stateAtConstruction"] as? Int, 0, "should start in CONNECTING")
        XCTAssertEqual(result["stateAfterWait"] as? Int, 3, "should end in CLOSED")
        XCTAssertEqual(result["events"] as? [String], ["error", "close"],
                       "the guard should fail the connection the way an unreachable server does")
        XCTAssertEqual(result["closeCode"] as? Int, 1006)
        XCTAssertEqual(result["closeWasClean"] as? Bool, false)
    }

    /// The first socket in a context fails at once; each further one backs off by
    /// 250 ms so a client reconnecting straight from onclose cannot spin the worker.
    func testWebSocketGuardBacksOffRepeatedConnections() async throws {
        let result = try await evalDictionary("""
        const first = new WebSocket('wss://example.invalid/first');
        await new Promise(r => setTimeout(r, 50));
        const firstAfter50 = first.readyState;

        const second = new WebSocket('wss://example.invalid/second');
        const third = new WebSocket('wss://example.invalid/third');
        await new Promise(r => setTimeout(r, 50));
        const secondAfter50 = second.readyState;
        const thirdAfter50 = third.readyState;

        await new Promise(r => setTimeout(r, 600));
        return JSON.stringify({
            firstAfter50: firstAfter50,
            secondAfter50: secondAfter50,
            thirdAfter50: thirdAfter50,
            secondAtEnd: second.readyState,
            thirdAtEnd: third.readyState
        });
        """)

        XCTAssertEqual(result["firstAfter50"] as? Int, 3,
                       "the first socket in a context should fail immediately")
        XCTAssertEqual(result["secondAfter50"] as? Int, 0,
                       "the second socket should still be CONNECTING after 50 ms (250 ms backoff)")
        XCTAssertEqual(result["thirdAfter50"] as? Int, 0,
                       "the third socket should still be CONNECTING after 50 ms (500 ms backoff)")
        XCTAssertEqual(result["secondAtEnd"] as? Int, 3)
        XCTAssertEqual(result["thirdAtEnd"] as? Int, 3,
                       "the backoff is a delay, not a cap: every socket still fails")
    }

    func testWebSocketGuardInvokesHandlerProperties() async throws {
        let result = try await evalDictionary("""
        const socket = new WebSocket('wss://example.invalid/');
        let errorCalls = 0, closeCalls = 0, closeCode = null;
        socket.onerror = () => { errorCalls += 1; };
        socket.onclose = e => { closeCalls += 1; closeCode = e.code; };
        await new Promise(r => setTimeout(r, 50));
        return JSON.stringify({ errorCalls: errorCalls, closeCalls: closeCalls, closeCode: closeCode });
        """)

        XCTAssertEqual(result["errorCalls"] as? Int, 1, "onerror should be invoked once")
        XCTAssertEqual(result["closeCalls"] as? Int, 1, "onclose should be invoked once")
        XCTAssertEqual(result["closeCode"] as? Int, 1006)
    }

    func testWebSocketGuardSendWhileConnectingThrowsInvalidState() async throws {
        let result = try await evalDictionary("""
        const socket = new WebSocket('wss://example.invalid/');
        let threw = false, name = null;
        try { socket.send('x'); } catch (e) { threw = true; name = e.name; }
        return JSON.stringify({ threw: threw, name: name, readyState: socket.readyState });
        """)

        XCTAssertEqual(result["threw"] as? Bool, true, "send() while CONNECTING must throw")
        XCTAssertEqual(result["name"] as? String, "InvalidStateError")
        XCTAssertEqual(result["readyState"] as? Int, 0)
    }

    func testWebSocketGuardSendAfterCloseIsSilent() async throws {
        let result = try await evalDictionary("""
        const socket = new WebSocket('wss://example.invalid/');
        await new Promise(r => setTimeout(r, 50));
        let threw = false;
        try { socket.send('x'); } catch (e) { threw = true; }
        return JSON.stringify({ threw: threw, readyState: socket.readyState });
        """)

        XCTAssertEqual(result["readyState"] as? Int, 3)
        XCTAssertEqual(result["threw"] as? Bool, false,
                       "send() after the socket closed should be a silent no-op, as in browsers")
    }

    func testWebSocketGuardExplicitCloseUsesGivenCode() async throws {
        let result = try await evalDictionary("""
        function watch(socket) {
            const record = { events: [], code: null, reason: null };
            socket.addEventListener('error', e => record.events.push(e.type));
            socket.addEventListener('close', e => {
                record.events.push(e.type);
                record.code = e.code;
                record.reason = e.reason;
            });
            return record;
        }

        const withCode = new WebSocket('wss://example.invalid/a');
        const withCodeRecord = watch(withCode);
        withCode.close(4000, 'bye');

        const withoutCode = new WebSocket('wss://example.invalid/b');
        const withoutCodeRecord = watch(withoutCode);
        withoutCode.close();

        await new Promise(r => setTimeout(r, 50));
        return JSON.stringify({
            withCode: withCodeRecord,
            withCodeReadyState: withCode.readyState,
            withoutCode: withoutCodeRecord,
            withoutCodeReadyState: withoutCode.readyState
        });
        """)

        let withCode = try XCTUnwrap(result["withCode"] as? [String: Any])
        XCTAssertEqual(withCode["events"] as? [String], ["close"],
                       "an explicit close before the automatic failure must not fire an error event")
        XCTAssertEqual(withCode["code"] as? Int, 4000)
        XCTAssertEqual(withCode["reason"] as? String, "bye")
        XCTAssertEqual(result["withCodeReadyState"] as? Int, 3)

        let withoutCode = try XCTUnwrap(result["withoutCode"] as? [String: Any])
        XCTAssertEqual(withoutCode["events"] as? [String], ["close"])
        XCTAssertEqual(withoutCode["code"] as? Int, 1005, "close() with no code should report 1005")
        XCTAssertEqual(result["withoutCodeReadyState"] as? Int, 3)
    }

    func testWebSocketGuardWarnsOnce() async throws {
        let result = try await evalDictionary("""
        const originalWarn = console.warn;
        let warnings = 0;
        try {
            console.warn = function(...args) {
                if (args.some(a => typeof a === 'string' && a.includes('WebSocket is unavailable'))) warnings += 1;
            };
            new WebSocket('wss://example.invalid/one');
            new WebSocket('wss://example.invalid/two');
            await new Promise(r => setTimeout(r, 50));
        } finally {
            console.warn = originalWarn;
        }
        return JSON.stringify({ warnings: warnings });
        """)

        XCTAssertEqual(result["warnings"] as? Int, 1,
                       "the guard should warn once per context, not once per socket")
    }

    func testWebSocketGuardDoesNotAffectEventTargetSemantics() async throws {
        let result = try await evalDictionary("""
        const socket = new WebSocket('wss://example.invalid/');
        let removedCalls = 0, keptCalls = 0;
        const removed = () => { removedCalls += 1; };
        socket.addEventListener('close', removed);
        socket.addEventListener('close', () => { keptCalls += 1; });
        socket.removeEventListener('close', removed);
        await new Promise(r => setTimeout(r, 50));
        return JSON.stringify({ removedCalls: removedCalls, keptCalls: keptCalls });
        """)

        XCTAssertEqual(result["removedCalls"] as? Int, 0,
                       "a listener removed before the failure must not be called")
        XCTAssertEqual(result["keptCalls"] as? Int, 1)
    }
}
