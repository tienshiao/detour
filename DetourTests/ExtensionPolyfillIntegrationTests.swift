import XCTest
import Network
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
                             "sessions", "search", "offscreen", "fontSettings", "nativeMessaging",
                             "webRequest", "webNavigation"],
            "host_permissions": ["<all_urls>"],
            "background": {"service_worker": "background.js", "type": "module"},
            "content_scripts": [
                {"matches": ["<all_urls>"], "js": ["content.js"], "all_frames": true, "run_at": "document_end"}
            ],
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
                    armed: globalThis.__detourNativePortKeepAlive ? globalThis.__detourNativePortKeepAlive.armed : null,
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
            // TASK-8: a real WebSocket from inside the worker, relayed through
            // Detour. Opens, echoes one text and one binary frame off the
            // loopback server, then closes cleanly.
            if (message && message.type === 'wsProbe') {
                (async () => {
                    const out = {
                        opened: false, protocol: null, messages: [], closeCode: null,
                        closeReason: null, wasClean: null, mode: null, error: null, timedOut: false
                    };
                    try {
                        const socket = new WebSocket(message.url);
                        socket.binaryType = 'arraybuffer';
                        await new Promise((resolve) => {
                            socket.onopen = () => {
                                out.opened = true;
                                out.protocol = socket.protocol;
                                socket.send('hello');
                                socket.send(new Uint8Array([1, 2, 3, 4]));
                            };
                            socket.onmessage = (e) => {
                                if (typeof e.data === 'string') out.messages.push({ text: e.data });
                                else out.messages.push({ bytes: Array.from(new Uint8Array(e.data)) });
                                if (out.messages.length >= 2) socket.close(1000, 'done');
                            };
                            socket.onerror = () => { out.error = 'error event'; };
                            socket.onclose = (e) => {
                                out.closeCode = e.code;
                                out.closeReason = e.reason;
                                out.wasClean = e.wasClean;
                                resolve();
                            };
                            setTimeout(() => { out.timedOut = true; resolve(); }, 8000);
                        });
                    } catch (e) {
                        out.error = String(e && e.message ? e.message : e);
                    }
                    try {
                        out.mode = globalThis.__detourWebSocketRelay
                            ? globalThis.__detourWebSocketRelay.mode : 'missing';
                        out.openSockets = globalThis.__detourWebSocketRelay
                            ? globalThis.__detourWebSocketRelay.openSockets : null;
                    } catch (e) {}
                    return out;
                })().then((r) => sendResponse(r), (e) => sendResponse({ fatal: String(e && e.message ? e.message : e) }));
                return true;
            }
            // TASK-8 (negative): the relay host is port-only, so a one-shot
            // sendNativeMessage to it must be refused by the delegate.
            if (message && message.type === 'rawRelayNative') {
                Promise.resolve()
                    .then(() => chrome.runtime.sendNativeMessage('detourWebSocketRelay', { op: 'open', url: 'wss://example.invalid/' }))
                    .then((r) => sendResponse({ ok: true, reply: r === undefined ? null : r }),
                          (e) => sendResponse({ ok: false, error: String(e && e.message ? e.message : e) }));
                return true;
            }
            // TASK-4: what WebKit itself provides for frame enumeration, as seen
            // from inside the worker, plus what native getAllFrames answers for a
            // real tab. Everything is wrapped so a throw or rejection comes back
            // as text rather than an empty reply.
            if (message && message.type === 'probeWebNavFrames') {
                (async () => {
                    const out = {
                        frames: globalThis.__detourWebNavFrames || null,
                        navType: typeof chrome.webNavigation,
                        getAllFramesType: 'n/a',
                        getFrameType: 'n/a',
                        tabs: null,
                        tabsError: null,
                        getAllFrames: null,
                        getAllFramesError: null
                    };
                    try { out.getAllFramesType = typeof chrome.webNavigation.getAllFrames; } catch (e) { out.getAllFramesType = 'error: ' + e.message; }
                    try { out.getFrameType = typeof chrome.webNavigation.getFrame; } catch (e) { out.getFrameType = 'error: ' + e.message; }
                    try {
                        const tabs = await chrome.tabs.query({});
                        out.tabs = tabs.map((t) => ({ id: t.id, url: t.url }));
                    } catch (e) { out.tabsError = String(e && e.message ? e.message : e); }
                    const tabId = message.tabId != null
                        ? message.tabId
                        : (out.tabs && out.tabs.length ? out.tabs[0].id : null);
                    out.probedTabId = tabId;
                    if (tabId != null) {
                        try {
                            out.getAllFrames = await chrome.webNavigation.getAllFrames({ tabId: tabId });
                        } catch (e) { out.getAllFramesError = String(e && e.message ? e.message : e); }
                    }
                    return out;
                })().then((r) => sendResponse(r), (e) => sendResponse({ fatal: String(e && e.message ? e.message : e) }));
                return true;
            }
            // TASK-4: every content-script hello, with the sender fields the
            // frame registry would be built out of.
            if (message && message.type === 'frameHello') {
                const record = {
                    frameId: sender.frameId,
                    tabId: sender.tab ? sender.tab.id : null,
                    hasTab: !!sender.tab,
                    url: sender.url,
                    documentId: sender.documentId,
                    reportedURL: message.url,
                    isTop: message.isTop,
                    parentIsTop: message.parentIsTop
                };
                if (!globalThis.__frameHellos) globalThis.__frameHellos = [];
                globalThis.__frameHellos.push(record);
                sendResponse(record);
                return true;
            }
            if (message && message.type === 'getFrameHellos') {
                sendResponse({ hellos: globalThis.__frameHellos || [] });
                return true;
            }
            // The whole class shares this worker, so `__frameHellos` outlives
            // any one probe (and every `-test-iterations` repetition of it). A
            // probe drops the previous run's records before loading its page.
            if (message && message.type === 'clearFrameHellos') {
                globalThis.__frameHellos = [];
                sendResponse({ cleared: true });
                return true;
            }
            // TASK-4: are the observed ids usable for targeting?
            if (message && message.type === 'probeFrameTargeting') {
                (async () => {
                    const out = { getFrame: null, getFrameError: null, sendMessage: null, sendMessageError: null };
                    try {
                        out.getFrame = await chrome.webNavigation.getFrame({
                            tabId: message.tabId, frameId: message.frameId
                        });
                    } catch (e) { out.getFrameError = String(e && e.message ? e.message : e); }
                    try {
                        out.sendMessage = await new Promise((resolve) => {
                            let settled = false;
                            try {
                                chrome.tabs.sendMessage(message.tabId, { type: 'ping' }, { frameId: message.frameId }, (r) => {
                                    settled = true;
                                    resolve({ reply: r === undefined ? null : r,
                                              lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
                                });
                            } catch (e) { resolve({ threw: String(e && e.message ? e.message : e) }); return; }
                            setTimeout(() => { if (!settled) resolve({ reply: 'timeout' }); }, 5000);
                        });
                    } catch (e) { out.sendMessageError = String(e && e.message ? e.message : e); }
                    return out;
                })().then((r) => sendResponse(r), (e) => sendResponse({ fatal: String(e && e.message ? e.message : e) }));
                return true;
            }
        });
        """
        try backgroundJS.write(to: tempDir.appendingPathComponent("background.js"),
                               atomically: true, encoding: .utf8)

        // Content script for the frame-enumeration probe (TASK-4): says hello
        // from every frame it is injected into, stores the worker's reply on the
        // document so Swift can read it, and answers a targeted ping so
        // `tabs.sendMessage(tabId, msg, {frameId})` can be verified end to end.
        let contentJS = """
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message && message.type === 'ping') {
                sendResponse({ type: 'pong', url: location.href, isTop: self === top });
                return true;
            }
        });
        try {
            chrome.runtime.sendMessage({
                type: 'frameHello',
                url: location.href,
                isTop: self === top,
                parentIsTop: self.parent === top
            }, (reply) => {
                const payload = {
                    reply: reply === undefined ? null : reply,
                    lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
                };
                try { document.documentElement.dataset.frameReply = JSON.stringify(payload); } catch (e) {}
            });
        } catch (e) {
            try { document.documentElement.dataset.frameReply = JSON.stringify({ threw: String(e) }); } catch (e2) {}
        }
        """
        try contentJS.write(to: tempDir.appendingPathComponent("content.js"),
                            atomically: true, encoding: .utf8)

        // A test page we can load in an extension context web view
        let testHTML = "<html><body><div id=\"test\">Extension Context Page</div></body></html>"
        try testHTML.write(to: tempDir.appendingPathComponent("test.html"),
                           atomically: true, encoding: .utf8)

        // --- Set up controller with polyfill handler ---

        let wkExt = try await WKWebExtension(resourceBaseURL: tempDir)
        // A persistent controller and store like a profile's, under an
        // identifier the test data directory records, so the bundle cleanup
        // removes both (TASK-36). The store is the in-use probe that keeps a
        // live controller's directory from being removed.
        let storageIdentifier = WebKitStorageScope.current.identifierForCreatingStorage(forProfile: UUID())
        let config = WKWebExtensionController.Configuration(identifier: storageIdentifier)
        config.defaultWebsiteDataStore = WKWebsiteDataStore(forIdentifier: storageIdentifier)

        // The handler attributes senders through its profile's loaded contexts,
        // so the profile has to exist before it. It lives for the whole suite
        // (pinned by SharedState); a released profile would turn every test into
        // an "Unrecognized extension origin" rejection.
        let testProfile = TabStore.shared.addProfile(name: "Polyfill Int Profile")

        // Wire the polyfill handler onto the controller's webViewConfiguration
        let polyfillHandler = ExtensionPolyfillHandler(profile: testProfile)
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
        // by resolving that origin against the profile's loaded contexts (this
        // context is registered in the test profile below).
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

        testProfile.extensionContexts[Self.extensionID] = context
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
        try await loadAndWait(wv, URLRequest(url: testURL))
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

    /// What a *real* extension context gets for the gaps TASK-3 fills, rather
    /// than what the bare-WKWebView suite can infer. The diag records which path
    /// each module took, so this both asserts the API is usable and pins the
    /// environment: if a future WebKit starts vending `chrome.webRequest` or
    /// `chrome.action.getUserSettings`, the install mode changes here first.
    func testGapFillingModulesInRealExtensionContext() async throws {
        let wv = try await makeExtensionWebView()
        let result = try await evalJSON("""
            return JSON.stringify({
                webRequestInstall: __detourPolyfillDiag.apis.webRequest,
                onAuthRequired: typeof chrome.webRequest.onAuthRequired.addListener,
                actionInstall: __detourPolyfillDiag.apis.actionGetUserSettings,
                getUserSettings: chrome.action ? typeof chrome.action.getUserSettings : 'no-action',
                privacyInstall: __detourPolyfillDiag.apis.privacy,
                privacyType: typeof chrome.privacy
            });
        """, in: wv) as? [String: Any]

        // The manifest declares `webRequest`, so the stub is installed and —
        // whichever path was taken — onAuthRequired must be registrable.
        // Observed on macOS 26 (2026-09-12): WebKit provides neither
        // chrome.webRequest nor chrome.action.getUserSettings, so both are
        // 'polyfill' here; the assertions stay tolerant so a future WebKit that
        // ships them is a passing test rather than a mystery failure.
        XCTAssertEqual(result?["onAuthRequired"] as? String, "function")
        XCTAssertTrue(["native", "polyfill", "native+onAuthRequired"].contains(result?["webRequestInstall"] as? String ?? ""),
                      "unexpected webRequest install mode: \(result?["webRequestInstall"] ?? "nil")")

        // The test manifest declares an `action`, so chrome.action exists here.
        XCTAssertEqual(result?["getUserSettings"] as? String, "function")
        XCTAssertTrue(["native", "polyfill"].contains(result?["actionInstall"] as? String ?? ""),
                      "unexpected action.getUserSettings install mode: \(result?["actionInstall"] ?? "nil")")

        // The manifest does not declare `privacy`, so the namespace stays absent.
        XCTAssertEqual(result?["privacyInstall"] as? String, "absent")
        XCTAssertEqual(result?["privacyType"] as? String, "undefined")
    }

    /// `chrome.action` is `[MainWorldOnly, Dynamic]`, so every read hands back the
    /// action wrapper from WebKit's *weak* wrapper cache: before TASK-60 the first
    /// garbage collection after the polyfill ran collected the wrapper it had
    /// patched, and the next read minted a fresh one with `getUserSettings` gone —
    /// a failure that surfaced only as a rare flake in
    /// `testGapFillingModulesInRealExtensionContext`. Two guards: the deterministic
    /// one is that the root the polyfill keeps (`__detourHeldWrappers.action`) is
    /// the object `chrome.action` answers with; the measured one churns garbage
    /// until a control `WeakRef` is cleared and reads the API back afterwards.
    /// The control is a young object, which an eden collection can clear without
    /// touching the older wrapper, so the root check is what guards a deletion of
    /// the hold; the churn guards the mechanism itself. The churn escalates each
    /// round on purpose: after the rest of the suite has grown the heap, a flat
    /// 1M allocations a round went 10 rounds without a collection (2026-09-13).
    func testActionGetUserSettingsSurvivesGarbageCollection() async throws {
        let wv = try await makeExtensionWebView()
        let install = try await eval("return __detourPolyfillDiag.apis.actionGetUserSettings;", in: wv) as? String
        if install == "native" {
            throw XCTSkip("WebKit vends chrome.action.getUserSettings natively; nothing was patched, so there is no root to guard")
        }
        XCTAssertEqual(install, "polyfill", "unexpected action.getUserSettings install mode")

        let result = try await evalJSON("""
            const before = typeof chrome.action.getUserSettings;
            const heldBefore = __detourHeldWrappers.action === chrome.action;
            // Unreachable the moment it is created: once a collection runs, the
            // WeakRef is cleared, which is the proof that one did.
            const control = new WeakRef({ marker: 'control' });
            let collected = false;
            let rounds = 0;
            while (!collected && rounds < 10) {
                rounds += 1;
                for (let i = 0; i < 20 * rounds; i++) {
                    const junk = [];
                    for (let k = 0; k < 50000; k++) junk.push({ i: i, k: k, s: 'x' + k });
                }
                await new Promise(resolve => setTimeout(resolve, 25));
                collected = control.deref() === undefined;
            }
            // Read the API back rather than calling it blind, so losing the patch
            // reports as the assertion below and not as an opaque TypeError.
            const after = typeof chrome.action.getUserSettings;
            const heldAfter = __detourHeldWrappers.action === chrome.action;
            const settings = after === 'function' ? await chrome.action.getUserSettings() : null;
            return JSON.stringify({
                before: before,
                heldBefore: heldBefore,
                collected: collected,
                rounds: rounds,
                after: after,
                heldAfter: heldAfter,
                isOnToolbar: settings ? settings.isOnToolbar : null
            });
        """, in: wv) as? [String: Any]

        XCTAssertEqual(result?["before"] as? String, "function")
        XCTAssertEqual(result?["heldBefore"] as? Bool, true,
                       "the polyfill must root the very wrapper chrome.action answers with")
        XCTAssertEqual(result?["collected"] as? Bool, true,
                       "no collection observed in \(result?["rounds"] ?? "nil") rounds, so the read-back below "
                       + "proves nothing — churn more garbage")
        XCTAssertEqual(result?["after"] as? String, "function",
                       "the patch on WebKit's weakly cached chrome.action wrapper did not survive a collection")
        XCTAssertEqual(result?["heldAfter"] as? Bool, true,
                       "after a collection chrome.action must still be the rooted, patched wrapper")
        XCTAssertEqual(result?["isOnToolbar"] as? Bool, true,
                       "getUserSettings must still answer after a collection, not just exist")
    }

    /// TASK-80: what a real extension context gets for `chrome.storage.managed`.
    /// Observed on macOS 27 (2026-09-14): WebKit provides no managed area, so the
    /// polyfill installs; a future WebKit that ships one is a passing test.
    /// Then the same collection churn as the getUserSettings guard, because
    /// `chrome.storage` is a weakly cached wrapper too.
    func testStorageManagedInRealExtensionContextSurvivesGarbageCollection() async throws {
        let wv = try await makeExtensionWebView()
        let install = try await eval("return __detourPolyfillDiag.apis.storageManaged;", in: wv) as? String
        if install == "native" {
            throw XCTSkip("WebKit vends chrome.storage.managed natively; nothing was patched")
        }
        XCTAssertEqual(install, "polyfill", "unexpected storage.managed install mode")

        let result = try await evalJSON("""
            const listener = () => {};
            chrome.storage.managed.onChanged.addListener(listener);
            const registered = chrome.storage.managed.onChanged.hasListener(listener);
            const localNative = __detourNativeness(chrome.storage.local.get);
            const control = new WeakRef({ marker: 'control' });
            let collected = false;
            let rounds = 0;
            while (!collected && rounds < 10) {
                rounds += 1;
                for (let i = 0; i < 20 * rounds; i++) {
                    const junk = [];
                    for (let k = 0; k < 50000; k++) junk.push({ i: i, k: k, s: 'x' + k });
                }
                await new Promise(resolve => setTimeout(resolve, 25));
                collected = control.deref() === undefined;
            }
            const after = typeof chrome.storage.managed;
            const held = __detourHeldWrappers.storage === chrome.storage;
            const got = after === 'object' ? await chrome.storage.managed.get(null) : null;
            // The native areas must still work on the patched wrapper.
            await chrome.storage.local.set({ __task80: 'ok' });
            const local = await chrome.storage.local.get('__task80');
            return JSON.stringify({ registered, localNative, collected, rounds, after, held, got, local: local.__task80 });
        """, in: wv) as? [String: Any]

        XCTAssertEqual(result?["registered"] as? Bool, true)
        XCTAssertEqual(result?["localNative"] as? String, "native", "storage.local must stay WebKit's")
        XCTAssertEqual(result?["collected"] as? Bool, true,
                       "no collection observed in \(result?["rounds"] ?? "nil") rounds — churn more garbage")
        XCTAssertEqual(result?["after"] as? String, "object",
                       "chrome.storage.managed did not survive a collection")
        XCTAssertEqual(result?["held"] as? Bool, true)
        XCTAssertEqual((result?["got"] as? [String: Any])?.count, 0)
        XCTAssertEqual(result?["local"] as? String, "ok")
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
        let result = try await askWorker(from: wv, message: ["type": "ping"])
        XCTAssertNil(result["lastError"] as? String, "sendMessage reported lastError")
        let reply = result["reply"] as? [String: Any]
        XCTAssertEqual(reply?["type"] as? String, "pong",
                       "the worker must answer; an empty reply means WebKit skipped the worker (globals not native?). Got: \(String(describing: result))")
        XCTAssertEqual(reply?["chromeIsNamespace"] as? String, "[object Namespace]",
                       "the worker's chrome global must still be WebKit's native namespace object")
        // The keep-alive no longer patches anything (WebKit re-materializes
        // `runtime.connectNative` on every read, so a wrap never took; probed
        // 2026-09-11, TASK-15). It just calls it once at worker start and holds the
        // resulting port idle: 'port' with no detail, and disarmed, because nothing
        // in this suite connects a real native host (TASK-16).
        XCTAssertEqual(reply?["connectNativeType"] as? String, "function", "nativeMessaging is granted, connectNative must exist")
        XCTAssertEqual(reply?["installMode"] as? String, "port",
                       "the worker must hold a port to Detour's polyfill host; detail: \(reply?["installDetail"] ?? "nil")")
        XCTAssertEqual(reply?["installDetail"] as? String, "")
        XCTAssertEqual(reply?["armed"] as? Bool, false,
                       "only Detour arms the worker, and no native host is connected here")
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

    // MARK: - TASK-4: frame enumeration

    /// Does WebKit vend `webNavigation.getAllFrames`/`getFrame` in a real
    /// extension context — the question that decided TASK-4 Phase 3 (no
    /// worker-side frame registry, and no polyfill fallback either)?
    ///
    /// The answer is recorded pre-patch in
    /// `_polyfillDiag.apis.webNavigationFrames`. The `native`/`native`/`object`
    /// pin below is intentional, not an over-tight assertion: it is the measured
    /// environment 1Password's iframe autofill depends on, and nothing in the
    /// polyfill stands in if it goes away. A change here means the platform
    /// moved under us and must be investigated — re-measure and decide what
    /// replaces native frame enumeration — never loosened to make the suite
    /// green. The observed values are carried in the failure messages so the new
    /// reading is visible immediately.
    func testWebNavigationFrameAPIsInRealExtensionContext() async throws {
        let wv = try await makeExtensionWebView()

        let page = try await evalJSON("""
            return JSON.stringify({
                diag: __detourPolyfillDiag.apis.webNavigationFrames,
                navType: typeof chrome.webNavigation,
                getAllFrames: chrome.webNavigation ? typeof chrome.webNavigation.getAllFrames : 'no-namespace',
                getFrame: chrome.webNavigation ? typeof chrome.webNavigation.getFrame : 'no-namespace'
            });
        """, in: wv) as? [String: Any]

        let worker = try await askWorker(from: wv, message: ["type": "probeWebNavFrames"])
        let workerReply = worker["reply"] as? [String: Any]

        let evidence = """
        page=\(page ?? [:])
        worker=\(String(describing: worker))
        """

        // The page always ends up with callable frame enumeration, whether it is
        // WebKit's or the polyfill's.
        XCTAssertEqual(page?["getAllFrames"] as? String, "function", evidence)
        XCTAssertEqual(page?["getFrame"] as? String, "function", evidence)

        let diag = try XCTUnwrap(page?["diag"] as? [String: Any], evidence)
        let pageGetAllFrames = try XCTUnwrap(diag["getAllFrames"] as? String, evidence)
        XCTAssertTrue(["missing", "native", "non-native"].contains(pageGetAllFrames), evidence)

        // The worker must answer at all (an empty reply means WebKit skipped it).
        XCTAssertNotNil(workerReply, "the worker did not answer the probe: \(evidence)")
        let workerFrames = workerReply?["frames"] as? [String: Any]
        let workerGetAllFrames = workerFrames?["getAllFrames"] as? String
        XCTAssertTrue(["missing", "native", "non-native"].contains(workerGetAllFrames ?? ""), evidence)

        // Whatever the worker reports for the pre-patch environment, the API is
        // callable there afterwards.
        XCTAssertEqual(workerReply?["getAllFramesType"] as? String, "function", evidence)
        XCTAssertEqual(workerReply?["getFrameType"] as? String, "function", evidence)

        XCTAssertEqual(pageGetAllFrames, workerGetAllFrames,
                       "page and worker should see the same environment: \(evidence)")

        // Observed on macOS 26 (2026-09-12): WebKit vends chrome.webNavigation
        // with *native* getAllFrames and getFrame in both the extension page and
        // the service worker, so no polyfill fallback and no worker-side frame
        // registry is needed (TASK-4). This is the load-bearing reading; if it
        // ever flips to 'missing' nothing stands in — `getAllFrames` becomes a
        // TypeError at the call site and 1Password loses iframe autofill.
        XCTAssertEqual(pageGetAllFrames, "native", evidence)
        XCTAssertEqual(diag["getFrame"] as? String, "native", evidence)
        XCTAssertEqual(diag["namespace"] as? String, "object", evidence)
    }

    /// Does a content script injected with `all_frames: true` reach the worker,
    /// and are the `sender.frameId`s it arrives with usable for targeting? This
    /// is the mechanism the Phase-3 frame registry would be built on, so it is
    /// probed directly rather than assumed.
    func testContentScriptFrameHellosReachTheWorker() async throws {
        // Real http(s) subframes, not srcdoc/data: ones — content scripts are
        // only injected into frames whose URL a match pattern accepts, and
        // `<all_urls>` does not cover about:srcdoc or data:. A loopback server
        // is the cheapest way to get a page with genuine subframe documents.
        let server = try LoopbackHTTPServer(routes: [
            "/": """
                <html><body><p>top</p>
                <iframe id="a" src="/child-a"></iframe>
                <iframe id="b" src="/child-b"></iframe>
                <iframe id="c" srcdoc="<p>srcdoc child</p>"></iframe>
                </body></html>
                """,
            "/child-a": "<html><body><p>child a</p></body></html>",
            "/child-b": "<html><body><p>child b</p></body></html>"
        ])
        // Above `start`: a throwing start (timeout, bind failure) must not leak
        // the listener.
        defer { server.stop() }
        let port = try await server.start()

        // Wake the service worker before the page loads: a hello sent while the
        // worker is asleep gets an empty reply and is never recorded (observed
        // 2026-09-12), which matters for the Phase-3 registry design too.
        let wv = try await makeExtensionWebView()
        _ = try await askWorker(from: wv, message: ["type": "ping"])
        // `__frameHellos` lives on the shared worker's globalThis and is never
        // reset by it, so a previous probe's records are still there. Drop them
        // before this probe's page loads, or the poll below returns instantly
        // with hellos from a tab that no longer exists (TASK-65).
        _ = try await askWorker(from: wv, message: ["type": "clearFrameHellos"])

        let config = WKWebViewConfiguration()
        config.webExtensionController = state.controller
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)

        // Register the web view as a tab in a window of the extension context
        // *before* loading. Without it the worker sees no tab at all: content
        // script messages never arrive and chrome.tabs.query is empty. Nothing
        // in this suite goes through TabStore's observer (which is what does
        // this in the app), and BrowserTab's `window(for:)` needs a real
        // BrowserWindowController, so use minimal conformances instead.
        let probe = registerProbeTab(for: pageView, in: state.context)
        defer { unregisterProbeTab(probe, in: state.context) }

        try await loadAndWait(pageView, URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))

        // Subframes finish after the main frame's didFinish; poll for the hellos
        // instead of sleeping blindly.
        // Belt and braces with the clear above: the loopback port is unique to
        // this probe, so scoping by it keeps any other tab's hello out of the
        // poll and out of the assertions below.
        let probeOrigin = "http://127.0.0.1:\(port)/"
        var hellos: [[String: Any]] = []
        for _ in 0..<40 {
            let reply = try await askWorker(from: wv, message: ["type": "getFrameHellos"])
            let recorded = (reply["reply"] as? [String: Any])?["hellos"] as? [[String: Any]] ?? []
            hellos = recorded.filter { ($0["url"] as? String)?.hasPrefix(probeOrigin) == true }
            if hellos.count >= 3 { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let topReply = try await pageView.evaluateJavaScript(
            "document.documentElement.dataset.frameReply || null") as? String

        let probedTabID = hellos.compactMap { $0["tabId"] as? Int }.first
        let frameProbe = probedTabID != nil
            ? try await askWorker(from: wv, message: ["type": "probeWebNavFrames", "tabId": probedTabID!])
            : try await askWorker(from: wv, message: ["type": "probeWebNavFrames"])

        // Can a non-zero frame id actually be used to target that frame?
        let enumeratedFrames = ((frameProbe["reply"] as? [String: Any])?["getAllFrames"] as? [[String: Any]]) ?? []
        let helloSubframeID = hellos.compactMap { $0["frameId"] as? Int }.first { $0 != 0 }
        let nonZeroFrameID = helloSubframeID
            ?? enumeratedFrames.compactMap { $0["frameId"] as? Int }.first { $0 != 0 }
        var targeting: [String: Any] = [:]
        if let tabID = probedTabID, let frameID = nonZeroFrameID {
            targeting = try await askWorker(
                from: wv, message: ["type": "probeFrameTargeting", "tabId": tabID, "frameId": frameID])
        }

        let evidence = """
        topReply=\(topReply ?? "nil")
        hellos=\(hellos)
        frameProbe=\(frameProbe)
        targetedFrameId=\(nonZeroFrameID.map(String.init) ?? "nil")
        targeting=\(targeting)
        """

        // 1. Content scripts reach the worker from every real frame, top and sub.
        XCTAssertNotNil(topReply, "content script never stored a reply in the top frame: \(evidence)")
        XCTAssertGreaterThanOrEqual(hellos.count, 3,
                                    "expected a hello from the top frame and both http subframes: \(evidence)")
        XCTAssertTrue(hellos.contains { ($0["frameId"] as? Int) == 0 },
                      "the top frame must report frameId 0: \(evidence)")
        XCTAssertNotNil(helloSubframeID, "no subframe reported a non-zero frameId: \(evidence)")

        // 2. `sender.tab` resolves once the web view is a registered tab, and
        //    every frame reports the same tab with a distinct frame id.
        XCTAssertTrue(hellos.allSatisfy { ($0["hasTab"] as? Bool) == true },
                      "sender.tab must be populated for a registered tab: \(evidence)")
        XCTAssertEqual(Set(hellos.compactMap { $0["tabId"] as? Int }).count, 1, evidence)
        let distinctFrameIDs = Set(hellos.compactMap { $0["frameId"] as? Int })
        XCTAssertEqual(distinctFrameIDs.count, hellos.count,
                       "frame ids must be unique per frame: \(evidence)")

        // 3. Native getAllFrames enumerates the subframes with those same ids.
        //    This is the finding that decides TASK-4: WebKit already answers the
        //    question a worker-side frame registry would have been built for.
        XCTAssertGreaterThanOrEqual(enumeratedFrames.count, 3,
                                    "native getAllFrames should list the subframes: \(evidence)")
        let enumeratedIDs = Set(enumeratedFrames.compactMap { $0["frameId"] as? Int })
        XCTAssertTrue(distinctFrameIDs.isSubset(of: enumeratedIDs),
                      "every frame that said hello must appear in getAllFrames with the same id: \(evidence)")
        let topRecord = enumeratedFrames.first { ($0["frameId"] as? Int) == 0 }
        XCTAssertEqual(topRecord?["parentFrameId"] as? Int, -1, evidence)
        for frame in enumeratedFrames where (frame["frameId"] as? Int) != 0 {
            XCTAssertEqual(frame["parentFrameId"] as? Int, 0,
                           "depth-one frames should report parentFrameId 0: \(evidence)")
        }

        // 4. Those ids are usable for targeting: getFrame resolves one and
        //    tabs.sendMessage with {frameId} reaches that frame's content script.
        XCTAssertNil(targeting["lastError"] as? String, evidence)
        let targetingReply = try XCTUnwrap(targeting["reply"] as? [String: Any], evidence)
        XCTAssertNil(targetingReply["getFrameError"] as? String, evidence)
        XCTAssertNotNil(targetingReply["getFrame"] as? [String: Any],
                        "getFrame should resolve an observed frame id: \(evidence)")
        let pong = (targetingReply["sendMessage"] as? [String: Any])?["reply"] as? [String: Any]
        XCTAssertEqual(pong?["type"] as? String, "pong",
                       "tabs.sendMessage with {frameId} must reach that frame: \(evidence)")
        XCTAssertEqual(pong?["isTop"] as? Bool, false,
                       "the pong must come from the subframe, not the top frame: \(evidence)")
    }

    /// TASK-4: which *kinds* of frame does WebKit's native frame enumeration
    /// report, and which of them does a content script actually reach?
    ///
    /// 1Password logs "[Tabs] Could not collect all frames that were initially
    /// found" while filling a login form inside an iframe. It counts frames from
    /// `webNavigation.getAllFrames({tabId})`, filters them by URL, and fans
    /// `tabs.sendMessage(tabId, msg, {frameId})` out to each one. A frame that is
    /// enumerated but carries no URL for that filter — or that has no content
    /// script to receive the fan-out — is exactly the shape of that complaint, so
    /// this measures what WebKit answers per frame kind rather than assuming.
    ///
    /// The fixture is a login page with three login-form iframes: a cross-origin
    /// http one (a second loopback server — a different port is a different
    /// origin), a `srcdoc` one, and an `about:blank` one the parent fills by
    /// script after load. Only the stable facts are asserted; the srcdoc and
    /// about:blank rows are the measurement, printed as
    /// `TASK-4 frame-kind measurement:` lines and attached to the activity.
    func testFrameKindsAsReportedByNativeGetAllFrames() async throws {
        // Single-quoted attributes so the same markup can also sit inside a
        // double-quoted `srcdoc=` attribute and a double-quoted JS string.
        func loginForm(_ marker: String) -> String {
            "<form><input name='username' value='\(marker)'>"
                + "<input type='password' name='password'><button>Sign in</button></form>"
        }

        // Server B: the cross-origin child. Started first so the top page can
        // point an iframe at its port.
        let crossOriginServer = try LoopbackHTTPServer(routes: [
            "/login": "<html><body><p>cross-origin login</p>\(loginForm("cross-origin-marker"))</body></html>"
        ])
        defer { crossOriginServer.stop() }
        let crossOriginPort = try await crossOriginServer.start()

        let topServer = try LoopbackHTTPServer(routes: [
            "/": """
                <html><body><p>top</p>
                \(loginForm("top-marker"))
                <iframe id="crossOriginFrame" name="crossOriginFrame"
                        src="http://127.0.0.1:\(crossOriginPort)/login"></iframe>
                <iframe id="srcdocFrame" name="srcdocFrame"
                        srcdoc="<p>srcdoc login</p>\(loginForm("srcdoc-marker"))"></iframe>
                <iframe id="blankFrame" name="blankFrame"></iframe>
                <script>
                window.addEventListener('load', () => {
                    const frame = document.getElementById('blankFrame');
                    frame.contentDocument.body.innerHTML =
                        "<p>about:blank login</p>\(loginForm("blank-marker"))";
                    document.documentElement.dataset.blankFilled = '1';
                });
                </script>
                </body></html>
                """
        ])
        defer { topServer.stop() }
        let topPort = try await topServer.start()

        let topOrigin = "http://127.0.0.1:\(topPort)/"
        let childOrigin = "http://127.0.0.1:\(crossOriginPort)/"

        // Wake the worker before the page loads (a hello sent to a sleeping
        // worker is never recorded), then drop the previous probe's records —
        // `__frameHellos` lives on the shared worker and only grows (TASK-65).
        let wv = try await makeExtensionWebView()
        _ = try await askWorker(from: wv, message: ["type": "ping"])
        _ = try await askWorker(from: wv, message: ["type": "clearFrameHellos"])

        let config = WKWebViewConfiguration()
        config.webExtensionController = state.controller
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 500), configuration: config)

        // The web view has to be a registered tab *before* it loads, or the
        // worker sees no tab: content-script messages never arrive and
        // getAllFrames answers "Tab not found".
        let probe = registerProbeTab(for: pageView, in: state.context)
        defer { unregisterProbeTab(probe, in: state.context) }

        try await loadAndWait(pageView, URLRequest(url: URL(string: topOrigin)!))

        // The about:blank frame only has its login form once the parent's load
        // handler has run.
        try await waitUntil("the about:blank frame to be filled by its parent") {
            (try await pageView.evaluateJavaScript(
                "document.documentElement.dataset.blankFilled === '1'") as? Bool) == true
        }

        // Which frames say hello is the thing being measured, so the poll must
        // not stop at an expected count: wait for the first hello, then give the
        // remaining frames a fixed grace period.
        var hellos: [[String: Any]] = []
        var probedTabID: Int?
        var firstHelloAt: Date?
        let helloDeadline = Date().addingTimeInterval(10)
        while Date() < helloDeadline {
            let reply = try await askWorker(from: wv, message: ["type": "getFrameHellos"])
            let recorded = ((reply["reply"] as? [String: Any])?["hellos"] as? [[String: Any]]) ?? []
            // Scope by tab id, not origin: a srcdoc or about:blank frame's hello
            // may carry no URL this probe could be recognised by. The top
            // frame's hello is what supplies the id.
            if probedTabID == nil {
                probedTabID = recorded.first {
                    ($0["url"] as? String)?.hasPrefix(topOrigin) == true
                }?["tabId"] as? Int
            }
            if let tabID = probedTabID {
                hellos = recorded.filter { ($0["tabId"] as? Int) == tabID }
                if firstHelloAt == nil { firstHelloAt = Date() }
            }
            if let first = firstHelloAt, Date().timeIntervalSince(first) >= 3 { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let frameProbe = probedTabID != nil
            ? try await askWorker(from: wv, message: ["type": "probeWebNavFrames", "tabId": probedTabID!])
            : try await askWorker(from: wv, message: ["type": "probeWebNavFrames"])
        let frameReply = frameProbe["reply"] as? [String: Any]
        let enumeratedFrames = (frameReply?["getAllFrames"] as? [[String: Any]]) ?? []
        let tabID = probedTabID ?? (frameReply?["probedTabId"] as? Int)

        // Is each enumerated id usable for targeting — does getFrame resolve it,
        // and does tabs.sendMessage with it find a receiver?
        var targetingByFrameID: [Int: [String: Any]] = [:]
        if let tabID {
            for frame in enumeratedFrames {
                guard let frameID = frame["frameId"] as? Int else { continue }
                let answer = try await askWorker(
                    from: wv,
                    message: ["type": "probeFrameTargeting", "tabId": tabID, "frameId": frameID],
                    timeout: 15)
                targetingByFrameID[frameID] = (answer["reply"] as? [String: Any]) ?? [:]
            }
        }

        // If WebKit reports the srcdoc and about:blank frames with the same
        // (empty) URL, nothing in the row says which is which. Remove one iframe
        // element at a time and diff the enumeration: the id that disappears
        // belonged to the element just removed. Runs after every probe above, so
        // it cannot disturb them.
        func currentFrameIDs() async throws -> Set<Int> {
            guard let tabID else { return [] }
            let answer = try await askWorker(
                from: wv, message: ["type": "probeWebNavFrames", "tabId": tabID])
            let rows = ((answer["reply"] as? [String: Any])?["getAllFrames"] as? [[String: Any]]) ?? []
            return Set(rows.compactMap { $0["frameId"] as? Int })
        }
        func removeIFrame(_ elementID: String, from ids: Set<Int>) async throws
            -> (removed: Int?, remaining: Set<Int>) {
            _ = try await pageView.evaluateJavaScript(
                "(() => { const e = document.getElementById('\(elementID)'); if (e) { e.remove(); } return true; })()")
            var remaining = ids
            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 250_000_000)
                remaining = try await currentFrameIDs()
                if remaining.count < ids.count { break }
            }
            let gone = ids.subtracting(remaining)
            return (gone.count == 1 ? gone.first : nil, remaining)
        }

        let enumeratedIDs = Set(enumeratedFrames.compactMap { $0["frameId"] as? Int })
        let srcdocRemoval = try await removeIFrame("srcdocFrame", from: enumeratedIDs)
        let blankRemoval = try await removeIFrame("blankFrame", from: srcdocRemoval.remaining)

        func row(forFrameID frameID: Int?) -> [String: Any]? {
            guard let frameID else { return nil }
            return enumeratedFrames.first { ($0["frameId"] as? Int) == frameID }
        }
        let topRow = enumeratedFrames.first { ($0["frameId"] as? Int) == 0 }
        let crossOriginRow = enumeratedFrames.first {
            ($0["url"] as? String)?.hasPrefix(childOrigin) == true
        }
        let srcdocRow = row(forFrameID: srcdocRemoval.removed)
        let blankRow = row(forFrameID: blankRemoval.removed)

        // One measurement per line: a nested dictionary's default description
        // spans several lines, which would split a measurement across them.
        func show(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "nil" }
            if let text = value as? String { return text.isEmpty ? "''" : text }
            return String(describing: value)
                .split(whereSeparator: { $0.isNewline || $0 == "\t" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
        }
        func helloReply(_ frameID: Int) -> [String: Any]? {
            hellos.first { ($0["frameId"] as? Int) == frameID }
        }
        func pongArrived(_ frameID: Int) -> Bool {
            let sendMessage = targetingByFrameID[frameID]?["sendMessage"] as? [String: Any]
            return ((sendMessage?["reply"] as? [String: Any])?["type"] as? String) == "pong"
        }
        func measurement(_ kind: String, _ frameRow: [String: Any]?) -> String {
            guard let frameRow, let frameID = frameRow["frameId"] as? Int else {
                return "kind=\(kind) enumerated=no (not identified in getAllFrames)"
            }
            let hello = helloReply(frameID)
            let targeting = targetingByFrameID[frameID]
            var parts = [
                "kind=\(kind)",
                "enumerated=yes",
                "url=\(show(frameRow["url"]))",
                "frameId=\(frameID)",
                "parentFrameId=\(show(frameRow["parentFrameId"]))",
                "contentScriptHello=\(hello == nil ? "no" : "yes")",
                "helloLocation=\(show(hello?["reportedURL"]))",
                "helloSenderURL=\(show(hello?["url"]))",
                "sendMessageReached=\(pongArrived(frameID) ? "yes" : "no")"
            ]
            parts.append("sendMessage=\(show(targeting?["sendMessage"]))")
            parts.append("getFrame=\(show(targeting?["getFrame"]))")
            parts.append("getFrameError=\(show(targeting?["getFrameError"]))")
            return parts.joined(separator: " ")
        }

        let measurements = [
            measurement("top (http)", topRow),
            measurement("iframe-a cross-origin http", crossOriginRow),
            measurement("iframe-b srcdoc", srcdocRow),
            measurement("iframe-c about:blank", blankRow)
        ]
        let unclassified = enumeratedFrames.filter { frame in
            let id = frame["frameId"] as? Int
            return id != 0
                && id != (crossOriginRow?["frameId"] as? Int)
                && id != srcdocRemoval.removed
                && id != blankRemoval.removed
        }
        let evidence = ([
            "probedTabId=\(show(tabID))",
            "srcdocFrameId=\(show(srcdocRemoval.removed)) blankFrameId=\(show(blankRemoval.removed))",
            "rawGetAllFrames=\(enumeratedFrames)",
            "rawHellos=\(hellos)",
            "unclassifiedRows=\(unclassified)",
            "getAllFramesError=\(show(frameReply?["getAllFramesError"]))"
        ] + measurements).joined(separator: "\n")
        for line in measurements { print("TASK-4 frame-kind measurement: \(line)") }
        print("TASK-4 frame-kind measurement: probedTabId=\(show(tabID)) "
              + "srcdocFrameId=\(show(srcdocRemoval.removed)) blankFrameId=\(show(blankRemoval.removed))")
        print("TASK-4 frame-kind measurement: rawGetAllFrames=\(enumeratedFrames)")
        print("TASK-4 frame-kind measurement: rawHellos=\(hellos)")
        print("TASK-4 frame-kind measurement: unclassifiedRows=\(unclassified)")
        XCTContext.runActivity(named: "TASK-4 frame-kind measurement") { activity in
            let attachment = XCTAttachment(string: evidence)
            attachment.name = "frame-kind measurement"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        // --- Stable facts only. ---

        // 1. The top frame and the cross-origin http frame are both enumerated
        //    with a real http URL, at the expected depth.
        let topFrame = try XCTUnwrap(topRow, "the top frame must be enumerated: \(evidence)")
        XCTAssertEqual(topFrame["parentFrameId"] as? Int, -1, evidence)
        XCTAssertTrue((topFrame["url"] as? String)?.hasPrefix(topOrigin) == true,
                      "the top frame must be enumerated with its http URL: \(evidence)")
        let crossOriginFrame = try XCTUnwrap(
            crossOriginRow, "the cross-origin http frame must be enumerated with its URL: \(evidence)")
        let crossOriginFrameID = try XCTUnwrap(crossOriginFrame["frameId"] as? Int, evidence)
        XCTAssertNotEqual(crossOriginFrameID, 0, evidence)
        XCTAssertEqual(crossOriginFrame["parentFrameId"] as? Int, 0, evidence)

        // 2. Both real http frames run a content script that reaches the worker,
        //    each with its own frame id, and both are reachable by frame id.
        XCTAssertNotNil(helloReply(0), "the top frame must say hello: \(evidence)")
        XCTAssertNotNil(helloReply(crossOriginFrameID),
                        "the cross-origin http frame must say hello: \(evidence)")
        XCTAssertTrue(pongArrived(0),
                      "tabs.sendMessage must reach the top frame by frame id: \(evidence)")
        XCTAssertTrue(pongArrived(crossOriginFrameID),
                      "tabs.sendMessage must reach the cross-origin frame by frame id: \(evidence)")

        // 3. Every frame that said hello is enumerated under the same id — the
        //    invariant 1Password's "frames I found vs frames I reached"
        //    bookkeeping rests on.
        let helloFrameIDs = Set(hellos.compactMap { $0["frameId"] as? Int })
        XCTAssertEqual(helloFrameIDs.count, hellos.count,
                       "frame ids must be unique per frame: \(evidence)")
        XCTAssertTrue(helloFrameIDs.isSubset(of: enumeratedIDs),
                      "every hello's frameId must appear in getAllFrames: \(evidence)")

        // 4. Measured behaviour of the two non-http frame kinds, pinned so a
        //    WebKit change is noticed rather than silently changing the answer
        //    this task is based on (macOS 26.0, Safari/WebKit 26.0 —
        //    see docs/1password-integration-plan.md, Phase 3). These are NOT
        //    requirements: if WebKit starts reporting about:srcdoc/about:blank
        //    or injecting content scripts there, that is the fix TASK-4 wants
        //    and these assertions are what will say so.
        let srcdocFrame = try XCTUnwrap(
            srcdocRow, "the srcdoc frame was not identified in getAllFrames: \(evidence)")
        let blankFrame = try XCTUnwrap(
            blankRow, "the about:blank frame was not identified in getAllFrames: \(evidence)")
        for (kind, frame) in [("srcdoc", srcdocFrame), ("about:blank", blankFrame)] {
            let frameID = try XCTUnwrap(frame["frameId"] as? Int, evidence)
            // Enumerated — so 1Password counts it — but with no URL for its
            // URL filter (Chrome reports about:srcdoc / about:blank here).
            XCTAssertEqual(frame["url"] as? String, "",
                           "WebKit reports the \(kind) frame with an empty URL: \(evidence)")
            XCTAssertEqual(frame["parentFrameId"] as? Int, 0, evidence)
            // ...and no content script runs in it, so the fan-out finds no
            // receiver there however the frame id is obtained.
            XCTAssertNil(helloReply(frameID),
                         "no content script is injected into the \(kind) frame: \(evidence)")
            XCTAssertFalse(pongArrived(frameID),
                           "tabs.sendMessage must find no receiver in the \(kind) frame: \(evidence)")
        }
    }

    // MARK: - TASK-8: WebSocket relay

    /// The whole relay, end to end in a real module service worker: `new
    /// WebSocket()` reaches a real server through Detour's port, echoes a text and
    /// a binary frame, and closes cleanly — without touching WebKit's worker
    /// channel, which would deadlock this worker (TASK-2).
    func testWorkerWebSocketIsRelayedToARealServer() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let serverPort = try await server.start()

        let wv = try await makeExtensionWebView()
        let answer = try await askWorker(
            from: wv, message: ["type": "wsProbe", "url": "ws://127.0.0.1:\(serverPort)/"], timeout: 20)
        XCTAssertNil(answer["lastError"] as? String, "sendMessage to the worker reported lastError")
        let reply = try XCTUnwrap(answer["reply"] as? [String: Any],
                                  "the worker must answer the probe: \(answer)")

        XCTAssertEqual(reply["mode"] as? String, "relay",
                       "the worker must have taken the relay, not the guard fallback: \(reply)")
        XCTAssertEqual(reply["timedOut"] as? Bool, false, "the probe timed out: \(reply)")
        XCTAssertEqual(reply["opened"] as? Bool, true, "the socket never opened: \(reply)")
        XCTAssertNil(reply["error"] as? String, "\(reply)")

        let messages = try XCTUnwrap(reply["messages"] as? [[String: Any]], "\(reply)")
        XCTAssertEqual(messages.count, 2, "expected a text and a binary echo: \(reply)")
        XCTAssertEqual(messages.first?["text"] as? String, "hello")
        XCTAssertEqual(messages.last?["bytes"] as? [Int], [1, 2, 3, 4],
                       "binary frames must survive the base64 hop in both directions")

        XCTAssertEqual(reply["closeCode"] as? Int, 1000, "\(reply)")
        XCTAssertEqual(reply["wasClean"] as? Bool, true, "\(reply)")
        XCTAssertEqual(reply["openSockets"] as? Int, 0, "the socket must be accounted closed")

        // The worker dropped its port when the socket closed, so Detour holds no
        // session for it any more.
        try await waitUntil("the relay session to be released") {
            ExtensionManager.shared.webSocketRelayCountForTesting(
                controller: self.state.controller, extensionID: Self.extensionID) == 0
        }
    }

    /// NEGATIVE: the relay host only exists as a port. A one-shot
    /// `sendNativeMessage` to it must be refused by the delegate rather than
    /// falling through to the real native-host path (where its name is exempt from
    /// the manifest gate and a host process named after it would be looked up).
    func testOneShotMessageToTheRelayHostIsRejected() async throws {
        let wv = try await makeExtensionWebView()
        let answer = try await askWorker(from: wv, message: ["type": "rawRelayNative"], timeout: 10)
        let reply = try XCTUnwrap(answer["reply"] as? [String: Any], "\(answer)")
        XCTAssertEqual(reply["ok"] as? Bool, false, "a one-shot relay message must not be accepted: \(reply)")
        let error = reply["error"] as? String ?? ""
        XCTAssertTrue(error.contains("port-only host"),
                      "expected the delegate's port-only rejection, got: \(error)")
    }
}

// `LoopbackHTTPServer` (also used by ExtensionMenuPopupDecisionTests),
// `LockedFlag` (shared with the loopback WebSocket server) and the
// `ProbeExtensionWindow`/`ProbeExtensionTab` conformances used above (shared with
// WKExtensionIntegrationTests) live in ExtensionTestSupport.
