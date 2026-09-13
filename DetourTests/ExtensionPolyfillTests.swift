import XCTest
import WebKit
import GRDB
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
        // both stubs, and `nativeMessaging`, without which the native port
        // keep-alive installs nothing at all (TASK-16); the
        // absent-without-permission cases build their own view.
        webView = try await makeWebView(
            manifestPermissions: ["history", "management", "privacy", "webRequest", "nativeMessaging"])
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
    /// `baseURL` is what the page loads at: its scheme and host are what the
    /// handler attributes the sender by, and its *path* is what the
    /// background-context-only requests are matched against (TASK-64), so a
    /// fixture standing in for the background context loads at the background
    /// document's path.
    private func makeWebView(manifestPermissions: [String], shimExtras: String = "",
                             baseURL: URL = URL(string: "https://test.example.com")!) async throws -> WKWebView {
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
        // without a real native host or a real Detour port. Each fake port can be
        // driven from the test with `__simulateNativeMessage` (what Detour sends:
        // keepalive-start / keepalive-stop) and `__simulateRemoteDisconnect`.
        // The keep-alive's ping interval and reconnect backoff are shortened so
        // tests need not wait 45 s / 1 s.
        let shimScript = WKUserScript(
            source: """
            if (!globalThis.chrome) globalThis.chrome = {};
            if (!globalThis.chrome.runtime) globalThis.chrome.runtime = {};
            if (!globalThis.chrome.runtime.id) globalThis.chrome.runtime.id = 'test-polyfill-extension';
            globalThis.chrome.runtime.getManifest = () => ({ manifest_version: 3, permissions: \(permissionsJSON) });

            globalThis.__detourKeepAlivePingIntervalMs = 50;
            globalThis.__detourKeepAliveReconnectBaseMs = 100;
            // Install the service-worker-only WebSocket relay and native port
            // keep-alive in this page context so they can be exercised without a
            // real service worker.
            globalThis.__detourForceWebSocketRelay = true;
            globalThis.__detourForceNativePortKeepAlive = true;
            globalThis.__fakeNativePorts = [];
            globalThis.chrome.runtime.connectNative = function(application) {
                const disconnectListeners = [];
                const messageListeners = [];
                const port = {
                    name: application,
                    application: application,
                    posted: [],
                    disconnectedLocally: false,
                    onDisconnect: { addListener(fn) { disconnectListeners.push(fn); } },
                    onMessage: { addListener(fn) { messageListeners.push(fn); } },
                    postMessage(m) { this.posted.push(m); },
                    disconnect() { this.disconnectedLocally = true; },
                    // Test helper: deliver a message from the other side (Detour).
                    __simulateNativeMessage(m) { messageListeners.slice().forEach(fn => fn(m)); },
                    // Test helper: simulate the other side closing the port.
                    __simulateRemoteDisconnect() { disconnectListeners.slice().forEach(fn => fn()); }
                };
                globalThis.__fakeNativePorts.push(port);
                return port;
            };
            // Pinned so a test can assert the keep-alive left connectNative alone.
            globalThis.__shimConnectNative = globalThis.chrome.runtime.connectNative;
            globalThis.__shimChrome = globalThis.chrome;
            globalThis.__shimRuntime = globalThis.chrome.runtime;
            \(shimExtras)
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        // Inject before the polyfill: it reads the timer overrides and opens its
        // keep-alive port through chrome.runtime.connectNative while it installs.
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
                                        baseURL: baseURL)
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
    /// `background`, when given, is the manifest's `background` entry — needed
    /// by the background-context-only requests (TASK-64).
    @discardableResult
    private func registerExtension(id: String, permissions: [String],
                                   background: [String: Any]? = nil) throws -> WebExtension {
        var manifestDict: [String: Any] = [
            "manifest_version": 3,
            "name": "Polyfill Permission Test",
            "version": "1.0.0",
            "permissions": permissions
        ]
        if let background { manifestDict["background"] = background }
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

    // MARK: - chrome.webNavigation frame enumeration

    /// `getAllFrames`/`getFrame` are deliberately not polyfilled — the only
    /// honest implementation is WebKit's, and a stub would hand 1Password
    /// fabricated frames. So in a bare WKWebView, which has no native
    /// chrome.webNavigation at all, the diag must read `missing` and the
    /// functions must stay `undefined`: no silent fallback.
    func testWebNavigationFrameNativenessRecordedInDiag() async throws {
        let result = try await evalDictionary("""
        return JSON.stringify({
            diag: __detourPolyfillDiag.apis.webNavigationFrames,
            getAllFrames: typeof chrome.webNavigation.getAllFrames,
            getFrame: typeof chrome.webNavigation.getFrame
        });
        """)

        let diag = try XCTUnwrap(result["diag"] as? [String: Any])
        XCTAssertEqual(diag["namespace"] as? String, "undefined",
                       "a bare WKWebView has no native chrome.webNavigation")
        XCTAssertEqual(diag["getAllFrames"] as? String, "missing")
        XCTAssertEqual(diag["getFrame"] as? String, "missing")

        XCTAssertEqual(result["getAllFrames"] as? String, "undefined",
                       "the polyfill must not fabricate frame enumeration")
        XCTAssertEqual(result["getFrame"] as? String, "undefined")
    }

    /// Re-running the polyfill must not relabel the environment: the diag
    /// records the *pre-patch* reading once, and nothing patches these two.
    func testWebNavigationFrameNativenessSurvivesRerun() async throws {
        let result = try await evalDictionary("""
        \(ExtensionAPIPolyfill.polyfillJS)
        return JSON.stringify({
            diag: globalThis.__detourWebNavFrames,
            getAllFrames: typeof chrome.webNavigation.getAllFrames
        });
        """)
        let diag = try XCTUnwrap(result["diag"] as? [String: Any])
        XCTAssertEqual(diag["getAllFrames"] as? String, "missing")
        XCTAssertEqual(diag["getFrame"] as? String, "missing")
        XCTAssertEqual(result["getAllFrames"] as? String, "undefined")
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

    // MARK: - Callback form and runtime.lastError (TASK-23)
    //
    // The shim's chrome.runtime is a plain object, so these exercise the 'js'
    // path of `__detourSettle` (lastError installed as a getter for the
    // duration of the callback). WebKit's native runtime ignores that, and the
    // 'native-relay' path it takes instead is covered against a real extension
    // page in ExtensionPolyfillProfileWiringTests.

    private static let offscreenParams =
        "{ url: 'offscreen.html', reasons: ['DOM_PARSER'], justification: 'test' }"

    private func callbackOutcome(call: String, setup: String = "", teardown: String = "",
                                 readLastError: Bool = true, throwFromCallback: Bool = false,
                                 on target: WKWebView? = nil) async throws -> [String: Any] {
        try await evalDictionary(
            callbackOutcomeJS(call: call, setup: setup, teardown: teardown,
                              readLastError: readLastError, throwFromCallback: throwFromCallback),
            on: target)
    }

    /// The harness must be able to see an unhandled rejection at all, or the
    /// "no unhandled rejection" assertions below prove nothing.
    func testCallbackHarnessObservesUnhandledRejections() async throws {
        let outcome = try await callbackOutcome(call: """
            Promise.reject(new Error('control rejection'));
            cb();
        """)
        XCTAssertEqual(outcome["unhandled"] as? [String], ["control rejection"])
    }

    /// NEGATIVE: the native side rejects (a bare web view has no loaded
    /// context, so "Extension not found"). The callback still runs, with no
    /// arguments and lastError carrying the message, and lastError is gone
    /// once it returns. A checked error is not reported to the console.
    func testOffscreenCreateDocumentCallbackGetsLastErrorOnNativeFailure() async throws {
        let outcome = try await callbackOutcome(
            call: "return chrome.offscreen.createDocument(\(Self.offscreenParams), cb);")

        XCTAssertEqual(outcome["timedOut"] as? Bool, false, "the callback must run on failure: \(outcome)")
        XCTAssertEqual(outcome["returnedType"] as? String, "undefined")
        XCTAssertEqual(outcome["argc"] as? Int, 0)
        XCTAssertEqual(outcome["lastErrorInCallback"] as? String, "Extension not found")
        XCTAssertEqual(outcome["lastErrorAfter"] as? String, "undefined", "lastError must be cleared after the callback")
        XCTAssertEqual(outcome["ownLastErrorAfter"] as? Bool, false, "the runtime object must be left as it was")
        XCTAssertEqual(outcome["mode"] as? String, "js")
        XCTAssertEqual(outcome["unhandled"] as? [String], [])
        XCTAssertEqual(outcome["consoleErrors"] as? [String], [], "a checked lastError is not reported")
    }

    /// NEGATIVE: a callback that never reads lastError gets Chrome's
    /// "Unchecked runtime.lastError" console report, and still no unhandled
    /// rejection.
    func testOffscreenCreateDocumentUncheckedLastErrorIsReported() async throws {
        let outcome = try await callbackOutcome(
            call: "return chrome.offscreen.createDocument(\(Self.offscreenParams), cb);",
            readLastError: false)

        XCTAssertEqual(outcome["argc"] as? Int, 0)
        XCTAssertEqual(outcome["consoleErrors"] as? [String], ["Unchecked runtime.lastError: Extension not found"])
        XCTAssertEqual(outcome["unhandled"] as? [String], [])
        XCTAssertEqual(outcome["lastErrorAfter"] as? String, "undefined")
    }

    /// NEGATIVE: the promise form is untouched by the callback handling and
    /// still rejects with the native message.
    func testOffscreenCreateDocumentPromiseFormStillRejects() async throws {
        let outcome = try await evalDictionary(
            promiseOutcomeJS("chrome.offscreen.createDocument(\(Self.offscreenParams))"))
        XCTAssertEqual(outcome["settled"] as? String, "rejected")
        XCTAssertEqual(outcome["message"] as? String, "Extension not found")
    }

    /// POSITIVE: a successful createDocument runs the callback with no
    /// arguments and no lastError. The bridge is stubbed to succeed, since a
    /// bare web view cannot host a real offscreen document (the real success
    /// path is covered in ExtensionPolyfillProfileWiringTests).
    func testOffscreenCreateDocumentCallbackOnSuccess() async throws {
        let outcome = try await callbackOutcome(
            call: "return chrome.offscreen.createDocument(\(Self.offscreenParams), cb);",
            setup: """
                const realRequest = globalThis.__detourPolyfillRequest;
                globalThis.__detourRestoreRequest = () => { globalThis.__detourPolyfillRequest = realRequest; };
                globalThis.__detourPolyfillRequest = function(type, params) {
                    return type === 'offscreen.createDocument' ? Promise.resolve(true) : realRequest(type, params);
                };
            """,
            teardown: "globalThis.__detourRestoreRequest();")

        XCTAssertEqual(outcome["timedOut"] as? Bool, false)
        XCTAssertEqual(outcome["returnedType"] as? String, "undefined")
        XCTAssertEqual(outcome["argc"] as? Int, 0, "createDocument's callback takes no arguments")
        XCTAssertNil(outcome["lastErrorInCallback"] as? String)
        XCTAssertEqual(outcome["lastErrorAfter"] as? String, "undefined")
        XCTAssertEqual(outcome["consoleErrors"] as? [String], [])
        XCTAssertEqual(outcome["unhandled"] as? [String], [])
    }

    /// POSITIVE: history.search through the real native bridge hands its
    /// result to the callback with no lastError.
    func testHistorySearchCallbackReceivesResults() async throws {
        let outcome = try await callbackOutcome(call: "return chrome.history.search({ text: '' }, cb);")

        XCTAssertEqual(outcome["returnedType"] as? String, "undefined")
        XCTAssertEqual(outcome["argc"] as? Int, 1)
        let results = try JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(outcome["arg0"] as? String).utf8))
        XCTAssertTrue(results is [Any], "the callback should receive the results array, got \(String(describing: results))")
        XCTAssertNil(outcome["lastErrorInCallback"] as? String)
        XCTAssertEqual(outcome["consoleErrors"] as? [String], [])
    }

    /// NEGATIVE: without the `history` permission the native gate rejects;
    /// the callback gets that as lastError, and the promise form rejects.
    func testHistorySearchCallbackGetsLastErrorWithoutPermission() async throws {
        ExtensionManager.shared.extensions.removeAll { $0.id == "test-polyfill-extension" }
        try registerExtension(id: "test-polyfill-extension", permissions: ["management"])

        let outcome = try await callbackOutcome(call: "return chrome.history.search({ text: '' }, cb);")
        XCTAssertEqual(outcome["argc"] as? Int, 0, "a failed call passes no result: \(outcome)")
        XCTAssertEqual(outcome["lastErrorInCallback"] as? String, "history permission not declared")
        XCTAssertEqual(outcome["lastErrorAfter"] as? String, "undefined")
        XCTAssertEqual(outcome["ownLastErrorAfter"] as? Bool, false)
        XCTAssertEqual(outcome["unhandled"] as? [String], [])

        let promise = try await evalDictionary(promiseOutcomeJS("chrome.history.search({ text: '' })"))
        XCTAssertEqual(promise["settled"] as? String, "rejected")
        XCTAssertEqual(promise["message"] as? String, "history permission not declared")
    }

    /// An exception thrown by the callback surfaces as an uncaught error (as
    /// in Chrome), not as an unhandled rejection, and lastError is still
    /// cleared behind it.
    func testCallbackExceptionIsRethrownAndLastErrorStillCleared() async throws {
        let outcome = try await callbackOutcome(
            call: "return chrome.offscreen.createDocument(\(Self.offscreenParams), cb);",
            throwFromCallback: true)

        XCTAssertEqual(outcome["lastErrorInCallback"] as? String, "Extension not found")
        XCTAssertEqual(outcome["lastErrorAfter"] as? String, "undefined")
        XCTAssertEqual(outcome["ownLastErrorAfter"] as? Bool, false)
        XCTAssertEqual(outcome["unhandled"] as? [String], [])
        // The rethrow happens inside the polyfill, a user script, so WebKit
        // mutes the error event's text to "Script error."; its count is what
        // shows the exception surfaced exactly once.
        let uncaught = outcome["uncaught"] as? [String] ?? []
        XCTAssertEqual(uncaught.count, 1, "the callback's exception should be reported as uncaught, got \(uncaught)")
    }

    /// A runtime whose lastError cannot be redefined (WebKit's native one
    /// ignores the write; here the property is made non-configurable) takes
    /// the relay: the message goes to Detour's polyfill host through the
    /// callback-style sendNativeMessage, and the callback runs from that
    /// callback. The fake sendNativeMessage stands in for WebKit's.
    func testNonOverridableLastErrorRelaysThroughSendNativeMessage() async throws {
        let outcome = try await callbackOutcome(
            call: "return chrome.offscreen.createDocument(\(Self.offscreenParams), cb);",
            setup: """
                Object.defineProperty(chrome.runtime, 'lastError', { get() { return undefined; }, configurable: false });
                globalThis.__relayed = [];
                chrome.runtime.sendNativeMessage = function(application, message, callback) {
                    globalThis.__relayed.push({ application, message });
                    callback();
                };
            """,
            teardown: "delete chrome.runtime.sendNativeMessage;")

        XCTAssertEqual(outcome["mode"] as? String, "native-relay")
        XCTAssertEqual(outcome["timedOut"] as? Bool, false)
        XCTAssertEqual(outcome["argc"] as? Int, 0)
        XCTAssertEqual(outcome["unhandled"] as? [String], [])
        XCTAssertEqual(outcome["ownLastErrorAfter"] as? Bool, true, "the non-configurable property is untouched")

        let relayedValue = try await evalJSON("return JSON.stringify(globalThis.__relayed)")
        let relayed = try XCTUnwrap(relayedValue as? [[String: Any]])
        XCTAssertEqual(relayed.count, 1)
        XCTAssertEqual(relayed.first?["application"] as? String, ExtensionPolyfillHandler.handlerName)
        let message = relayed.first?["message"] as? [String: Any]
        XCTAssertEqual(message?["type"] as? String, ExtensionPolyfillHandler.lastErrorRelayType)
        XCTAssertEqual((message?["params"] as? [String: Any])?["message"] as? String, "Extension not found")
    }

    /// With neither a redefinable lastError nor sendNativeMessage, the callback
    /// still runs and the error is reported to the console.
    func testNonOverridableLastErrorWithoutRelayFallsBackToConsole() async throws {
        let outcome = try await callbackOutcome(
            call: "return chrome.offscreen.createDocument(\(Self.offscreenParams), cb);",
            setup: "Object.defineProperty(chrome.runtime, 'lastError', { get() { return undefined; }, configurable: false });")

        XCTAssertEqual(outcome["mode"] as? String, "console")
        XCTAssertEqual(outcome["timedOut"] as? Bool, false)
        XCTAssertEqual(outcome["argc"] as? Int, 0)
        XCTAssertNil(outcome["lastErrorInCallback"] as? String)
        XCTAssertEqual(outcome["consoleErrors"] as? [String], ["Unchecked runtime.lastError: Extension not found"])
        XCTAssertEqual(outcome["unhandled"] as? [String], [])
    }

    /// The native half of the relay: it always fails, with the sender's own
    /// message (capped), and needs no permission.
    func testLastErrorRelayRepliesWithTheMessageAsItsError() async throws {
        func relay(_ params: [String: Any]) async -> (result: Any?, error: String?) {
            await withCheckedContinuation { continuation in
                handler.handleNativeMessage(
                    ["type": ExtensionPolyfillHandler.lastErrorRelayType, "extensionID": "", "params": params],
                    verifiedExtensionID: "no-permissions-extension"
                ) { result, error in
                    continuation.resume(returning: (result, (error as NSError?)?.localizedDescription))
                }
            }
        }
        let echoed = await relay(["message": "offscreen page failed to load"])
        XCTAssertNil(echoed.result)
        XCTAssertEqual(echoed.error, "offscreen page failed to load")

        let empty = await relay([:])
        XCTAssertEqual(empty.error, "Unknown error")

        let long = await relay(["message": String(repeating: "x", count: ExtensionPolyfillHandler.lastErrorRelayMessageLimit + 100)])
        XCTAssertEqual(long.error?.count, ExtensionPolyfillHandler.lastErrorRelayMessageLimit)
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

    /// Run `statementJS` with the polyfill bridge stubbed out and return every
    /// 'log' request it produced, in order. The rate limiter (TASK-17) is reset
    /// first, so a test starts from a full token bucket and an empty dedupe
    /// window whatever the context logged while loading.
    private func bridgedLogs(running statementJS: String, on target: WKWebView? = nil)
        async throws -> [(level: String, message: String)] {
        let raw = try await evalJSON("""
        globalThis.__detourConsoleBridge.reset();
        const calls = [];
        const orig = globalThis.__detourPolyfillRequest;
        globalThis.__detourPolyfillRequest = function(type, params) { if (type === 'log') calls.push(params); return Promise.resolve(); };
        try { \(statementJS) } finally { globalThis.__detourPolyfillRequest = orig; }
        return JSON.stringify(calls.map(p => ({ level: String(p.level), message: String(p.message) })));
        """, on: target)
        let entries = try XCTUnwrap(raw as? [[String: Any]],
                                    "expected a JSON array of log requests, got: \(raw ?? "nil")")
        return try entries.map {
            (try XCTUnwrap($0["level"] as? String, "a bridged log carried no level"),
             try XCTUnwrap($0["message"] as? String, "a bridged log carried no message"))
        }
    }

    /// The level and message of the first 'log' request `statementJS` produced.
    /// Covers both ways the console bridge is driven: calling `console.*`
    /// directly, and dispatching an `error` / `unhandledrejection` event that the
    /// bridge reports.
    private func bridgedLog(running statementJS: String) async throws -> (level: String, message: String) {
        let logs = try await bridgedLogs(running: statementJS)
        return try XCTUnwrap(logs.first, "nothing reached the bridge")
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

    // MARK: - Console bridge rate limit (TASK-17)

    /// The JS limiter's burst, read from the polyfill so the tests follow tuning.
    private func consoleBridgeBurst(on target: WKWebView? = nil) async throws -> Int {
        // Hoisted out of XCTUnwrap: its argument is an autoclosure and cannot await.
        let value = try await eval("return globalThis.__detourConsoleBridge.BURST", on: target)
        return try XCTUnwrap(value as? Int, "the console bridge exposes no BURST constant")
    }

    func testConsoleBridgeForwardsTheWholeBurst() async throws {
        let burst = try await consoleBridgeBurst()
        let logs = try await bridgedLogs(running: """
        for (let i = 0; i < \(burst); i++) console.log('burst ' + i);
        """)
        XCTAssertEqual(logs.count, burst, "the whole burst must reach the bridge")
        XCTAssertEqual(logs.map(\.message), (0..<burst).map { "burst \($0)" })
    }

    /// Distinct messages beyond the burst are dropped, and the drop is accounted
    /// for by one summary line once a token comes back.
    func testConsoleBridgeDropsBeyondTheBurstAndSummarizesWhatItDropped() async throws {
        let burst = try await consoleBridgeBurst()
        let flood = 200
        let logs = try await bridgedLogs(running: """
        for (let i = 0; i < \(flood); i++) console.error('flood ' + i);
        // A token returns within ~50ms of the bucket emptying; the next message
        // is what carries the summary of everything dropped in between.
        await new Promise(r => setTimeout(r, 200));
        console.error('after the flood');
        """)

        let summaries = logs.filter { $0.message.hasPrefix("[console bridge] dropped") }
        XCTAssertEqual(summaries.count, 1, "exactly one summary per drop episode, got: \(logs.map(\.message))")
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.level, "warn", "the summary is a warning whatever the dropped levels were")

        let forwardedFlood = logs.filter { $0.message.hasPrefix("flood ") }
        // The burst always gets through; a few more only if the loop itself took
        // long enough to refill a token, which must not make this flaky.
        XCTAssertGreaterThanOrEqual(forwardedFlood.count, burst)
        XCTAssertLessThanOrEqual(forwardedFlood.count, burst + 5,
                                 "far short of the \(flood) sent: \(logs.count) reached the bridge")
        XCTAssertEqual(forwardedFlood.map(\.message), (0..<forwardedFlood.count).map { "flood \($0)" },
                       "the *first* occurrences are the ones kept")
        let dropped = flood - forwardedFlood.count
        XCTAssertTrue(summary.message.contains("dropped \(dropped) messages (\(dropped) errors, 0 warnings, 0 info)"),
                      "the summary must account for every dropped message and its level: \(summary.message)")
        XCTAssertEqual(logs.last?.message, "after the flood",
                       "logging resumes once tokens return, after the summary")
        XCTAssertEqual(logs.count, forwardedFlood.count + 2,
                       "nothing but the burst, one summary and the tail: \(logs.map(\.message))")
    }

    /// A flood that outlasts the burst: tokens return every 1/REFILL_PER_SEC, and
    /// each return must not buy its own summary line, or the summaries double the
    /// traffic the bucket caps. One summary per DROP_SUMMARY_MS, the rest deferred.
    func testConsoleBridgeSummarizesASustainedFloodOncePerPeriod() async throws {
        let logs = try await bridgedLogs(running: """
        for (let batch = 0; batch < 8; batch++) {
            for (let i = 0; i < 30; i++) console.error('sustained ' + batch + '/' + i);
            // Long enough for at least one token to return between batches.
            await new Promise(r => setTimeout(r, 60));
        }
        """)
        let summaries = logs.filter { $0.message.hasPrefix("[console bridge] dropped") }
        XCTAssertEqual(summaries.count, 1,
                       "a returning token must not buy a summary each time: \(summaries.map(\.message))")
    }

    /// A `(repeated N times)` flush that the bucket drops loses N messages; the
    /// summary must say so rather than counting the one line.
    func testConsoleBridgeCountsADroppedRepeatFlushAsEveryRepeat() async throws {
        let burst = try await consoleBridgeBurst()
        let logs = try await bridgedLogs(running: """
        for (let i = 0; i < \(burst); i++) console.error('burst ' + i);
        // Bucket empty: the first 'same' is dropped, the next 99 fold into it.
        for (let i = 0; i < 100; i++) console.error('same');
        // Closes the dedupe window; the flush line is dropped too, worth 99.
        console.error('other');
        await new Promise(r => setTimeout(r, 200));
        console.error('after');
        """)
        let summary = try XCTUnwrap(logs.first { $0.message.hasPrefix("[console bridge] dropped") },
                                    "no summary in: \(logs.map(\.message))")
        // 1 ('same') + 99 (its repeats, via the dropped flush) + 1 ('other').
        XCTAssertTrue(summary.message.contains("dropped 101 messages (101 errors, 0 warnings, 0 info)"),
                      "every folded repeat must be accounted for: \(summary.message)")
    }

    /// The shape of the 2026-09-11 incident: a worker error loop repeating one
    /// message. It must cost a couple of sends, not one per iteration, and must
    /// not burn the bucket other messages need.
    func testConsoleBridgeCoalescesARepeatingMessageIntoACount() async throws {
        let logs = try await bridgedLogs(running: """
        for (let i = 0; i < 5000; i++) console.error('the same error');
        console.error('something else');
        """)
        XCTAssertEqual(logs.map(\.message), [
            "the same error",
            "the same error (repeated 4999 times)",
            "something else",
        ])
        XCTAssertEqual(logs.map(\.level), ["error", "error", "error"])
    }

    /// With no different message to close it, the dedupe window is flushed by its
    /// own timer so a still-looping worker is reported about once a second.
    func testConsoleBridgeFlushesARepeatCountOnATimer() async throws {
        let logs = try await bridgedLogs(running: """
        console.warn('tick');
        console.warn('tick');
        console.warn('tick');
        const flush = globalThis.__detourConsoleBridge.DEDUPE_FLUSH_MS;
        await new Promise(r => setTimeout(r, flush + 300));
        """)
        XCTAssertEqual(logs.map(\.message), ["tick", "tick (repeated 2 times)"])
        XCTAssertEqual(logs.map(\.level), ["warn", "warn"])
    }

    /// Identical messages at *different* levels are different messages: a
    /// warn/error pair must not be collapsed into one.
    func testConsoleBridgeDoesNotCoalesceAcrossLevels() async throws {
        let logs = try await bridgedLogs(running: """
        console.warn('same text');
        console.error('same text');
        """)
        XCTAssertEqual(logs.map(\.level), ["warn", "error"])
        XCTAssertEqual(logs.map(\.message), ["same text", "same text"])
    }

    /// Only the bridge send is limited. The extension's own console — what the Web
    /// Inspector shows — still receives every call, so limiting never hides
    /// anything from the extension developer.
    func testConsoleBridgeLimitDoesNotTouchTheContextsOwnConsole() async throws {
        // The shim runs before the polyfill, so the polyfill binds _origError to
        // this counter the way it would bind the real console.
        let wv = try await makeWebView(manifestPermissions: ["history"], shimExtras: """
        globalThis.__origConsoleCalls = 0;
        console.error = function() { globalThis.__origConsoleCalls += 1; };
        """)
        let logs = try await bridgedLogs(running: """
        globalThis.__origConsoleCalls = 0;
        for (let i = 0; i < 200; i++) console.error('flood ' + i);
        """, on: wv)
        let seen = try await eval("return globalThis.__origConsoleCalls", on: wv) as? Int
        XCTAssertEqual(seen, 200, "the context's own console must see every message")
        XCTAssertLessThan(logs.count, 200, "the bridge must not have seen all of them")
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
    private func keepAliveStatus(on target: WKWebView? = nil) async throws -> [String: Any] {
        try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        return JSON.stringify({
            armed: status.armed,
            active: status.active,
            pingIntervalMs: status.pingIntervalMs,
            installMode: status.installMode,
            installDetail: status.installDetail,
            reconnectAttempts: status.reconnectAttempts,
            applications: globalThis.__fakeNativePorts.map(p => p.application)
        });
        """, on: target)
    }

    /// The worker opens its port to Detour at startup and then waits: nothing is
    /// pinging until Detour says a native host is connected (TASK-16).
    func testKeepAliveOpensOneIdlePortAtInstall() async throws {
        let status = try await keepAliveStatus()
        XCTAssertEqual(status["applications"] as? [String], ["detourPolyfill"],
                       "exactly one port, to Detour's own host, opened at install")
        XCTAssertEqual(status["installMode"] as? String, "port")
        XCTAssertEqual(status["installDetail"] as? String, "")
        XCTAssertEqual(status["armed"] as? Bool, false, "an idle port must not ping")
        XCTAssertEqual(status["active"] as? Bool, false)
        XCTAssertEqual(status["pingIntervalMs"] as? Int, 50, "the test override should be honoured")
        XCTAssertEqual(status["reconnectAttempts"] as? Int, 0)
    }

    /// Opening a real native port is Detour's business now: the worker must not
    /// react to it at all (it cannot even see it — TASK-15).
    func testKeepAliveIgnoresTheExtensionsOwnNativePorts() async throws {
        _ = try await eval("chrome.runtime.connectNative('com.example.host');")

        let status = try await keepAliveStatus()
        XCTAssertEqual(status["armed"] as? Bool, false,
                       "only Detour's keepalive-start may arm the worker")
        XCTAssertEqual(status["applications"] as? [String], ["detourPolyfill", "com.example.host"],
                       "no extra keep-alive port should be opened")
    }

    func testKeepAliveStartPingsImmediatelyThenAtTheInterval() async throws {
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        const keepAlive = globalThis.__fakeNativePorts[0];
        keepAlive.__simulateNativeMessage({ type: 'keepalive-start' });
        const postedImmediately = keepAlive.posted.length;
        const armedImmediately = status.armed;
        await new Promise(r => setTimeout(r, 250));
        return JSON.stringify({
            postedImmediately: postedImmediately,
            armedImmediately: armedImmediately,
            active: status.active,
            posted: keepAlive.posted
        });
        """)

        XCTAssertEqual(result["postedImmediately"] as? Int, 1,
                       "the first ping must go out with the start, not one interval later")
        XCTAssertEqual(result["armedImmediately"] as? Bool, true)
        XCTAssertEqual(result["active"] as? Bool, true)
        let posted = try XCTUnwrap(result["posted"] as? [[String: String]])
        XCTAssertGreaterThanOrEqual(posted.count, 3,
                                    "expected repeated pings at a 50 ms interval, got \(posted.count)")
        for message in posted {
            XCTAssertEqual(message, ["type": "keepalive"])
        }
    }

    func testKeepAliveStopEndsThePings() async throws {
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        const keepAlive = globalThis.__fakeNativePorts[0];
        keepAlive.__simulateNativeMessage({ type: 'keepalive-start' });
        await new Promise(r => setTimeout(r, 150));
        keepAlive.__simulateNativeMessage({ type: 'keepalive-stop' });
        const postedAtStop = keepAlive.posted.length;
        const armedAfterStop = status.armed;
        await new Promise(r => setTimeout(r, 250));
        return JSON.stringify({
            postedAtStop: postedAtStop,
            armedAfterStop: armedAfterStop,
            active: status.active,
            postedAfterWait: keepAlive.posted.length,
            disconnectedLocally: keepAlive.disconnectedLocally
        });
        """)

        XCTAssertGreaterThanOrEqual(result["postedAtStop"] as? Int ?? 0, 2,
                                    "the port should have been pinging before the stop")
        XCTAssertEqual(result["armedAfterStop"] as? Bool, false)
        XCTAssertEqual(result["active"] as? Bool, false)
        XCTAssertEqual(result["postedAfterWait"] as? Int, result["postedAtStop"] as? Int,
                       "pings must stop when Detour disarms the worker")
        XCTAssertEqual(result["disconnectedLocally"] as? Bool, false,
                       "the port stays open while idle; Detour re-arms it on the same port")
    }

    func testKeepAliveIgnoresUnknownMessages() async throws {
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        const keepAlive = globalThis.__fakeNativePorts[0];
        keepAlive.__simulateNativeMessage({ type: 'something-else' });
        keepAlive.__simulateNativeMessage('keepalive-start');
        keepAlive.__simulateNativeMessage(null);
        await new Promise(r => setTimeout(r, 150));
        return JSON.stringify({ armed: status.armed, posted: keepAlive.posted.length });
        """)

        XCTAssertEqual(result["armed"] as? Bool, false)
        XCTAssertEqual(result["posted"] as? Int, 0, "nothing should have been posted")
    }

    /// Detour dropping the port (a profile reload, an unloaded context) must not
    /// leave the worker without one: it reconnects with a backoff, disarmed, and
    /// Detour re-sends keepalive-start on the new port if hosts are still connected.
    func testKeepAliveReconnectsAfterARemoteDisconnect() async throws {
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        const first = globalThis.__fakeNativePorts[0];
        first.__simulateNativeMessage({ type: 'keepalive-start' });
        first.__simulateRemoteDisconnect();
        const immediately = {
            installMode: status.installMode,
            installDetail: status.installDetail,
            armed: status.armed,
            portCount: globalThis.__fakeNativePorts.length
        };
        const postedOnFirstAtDrop = first.posted.length;

        await new Promise(r => setTimeout(r, 400));
        const second = globalThis.__fakeNativePorts[1];
        const afterReconnect = {
            installMode: status.installMode,
            installDetail: status.installDetail,
            armed: status.armed,
            reconnectAttempts: status.reconnectAttempts,
            application: second ? second.application : null,
            postedOnSecond: second ? second.posted.length : null,
            postedOnFirst: first.posted.length
        };

        if (second) second.__simulateNativeMessage({ type: 'keepalive-start' });
        await new Promise(r => setTimeout(r, 150));
        return JSON.stringify({
            immediately: immediately,
            postedOnFirstAtDrop: postedOnFirstAtDrop,
            afterReconnect: afterReconnect,
            armedAfterRestart: status.armed,
            postedOnSecondAfterRestart: second ? second.posted.length : null,
            portCount: globalThis.__fakeNativePorts.length
        });
        """)

        let immediately = try XCTUnwrap(result["immediately"] as? [String: Any])
        XCTAssertEqual(immediately["installMode"] as? String, "none")
        XCTAssertEqual(immediately["installDetail"] as? String, "disconnected")
        XCTAssertEqual(immediately["armed"] as? Bool, false, "a dropped port cannot be armed")
        XCTAssertEqual(immediately["portCount"] as? Int, 1, "the reconnect is delayed by the backoff")

        let afterReconnect = try XCTUnwrap(result["afterReconnect"] as? [String: Any])
        XCTAssertEqual(afterReconnect["application"] as? String, "detourPolyfill",
                       "the worker should have reopened its port to Detour")
        XCTAssertEqual(afterReconnect["installMode"] as? String, "port")
        XCTAssertEqual(afterReconnect["installDetail"] as? String, "")
        XCTAssertEqual(afterReconnect["reconnectAttempts"] as? Int, 0,
                       "the backoff resets after a successful connect")
        XCTAssertEqual(afterReconnect["armed"] as? Bool, false,
                       "a reconnected port starts disarmed until Detour arms it again")
        XCTAssertEqual(afterReconnect["postedOnSecond"] as? Int, 0)
        XCTAssertEqual(afterReconnect["postedOnFirst"] as? Int, result["postedOnFirstAtDrop"] as? Int,
                       "the dropped port must never be posted on again")

        XCTAssertEqual(result["armedAfterRestart"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(result["postedOnSecondAfterRestart"] as? Int ?? 0, 2,
                                    "a new keepalive-start must ping on the reconnected port")
        XCTAssertEqual(result["portCount"] as? Int, 2, "exactly one reconnect")
    }

    func testKeepAliveStatusIsReadOnly() async throws {
        // The callAsyncJavaScript body is sloppy mode, so the write to the frozen
        // status object silently no-ops rather than throwing.
        let result = try await evalDictionary("""
        const status = globalThis.__detourNativePortKeepAlive;
        status.armed = true;
        status.installMode = 'hijacked';
        return JSON.stringify({ armed: status.armed, installMode: status.installMode });
        """)

        XCTAssertEqual(result["armed"] as? Bool, false, "the status object must not be writable")
        XCTAssertEqual(result["installMode"] as? String, "port")
    }

    /// Only an extension that declares `nativeMessaging` can ever have a native
    /// host, so for every other worker the keep-alive would open a port that stays
    /// idle for the worker's whole life — and moves it off WebKit's 30 s idle
    /// unload onto the 2-minute inactive-ports path for nothing (TASK-16).
    func testKeepAliveNotInstalledWithoutNativeMessagingPermission() async throws {
        let noNativeMessaging = try await makeWebView(manifestPermissions: ["history", "management"])

        let status = try await keepAliveStatus(on: noNativeMessaging)
        XCTAssertEqual(status["installMode"] as? String, "none")
        XCTAssertEqual(status["installDetail"] as? String, "no-nativeMessaging-permission")
        XCTAssertEqual(status["armed"] as? Bool, false)
        XCTAssertEqual(status["applications"] as? [String], [],
                       "no port may be opened for an extension that cannot use native messaging")
    }

    /// Only the background context holds a keep-alive port: Detour keeps one per
    /// extension, so a popup or options page opening its own would evict the
    /// background's. Ordinary page contexts install nothing at all — and since
    /// TASK-62 a background *page* is a background context, which this fixture's
    /// page is not: its manifest declares no `background` entry at all.
    func testKeepAliveIsNotInstalledOutsideABackgroundContext() async throws {
        let pageView = try await makeWebView(
            manifestPermissions: ["history"],
            // Runs after the shim set the flag and before the polyfill reads it.
            shimExtras: "globalThis.__detourForceNativePortKeepAlive = false;")

        let status = try await keepAliveStatus(on: pageView)
        XCTAssertEqual(status["installMode"] as? String, "none")
        XCTAssertEqual(status["installDetail"] as? String, "not-a-background-context")
        XCTAssertEqual(status["armed"] as? Bool, false)
        XCTAssertEqual(status["applications"] as? [String], [],
                       "a page context must not open a port to Detour")
    }

    /// Nothing is wrapped, bound or replaced any more: the namespace, its runtime
    /// and `connectNative` must be exactly what the environment provided (TASK-15).
    func testKeepAliveLeavesConnectNativeAndTheGlobalsUntouched() async throws {
        let result = try await evalDictionary("""
        return JSON.stringify({
            chromeIsShim: globalThis.chrome === globalThis.__shimChrome,
            runtimeIsShim: chrome.runtime === globalThis.__shimRuntime,
            connectNativeIsShim: chrome.runtime.connectNative === globalThis.__shimConnectNative
        });
        """)

        XCTAssertEqual(result["chromeIsShim"] as? Bool, true, "the chrome global must not be replaced")
        XCTAssertEqual(result["runtimeIsShim"] as? Bool, true, "chrome.runtime must not be swapped for a stand-in")
        XCTAssertEqual(result["connectNativeIsShim"] as? Bool, true,
                       "connectNative must be called, never wrapped")
    }

    // MARK: - Keep-alive must never replace the chrome/browser globals

    /// Builds a page whose `chrome`/`browser` namespace is one shared object under
    /// both names, with a `runtime` whose `connectNative` cannot be patched: it is
    /// a getter-only accessor on the prototype (assignment cannot replace it) and
    /// the runtime is non-extensible (defineProperty cannot add an own override).
    /// This is the shape WebKit's own namespace has, in which any attempt to
    /// observe `connectNative` calls fails and a stand-in is tempting.
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
            // The keep-alive only installs for extensions declaring nativeMessaging.
            realRuntime.getManifest = function() {
                return { manifest_version: 3, permissions: ['nativeMessaging'] };
            };
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
    /// The keep-alive only ever *calls* `connectNative`: even on a namespace where
    /// nothing can be patched, the globals, the runtime and connectNative must be
    /// left exactly as found and the port must still open (TASK-16).
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
                    armed: globalThis.__detourNativePortKeepAlive.armed,
                    openedApplications: globalThis.__fakeNativePorts.map(p => p.application),
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
        XCTAssertEqual(result["connectNativeIsNative"] as? Bool, true, "connectNative is called, never patched")
        XCTAssertEqual(result["installMode"] as? String, "port",
                       "calling connectNative needs no patching, so the keep-alive port opens here too")
        XCTAssertEqual(result["armed"] as? Bool, false, "nothing arms it but Detour")
        XCTAssertEqual(result["openedApplications"] as? [String], ["detourPolyfill"])
        XCTAssertEqual(result["listenerReachedRealEvent"] as? Bool, true, "onMessage.addListener must register on the real event object")
        XCTAssertEqual(result["getURL"] as? String, "webkit-extension://0000/x.html", "later polyfill patches (getURL) still work")
        withExtendedLifetime(wv) {}
    }

    // MARK: - WebSocket relay (TASK-8)

    /// The relay normally installs only in service worker contexts; the test shim
    /// sets `__detourForceWebSocketRelay` before the polyfill loads so these run
    /// against the page context, with the shim's fake `connectNative` standing in
    /// for Detour's relay host.

    /// JS prelude for the relay tests: the fake native ports opened for the relay
    /// host (the keep-alive holds one to `detourPolyfill`, which these must skip).
    private static let relayHelpersJS = """
    const relayPorts = () => globalThis.__fakeNativePorts.filter(p => p.application === 'detourWebSocketRelay');
    const relayPort = (i) => relayPorts()[i === undefined ? relayPorts().length - 1 : i];

    """

    private func evalRelay(_ js: String, on target: WKWebView? = nil) async throws -> [String: Any] {
        try await evalDictionary(Self.relayHelpersJS + js, on: target)
    }

    /// A context whose `connectNative` is missing, so every socket takes the
    /// guard fallback (the TASK-2 behaviour: fail asynchronously, never deadlock).
    private func makeGuardFallbackWebView() async throws -> WKWebView {
        try await makeWebView(
            manifestPermissions: ["history", "nativeMessaging"],
            // Runs after the shim installed the fake connectNative and before the
            // polyfill reads it.
            shimExtras: "delete globalThis.chrome.runtime.connectNative;")
    }

    func testWebSocketRelayInstallsAndOpensARelayPort() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/notify', ['p1', 'p2']);
        const port = relayPort();
        return JSON.stringify({
            relayed: WebSocket.__detourRelay === true,
            nativeType: typeof globalThis.__detourNativeWebSocket,
            nativeIsReplaced: globalThis.__detourNativeWebSocket !== WebSocket,
            statics: [WebSocket.CONNECTING, WebSocket.OPEN, WebSocket.CLOSING, WebSocket.CLOSED],
            onInstance: [socket.CONNECTING, socket.OPEN, socket.CLOSING, socket.CLOSED],
            mode: globalThis.__detourWebSocketRelay.mode,
            openSockets: globalThis.__detourWebSocketRelay.openSockets,
            portCount: relayPorts().length,
            posted: port ? port.posted : null,
            url: socket.url,
            readyState: socket.readyState,
            protocol: socket.protocol,
            extensions: socket.extensions,
            binaryType: socket.binaryType,
            bufferedAmount: socket.bufferedAmount
        });
        """)

        XCTAssertEqual(result["relayed"] as? Bool, true,
                       "globalThis.WebSocket should be the relay, not the native constructor")
        XCTAssertEqual(result["nativeType"] as? String, "function",
                       "the native constructor should be kept at __detourNativeWebSocket")
        XCTAssertEqual(result["nativeIsReplaced"] as? Bool, true)
        XCTAssertEqual(result["statics"] as? [Int], [0, 1, 2, 3])
        XCTAssertEqual(result["onInstance"] as? [Int], [0, 1, 2, 3],
                       "the ready-state constants should also be on the prototype")
        XCTAssertEqual(result["mode"] as? String, "relay")
        XCTAssertEqual(result["openSockets"] as? Int, 1)
        XCTAssertEqual(result["portCount"] as? Int, 1,
                       "one socket opens exactly one port to the relay host")
        XCTAssertEqual(result["url"] as? String, "wss://example.invalid/notify")
        XCTAssertEqual(result["readyState"] as? Int, 0)
        XCTAssertEqual(result["protocol"] as? String, "")
        XCTAssertEqual(result["extensions"] as? String, "")
        XCTAssertEqual(result["binaryType"] as? String, "blob")
        XCTAssertEqual(result["bufferedAmount"] as? Int, 0)

        let posted = try XCTUnwrap(result["posted"] as? [[String: Any]])
        XCTAssertEqual(posted.count, 1, "constructing must post exactly one op")
        XCTAssertEqual(posted.first?["op"] as? String, "open")
        XCTAssertEqual(posted.first?["url"] as? String, "wss://example.invalid/notify")
        XCTAssertEqual(posted.first?["protocols"] as? [String], ["p1", "p2"])
    }

    func testWebSocketRelayRejectsInvalidURLs() async throws {
        let result = try await evalRelay("""
        function attempt(u) {
            try { new WebSocket(u); return { threw: false, name: null }; }
            catch (e) { return { threw: true, name: e.name }; }
        }
        return JSON.stringify({
            garbage: attempt('not a url'),
            ftp: attempt('ftp://example.invalid/'),
            fragment: attempt('wss://example.invalid/x#frag'),
            ok: attempt('wss://example.invalid/x'),
            httpRewritten: new WebSocket('http://example.invalid/y').url,
            httpsRewritten: new WebSocket('https://example.invalid/z').url,
            stringProtocol: relayPort().posted[0].protocols
        });
        """)

        for key in ["garbage", "ftp", "fragment"] {
            let attempt = try XCTUnwrap(result[key] as? [String: Any], key)
            XCTAssertEqual(attempt["threw"] as? Bool, true, "\(key) must throw")
            XCTAssertEqual(attempt["name"] as? String, "SyntaxError", key)
        }
        XCTAssertEqual((result["ok"] as? [String: Any])?["threw"] as? Bool, false)
        XCTAssertEqual(result["httpRewritten"] as? String, "ws://example.invalid/y",
                       "http: is rewritten to ws:, as browsers do")
        XCTAssertEqual(result["httpsRewritten"] as? String, "wss://example.invalid/z")
    }

    func testWebSocketRelayNormalizesAStringProtocol() async throws {
        let result = try await evalRelay("""
        new WebSocket('wss://example.invalid/', 'chat.v1');
        return JSON.stringify({ posted: relayPort().posted });
        """)
        let posted = try XCTUnwrap(result["posted"] as? [[String: Any]])
        XCTAssertEqual(posted.first?["protocols"] as? [String], ["chat.v1"],
                       "a single protocol string must be sent as a one-element list")
    }

    func testWebSocketRelaySendWhileConnectingThrowsInvalidState() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        let threw = false, name = null;
        try { socket.send('x'); } catch (e) { threw = true; name = e.name; }
        return JSON.stringify({
            threw: threw, name: name, readyState: socket.readyState,
            posted: relayPort().posted.length
        });
        """)

        XCTAssertEqual(result["threw"] as? Bool, true, "send() while CONNECTING must throw")
        XCTAssertEqual(result["name"] as? String, "InvalidStateError")
        XCTAssertEqual(result["readyState"] as? Int, 0)
        XCTAssertEqual(result["posted"] as? Int, 1, "only the open op should have been posted")
    }

    func testWebSocketRelayOpensOnTheNativeOpenMessage() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        let handlerCalls = 0, listenerCalls = 0;
        socket.onopen = () => { handlerCalls += 1; };
        socket.addEventListener('open', () => { listenerCalls += 1; });
        relayPort().__simulateNativeMessage({ op: 'open', protocol: 'chat.v1', extensions: '' });
        return JSON.stringify({
            readyState: socket.readyState,
            handlerCalls: handlerCalls,
            listenerCalls: listenerCalls,
            protocol: socket.protocol,
            openSockets: globalThis.__detourWebSocketRelay.openSockets
        });
        """)

        XCTAssertEqual(result["readyState"] as? Int, 1)
        XCTAssertEqual(result["handlerCalls"] as? Int, 1, "onopen should be invoked once")
        XCTAssertEqual(result["listenerCalls"] as? Int, 1)
        XCTAssertEqual(result["protocol"] as? String, "chat.v1",
                       "the negotiated subprotocol comes back from native")
        XCTAssertEqual(result["openSockets"] as? Int, 1)
    }

    func testWebSocketRelayDeliversTextMessages() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        const port = relayPort();
        port.__simulateNativeMessage({ op: 'open', protocol: '', extensions: '' });
        const received = [];
        socket.onmessage = (e) => { received.push({ type: typeof e.data, data: e.data }); };
        port.__simulateNativeMessage({ op: 'message', text: 'hello worker' });
        port.__simulateNativeMessage({ op: 'message', text: '' });
        return JSON.stringify({ received: received });
        """)

        let received = try XCTUnwrap(result["received"] as? [[String: Any]])
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.first?["type"] as? String, "string")
        XCTAssertEqual(received.first?["data"] as? String, "hello worker")
        XCTAssertEqual(received.last?["data"] as? String, "")
    }

    func testWebSocketRelayDeliversBinaryMessagesPerBinaryType() async throws {
        let result = try await evalRelay("""
        // 0x01 0x02 0xFA 0xFF — bytes that are not valid UTF-8 on their own.
        const base64 = btoa(String.fromCharCode(1, 2, 250, 255));

        const asBuffer = new WebSocket('wss://example.invalid/a');
        const bufferPort = relayPort();
        asBuffer.binaryType = 'arraybuffer';
        bufferPort.__simulateNativeMessage({ op: 'open' });
        let bufferData = null, bufferIsArrayBuffer = null;
        asBuffer.onmessage = (e) => {
            bufferIsArrayBuffer = e.data instanceof ArrayBuffer;
            bufferData = Array.from(new Uint8Array(e.data));
        };
        bufferPort.__simulateNativeMessage({ op: 'message', binary: base64 });

        const asBlob = new WebSocket('wss://example.invalid/b');
        const blobPort = relayPort();
        blobPort.__simulateNativeMessage({ op: 'open' });
        let blobIsBlob = null, blobBytes = null;
        const blobDelivered = new Promise((resolve) => {
            asBlob.onmessage = async (e) => {
                blobIsBlob = typeof Blob !== 'undefined' && e.data instanceof Blob;
                blobBytes = Array.from(new Uint8Array(await e.data.arrayBuffer()));
                resolve();
            };
        });
        blobPort.__simulateNativeMessage({ op: 'message', binary: base64 });
        await blobDelivered;

        return JSON.stringify({
            base64: base64,
            bufferIsArrayBuffer: bufferIsArrayBuffer,
            bufferData: bufferData,
            blobIsBlob: blobIsBlob,
            blobBytes: blobBytes,
            defaultBinaryType: asBlob.binaryType
        });
        """)

        XCTAssertEqual(result["bufferIsArrayBuffer"] as? Bool, true,
                       "binaryType 'arraybuffer' must deliver an ArrayBuffer")
        XCTAssertEqual(result["bufferData"] as? [Int], [1, 2, 250, 255],
                       "the base64 payload must round-trip byte for byte")
        XCTAssertEqual(result["defaultBinaryType"] as? String, "blob")
        XCTAssertEqual(result["blobIsBlob"] as? Bool, true)
        XCTAssertEqual(result["blobBytes"] as? [Int], [1, 2, 250, 255])
    }

    func testWebSocketRelayPostsSendOpsForEveryDataType() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        const port = relayPort();
        port.__simulateNativeMessage({ op: 'open' });
        socket.send('hi');
        socket.send(new Uint8Array([1, 2, 3]).buffer);
        // A view with a non-zero offset: only its own bytes may be sent.
        socket.send(new Uint8Array([9, 8, 7, 6]).subarray(1, 3));
        const blob = new Blob([new Uint8Array([1, 2])]);
        socket.send(blob);
        const bufferedWhileReading = socket.bufferedAmount;
        await new Promise((r) => setTimeout(r, 50));
        return JSON.stringify({
            posted: port.posted,
            bufferedWhileReading: bufferedWhileReading,
            bufferedAfter: socket.bufferedAmount
        });
        """)

        let posted = try XCTUnwrap(result["posted"] as? [[String: Any]])
        XCTAssertEqual(posted.count, 5, "open + four sends, got: \(posted)")
        XCTAssertEqual(posted[1]["op"] as? String, "send")
        XCTAssertEqual(posted[1]["text"] as? String, "hi")
        XCTAssertEqual(posted[2]["binary"] as? String, "AQID", "ArrayBuffer -> base64")
        XCTAssertEqual(posted[3]["binary"] as? String, "CAc=",
                       "a view must send only the bytes it covers")
        XCTAssertEqual(posted[4]["binary"] as? String, "AQI=", "Blob -> base64, asynchronously")
        XCTAssertEqual(result["bufferedWhileReading"] as? Int, 2,
                       "a Blob still being read counts towards bufferedAmount")
        XCTAssertEqual(result["bufferedAfter"] as? Int, 0)
    }

    /// A Blob's bytes only arrive a microtask later, so a frame sent behind one
    /// must not overtake it: every send goes through one FIFO and the drain loop
    /// waits at a pending Blob.
    func testWebSocketRelaySendQueueKeepsFrameOrderAcrossABlob() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        const port = relayPort();
        port.__simulateNativeMessage({ op: 'open' });
        socket.send('first');
        socket.send(new Blob([new Uint8Array([1, 2])]));
        socket.send('ack');
        socket.send(new Uint8Array([3, 4, 5]).buffer);
        const postedImmediately = port.posted.length;
        const bufferedWhileReading = socket.bufferedAmount;
        await new Promise((r) => setTimeout(r, 50));
        return JSON.stringify({
            postedImmediately: postedImmediately,
            bufferedWhileReading: bufferedWhileReading,
            posted: port.posted,
            bufferedAfter: socket.bufferedAmount
        });
        """)

        XCTAssertEqual(result["postedImmediately"] as? Int, 2,
                       "only open and the first text frame can post before the Blob is read")
        XCTAssertEqual(result["bufferedWhileReading"] as? Int, 8,
                       "the Blob (2) and the two frames queued behind it (3 + 3) are outstanding")

        let posted = try XCTUnwrap(result["posted"] as? [[String: Any]])
        XCTAssertEqual(posted.count, 5, "open + four sends, got: \(posted)")
        XCTAssertEqual(posted[1]["text"] as? String, "first")
        XCTAssertEqual(posted[2]["binary"] as? String, "AQI=",
                       "the Blob must post before anything sent after it: \(posted)")
        XCTAssertEqual(posted[3]["text"] as? String, "ack")
        XCTAssertEqual(posted[4]["binary"] as? String, "AwQF")
        XCTAssertEqual(result["bufferedAfter"] as? Int, 0)
    }

    /// A real socket flushes what is buffered during the closing handshake, so a
    /// Blob still being read when `close()` runs must still be sent — and the
    /// close must land behind it.
    func testWebSocketRelayCloseFlushesAPendingBlob() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        const port = relayPort();
        port.__simulateNativeMessage({ op: 'open' });
        socket.send(new Blob([new Uint8Array([7, 8])]));
        socket.close(1000, 'bye');
        const stateAfterClose = socket.readyState;
        const postedImmediately = port.posted.length;
        await new Promise((r) => setTimeout(r, 50));
        return JSON.stringify({
            stateAfterClose: stateAfterClose,
            postedImmediately: postedImmediately,
            posted: port.posted
        });
        """)

        XCTAssertEqual(result["stateAfterClose"] as? Int, 2, "close() must move to CLOSING at once")
        XCTAssertEqual(result["postedImmediately"] as? Int, 1,
                       "only the open op: the close waits behind the Blob")

        let posted = try XCTUnwrap(result["posted"] as? [[String: Any]])
        XCTAssertEqual(posted.count, 3, "open + the flushed Blob + the close, got: \(posted)")
        XCTAssertEqual(posted[1]["op"] as? String, "send")
        XCTAssertEqual(posted[1]["binary"] as? String, "Bwg=",
                       "a Blob still being read when close() ran must not be dropped")
        XCTAssertEqual(posted[2]["op"] as? String, "close")
        XCTAssertEqual(posted[2]["code"] as? Int, 1000)
        XCTAssertEqual(posted[2]["reason"] as? String, "bye")
    }

    /// `close()` with no code closes with *no status*: the op must carry no code
    /// at all (native turns that into 1005), not a 1000 the caller never chose.
    func testWebSocketRelayCloseWithoutACodeOmitsIt() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        const port = relayPort();
        port.__simulateNativeMessage({ op: 'open' });
        let closeEvent = null;
        socket.onclose = (e) => { closeEvent = { code: e.code, reason: e.reason, wasClean: e.wasClean }; };
        socket.close();
        const closeOp = port.posted[port.posted.length - 1];
        const has = (k) => Object.prototype.hasOwnProperty.call(closeOp, k);
        port.__simulateNativeMessage({ op: 'close', code: 1005, reason: '', wasClean: true });
        return JSON.stringify({
            closeOp: closeOp,
            hasCode: has('code'),
            hasReason: has('reason'),
            closeEvent: closeEvent
        });
        """)

        XCTAssertEqual((result["closeOp"] as? [String: Any])?["op"] as? String, "close")
        XCTAssertEqual(result["hasCode"] as? Bool, false,
                       "an omitted code must stay omitted on the wire: \(result["closeOp"] ?? "-")")
        XCTAssertEqual(result["hasReason"] as? Bool, false)

        let closeEvent = try XCTUnwrap(result["closeEvent"] as? [String: Any])
        XCTAssertEqual(closeEvent["code"] as? Int, 1005,
                       "close() with no code reports 'no status received'")
        XCTAssertEqual(closeEvent["reason"] as? String, "")
    }

    func testWebSocketRelayValidatesCloseArguments() async throws {
        let result = try await evalRelay("""
        function attempt(fn) {
            try { fn(); return { threw: false, name: null }; }
            catch (e) { return { threw: true, name: e.name }; }
        }
        const socket = () => new WebSocket('wss://example.invalid/');
        return JSON.stringify({
            tooLow: attempt(() => socket().close(999)),
            reserved: attempt(() => socket().close(1006)),
            normal: attempt(() => socket().close(1000)),
            appRange: attempt(() => socket().close(3500)),
            noArguments: attempt(() => socket().close()),
            // WebIDL converts null to 0, which is not a permitted close code —
            // only an omitted argument means "no code".
            nullCode: attempt(() => socket().close(null)),
            longReason: attempt(() => socket().close(1000, 'x'.repeat(124))),
            maxReason: attempt(() => socket().close(1000, 'x'.repeat(123))),
            multiByteReason: attempt(() => socket().close(1000, '\\u00e9'.repeat(62)))
        });
        """)

        func check(_ key: String, throws expected: String?) throws {
            let attempt = try XCTUnwrap(result[key] as? [String: Any], key)
            XCTAssertEqual(attempt["threw"] as? Bool, expected != nil, key)
            XCTAssertEqual(attempt["name"] as? String, expected, key)
        }
        try check("tooLow", throws: "InvalidAccessError")
        try check("reserved", throws: "InvalidAccessError")
        try check("normal", throws: nil)
        try check("appRange", throws: nil)
        try check("noArguments", throws: nil)
        try check("nullCode", throws: "InvalidAccessError")
        try check("longReason", throws: "SyntaxError")
        try check("maxReason", throws: nil)
        try check("multiByteReason", throws: "SyntaxError")
    }

    func testWebSocketRelayCloseRoundTripsThroughNative() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        const port = relayPort();
        port.__simulateNativeMessage({ op: 'open' });
        const events = [];
        let closeEvent = null;
        socket.addEventListener('error', () => events.push('error'));
        socket.onclose = (e) => {
            events.push('close');
            closeEvent = { code: e.code, reason: e.reason, wasClean: e.wasClean };
        };
        socket.close(1000, 'bye');
        const stateWhileClosing = socket.readyState;
        const postedWhileClosing = port.posted.slice();
        const disconnectedWhileClosing = port.disconnectedLocally;
        port.__simulateNativeMessage({ op: 'close', code: 1000, reason: 'bye', wasClean: true });
        return JSON.stringify({
            stateWhileClosing: stateWhileClosing,
            postedWhileClosing: postedWhileClosing,
            disconnectedWhileClosing: disconnectedWhileClosing,
            finalState: socket.readyState,
            events: events,
            closeEvent: closeEvent,
            disconnected: port.disconnectedLocally,
            openSockets: globalThis.__detourWebSocketRelay.openSockets
        });
        """)

        XCTAssertEqual(result["stateWhileClosing"] as? Int, 2,
                       "close() must move the socket to CLOSING and wait for native")
        let posted = try XCTUnwrap(result["postedWhileClosing"] as? [[String: Any]])
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted[1]["op"] as? String, "close")
        XCTAssertEqual(posted[1]["code"] as? Int, 1000)
        XCTAssertEqual(posted[1]["reason"] as? String, "bye")
        XCTAssertEqual(result["disconnectedWhileClosing"] as? Bool, false,
                       "the port must stay open until native answers")
        XCTAssertEqual(result["finalState"] as? Int, 3)
        XCTAssertEqual(result["events"] as? [String], ["close"],
                       "a clean close must not fire an error event")
        let closeEvent = try XCTUnwrap(result["closeEvent"] as? [String: Any])
        XCTAssertEqual(closeEvent["code"] as? Int, 1000)
        XCTAssertEqual(closeEvent["reason"] as? String, "bye")
        XCTAssertEqual(closeEvent["wasClean"] as? Bool, true)
        XCTAssertEqual(result["disconnected"] as? Bool, true,
                       "the relay port is released once the socket is closed")
        XCTAssertEqual(result["openSockets"] as? Int, 0)
    }

    func testWebSocketRelayForwardsANativeError() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        const port = relayPort();
        const events = [];
        let closeEvent = null;
        socket.onerror = () => events.push('error');
        socket.onclose = (e) => {
            events.push('close');
            closeEvent = { code: e.code, reason: e.reason, wasClean: e.wasClean };
        };
        port.__simulateNativeMessage({ op: 'error', message: 'connection refused' });
        port.__simulateNativeMessage({ op: 'close', code: 1006, reason: 'connection refused', wasClean: false });
        return JSON.stringify({
            events: events, closeEvent: closeEvent, readyState: socket.readyState,
            disconnected: port.disconnectedLocally
        });
        """)

        XCTAssertEqual(result["events"] as? [String], ["error", "close"])
        let closeEvent = try XCTUnwrap(result["closeEvent"] as? [String: Any])
        XCTAssertEqual(closeEvent["code"] as? Int, 1006)
        XCTAssertEqual(closeEvent["wasClean"] as? Bool, false)
        XCTAssertEqual(result["readyState"] as? Int, 3)
        XCTAssertEqual(result["disconnected"] as? Bool, true)
    }

    /// Detour dropping the port (context unload, a relay session torn down) must
    /// look to the extension like a socket that died: error, then close 1006.
    func testWebSocketRelayPortDisconnectFailsTheSocket() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        const port = relayPort();
        port.__simulateNativeMessage({ op: 'open' });
        const events = [];
        let closeEvent = null;
        socket.onerror = () => events.push('error');
        socket.onclose = (e) => {
            events.push('close');
            closeEvent = { code: e.code, reason: e.reason, wasClean: e.wasClean };
        };
        port.__simulateRemoteDisconnect();
        return JSON.stringify({
            events: events, closeEvent: closeEvent, readyState: socket.readyState,
            openSockets: globalThis.__detourWebSocketRelay.openSockets
        });
        """)

        XCTAssertEqual(result["events"] as? [String], ["error", "close"])
        let closeEvent = try XCTUnwrap(result["closeEvent"] as? [String: Any])
        XCTAssertEqual(closeEvent["code"] as? Int, 1006)
        XCTAssertEqual(closeEvent["reason"] as? String, "")
        XCTAssertEqual(closeEvent["wasClean"] as? Bool, false)
        XCTAssertEqual(result["readyState"] as? Int, 3)
        XCTAssertEqual(result["openSockets"] as? Int, 0)
    }

    func testWebSocketRelayDoesNotAffectEventTargetSemantics() async throws {
        let result = try await evalRelay("""
        const socket = new WebSocket('wss://example.invalid/');
        const port = relayPort();
        let removedCalls = 0, keptCalls = 0;
        const removed = () => { removedCalls += 1; };
        socket.addEventListener('close', removed);
        socket.addEventListener('close', () => { keptCalls += 1; });
        socket.removeEventListener('close', removed);
        port.__simulateRemoteDisconnect();
        return JSON.stringify({ removedCalls: removedCalls, keptCalls: keptCalls });
        """)

        XCTAssertEqual(result["removedCalls"] as? Int, 0,
                       "a listener removed before the failure must not be called")
        XCTAssertEqual(result["keptCalls"] as? Int, 1)
    }

    func testWebSocketRelayStatusIsReadOnly() async throws {
        // The callAsyncJavaScript body is sloppy mode, so the write to the frozen
        // status object silently no-ops rather than throwing.
        let result = try await evalRelay("""
        const status = globalThis.__detourWebSocketRelay;
        status.mode = 'hijacked';
        status.openSockets = 99;
        return JSON.stringify({ mode: status.mode, openSockets: status.openSockets });
        """)

        XCTAssertEqual(result["mode"] as? String, "relay", "the status object must not be writable")
        XCTAssertEqual(result["openSockets"] as? Int, 0)
    }

    /// Page contexts (popups, options pages, content scripts) run on their own
    /// thread and never deadlocked: they keep the real WebSocket.
    func testWebSocketRelayNotInstalledOutsideAWorker() async throws {
        let pageView = try await makeWebView(
            manifestPermissions: ["history"],
            shimExtras: "globalThis.__detourForceWebSocketRelay = false;")

        let result = try await evalDictionary("""
        return JSON.stringify({
            relayed: WebSocket.__detourRelay === true,
            isNativeConstructor: WebSocket === globalThis.__detourNativeWebSocket || globalThis.__detourNativeWebSocket === undefined,
            statusType: typeof globalThis.__detourWebSocketRelay,
            diag: __detourPolyfillDiag.apis.webSocket
        });
        """, on: pageView)

        XCTAssertEqual(result["relayed"] as? Bool, false, "a page context keeps the native WebSocket")
        XCTAssertEqual(result["isNativeConstructor"] as? Bool, true,
                       "nothing was installed, so nothing was stashed either")
        XCTAssertEqual(result["statusType"] as? String, "undefined")
        XCTAssertEqual(result["diag"] as? String, "native")
    }

    func testWebSocketRelayReportsItsModeInTheDiagnostics() async throws {
        let relayDiag = try await eval("return __detourPolyfillDiag.apis.webSocket") as? String
        XCTAssertEqual(relayDiag, "relay")

        let guardView = try await makeGuardFallbackWebView()
        let guardDiag = try await eval("return __detourPolyfillDiag.apis.webSocket", on: guardView) as? String
        XCTAssertEqual(guardDiag, "guard",
                       "without a relay host the module reports the fallback it installed")
    }

    // MARK: - WebSocket guard fallback (no relay host)

    /// Without `connectNative` there is no relay, and a real `WebSocket` would
    /// deadlock the worker (TASK-2), so the socket fails asynchronously instead:
    /// an `error` then a `close` with code 1006, the path extensions already
    /// handle for an unreachable server.

    func testWebSocketGuardFallbackFailsAsynchronously() async throws {
        let guardView = try await makeGuardFallbackWebView()
        let result = try await evalRelay("""
        const events = [];
        const socket = new WebSocket('wss://example.invalid/notify');
        const stateAtConstruction = socket.readyState;
        let closeCode = null, closeWasClean = null;
        socket.addEventListener('error', (e) => events.push(e.type));
        socket.addEventListener('close', (e) => {
            events.push(e.type);
            closeCode = e.code;
            closeWasClean = e.wasClean;
        });
        await new Promise((r) => setTimeout(r, 50));
        return JSON.stringify({
            mode: globalThis.__detourWebSocketRelay.mode,
            relayPortCount: relayPorts().length,
            url: socket.url,
            stateAtConstruction: stateAtConstruction,
            stateAfterWait: socket.readyState,
            events: events,
            closeCode: closeCode,
            closeWasClean: closeWasClean
        });
        """, on: guardView)

        XCTAssertEqual(result["mode"] as? String, "guard")
        XCTAssertEqual(result["relayPortCount"] as? Int, 0, "there is no relay host to connect to")
        XCTAssertEqual(result["url"] as? String, "wss://example.invalid/notify")
        XCTAssertEqual(result["stateAtConstruction"] as? Int, 0)
        XCTAssertEqual(result["stateAfterWait"] as? Int, 3)
        XCTAssertEqual(result["events"] as? [String], ["error", "close"])
        XCTAssertEqual(result["closeCode"] as? Int, 1006)
        XCTAssertEqual(result["closeWasClean"] as? Bool, false)
    }

    /// The first socket in a context fails at once; each further one backs off by
    /// 250 ms so a client reconnecting straight from onclose cannot spin the worker.
    func testWebSocketGuardFallbackBacksOffRepeatedConnections() async throws {
        let guardView = try await makeGuardFallbackWebView()
        let result = try await evalDictionary("""
        const first = new WebSocket('wss://example.invalid/first');
        await new Promise((r) => setTimeout(r, 50));
        const firstAfter50 = first.readyState;

        const second = new WebSocket('wss://example.invalid/second');
        const third = new WebSocket('wss://example.invalid/third');
        await new Promise((r) => setTimeout(r, 50));
        const secondAfter50 = second.readyState;
        const thirdAfter50 = third.readyState;

        await new Promise((r) => setTimeout(r, 600));
        return JSON.stringify({
            firstAfter50: firstAfter50,
            secondAfter50: secondAfter50,
            thirdAfter50: thirdAfter50,
            secondAtEnd: second.readyState,
            thirdAtEnd: third.readyState
        });
        """, on: guardView)

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

    func testWebSocketGuardFallbackSendAfterCloseIsSilent() async throws {
        let guardView = try await makeGuardFallbackWebView()
        let result = try await evalDictionary("""
        const socket = new WebSocket('wss://example.invalid/');
        await new Promise((r) => setTimeout(r, 50));
        let threw = false;
        try { socket.send('x'); } catch (e) { threw = true; }
        return JSON.stringify({ threw: threw, readyState: socket.readyState });
        """, on: guardView)

        XCTAssertEqual(result["readyState"] as? Int, 3)
        XCTAssertEqual(result["threw"] as? Bool, false,
                       "send() after the socket closed should be a silent no-op, as in browsers")
    }

    func testWebSocketGuardFallbackExplicitCloseUsesGivenCode() async throws {
        let guardView = try await makeGuardFallbackWebView()
        let result = try await evalDictionary("""
        function watch(socket) {
            const record = { events: [], code: null, reason: null };
            socket.addEventListener('error', (e) => record.events.push(e.type));
            socket.addEventListener('close', (e) => {
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

        await new Promise((r) => setTimeout(r, 50));
        return JSON.stringify({
            withCode: withCodeRecord,
            withCodeReadyState: withCode.readyState,
            withoutCode: withoutCodeRecord,
            withoutCodeReadyState: withoutCode.readyState
        });
        """, on: guardView)

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

    func testWebSocketGuardFallbackWarnsOnce() async throws {
        let guardView = try await makeGuardFallbackWebView()
        let result = try await evalDictionary("""
        const originalWarn = console.warn;
        let warnings = 0;
        try {
            console.warn = function(...args) {
                if (args.some((a) => typeof a === 'string' && a.includes('WebSocket'))) warnings += 1;
            };
            new WebSocket('wss://example.invalid/one');
            new WebSocket('wss://example.invalid/two');
            await new Promise((r) => setTimeout(r, 50));
        } finally {
            console.warn = originalWarn;
        }
        return JSON.stringify({ warnings: warnings });
        """, on: guardView)

        XCTAssertEqual(result["warnings"] as? Int, 1,
                       "the fallback should warn once per context, not once per socket")
    }

    // MARK: - runtime.onInstalled (TASK-22)

    /// A web view running the worker's `runtime.onInstalled` module against a fake
    /// native event: `addListener`/`removeListener`/`hasListener` on the fake record
    /// natively registered listeners in `__nativeInstalledListeners`, and
    /// `__fireNativeInstalled(details)` plays WebKit dispatching its own event to
    /// them. `eventExpression` replaces how `chrome.runtime.onInstalled` is set up.
    private func makeInstalledEventWebView(force: Bool = true, eventExpression: String? = nil) async throws -> WKWebView {
        let makeEvent = """
        (() => ({
            addListener(fn) { globalThis.__nativeInstalledListeners.push(fn); },
            removeListener(fn) {
                const i = globalThis.__nativeInstalledListeners.indexOf(fn);
                if (i !== -1) globalThis.__nativeInstalledListeners.splice(i, 1);
            },
            hasListener(fn) { return globalThis.__nativeInstalledListeners.includes(fn); }
        }))
        """
        let install = eventExpression
            ?? "globalThis.__shimInstalledEvent = globalThis.__makeNativeInstalledEvent(); globalThis.chrome.runtime.onInstalled = globalThis.__shimInstalledEvent;"
        // This fixture stands in for the extension's background context, the
        // only one allowed to claim the event (TASK-64): register the manifest
        // background that makes one, and load the page at the path WebKit runs
        // it at, so the claim reaches native the way a real background page's
        // does. The shim's own `getManifest` still reports no background, so
        // the polyfill keeps classifying the context from
        // `__detourForceRuntimeOnInstalled` exactly as before. The fixture's
        // web view is a plain WKWebView the test makes and never hands to a
        // BrowserTab, a popup or an offscreen host, so it is absent from
        // `ExtensionPageHostRegistry` — exactly like WebKit's real background
        // view, which is what lets it pass the TASK-66 host check too.
        try reregisterSuiteExtension(background: ["scripts": ["background.js"]])
        return try await makeWebView(
            manifestPermissions: ["history", "management", "privacy", "webRequest", "nativeMessaging"],
            shimExtras: """
            globalThis.__nativeInstalledListeners = [];
            globalThis.__fireNativeInstalled = (details) => globalThis.__nativeInstalledListeners.slice().forEach(fn => fn(details));
            globalThis.__makeNativeInstalledEvent = \(makeEvent);
            \(force ? "globalThis.__detourForceRuntimeOnInstalled = true;" : "")
            \(install)
            """,
            baseURL: URL(string: "https://test.example.com\(ExtensionPolyfillHandler.generatedBackgroundPagePath)")!)
    }

    /// Re-register the suite's extension (setUp's permissions) with the given
    /// manifest `background`, for the background-context-only requests
    /// (TASK-64). tearDown removes the registration by id.
    private func reregisterSuiteExtension(background: [String: Any]) throws {
        ExtensionManager.shared.extensions.removeAll { $0.id == "test-polyfill-extension" }
        try registerExtension(id: "test-polyfill-extension",
                              permissions: ["history", "management", "privacy"],
                              background: background)
    }

    /// Put the ledger row for the suite's extension in the suite's profile at
    /// `version`, or remove it (nil: the event was never delivered there).
    private func setInstalledLedger(version: String?) throws {
        let profileID = profile.id.uuidString
        try AppDatabase.shared.dbQueue.write { db in
            try ExtensionInstalledEventRecord
                .filter(Column("extensionID") == "test-polyfill-extension" && Column("profileID") == profileID)
                .deleteAll(db)
            if let version {
                try ExtensionInstalledEventRecord(extensionID: "test-polyfill-extension", profileID: profileID,
                                                  deliveredVersion: version, deliveredAt: 0).insert(db)
            }
        }
    }

    /// Wait for the claim the module sends by itself at install to settle, so a
    /// test's own claim never races it.
    private func settleInstallClaim(on target: WKWebView) async throws {
        _ = try await eval("await new Promise((r) => setTimeout(r, 50));", on: target)
    }

    /// The extension's listeners live in Detour's list, not on WebKit's event, so
    /// WebKit's own dispatch — the spurious `install` on every same-version reload —
    /// never reaches them; and nothing but the event's methods was touched.
    func testRuntimeOnInstalledKeepsListenersOffWebKitsEvent() async throws {
        try setInstalledLedger(version: "1.0.0")
        defer { try? setInstalledLedger(version: nil) }
        let view = try await makeInstalledEventWebView()
        try await settleInstallClaim(on: view)

        let result = try await evalDictionary("""
        const calls = [];
        const listener = (details) => calls.push(details);
        chrome.runtime.onInstalled.addListener(listener);
        chrome.runtime.onInstalled.addListener(listener);
        globalThis.__fireNativeInstalled({ reason: 'install' });
        const status = globalThis.__detourRuntimeOnInstalled;
        let threw = false;
        try { chrome.runtime.onInstalled.addListener('not a function'); } catch (e) { threw = e instanceof TypeError; }
        const out = {
            mode: status.mode,
            detail: status.detail,
            holdsEvent: status.holdsEvent,
            calls: calls.length,
            nativeListeners: globalThis.__nativeInstalledListeners.length,
            hasListener: chrome.runtime.onInstalled.hasListener(listener),
            hasListeners: chrome.runtime.onInstalled.hasListeners(),
            listenerCount: status.listenerCount,
            sameEvent: chrome.runtime.onInstalled === globalThis.__shimInstalledEvent,
            sameRuntime: chrome.runtime === globalThis.__shimRuntime,
            threwForNonFunction: threw
        };
        chrome.runtime.onInstalled.removeListener(listener);
        out.hasListenerAfterRemove = chrome.runtime.onInstalled.hasListener(listener);
        return JSON.stringify(out);
        """, on: view)

        XCTAssertEqual(result["mode"] as? String, "detour")
        XCTAssertEqual(result["detail"] as? String, "")
        XCTAssertEqual(result["holdsEvent"] as? Bool, true, "the patched wrapper must be held strongly")
        XCTAssertEqual(result["calls"] as? Int, 0, "WebKit's own dispatch must not reach the extension")
        XCTAssertEqual(result["nativeListeners"] as? Int, 0, "no listener may be registered on WebKit's event")
        XCTAssertEqual(result["hasListener"] as? Bool, true)
        XCTAssertEqual(result["hasListeners"] as? Bool, true)
        XCTAssertEqual(result["listenerCount"] as? Int, 1, "adding the same listener twice keeps one")
        XCTAssertEqual(result["sameEvent"] as? Bool, true, "the event object is patched in place, not replaced")
        XCTAssertEqual(result["sameRuntime"] as? Bool, true, "chrome.runtime must not be replaced (TASK-15)")
        XCTAssertEqual(result["threwForNonFunction"] as? Bool, true)
        XCTAssertEqual(result["hasListenerAfterRemove"] as? Bool, false)
    }

    /// Owed an update: the claim delivers `update` with the previous version to
    /// every listener exactly once, and a second claim — a restarted worker, or
    /// this one again — gets nothing. The ledger then says nothing is owed.
    func testRuntimeOnInstalledClaimDeliversAnOwedUpdateExactlyOnce() async throws {
        try setInstalledLedger(version: "1.0.0")
        defer { try? setInstalledLedger(version: nil) }
        let view = try await makeInstalledEventWebView()
        try await settleInstallClaim(on: view)
        try setInstalledLedger(version: "0.9.0")

        let result = try await evalDictionary("""
        const first = [], second = [];
        chrome.runtime.onInstalled.addListener((d) => first.push(d));
        chrome.runtime.onInstalled.addListener((d) => { second.push(d); throw new Error('listener failure is contained'); });
        const status = globalThis.__detourRuntimeOnInstalled;
        const claimed = await status.claim();
        const again = await status.claim();
        return JSON.stringify({ claimed, again, first, second });
        """, on: view)

        XCTAssertEqual(result["claimed"] as? [String: String], ["reason": "update", "previousVersion": "0.9.0"])
        XCTAssertTrue(result["again"] is NSNull, "a second claim must deliver nothing, got \(result["again"] ?? "nil")")
        XCTAssertEqual(result["first"] as? [[String: String]], [["reason": "update", "previousVersion": "0.9.0"]])
        XCTAssertEqual(result["second"] as? [[String: String]], [["reason": "update", "previousVersion": "0.9.0"]])
        XCTAssertNil(AppDatabase.shared.pendingRuntimeInstalledEvent(
            extensionID: "test-polyfill-extension", profileID: profile.id.uuidString, isPrivateProfile: false, currentVersion: "1.0.0"))
    }

    /// A throwing listener does not keep the event from the listeners after it.
    func testRuntimeOnInstalledListenerErrorIsContained() async throws {
        try setInstalledLedger(version: "1.0.0")
        defer { try? setInstalledLedger(version: nil) }
        let view = try await makeInstalledEventWebView()
        try await settleInstallClaim(on: view)
        try setInstalledLedger(version: nil)

        let result = try await evalDictionary("""
        const later = [];
        chrome.runtime.onInstalled.addListener(() => { throw new Error('first listener fails'); });
        chrome.runtime.onInstalled.addListener((d) => later.push(d));
        await globalThis.__detourRuntimeOnInstalled.claim();
        return JSON.stringify({ later });
        """, on: view)

        XCTAssertEqual(result["later"] as? [[String: String]], [["reason": "install"]])
    }

    /// Never delivered in this profile: the claim the module sends by itself at
    /// install delivers `install`, without `previousVersion`.
    func testRuntimeOnInstalledInstallIsClaimedAtStartup() async throws {
        try setInstalledLedger(version: nil)
        defer { try? setInstalledLedger(version: nil) }
        let view = try await makeInstalledEventWebView()
        try await settleInstallClaim(on: view)

        let result = try await evalDictionary("""
        const status = globalThis.__detourRuntimeOnInstalled;
        return JSON.stringify({ lastDispatched: status.lastDispatched, claimCount: status.claimCount, again: await status.claim() });
        """, on: view)

        XCTAssertEqual(result["lastDispatched"] as? [String: String], ["reason": "install"])
        XCTAssertEqual(result["claimCount"] as? Int, 1, "one claim per worker start")
        XCTAssertTrue(result["again"] is NSNull)
    }

    /// Same version as delivered (a reload, relaunch or re-enable): nothing.
    func testRuntimeOnInstalledNothingOwedForTheDeliveredVersion() async throws {
        try setInstalledLedger(version: "1.0.0")
        defer { try? setInstalledLedger(version: nil) }
        let view = try await makeInstalledEventWebView()
        try await settleInstallClaim(on: view)

        let result = try await evalDictionary("""
        const status = globalThis.__detourRuntimeOnInstalled;
        return JSON.stringify({ lastDispatched: status.lastDispatched, claimCount: status.claimCount, again: await status.claim() });
        """, on: view)

        XCTAssertTrue(result["lastDispatched"] is NSNull)
        XCTAssertEqual(result["claimCount"] as? Int, 1)
        XCTAssertTrue(result["again"] is NSNull)
    }

    /// Outside a worker — an extension page — WebKit's event is hidden too (TASK-29):
    /// listeners are kept off the native event, WebKit's dispatch reaches none of
    /// them, and the page never claims or receives Detour's event, which is the
    /// worker's alone. The same against a real page and a real WebKit dispatch is
    /// `ExtensionPolyfillProfileWiringTests.testRealExtensionPageDoesNotSeeWebKitsRuntimeOnInstalled`.
    func testRuntimeOnInstalledSuppressedInExtensionPages() async throws {
        try setInstalledLedger(version: nil)
        defer { try? setInstalledLedger(version: nil) }
        let view = try await makeInstalledEventWebView(force: false)
        try await settleInstallClaim(on: view)

        let result = try await evalDictionary("""
        const calls = [];
        const listener = (d) => calls.push(d);
        chrome.runtime.onInstalled.addListener(listener);
        globalThis.__fireNativeInstalled({ reason: 'install' });
        const status = globalThis.__detourRuntimeOnInstalled;
        return JSON.stringify({ mode: status.mode, detail: status.detail, holdsEvent: status.holdsEvent,
                                calls: calls.length,
                                nativeListeners: globalThis.__nativeInstalledListeners.length,
                                hasListener: chrome.runtime.onInstalled.hasListener(listener),
                                sameEvent: chrome.runtime.onInstalled === globalThis.__shimInstalledEvent,
                                sameRuntime: chrome.runtime === globalThis.__shimRuntime,
                                claimCount: status.claimCount, claimed: await status.claim(),
                                lastDispatched: status.lastDispatched });
        """, on: view)

        XCTAssertEqual(result["mode"] as? String, "suppressed")
        XCTAssertEqual(result["detail"] as? String, "")
        XCTAssertEqual(result["holdsEvent"] as? Bool, true)
        XCTAssertEqual(result["calls"] as? Int, 0, "WebKit's own dispatch must not reach a page listener")
        XCTAssertEqual(result["nativeListeners"] as? Int, 0)
        XCTAssertEqual(result["hasListener"] as? Bool, true)
        XCTAssertEqual(result["sameEvent"] as? Bool, true)
        XCTAssertEqual(result["sameRuntime"] as? Bool, true, "chrome.runtime must not be replaced (TASK-15)")
        XCTAssertEqual(result["claimCount"] as? Int, 0, "a page must never claim")
        XCTAssertTrue(result["claimed"] is NSNull)
        XCTAssertTrue(result["lastDispatched"] is NSNull)
        XCTAssertNotNil(AppDatabase.shared.pendingRuntimeInstalledEvent(
            extensionID: "test-polyfill-extension", profileID: profile.id.uuidString, isPrivateProfile: false, currentVersion: "1.0.0"),
            "a page must not consume the worker's event")
    }

    /// If reading the event again does not return the patched object (a wrapper
    /// that is not cached), the patch is undone and the event left to WebKit, so
    /// listeners are never split across two lists.
    func testRuntimeOnInstalledFallsBackWhenThePatchIsNotVisible() async throws {
        try setInstalledLedger(version: nil)
        defer { try? setInstalledLedger(version: nil) }
        let view = try await makeInstalledEventWebView(eventExpression: """
            globalThis.__handedOutInstalledEvents = [];
            Object.defineProperty(globalThis.chrome.runtime, 'onInstalled', {
                configurable: true,
                get() { const e = globalThis.__makeNativeInstalledEvent(); globalThis.__handedOutInstalledEvents.push(e); return e; }
            });
            """)
        try await settleInstallClaim(on: view)

        let result = try await evalDictionary("""
        const calls = [];
        chrome.runtime.onInstalled.addListener((d) => calls.push(d));
        globalThis.__fireNativeInstalled({ reason: 'install' });
        const status = globalThis.__detourRuntimeOnInstalled;
        const first = globalThis.__handedOutInstalledEvents[0];
        return JSON.stringify({ mode: status.mode, detail: status.detail, holdsEvent: status.holdsEvent,
                                calls: calls.length, claimCount: status.claimCount,
                                patchedOwnProps: Object.getOwnPropertyNames(first).filter(n => n === 'hasListeners'),
                                restoredOriginal: (() => {
                                    const before = globalThis.__nativeInstalledListeners.length;
                                    first.addListener(() => {});
                                    return globalThis.__nativeInstalledListeners.length === before + 1;
                                })() });
        """, on: view)

        XCTAssertEqual(result["mode"] as? String, "webkit")
        XCTAssertEqual(result["detail"] as? String, "patch-not-visible")
        XCTAssertEqual(result["holdsEvent"] as? Bool, false)
        XCTAssertEqual(result["calls"] as? Int, 1, "listeners must reach WebKit's event when the patch is undone")
        XCTAssertEqual(result["claimCount"] as? Int, 0)
        XCTAssertEqual(result["patchedOwnProps"] as? [String], [],
                       "the shadowing must be removed from the object it was tried on")
        XCTAssertEqual(result["restoredOriginal"] as? Bool, true,
                       "an own method the event already had must be put back, not deleted")
    }

    // MARK: - TASK-64: only the background context may claim runtime.onInstalled

    /// A manifest's `background` entry, decoded the way a real manifest's is.
    private func decodedBackground(_ entry: [String: Any]?) throws -> ExtensionManifest.Background? {
        var manifestDict: [String: Any] = [
            "manifest_version": 3, "name": "Claim Gate Test", "version": "1.0.0"
        ]
        if let entry { manifestDict["background"] = entry }
        let data = try JSONSerialization.data(withJSONObject: manifestDict)
        return try JSONDecoder().decode(ExtensionManifest.self, from: data).background
    }

    /// A URL in an extension's own origin, as `frameInfo.request.url` carries it.
    private func extensionURL(_ path: String) -> URL {
        URL(string: "webkit-extension://8A5B1C2D-3E4F-5061-7283-94A5B6C7D8E9\(path)")!
    }

    /// POSITIVE: the worker's native-message bridge is the background context
    /// exactly when the manifest declares a service worker.
    func testSenderIsBackgroundContextAcceptsTheServiceWorkersNativeMessage() throws {
        let background = try decodedBackground(["service_worker": "background.js"])
        XCTAssertTrue(ExtensionPolyfillHandler.senderIsBackgroundContext(.nativeMessage, background: background))
    }

    /// POSITIVE: a `scripts` list WebKit is asked to host in a worker
    /// (`preferred_environment`, string or list) reaches the handler over the
    /// native-message bridge like any worker, and is the background context.
    func testSenderIsBackgroundContextAcceptsANativeMessageForScriptsPreferringAServiceWorker() throws {
        for preferred in ["service_worker", ["service_worker", "document"]] as [Any] {
            let background = try decodedBackground(["scripts": ["background.js"], "preferred_environment": preferred])
            XCTAssertTrue(ExtensionPolyfillHandler.senderIsBackgroundContext(.nativeMessage, background: background),
                          "preferred_environment \(preferred) hosts the scripts in a worker")
        }
    }

    /// POSITIVE: a `service_worker` WebKit is asked to host in a document
    /// (`preferred_environment: document`) loads in the generated page, so the
    /// top-level frame at that path is the background context.
    func testSenderIsBackgroundContextAcceptsTheGeneratedPageForAServiceWorkerPreferringADocument() throws {
        let background = try decodedBackground(["service_worker": "background.js", "preferred_environment": ["document"]])
        XCTAssertTrue(ExtensionPolyfillHandler.senderIsBackgroundContext(
            .frame(url: extensionURL(ExtensionPolyfillHandler.generatedBackgroundPagePath), isMainFrame: true, isDetourHosted: false),
            background: background))
    }

    /// NEGATIVE: an alternate spelling of the background path (`bg%2Ehtml` for
    /// `bg.html`) is not the path WebKit serves the page at, so it is refused —
    /// the gate compares the percent-encoded path, as the polyfill does.
    func testSenderIsBackgroundContextRefusesAnAlternateEncodingOfTheBackgroundPath() throws {
        let background = try decodedBackground(["page": "bg.html"])
        XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
            .frame(url: extensionURL("/bg%2Ehtml"), isMainFrame: true, isDetourHosted: false), background: background))
    }

    /// POSITIVE: a page name with a space is declared raw in the manifest and
    /// served percent-encoded; the two must meet.
    func testSenderIsBackgroundContextAcceptsAPercentEncodedBackgroundPage() throws {
        let background = try decodedBackground(["page": "my page.html"])
        XCTAssertTrue(ExtensionPolyfillHandler.senderIsBackgroundContext(
            .frame(url: extensionURL("/my%20page.html"), isMainFrame: true, isDetourHosted: false), background: background))
    }

    /// POSITIVE: `background.scripts` runs in the page WebKit generates, so the
    /// top-level frame at that generated path is the background context.
    func testSenderIsBackgroundContextAcceptsTheGeneratedPageForBackgroundScripts() throws {
        let background = try decodedBackground(["scripts": ["background.js"], "persistent": false])
        XCTAssertTrue(ExtensionPolyfillHandler.senderIsBackgroundContext(
            .frame(url: extensionURL(ExtensionPolyfillHandler.generatedBackgroundPagePath), isMainFrame: true, isDetourHosted: false),
            background: background))
    }

    /// POSITIVE: an explicit `background.page`, in both the plain and the
    /// './'-prefixed spelling Chrome accepts — both load at /bg.html.
    func testSenderIsBackgroundContextAcceptsADeclaredBackgroundPage() throws {
        for spelling in ["bg.html", "./bg.html"] {
            let background = try decodedBackground(["page": spelling, "persistent": false])
            XCTAssertTrue(ExtensionPolyfillHandler.senderIsBackgroundContext(
                .frame(url: extensionURL("/bg.html"), isMainFrame: true, isDetourHosted: false),
                background: background),
                "'\(spelling)' must resolve to /bg.html")
        }
    }

    /// `page` wins over `scripts` when a manifest declares both, as the
    /// polyfill's own `contextKind` decides it: the declared page is the
    /// background context and the generated path is not.
    func testSenderIsBackgroundContextPrefersTheDeclaredPageOverTheGeneratedPath() throws {
        let background = try decodedBackground(["page": "bg.html", "scripts": ["background.js"]])
        XCTAssertTrue(ExtensionPolyfillHandler.senderIsBackgroundContext(
            .frame(url: extensionURL("/bg.html"), isMainFrame: true, isDetourHosted: false), background: background))
        XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
            .frame(url: extensionURL(ExtensionPolyfillHandler.generatedBackgroundPagePath), isMainFrame: true, isDetourHosted: false),
            background: background),
            "the generated page is not where this extension's background runs")
    }

    /// NEGATIVE: an ordinary extension page (a popup, an options page, an
    /// extension tab) is never the background context, whatever shape the
    /// manifest's background has.
    func testSenderIsBackgroundContextRefusesAnOrdinaryExtensionPage() throws {
        let shapes: [[String: Any]] = [
            ["service_worker": "background.js"],
            ["scripts": ["background.js"]],
            ["page": "bg.html"]
        ]
        for shape in shapes {
            let background = try decodedBackground(shape)
            XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
                .frame(url: extensionURL("/popup.html"), isMainFrame: true, isDetourHosted: false), background: background),
                "a popup must not be the background context for \(shape.keys.sorted())")
        }
    }

    /// NEGATIVE: an extension page that iframes the background path is at that
    /// path but is not the top-level document, so it must not claim.
    func testSenderIsBackgroundContextRefusesAnIframeOfTheBackgroundPath() throws {
        let pageBackground = try decodedBackground(["page": "bg.html"])
        XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
            .frame(url: extensionURL("/bg.html"), isMainFrame: false, isDetourHosted: false), background: pageBackground))

        let scriptsBackground = try decodedBackground(["scripts": ["background.js"]])
        XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
            .frame(url: extensionURL(ExtensionPolyfillHandler.generatedBackgroundPagePath), isMainFrame: false, isDetourHosted: false),
            background: scriptsBackground))
    }

    /// NEGATIVE (TASK-66): a frame in a web view Detour hosts — a tab, the
    /// action popup, an options page, an offscreen document — is never the
    /// background context, even at the background document's own path. That is
    /// the hole a path-only check leaves: a page can navigate itself there
    /// (`location.href = '/bg.html'`). WebKit's background page runs in the one
    /// view Detour never creates or presents, so it is unaffected.
    func testSenderIsBackgroundContextRefusesADetourHostedViewAtTheBackgroundPath() throws {
        let cases: [(shape: [String: Any], path: String)] = [
            (["scripts": ["background.js"]], ExtensionPolyfillHandler.generatedBackgroundPagePath),
            (["service_worker": "background.js", "preferred_environment": ["document"]],
             ExtensionPolyfillHandler.generatedBackgroundPagePath),
            (["page": "bg.html"], "/bg.html"),
            (["page": "bg.html", "scripts": ["background.js"]], "/bg.html")
        ]
        for (shape, path) in cases {
            let background = try decodedBackground(shape)
            XCTAssertTrue(ExtensionPolyfillHandler.senderIsBackgroundContext(
                .frame(url: extensionURL(path), isMainFrame: true, isDetourHosted: false),
                background: background),
                "precondition: an unhosted frame at \(path) is the background context for \(shape.keys.sorted())")
            XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
                .frame(url: extensionURL(path), isMainFrame: true, isDetourHosted: true),
                background: background),
                "a Detour-hosted page navigated to \(path) must not claim for \(shape.keys.sorted())")
        }
    }

    /// NEGATIVE: a frame whose URL WebKit does not report cannot be matched
    /// against a path, so it fails closed.
    func testSenderIsBackgroundContextRefusesAFrameWithNoURL() throws {
        for shape in [["scripts": ["background.js"]], ["page": "bg.html"]] as [[String: Any]] {
            let background = try decodedBackground(shape)
            XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
                .frame(url: nil, isMainFrame: true, isDetourHosted: false), background: background))
        }
    }

    /// NEGATIVE: a page-backed background always reaches the handler through
    /// `webkit.messageHandlers`, never through the native-message bridge, so a
    /// native-message claim for such a manifest is refused.
    func testSenderIsBackgroundContextRefusesANativeMessageForAPageBackedBackground() throws {
        for shape in [["scripts": ["background.js"]], ["page": "bg.html"]] as [[String: Any]] {
            let background = try decodedBackground(shape)
            XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
                .nativeMessage, background: background),
                "a background page does not use the native-message bridge (\(shape.keys.sorted()))")
        }
    }

    /// NEGATIVE: a manifest with no background content at all has no claiming
    /// context, so every sender is refused.
    func testSenderIsBackgroundContextRefusesEverySenderWithoutBackgroundContent() throws {
        for background in [try decodedBackground(nil), try decodedBackground([:])] {
            XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
                .nativeMessage, background: background))
            XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
                .frame(url: extensionURL(ExtensionPolyfillHandler.generatedBackgroundPagePath), isMainFrame: true, isDetourHosted: false),
                background: background))
            XCTAssertFalse(ExtensionPolyfillHandler.senderIsBackgroundContext(
                .frame(url: extensionURL("/bg.html"), isMainFrame: true, isDetourHosted: false), background: background))
        }
    }

    /// Re-register the suite's extension with a background `service_worker`, so
    /// its native-message claims count as coming from the background context
    /// (TASK-64). setUp registers a manifest with no background at all, which
    /// the claim gate refuses. tearDown removes the registration by id.
    private func registerWithServiceWorkerBackground() throws {
        try reregisterSuiteExtension(background: ["service_worker": "background.js"])
    }

    /// NEGATIVE (TASK-64): the native-message bridge is the *worker's* path, so a
    /// claim on it is only the background context when the manifest declares a
    /// service worker. With setUp's background-less manifest the claim is
    /// refused — and refused without touching the ledger, so the same claim
    /// delivers the install once the manifest does declare one.
    func testClaimInstalledEventThroughTheNativeBridgeIsRefusedWithoutABackgroundContext() async throws {
        try setInstalledLedger(version: nil)
        defer { try? setInstalledLedger(version: nil) }

        func claim() async -> (Any?, (any Error)?) {
            await withCheckedContinuation { continuation in
                handler.handleNativeMessage(["type": "runtime.claimInstalledEvent", "params": [String: Any]()],
                                            verifiedExtensionID: "test-polyfill-extension") { result, error in
                    continuation.resume(returning: (result, error))
                }
            }
        }
        let (refusedResult, refusedError) = await claim()
        XCTAssertNil(refusedResult)
        XCTAssertNotNil(refusedError,
                        "an extension with no background content may not claim the install")

        // The refusal left the ledger pending: the real background context
        // still gets its install.
        try registerWithServiceWorkerBackground()
        let (result, error) = await claim()
        XCTAssertNil(error)
        XCTAssertEqual(result as? [String: String], ["reason": "install"],
                       "the refused claim must not have advanced the ledger")
    }

    /// The native side of the claim, as the worker reaches it: of two claims for
    /// the same version exactly the first delivers.
    func testClaimInstalledEventThroughTheNativeBridgeDeliversOnce() async throws {
        try setInstalledLedger(version: nil)
        defer { try? setInstalledLedger(version: nil) }
        // Only the background context may claim (TASK-64); on this path that
        // means a manifest with a service worker.
        try registerWithServiceWorkerBackground()

        func claim() async -> Any? {
            await withCheckedContinuation { continuation in
                handler.handleNativeMessage(["type": "runtime.claimInstalledEvent", "params": [String: Any]()],
                                            verifiedExtensionID: "test-polyfill-extension") { result, _ in
                    continuation.resume(returning: result)
                }
            }
        }
        let first = await claim()
        let second = await claim()
        XCTAssertEqual(first as? [String: String], ["reason": "install"])
        XCTAssertEqual((second as? [String: Any])?.isEmpty, true, "got \(second ?? "nil")")
    }

    /// The Private profile's worker claims and gets nothing (TASK-29): not on its
    /// first run, not after a relaunch (a new profile object and handler over the
    /// same ledger), not after a reinstall; and no ledger row is written for it. The
    /// regular profile's claim on the same extension still delivers.
    func testClaimInstalledEventThroughTheNativeBridgeAnswersNothingInThePrivateProfile() async throws {
        try setInstalledLedger(version: nil)
        defer { try? setInstalledLedger(version: nil) }
        // Only the background context may claim (TASK-64); on this path that
        // means a manifest with a service worker.
        try registerWithServiceWorkerBackground()
        let privateID = TabStore.incognitoProfileID.uuidString
        func clearPrivateRows() throws {
            _ = try AppDatabase.shared.dbQueue.write { db in
                try ExtensionInstalledEventRecord
                    .filter(Column("extensionID") == "test-polyfill-extension" && Column("profileID") == privateID)
                    .deleteAll(db)
            }
        }
        try clearPrivateRows()
        defer { try? clearPrivateRows() }

        func claim(through claimHandler: ExtensionPolyfillHandler) async -> Any? {
            await withCheckedContinuation { continuation in
                claimHandler.handleNativeMessage(["type": "runtime.claimInstalledEvent", "params": [String: Any]()],
                                                 verifiedExtensionID: "test-polyfill-extension") { result, _ in
                    continuation.resume(returning: result)
                }
            }
        }

        for launch in 1...2 {
            let privateProfile = OriginMappingProfile(id: TabStore.incognitoProfileID, name: "Private", isIncognito: true)
            let privateHandler = ExtensionPolyfillHandler(profile: privateProfile)
            let reply = await claim(through: privateHandler)
            XCTAssertEqual((reply as? [String: Any])?.isEmpty, true, "launch \(launch): got \(reply ?? "nil")")
            AppDatabase.shared.markRuntimeInstalledEventReinstalled(extensionID: "test-polyfill-extension")
            let afterReinstall = await claim(through: privateHandler)
            XCTAssertEqual((afterReinstall as? [String: Any])?.isEmpty, true, "launch \(launch): got \(afterReinstall ?? "nil")")
        }
        let privateRows = try await AppDatabase.shared.dbQueue.read { db in
            try ExtensionInstalledEventRecord
                .filter(Column("extensionID") == "test-polyfill-extension" && Column("profileID") == privateID)
                .fetchCount(db)
        }
        XCTAssertEqual(privateRows, 0, "the Private profile must never get a ledger row")

        let regular = await claim(through: handler)
        XCTAssertEqual(regular as? [String: String], ["reason": "install"],
                       "the regular profile is still owed its install")
    }
}
