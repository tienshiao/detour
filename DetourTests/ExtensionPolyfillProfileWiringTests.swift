import XCTest
import WebKit
@testable import Detour

/// Tests the production wiring between `Profile` and `ExtensionPolyfillHandler`
/// (TASK-13): the handler is constructed with a back-reference to the profile
/// that owns its controller, and resolves both sender origins and extension
/// contexts through that profile.
///
/// Unlike `ExtensionPolyfillTests` (bare web view plus a test seam) and
/// `ExtensionPolyfillIntegrationTests` (controller built by hand), these tests
/// go through `Profile.extensionController` / `Profile.loadExtensionContext`
/// with no test-side origin wiring at all, so deleting the wiring in
/// `Profile.extensionController` fails them.
@MainActor
final class ExtensionPolyfillProfileWiringTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var previousLastActiveSpaceID: UUID?
    /// Restored in tearDown: a leg that shortens Detour's keep-alive ping interval
    /// (TASK-68) must not leave it shortened for the rest of the suite.
    private var previousKeepAlivePingInterval: TimeInterval = 30
    /// Restored in tearDown with it: the recovery knobs a leg lowers so a silent
    /// background is torn down and restarted in seconds rather than minutes.
    private var previousKeepAliveMissedReplyLimit = 2
    private var previousKeepAliveRestartDelay: TimeInterval = 35
    /// Fake native messaging hosts installed by a test (TASK-62); torn down —
    /// env var restored, every spawned process killed — after every test.
    private var fakeNativeHosts: [FakeNativeMessagingHost] = []

    override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
        previousKeepAlivePingInterval = ExtensionManager.shared.keepAlivePingInterval
        previousKeepAliveMissedReplyLimit = ExtensionManager.shared.keepAliveMissedReplyLimit
        previousKeepAliveRestartDelay = ExtensionManager.shared.keepAliveRestartDelay
    }

    override func tearDown() {
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
        for id in createdSpaceIDs {
            // `forceRemoveSpace` drops the space (and its closed-tab records) but
            // never tears a tab down, so any tab a test opened would keep its web
            // view loading. Close them first; the closed-tab rows the closes push
            // are purged by `forceRemoveSpace` right after.
            if let space = TabStore.shared.space(withID: id) {
                for tab in space.tabs {
                    TabStore.shared.closeTab(id: tab.id, in: space)
                }
            }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        ExtensionManager.shared.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.keepAlivePingInterval = previousKeepAlivePingInterval
        ExtensionManager.shared.keepAliveMissedReplyLimit = previousKeepAliveMissedReplyLimit
        ExtensionManager.shared.keepAliveRestartDelay = previousKeepAliveRestartDelay
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
        }
        registeredExtensionIDs.removeAll()
        // LIFO: each fixture restores the env var it captured at init, so the last one created must restore first.
        for host in fakeNativeHosts.reversed() {
            host.tearDown()
        }
        fakeNativeHosts.removeAll()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Write an MV3 extension to a fresh temp directory and register it in
    /// ExtensionManager, the way an installed extension is registered. The id is
    /// unique per call so leftovers from another run can never match.
    ///
    /// The default is a minimal extension with no background content, one test
    /// page and one offscreen page; `manifest` and `extraFiles` (written next to
    /// them, e.g. a `background.js`) replace and extend that for tests that need a
    /// different shape.
    private func makeTestExtension(idPrefix: String = "polyfill-wiring",
                                   manifest: String? = nil,
                                   extraFiles: [String: String] = [:]) async throws -> WebExtension {
        let id = "\(idPrefix)-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let manifestJSON = manifest ?? """
        {
            "manifest_version": 3,
            "name": "Polyfill Wiring Test",
            "version": "1.0.0",
            "permissions": ["offscreen"]
        }
        """
        try manifestJSON.write(to: dir.appendingPathComponent("manifest.json"),
                               atomically: true, encoding: .utf8)
        try "<html><body><div id=\"test\">wiring test page</div></body></html>"
            .write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)
        try "<html><body><div id=\"offscreen\">offscreen</div></body></html>"
            .write(to: dir.appendingPathComponent("offscreen.html"), atomically: true, encoding: .utf8)
        for (name, contents) in extraFiles {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    private func addSpace(for profile: Profile, name: String) -> Space {
        let space = TabStore.shared.addSpace(
            name: name, emoji: "W", colorHex: "#000000", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    /// Load an extension page from the profile's loaded context, exactly as a
    /// popup or options page is loaded (the configuration carries the polyfill
    /// handler registered by `Profile.extensionController`).
    private func makeExtensionWebView(for context: WKWebExtensionContext) async throws -> WKWebView {
        let config = try XCTUnwrap(context.webViewConfiguration,
                                   "webViewConfiguration is nil — context not loaded in a controller")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        try await loadAndWait(webView, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        return webView
    }

    // MARK: - AC #3: production wiring attributes a context origin

    /// A real Profile, its lazily built controller, and a context loaded through
    /// `loadExtensionContext` are enough on their own: the page's
    /// `webkit-extension://<UUID>/` origin is attributed to the extension with
    /// no test-side resolver.
    func testProductionWiringAttributesContextOriginToExtension() async throws {
        let ext = try await makeTestExtension()
        let profile = makeProfile("Wiring Profile")
        // Force the lazy controller (and with it the polyfill handler) before use.
        _ = profile.extensionController
        // The Bool means "has background content", not "loaded"; this extension
        // has none, so the contexts dictionary is the source of truth.
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id],
                                    "the context should be loaded in the profile's controller")

        let handler = try XCTUnwrap(profile.polyfillHandler,
                                    "extensionController must retain a polyfill handler")
        XCTAssertTrue(handler.profile === profile,
                      "the handler must point back at the profile that built it")

        let scheme = try XCTUnwrap(context.baseURL.scheme)
        let host = try XCTUnwrap(context.baseURL.host)
        XCTAssertEqual(profile.extensionID(forOriginScheme: scheme, host: host), ext.id)

        let webView = try await makeExtensionWebView(for: context)
        let reply = try await postRawPolyfillEnvelope(from: webView, type: "idle.queryState", claimedID: "")
        XCTAssertNil(reply.error, "an extension page in this profile must be recognised")
        XCTAssertTrue(["active", "idle", "locked"].contains(reply.result as? String ?? ""),
                      "expected an idle state, got \(String(describing: reply.result))")
    }

    // MARK: - AC #2: offscreen documents belong to the sender's profile

    /// The same extension is loaded in two profiles and the last-active space
    /// points at profile A, so `ExtensionManager.context(for:)` would answer with
    /// A's context. The document must still be built from B's context (B's
    /// controller, B's data store), because B's handler received the request.
    func testOffscreenDocumentIsCreatedInSendersProfile() async throws {
        let ext = try await makeTestExtension()
        let profileA = makeProfile("Wiring Profile A")
        let profileB = makeProfile("Wiring Profile B")
        _ = profileA.extensionController
        _ = profileB.extensionController
        _ = profileA.loadExtensionContext(ext)
        _ = profileB.loadExtensionContext(ext)

        let contextA = try XCTUnwrap(profileA.extensionContexts[ext.id])
        let contextB = try XCTUnwrap(profileB.extensionContexts[ext.id])
        let hostA = try XCTUnwrap(contextA.baseURL.host)
        let hostB = try XCTUnwrap(contextB.baseURL.host)
        XCTAssertNotEqual(hostA, hostB,
                          "WebKit should give each loaded context its own origin")

        // Make ExtensionManager's global lookup prefer profile A.
        let spaceA = addSpace(for: profileA, name: "Wiring Space A")
        ExtensionManager.shared.lastActiveSpaceID = spaceA.id
        XCTAssertTrue(ExtensionManager.shared.context(for: ext.id) === contextA,
                      "precondition: the global lookup must prefer profile A's context")

        let handlerB = try XCTUnwrap(profileB.polyfillHandler)
        let created = expectation(description: "offscreen.createDocument reply")
        var replyResult: Any?
        var replyError: Error?
        handlerB.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            replyResult = result
            replyError = error
            created.fulfill()
        }
        await fulfillment(of: [created], timeout: 10)

        XCTAssertNil(replyError, "createDocument failed: \(String(describing: replyError))")
        XCTAssertEqual(replyResult as? Bool, true)

        let host = try XCTUnwrap(profileB.polyfillHandler?.offscreenHosts[ext.id],
                                 "the sending profile should own the offscreen host")
        let documentHost = try XCTUnwrap(host.webView?.url?.host)
        XCTAssertEqual(documentHost.caseInsensitiveCompare(hostB), .orderedSame,
                       "the offscreen document must load from profile B's context origin, got \(documentHost)")
        XCTAssertNil(profileA.polyfillHandler?.offscreenHosts[ext.id],
                     "profile A never sent the request and must not host the document")

        // Teardown runs through the owning profile.
        profileB.unloadExtension(id: ext.id)
        XCTAssertNil(profileB.polyfillHandler?.offscreenHosts[ext.id],
                     "unloading the context in its own profile must release the document")
    }

    /// NEGATIVE: the handler's profile has no context for the extension, while
    /// another (last-active) profile does. Without the old
    /// `ExtensionManager.context(for:)` fallback this must fail rather than
    /// silently borrow the other profile's context.
    func testOffscreenDocumentFailsWhenContextNotLoadedInHandlersProfile() async throws {
        let ext = try await makeTestExtension()
        let profileA = makeProfile("Wiring Loaded Profile")
        let profileB = makeProfile("Wiring Empty Profile")
        _ = profileA.extensionController
        _ = profileB.extensionController
        _ = profileA.loadExtensionContext(ext)
        XCTAssertNotNil(profileA.extensionContexts[ext.id])
        XCTAssertNil(profileB.extensionContexts[ext.id])

        let spaceA = addSpace(for: profileA, name: "Wiring Loaded Space")
        ExtensionManager.shared.lastActiveSpaceID = spaceA.id

        let handlerB = try XCTUnwrap(profileB.polyfillHandler)
        let replied = expectation(description: "offscreen.createDocument reply")
        var replyResult: Any?
        var replyError: Error?
        handlerB.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            replyResult = result
            replyError = error
            replied.fulfill()
        }
        await fulfillment(of: [replied], timeout: 10)

        XCTAssertNil(replyResult)
        XCTAssertEqual((replyError as NSError?)?.localizedDescription, "Extension not found")
        XCTAssertNil(profileB.polyfillHandler?.offscreenHosts[ext.id])
        XCTAssertNil(profileA.polyfillHandler?.offscreenHosts[ext.id],
                     "the other profile must not have been used to host the document")
    }

    // MARK: - TASK-18: a failed offscreen page load settles and unregisters

    /// The page the extension asks for does not exist, so the navigation fails
    /// instead of finishing. The request must be rejected and the dead host
    /// unregistered: otherwise the promise pends forever, `hasDocument` claims a
    /// document that never loaded, and every later `createDocument`
    /// short-circuits with success against the corpse.
    func testOffscreenCreateDocumentFailsAndUnregistersWhenPageIsMissing() async throws {
        let ext = try await makeTestExtension()
        let profile = makeProfile("Offscreen Failure Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let contextHost = try XCTUnwrap(context.baseURL.host)
        let handler = try XCTUnwrap(profile.polyfillHandler)

        // One reply, and only one: the failure path stops the host, which must
        // not drain the same completion a second time.
        let failed = expectation(description: "offscreen.createDocument reply for a missing page")
        var replyResult: Any?
        var replyError: (any Error)?
        var replyCount = 0
        handler.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "no-such-offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            replyCount += 1
            replyResult = result
            replyError = error
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 10)

        XCTAssertNil(replyResult, "a document that never loaded must not report success")
        let message = try XCTUnwrap((replyError as NSError?)?.localizedDescription)
        XCTAssertTrue(message.contains("no-such-offscreen.html") && message.contains("failed to load"),
                      "the error should name the page that failed, got: \(message)")
        XCTAssertNil(handler.offscreenHosts[ext.id],
                     "the failed host must be unregistered, not left to fake a document")
        let hasDoc = await nativeReply(
            handler, ["type": "offscreen.hasDocument", "extensionID": ext.id],
            verifiedExtensionID: ext.id)
        XCTAssertEqual(hasDoc.result as? Bool, false,
                       "hasDocument must not report the document that failed to load")

        // A retry with a page that exists has to load: the failure left nothing
        // registered to short-circuit it.
        let retry = await nativeReply(
            handler, ["type": "offscreen.createDocument", "extensionID": ext.id,
                      "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id, description: "offscreen.createDocument retry")
        XCTAssertNil(retry.error, "the retry failed: \(String(describing: retry.error))")
        XCTAssertEqual(retry.result as? Bool, true)
        let host = try XCTUnwrap(handler.offscreenHosts[ext.id], "the retry should be hosted")
        let documentHost = try XCTUnwrap(host.webView?.url?.host)
        XCTAssertEqual(documentHost.caseInsensitiveCompare(contextHost), .orderedSame)
        XCTAssertEqual(replyCount, 1, "the failed request must be answered exactly once")
    }

    // MARK: - TASK-23: callback-form failures reach runtime.lastError

    /// The TASK-18 failure seen from a real extension page using the callback
    /// form. WebKit's native `runtime.lastError` ignores every JS write (probed
    /// 2026-09-12: defineProperty, assignment and delete all "succeed" and
    /// reads stay null), so the polyfill relays the message through the
    /// callback-style `runtime.sendNativeMessage` and WebKit sets lastError
    /// itself. The page's manifest declares only `offscreen`, so this also
    /// shows the relay does not depend on the extension declaring
    /// nativeMessaging (Profile grants it at the context level).
    ///
    /// If a future WebKit makes lastError writable, `mode` turns 'js' and the
    /// message loses WebKit's prefix; the callback contract assertions hold
    /// either way.
    func testOffscreenCreateDocumentCallbackGetsLastErrorInARealExtensionPage() async throws {
        let ext = try await makeTestExtension()
        let profile = makeProfile("Offscreen lastError Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let handler = try XCTUnwrap(profile.polyfillHandler)
        let webView = try await makeExtensionWebView(for: context)

        func evalObject(_ js: String) async throws -> [String: Any] {
            let raw = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
            let json = try XCTUnwrap(raw as? String, "expected a JSON string, got \(String(describing: raw))")
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }

        // NEGATIVE: the page does not exist.
        let failed = try await evalObject(callbackOutcomeJS(call: """
            return chrome.offscreen.createDocument(
                { url: 'no-such-offscreen.html', reasons: ['DOM_PARSER'], justification: 'test' }, cb);
        """))
        XCTAssertEqual(failed["timedOut"] as? Bool, false, "the callback must run on failure: \(failed)")
        XCTAssertEqual(failed["returnedType"] as? String, "undefined")
        XCTAssertEqual(failed["argc"] as? Int, 0)
        let message = try XCTUnwrap(failed["lastErrorInCallback"] as? String,
                                    "lastError must be set inside the callback: \(failed)")
        XCTAssertTrue(message.contains("no-such-offscreen.html") && message.contains("failed to load"),
                      "lastError should carry the native failure, got: \(message)")
        XCTAssertEqual(failed["mode"] as? String, "native-relay",
                       "WebKit's lastError was expected to ignore JS writes (see docs/chrome-runtime-patching.md)")
        XCTAssertTrue(["null", "undefined"].contains(failed["lastErrorAfter"] as? String ?? ""),
                      "lastError must be cleared after the callback, got \(failed["lastErrorAfter"] ?? "nil")")
        XCTAssertEqual(failed["unhandled"] as? [String], [])
        XCTAssertNil(handler.offscreenHosts[ext.id], "the failed document must not stay registered")

        // NEGATIVE: the promise form still rejects.
        let promise = try await evalObject(promiseOutcomeJS("""
            chrome.offscreen.createDocument({ url: 'no-such-offscreen.html', reasons: ['DOM_PARSER'], justification: 'test' })
        """))
        XCTAssertEqual(promise["settled"] as? String, "rejected")
        XCTAssertTrue((promise["message"] as? String ?? "").contains("failed to load"),
                      "unexpected rejection: \(promise)")

        // POSITIVE: a page that exists loads; the callback runs clean.
        let loaded = try await evalObject(callbackOutcomeJS(call: """
            return chrome.offscreen.createDocument(
                { url: 'offscreen.html', reasons: ['DOM_PARSER'], justification: 'test' }, cb);
        """))
        XCTAssertEqual(loaded["timedOut"] as? Bool, false, "the callback must run on success: \(loaded)")
        XCTAssertEqual(loaded["argc"] as? Int, 0)
        XCTAssertNil(loaded["lastErrorInCallback"] as? String, "no lastError on success: \(loaded)")
        XCTAssertEqual(loaded["unhandled"] as? [String], [])
        XCTAssertNotNil(handler.offscreenHosts[ext.id], "the document should be hosted")
    }

    /// The same contract from a background service worker, where the polyfill
    /// request itself travels over the promise-form sendNativeMessage bridge
    /// and its rejection is relayed back through the callback form.
    func testOffscreenCreateDocumentCallbackGetsLastErrorInARealServiceWorker() async throws {
        let backgroundJS = ExtensionAPIPolyfill.polyfillJS + """

        const unhandled = [];
        self.addEventListener('unhandledrejection', (event) => {
            unhandled.push(String(event.reason && event.reason.message ? event.reason.message : event.reason));
        });
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message && message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
            if (!message || message.type !== 'offscreenCallback') return false;
            const outcome = {};
            chrome.offscreen.createDocument(
                { url: message.url, reasons: ['DOM_PARSER'], justification: 'test' },
                function(...args) {
                    outcome.argc = args.length;
                    const lastError = chrome.runtime.lastError;
                    outcome.lastErrorInCallback = lastError ? String(lastError.message) : null;
                    setTimeout(() => {
                        outcome.lastErrorAfter = String(chrome.runtime.lastError);
                        outcome.mode = globalThis.__detourCallbackLastError.lastMode;
                        outcome.unhandled = unhandled.slice();
                        sendResponse(outcome);
                    }, 150);
                });
            return true;
        });
        """
        let ext = try await makeTestExtension(
            idPrefix: "lasterror-worker",
            manifest: """
            {
                "manifest_version": 3,
                "name": "lastError Worker Test",
                "version": "1.0.0",
                "permissions": ["offscreen"],
                "background": {"service_worker": "background.js", "type": "module"}
            }
            """,
            extraFiles: ["background.js": backgroundJS])
        let profile = makeProfile("Worker lastError Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let webView = try await makeExtensionWebView(for: context)

        // The worker is started on demand and answers nothing until it is up.
        try await waitUntil("the background worker to wake") {
            let ping = try await askWorker(from: webView, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }

        // NEGATIVE
        let failedAnswer = try await askWorker(
            from: webView, message: ["type": "offscreenCallback", "url": "no-such-offscreen.html"])
        XCTAssertNil(failedAnswer["lastError"] as? String, "the page could not reach the worker")
        let failed = try XCTUnwrap(failedAnswer["reply"] as? [String: Any],
                                   "the worker must answer: \(failedAnswer)")
        XCTAssertEqual(failed["argc"] as? Int, 0)
        let message = try XCTUnwrap(failed["lastErrorInCallback"] as? String,
                                    "lastError must be set inside the worker's callback: \(failed)")
        XCTAssertTrue(message.contains("no-such-offscreen.html") && message.contains("failed to load"),
                      "lastError should carry the native failure, got: \(message)")
        XCTAssertEqual(failed["mode"] as? String, "native-relay")
        XCTAssertTrue(["null", "undefined"].contains(failed["lastErrorAfter"] as? String ?? ""))
        XCTAssertEqual(failed["unhandled"] as? [String], [])

        // POSITIVE
        let loadedAnswer = try await askWorker(
            from: webView, message: ["type": "offscreenCallback", "url": "offscreen.html"])
        let loaded = try XCTUnwrap(loadedAnswer["reply"] as? [String: Any],
                                   "the worker must answer: \(loadedAnswer)")
        XCTAssertEqual(loaded["argc"] as? Int, 0)
        XCTAssertNil(loaded["lastErrorInCallback"] as? String, "no lastError on success: \(loaded)")
        XCTAssertEqual(loaded["unhandled"] as? [String], [])
    }

    /// A load failure that arrives once a *newer* document has taken the
    /// extension's slot must settle its own request and leave the newer host
    /// alone — unregistering by key would take the live document down with it.
    /// Driven through the navigation delegate directly, because production
    /// settles a replaced host's completion at `stop()` and so never produces a
    /// genuinely late reply; the guard is what keeps that true. The reply
    /// reports the failure it actually waited on, not the closed case: the load
    /// it was waiting for did fail, it just must not touch the newer host.
    func testLateOffscreenLoadFailureDoesNotUnregisterANewerHost() async throws {
        let ext = try await makeTestExtension()
        let profile = makeProfile("Offscreen Late Failure Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        _ = try XCTUnwrap(profile.extensionContexts[ext.id])
        let handler = try XCTUnwrap(profile.polyfillHandler)

        let replied = expectation(description: "offscreen.createDocument reply for a replaced host")
        var replyResult: Any?
        var replyError: (any Error)?
        handler.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            replyResult = result
            replyError = error
            replied.fulfill()
        }
        let pending = try XCTUnwrap(handler.offscreenHosts[ext.id],
                                    "precondition: the host is registered while its load is in flight")
        let pendingWebView = try XCTUnwrap(pending.webView)

        // A second document takes over the slot while the first is still loading.
        let replacement = OffscreenDocumentHost(extensionID: ext.id, basePath: ext.basePath)
        handler.offscreenHosts[ext.id] = replacement

        pending.webView(pendingWebView, didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        await fulfillment(of: [replied], timeout: 10)
        pending.stop()

        XCTAssertNil(replyResult)
        let lateMessage = try XCTUnwrap((replyError as NSError?)?.localizedDescription)
        XCTAssertTrue(lateMessage.contains("offscreen.html") && lateMessage.contains("failed to load"),
                      "a reply for a host that is no longer the extension's must report the failure "
                      + "it waited on, got: \(lateMessage)")
        XCTAssertTrue(handler.offscreenHosts[ext.id] === replacement,
                      "the newer host must still be registered")
    }

    // MARK: - TASK-12 AC #3: closing a document mid-load settles its create

    /// `closeOffscreenDocument` (an explicit `closeDocument`, or a context
    /// unload through `Profile.unloadExtension`) runs while the create is still
    /// loading. The worker's promise must reject rather than hang, and no
    /// document may be left behind.
    func testPendingOffscreenCreateDocumentFailsWhenTheDocumentIsClosed() async throws {
        let ext = try await makeTestExtension()
        let profile = makeProfile("Offscreen Close Race Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        _ = try XCTUnwrap(profile.extensionContexts[ext.id])
        let handler = try XCTUnwrap(profile.polyfillHandler)

        let replied = expectation(description: "offscreen.createDocument reply for a closed document")
        var replyResult: Any?
        var replyError: (any Error)?
        var replyCount = 0
        handler.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            replyCount += 1
            replyResult = result
            replyError = error
            replied.fulfill()
        }
        // `createDocument` registers the host and starts the load synchronously,
        // so at this point the request is genuinely in flight.
        let pending = try XCTUnwrap(handler.offscreenHosts[ext.id],
                                    "precondition: the host is registered while its load is in flight")
        XCTAssertEqual(replyCount, 0, "precondition: the load has not settled yet")

        handler.closeOffscreenDocument(for: ext.id)
        await fulfillment(of: [replied], timeout: 10)

        XCTAssertNil(replyResult)
        XCTAssertEqual((replyError as NSError?)?.localizedDescription,
                       OffscreenDocumentHost.LoadError.closedBeforeLoad.localizedDescription)
        XCTAssertNil(pending.webView, "stop() must release the hidden web view")
        XCTAssertNil(handler.offscreenHosts[ext.id])
        let hasDoc = await nativeReply(
            handler, ["type": "offscreen.hasDocument", "extensionID": ext.id],
            verifiedExtensionID: ext.id)
        XCTAssertEqual(hasDoc.result as? Bool, false,
                       "a create that was closed mid-load must not leave a document behind")

        // The extension can create one again afterwards; this also gives a
        // stray second reply for the closed request time to show up.
        let again = await nativeReply(
            handler, ["type": "offscreen.createDocument", "extensionID": ext.id,
                      "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id, description: "offscreen.createDocument after close")
        XCTAssertNil(again.error, "creating again after a close failed: \(String(describing: again.error))")
        XCTAssertEqual(again.result as? Bool, true)
        XCTAssertNotNil(handler.offscreenHosts[ext.id])
        XCTAssertEqual(replyCount, 1, "the closed request must be answered exactly once")
    }

    // MARK: - Concurrent createDocument joins the load in flight

    /// Two `createDocument` calls race (a worker that fires twice, or two
    /// listeners each ensuring the document exists). The second must wait on the
    /// load already in flight instead of being told a document exists: while the
    /// first load is pending there is no document yet, so replying success early
    /// would hand the worker a resolved promise for a page it cannot talk to.
    /// Both requests settle with the one outcome of the one load, and only one
    /// host is ever built.
    func testConcurrentOffscreenCreateDocumentJoinsTheLoadInFlight() async throws {
        let ext = try await makeTestExtension()
        let profile = makeProfile("Offscreen Concurrent Create Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        _ = try XCTUnwrap(profile.extensionContexts[ext.id])
        let handler = try XCTUnwrap(profile.polyfillHandler)

        let firstReplied = expectation(description: "first offscreen.createDocument reply")
        var firstResult: Any?
        var firstError: (any Error)?
        var firstCount = 0
        handler.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            firstCount += 1
            firstResult = result
            firstError = error
            firstReplied.fulfill()
        }

        let secondReplied = expectation(description: "second offscreen.createDocument reply")
        var secondResult: Any?
        var secondError: (any Error)?
        var secondCount = 0
        handler.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            secondCount += 1
            secondResult = result
            secondError = error
            secondReplied.fulfill()
        }

        // Both were issued without a suspension point between them, so the load
        // cannot have settled: neither request may have been answered yet.
        XCTAssertEqual(firstCount, 0, "precondition: the load has not settled yet")
        XCTAssertEqual(secondCount, 0, "the second create must wait on the load, not reply early")
        let pending = try XCTUnwrap(handler.offscreenHosts[ext.id],
                                   "precondition: the host is registered while its load is in flight")
        XCTAssertTrue(pending.isLoading, "precondition: the single host's load is still in flight")
        // `hasDocument` is answered synchronously, so this captures the value as
        // of now — while the load is still pending.
        let loadingHasDoc = await nativeReply(
            handler, ["type": "offscreen.hasDocument", "extensionID": ext.id],
            verifiedExtensionID: ext.id, description: "offscreen.hasDocument while loading")
        XCTAssertEqual(loadingHasDoc.result as? Bool, false,
                       "a host whose load has not settled is not a document yet")

        await fulfillment(of: [firstReplied, secondReplied], timeout: 10)

        XCTAssertEqual(firstResult as? Bool, true)
        XCTAssertNil(firstError, "the first create failed: \(String(describing: firstError))")
        XCTAssertEqual(secondResult as? Bool, true, "the joined create must see the same success")
        XCTAssertNil(secondError, "the joined create failed: \(String(describing: secondError))")
        XCTAssertEqual(firstCount, 1, "the first request must be answered exactly once")
        XCTAssertEqual(secondCount, 1, "the joined request must be answered exactly once")

        let host = try XCTUnwrap(handler.offscreenHosts[ext.id])
        XCTAssertTrue(host === pending, "the second create must not have built a second host")
        XCTAssertFalse(host.isLoading, "the load has settled")
        let hasDoc = await nativeReply(
            handler, ["type": "offscreen.hasDocument", "extensionID": ext.id],
            verifiedExtensionID: ext.id)
        XCTAssertEqual(hasDoc.result as? Bool, true, "the loaded document must be reported")
    }

    /// The same race, but the page does not exist. The request that joined the
    /// load must fail with it rather than inherit a success it never got: a
    /// joined waiter runs after the first completion has already unregistered
    /// the dead host, so it lands on the identity guard and must still report
    /// the failure. Nothing may be left registered to fake a document.
    func testConcurrentOffscreenCreateDocumentBothFailWhenPageIsMissing() async throws {
        let ext = try await makeTestExtension()
        let profile = makeProfile("Offscreen Concurrent Failure Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        _ = try XCTUnwrap(profile.extensionContexts[ext.id])
        let handler = try XCTUnwrap(profile.polyfillHandler)

        let firstReplied = expectation(description: "first offscreen.createDocument reply for a missing page")
        var firstResult: Any?
        var firstError: (any Error)?
        var firstCount = 0
        handler.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "no-such-offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            firstCount += 1
            firstResult = result
            firstError = error
            firstReplied.fulfill()
        }

        let secondReplied = expectation(description: "joined offscreen.createDocument reply for a missing page")
        var secondResult: Any?
        var secondError: (any Error)?
        var secondCount = 0
        handler.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "no-such-offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            secondCount += 1
            secondResult = result
            secondError = error
            secondReplied.fulfill()
        }

        XCTAssertEqual(firstCount, 0, "precondition: the load has not settled yet")
        XCTAssertEqual(secondCount, 0, "the second create must wait on the load, not reply early")
        let pending = try XCTUnwrap(handler.offscreenHosts[ext.id],
                                   "precondition: the host is registered while its load is in flight")
        XCTAssertTrue(pending.isLoading, "precondition: the single host's load is still in flight")

        await fulfillment(of: [firstReplied, secondReplied], timeout: 10)

        XCTAssertNil(firstResult, "a document that never loaded must not report success")
        XCTAssertNil(secondResult, "the joined request must not report success either")
        let firstMessage = try XCTUnwrap((firstError as NSError?)?.localizedDescription)
        XCTAssertTrue(firstMessage.contains("failed to load"),
                      "the error should say the load failed, got: \(firstMessage)")
        let secondMessage = try XCTUnwrap((secondError as NSError?)?.localizedDescription)
        XCTAssertTrue(secondMessage.contains("failed to load"),
                      "the joined error should say the load failed, got: \(secondMessage)")
        XCTAssertEqual(firstCount, 1, "the first request must be answered exactly once")
        XCTAssertEqual(secondCount, 1, "the joined request must be answered exactly once")
        XCTAssertNil(handler.offscreenHosts[ext.id],
                     "the failed host must be unregistered, not left to fake a document")
    }

    /// A page that navigates itself before its first load finishes fails that
    /// first navigation with `NSURLErrorCancelled` and then finishes the one
    /// that replaced it. A cancellation must therefore leave the load pending:
    /// settling it would reject a `createDocument` whose document does in fact
    /// arrive, and tearing the host down would kill the load in progress.
    func testCancelledOffscreenNavigationKeepsTheCreateDocumentPending() async throws {
        let ext = try await makeTestExtension()
        let profile = makeProfile("Offscreen Cancelled Navigation Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        _ = try XCTUnwrap(profile.extensionContexts[ext.id])
        let handler = try XCTUnwrap(profile.polyfillHandler)

        let replied = expectation(description: "offscreen.createDocument reply after a cancellation")
        var replyResult: Any?
        var replyError: (any Error)?
        var replyCount = 0
        handler.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { result, error in
            replyCount += 1
            replyResult = result
            replyError = error
            replied.fulfill()
        }
        let pending = try XCTUnwrap(handler.offscreenHosts[ext.id],
                                   "precondition: the host is registered while its load is in flight")
        let pendingWebView = try XCTUnwrap(pending.webView)

        // The test is @MainActor and there is no suspension point between the
        // create above and this callback, so the real `didFinish` cannot have
        // interleaved: the cancellation genuinely lands mid-load.
        pending.webView(pendingWebView, didFail: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))

        XCTAssertEqual(replyCount, 0, "a cancellation must not settle the pending create")
        XCTAssertTrue(pending.isLoading, "the load must still be waiting for the navigation that replaced it")
        XCTAssertTrue(handler.offscreenHosts[ext.id] === pending,
                      "a cancellation must not tear the host down")

        // The real load of offscreen.html still finishes, and answers the request.
        await fulfillment(of: [replied], timeout: 10)

        XCTAssertEqual(replyResult as? Bool, true)
        XCTAssertNil(replyError, "the create failed: \(String(describing: replyError))")
        XCTAssertEqual(replyCount, 1, "the request must be answered exactly once")
    }

    // MARK: - Profile-scoped tab actions (search.query / sessions.restore)

    /// Await one `handleNativeMessage` round trip.
    private func nativeReply(
        _ handler: ExtensionPolyfillHandler, _ body: [String: Any],
        verifiedExtensionID: String, description: String = "native bridge reply"
    ) async -> (result: Any?, error: (any Error)?) {
        let replied = expectation(description: description)
        var replyResult: Any?
        var replyError: (any Error)?
        handler.handleNativeMessage(body, verifiedExtensionID: verifiedExtensionID) { result, error in
            replyResult = result
            replyError = error
            replied.fulfill()
        }
        await fulfillment(of: [replied], timeout: 10)
        return (replyResult, replyError)
    }

    /// A search from an extension page in profile B must open its tab in one of
    /// B's spaces with B's search engine, even though the last-active space (and
    /// therefore the global lookup) belongs to profile A.
    func testSearchQueryOpensTabInHandlersProfileSpace() async throws {
        let ext = try await makeTestExtension()
        let profileA = makeProfile("Search Wiring Profile A")
        let profileB = makeProfile("Search Wiring Profile B")
        // Distinct engines, so the opened URL also proves whose settings were used.
        profileA.searchEngine = .google
        profileB.searchEngine = .duckDuckGo
        _ = profileA.extensionController
        _ = profileB.extensionController

        let spaceA = addSpace(for: profileA, name: "Search Wiring Space A")
        let spaceB = addSpace(for: profileB, name: "Search Wiring Space B")
        ExtensionManager.shared.lastActiveSpaceID = spaceA.id

        let countA = spaceA.tabs.count
        let countB = spaceB.tabs.count

        let handlerB = try XCTUnwrap(profileB.polyfillHandler)
        let reply = await nativeReply(
            handlerB,
            ["type": "search.query", "extensionID": ext.id,
             "params": ["query": ["text": "detour wiring test"]]],
            verifiedExtensionID: ext.id
        )

        XCTAssertNil(reply.error, "search.query failed: \(String(describing: reply.error))")
        XCTAssertEqual((reply.result as? [String: Any])?["success"] as? Bool, true)
        XCTAssertEqual(spaceA.tabs.count, countA,
                       "the other profile's space must not gain a tab")
        XCTAssertEqual(spaceB.tabs.count, countB + 1,
                       "the sending profile's space should have gained exactly one tab")

        let opened = try XCTUnwrap(spaceB.tabs.last)
        let expectedHost = try XCTUnwrap(profileB.searchEngine.searchURL(for: "detour wiring test")?.host)
        XCTAssertEqual(opened.url?.host, expectedHost,
                       "the tab should use the sending profile's search engine, got \(String(describing: opened.url))")
    }

    /// NEGATIVE: the handler's profile has no space at all. Falling back to the
    /// last-active space would leak the search into another profile, so the
    /// request must fail instead.
    func testSearchQueryFailsWhenProfileHasNoSpace() async throws {
        let ext = try await makeTestExtension()
        let profileA = makeProfile("Search Wiring Only Profile")
        let profileB = makeProfile("Search Wiring Spaceless Profile")
        _ = profileA.extensionController
        _ = profileB.extensionController

        let spaceA = addSpace(for: profileA, name: "Search Wiring Only Space")
        ExtensionManager.shared.lastActiveSpaceID = spaceA.id
        let countA = spaceA.tabs.count

        let handlerB = try XCTUnwrap(profileB.polyfillHandler)
        let reply = await nativeReply(
            handlerB,
            ["type": "search.query", "extensionID": ext.id,
             "params": ["query": ["text": "detour wiring test"]]],
            verifiedExtensionID: ext.id
        )

        XCTAssertNil(reply.result)
        XCTAssertEqual((reply.error as NSError?)?.localizedDescription, "No space in this profile")
        XCTAssertEqual(spaceA.tabs.count, countA,
                       "the other profile's space must not gain a tab")
    }

    /// sessions.restore reopens the tab the sending profile closed, not whatever
    /// the last-active (other-profile) space has on its closed-tab stack.
    func testSessionsRestoreReopensInHandlersProfileSpace() async throws {
        let ext = try await makeTestExtension()
        let profileA = makeProfile("Restore Wiring Profile A")
        let profileB = makeProfile("Restore Wiring Profile B")
        _ = profileA.extensionController
        _ = profileB.extensionController

        let spaceA = addSpace(for: profileA, name: "Restore Wiring Space A")
        let spaceB = addSpace(for: profileB, name: "Restore Wiring Space B")
        ExtensionManager.shared.lastActiveSpaceID = spaceA.id

        let closedURL = URL(string: "https://example.com/wiring-restore")!
        let doomed = TabStore.shared.addTab(in: spaceB, url: closedURL)
        TabStore.shared.closeTab(id: doomed.id, in: spaceB)
        XCTAssertTrue(TabStore.shared.canReopenClosedTab(in: spaceB))
        XCTAssertFalse(TabStore.shared.canReopenClosedTab(in: spaceA),
                       "precondition: the last-active space has nothing to restore")
        let countA = spaceA.tabs.count
        let countB = spaceB.tabs.count

        let handlerB = try XCTUnwrap(profileB.polyfillHandler)
        let reply = await nativeReply(
            handlerB, ["type": "sessions.restore", "extensionID": ext.id],
            verifiedExtensionID: ext.id
        )

        XCTAssertNil(reply.error, "sessions.restore failed: \(String(describing: reply.error))")
        XCTAssertNotNil(reply.result as? [String: Any])
        XCTAssertEqual(spaceA.tabs.count, countA,
                       "the other profile's space must not gain a tab")
        XCTAssertEqual(spaceB.tabs.count, countB + 1,
                       "the closed tab should come back in the sending profile's space")
        XCTAssertEqual(spaceB.tabs.last?.url, closedURL)
    }

    /// NEGATIVE: only the other (last-active) profile has a closed tab, so the
    /// sending profile has nothing to restore and must be told so rather than
    /// reopening the other profile's tab.
    func testSessionsRestoreFailsWhenSendersProfileHasNoClosedTab() async throws {
        let ext = try await makeTestExtension()
        let profileA = makeProfile("Restore Wiring Stocked Profile")
        let profileB = makeProfile("Restore Wiring Empty Profile")
        _ = profileA.extensionController
        _ = profileB.extensionController

        let spaceA = addSpace(for: profileA, name: "Restore Wiring Stocked Space")
        let spaceB = addSpace(for: profileB, name: "Restore Wiring Empty Space")
        ExtensionManager.shared.lastActiveSpaceID = spaceA.id

        let doomed = TabStore.shared.addTab(in: spaceA, url: URL(string: "https://example.com/other-profile")!)
        TabStore.shared.closeTab(id: doomed.id, in: spaceA)
        XCTAssertTrue(TabStore.shared.canReopenClosedTab(in: spaceA))
        let countA = spaceA.tabs.count

        let handlerB = try XCTUnwrap(profileB.polyfillHandler)
        let reply = await nativeReply(
            handlerB, ["type": "sessions.restore", "extensionID": ext.id],
            verifiedExtensionID: ext.id
        )

        XCTAssertNil(reply.result)
        XCTAssertEqual((reply.error as NSError?)?.localizedDescription, "No closed tabs to restore")
        XCTAssertEqual(spaceA.tabs.count, countA,
                       "the other profile's closed tab must stay closed")
        XCTAssertTrue(spaceB.tabs.isEmpty)
    }

    // Note: a released profile rejecting every web-view message is covered by
    // `ExtensionPolyfillTests.testWebViewMessageWithReleasedProfileRejected`;
    // it exercises nothing about the Profile→handler wiring these tests are for.

    // MARK: - TASK-16: Detour drives the worker's native-host keep-alive

    /// An extension with a background service worker running the real polyfill, so
    /// the worker opens its idle keep-alive port through the production path (the
    /// profile's own controller, with ExtensionManager as its delegate).
    /// `nativeMessaging` is what makes the keep-alive install at all (TASK-16).
    private func makeKeepAliveTestExtension() async throws -> WebExtension {
        let backgroundJS = ExtensionAPIPolyfill.polyfillJS + """

        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message && message.type === 'keepAliveStatus') {
                const status = globalThis.__detourNativePortKeepAlive;
                sendResponse(status ? {
                    installMode: status.installMode,
                    installDetail: status.installDetail,
                    armed: status.armed,
                    active: status.active
                } : { installMode: 'missing' });
                return true;
            }
            return false;
        });
        """
        return try await makeTestExtension(
            idPrefix: "keepalive-wiring",
            manifest: """
            {
                "manifest_version": 3,
                "name": "Keep-alive Wiring Test",
                "version": "1.0.0",
                "permissions": ["nativeMessaging"],
                "background": {"service_worker": "background.js", "type": "module"}
            }
            """,
            extraFiles: ["background.js": backgroundJS])
    }

    /// One round trip to the background worker, asking it what its keep-alive is
    /// doing. Fails the test if the message never reached the worker; returns nil
    /// when the worker answered nothing.
    private func workerKeepAliveStatus(from webView: WKWebView,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) async throws -> [String: Any]? {
        let answer = try await askWorker(from: webView, message: ["type": "keepAliveStatus"], timeout: 5)
        XCTAssertNil(answer["lastError"] as? String,
                     "sendMessage to the worker reported lastError", file: file, line: line)
        return answer["reply"] as? [String: Any]
    }

    /// End to end through the production wiring: the worker holds an idle port,
    /// Detour arms it when a real native messaging host connects for that
    /// extension and disarms it when the last one goes away, and the worker's
    /// pings arrive back on the same port.
    func testDetourArmsAndDisarmsTheWorkerKeepAlivePort() async throws {
        let ext = try await makeKeepAliveTestExtension()
        let profile = makeProfile("Keep-alive Wiring Profile")
        let controller = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id],
                                    "the context should be loaded in the profile's controller")
        let webView = try await makeExtensionWebView(for: context)

        let manager = ExtensionManager.shared
        func state() -> NativeHostKeepAliveState? {
            manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id)
        }

        try await waitUntil("the worker's keep-alive port to reach ExtensionManager") {
            state()?.portOpen == true
        }
        let opened = try XCTUnwrap(state())
        XCTAssertEqual(opened.connectedHosts, 0)
        XCTAssertFalse(opened.armed, "no native host is connected yet")

        let idleReply = try await workerKeepAliveStatus(from: webView)
        let idle = try XCTUnwrap(idleReply, "the worker must answer the status round trip")
        XCTAssertEqual(idle["installMode"] as? String, "port")
        XCTAssertEqual(idle["installDetail"] as? String, "")
        XCTAssertEqual(idle["armed"] as? Bool, false)

        // A real native host connects (the spawn itself is not what is under test).
        manager.simulateNativeHostForTesting(connected: true, controller: controller, extensionID: ext.id)
        XCTAssertEqual(state()?.armed, true, "the state machine should have armed on the first host")

        var armedStatus: [String: Any]?
        try await waitUntil("the worker to report itself armed") {
            armedStatus = try await self.workerKeepAliveStatus(from: webView)
            return armedStatus?["armed"] as? Bool == true
        }
        XCTAssertEqual(armedStatus?["active"] as? Bool, true)
        try await waitUntil("the worker's reply to Detour's first ping") {
            manager.keepAlivePingCountForTesting(controller: controller, extensionID: ext.id) >= 1
        }

        // The last host exits.
        manager.simulateNativeHostForTesting(connected: false, controller: controller, extensionID: ext.id)
        XCTAssertEqual(state()?.armed, false)

        var disarmedStatus: [String: Any]?
        try await waitUntil("the worker to report itself disarmed") {
            disarmedStatus = try await self.workerKeepAliveStatus(from: webView)
            return disarmedStatus?["armed"] as? Bool == false
        }
        XCTAssertEqual(disarmedStatus?["installMode"] as? String, "port",
                       "the worker keeps its idle port after the pings stop")
        XCTAssertEqual(state()?.portOpen, true)
    }

    // MARK: - TASK-67: a background context replaced without its ports closing

    /// An MV3 extension whose background content is a *service worker*, built at
    /// a given id so a `FakeNativeMessagingHost` can allow that id before the
    /// extension exists. The worker carries the polyfill itself: the user script
    /// `Profile.extensionController` installs reaches web views, not workers.
    private func makeWorkerExtension(id: String, permissions: [String],
                                     backgroundJS: String,
                                     extraFiles: [String: String] = [:]) async throws -> WebExtension {
        try await makeBackgroundPageExtension(
            .serviceWorker, id: id, permissions: permissions, backgroundJS: backgroundJS,
            extraFiles: extraFiles)
    }

    /// A worker that connects `portCount` native messaging ports to `hostName` at
    /// startup, can open one relayed WebSocket on request, and on request calls
    /// `chrome.runtime.reload()` — WebKit's own unload+load of the context, which
    /// is how a background context is replaced with none of its native ports ever
    /// reporting a disconnect (`WebExtensionContext::unload()` clears
    /// `m_nativePortMap` without calling `reportDisconnection`).
    private func makeNativeHostProbeWorkerExtension(
        id: String, hostName: String, portCount: Int
    ) async throws -> WebExtension {
        let backgroundJS = ExtensionAPIPolyfill.polyfillJS + """


        const HOST = '\(hostName)';
        const ports = [];
        let connectError = null;
        for (let i = 0; i < \(portCount); i++) {
            try {
                ports.push(chrome.runtime.connectNative(HOST));
            } catch (e) {
                connectError = String(e && e.message !== undefined ? e.message : e);
            }
        }
        // Held on the global so nothing collects the ports under us.
        globalThis.__detourProbeNativePorts = ports;
        let disconnects = 0;
        for (const port of ports) {
            try { port.onDisconnect.addListener(() => { disconnects += 1; }); } catch (e) {}
        }
        let probeSocket = null;

        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (!message) return false;
            if (message.type === 'ping') {
                const keepAlive = globalThis.__detourNativePortKeepAlive;
                sendResponse({
                    type: 'pong',
                    ports: ports.length,
                    disconnects: disconnects,
                    connectError: connectError,
                    installMode: keepAlive ? keepAlive.installMode : 'missing',
                    armed: keepAlive ? keepAlive.armed : false
                });
                return true;
            }
            if (message.type === 'wsOpen') {
                const out = { opened: false, error: null };
                try {
                    const socket = new WebSocket(message.url);
                    probeSocket = socket;
                    globalThis.__detourProbeSocket = socket;
                    socket.onopen = () => { out.opened = true; sendResponse(out); };
                    socket.onclose = (e) => {
                        if (!out.opened) {
                            out.error = 'closed before open: ' + e.code;
                            sendResponse(out);
                        }
                    };
                } catch (e) {
                    out.error = String(e && e.message !== undefined ? e.message : e);
                    sendResponse(out);
                }
                return true;
            }
            if (message.type === 'reload') {
                sendResponse({ ok: true });
                // Answered first: reload() tears this context down at once.
                setTimeout(() => { chrome.runtime.reload(); }, 50);
                return true;
            }
            return false;
        });
        """
        return try await makeWorkerExtension(
            id: id, permissions: ["nativeMessaging"], backgroundJS: backgroundJS)
    }

    /// Start the probe's context in a fresh profile and wait until its worker has
    /// connected `portCount` hosts and Detour has armed its keep-alive.
    private func startNativeHostProbe(
        _ ext: WebExtension, host: FakeNativeMessagingHost, portCount: Int, profileName: String
    ) async throws -> (profile: Profile, context: WKWebExtensionContext, page: WKWebView) {
        let started = try await startMeasurement(ext, profileName: profileName)
        let controller = started.profile.extensionController
        try await waitUntil("the worker's \(portCount) native host(s) to connect", timeout: 30) {
            ExtensionManager.shared.liveNativeHostCountForTesting(
                controller: controller, extensionID: ext.id) == portCount
                && host.processCount() == portCount
        }
        try await waitUntil("Detour to arm the worker's keep-alive", timeout: 20) {
            ExtensionManager.shared.keepAliveStateForTesting(
                controller: controller, extensionID: ext.id)?.armed == true
        }
        return started
    }

    /// Ask the worker to call `chrome.runtime.reload()` and wait until the
    /// replacement context has opened its own keep-alive port (the moment Detour
    /// learns a new background context exists). WebKit does not always start the
    /// replacement on its own, so the wake is nudged while waiting.
    private func reloadProbeContext(
        _ context: WKWebExtensionContext, page: WKWebView, controller: WKWebExtensionController,
        extensionID: String
    ) async throws {
        let manager = ExtensionManager.shared
        let portsBefore = manager.keepAlivePortOpenCountForTesting(
            controller: controller, extensionID: extensionID)
        let reloaded = try await askWorker(from: page, message: ["type": "reload"], timeout: 10)
        XCTAssertEqual((reloaded["reply"] as? [String: Any])?["ok"] as? Bool, true,
                       "the worker never acknowledged the reload: \(reloaded)")

        var nudged = Date.distantPast
        try await waitUntil("the replacement context's keep-alive port", timeout: 60) {
            if manager.keepAlivePortOpenCountForTesting(
                controller: controller, extensionID: extensionID) > portsBefore { return true }
            if Date().timeIntervalSince(nudged) > 5 {
                nudged = Date()
                context.loadBackgroundContent { _ in }
            }
            return false
        }
    }

    /// `chrome.runtime.reload()` replaces the background context behind Detour's
    /// back: WebKit's `unload()` clears its native port map without reporting a
    /// single disconnection, so every host Detour spawned for the old worker stays
    /// registered — and alive — while the new worker connects its own. The one
    /// signal Detour does get is the new context's keep-alive port superseding the
    /// old one, and that is where the replaced context's connections are torn down
    /// (TASK-67).
    func testRuntimeReloadTearsDownTheReplacedContextsNativeHost() async throws {
        try await assertRuntimeReloadReleasesTheReplacedContextsHosts(portCount: 1)
    }

    /// The same with two hosts, the shape production showed (1Password's workers
    /// hold several BrowserSupport helpers, and the leaked count climbed to 2 and
    /// then 3 for one profile).
    func testRuntimeReloadTearsDownEveryNativeHostOfTheReplacedContext() async throws {
        try await assertRuntimeReloadReleasesTheReplacedContextsHosts(portCount: 2)
    }

    private func assertRuntimeReloadReleasesTheReplacedContextsHosts(
        portCount: Int, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let id = measurementExtensionID("task67-reload-\(portCount)")
        let host = try FakeNativeMessagingHost(allowing: [id])
        fakeNativeHosts.append(host)
        let ext = try await makeNativeHostProbeWorkerExtension(
            id: id, hostName: host.name, portCount: portCount)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let started = try await startNativeHostProbe(
            ext, host: host, portCount: portCount, profileName: "TASK-67 Reload \(portCount)")
        let controller = started.profile.extensionController
        let manager = ExtensionManager.shared

        let firstGeneration = Set(host.processIDs())
        XCTAssertEqual(firstGeneration.count, portCount, "precondition: one process per port",
                       file: file, line: line)
        XCTAssertEqual(manager.keepAliveStateForTesting(
            controller: controller, extensionID: ext.id)?.connectedHosts, portCount,
                       file: file, line: line)

        try await reloadProbeContext(started.context, page: started.page,
                                     controller: controller, extensionID: ext.id)

        try await waitUntil("the replaced context's host processes to exit", timeout: 30) {
            host.processIDs().allSatisfy { !firstGeneration.contains($0) }
        }
        try await waitUntil("the replacement's hosts to be the only ones registered", timeout: 30) {
            manager.liveNativeHostCountForTesting(
                controller: controller, extensionID: ext.id) == portCount
                && host.processCount() == portCount
        }
        let secondGeneration = Set(host.processIDs())
        print("TASK-67 [\(portCount) host(s)]: first generation \(firstGeneration.sorted()), after the reload \(secondGeneration.sorted()); live hosts \(manager.liveNativeHostCountForTesting(controller: controller, extensionID: ext.id)), state \(String(describing: manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id)))")
        XCTAssertTrue(secondGeneration.isDisjoint(with: firstGeneration),
                      "every host process of the replaced context must be gone", file: file, line: line)

        let state = try XCTUnwrap(manager.keepAliveStateForTesting(
            controller: controller, extensionID: ext.id), file: file, line: line)
        XCTAssertEqual(state.connectedHosts, portCount,
                       "the armed count must be the new context's hosts only", file: file, line: line)
        XCTAssertTrue(state.portOpen, file: file, line: line)
        XCTAssertTrue(state.armed, "the new context's own hosts must arm it", file: file, line: line)
    }

    /// A relayed WebSocket (TASK-8) is a native port too, so WebKit drops it in
    /// the same silence — and it holds the keep-alive up exactly as a host does.
    /// The supersede teardown must end its session as well.
    func testASupersededKeepAlivePortTearsDownTheReplacedContextsRelayedSocket() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let serverPort = try await server.start()

        let id = measurementExtensionID("task67-relay")
        let host = try FakeNativeMessagingHost(allowing: [id])
        fakeNativeHosts.append(host)
        let ext = try await makeNativeHostProbeWorkerExtension(id: id, hostName: host.name, portCount: 1)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let started = try await startNativeHostProbe(
            ext, host: host, portCount: 1, profileName: "TASK-67 Reload Relay")
        let controller = started.profile.extensionController
        let manager = ExtensionManager.shared

        let opened = try await askWorker(
            from: started.page, message: ["type": "wsOpen", "url": "ws://127.0.0.1:\(serverPort)/"],
            timeout: 15)
        XCTAssertEqual((opened["reply"] as? [String: Any])?["opened"] as? Bool, true, "\(opened)")
        XCTAssertEqual(manager.webSocketRelayCountForTesting(controller: controller, extensionID: ext.id), 1)

        try await reloadProbeContext(started.context, page: started.page,
                                     controller: controller, extensionID: ext.id)

        // The replacement worker opens no socket of its own, so the count must
        // fall to zero and stay there.
        try await waitUntil("the replaced context's relayed socket to be torn down", timeout: 30) {
            manager.webSocketRelayCountForTesting(controller: controller, extensionID: ext.id) == 0
        }
        try await waitUntil("the replacement's own host to be the only connection", timeout: 30) {
            manager.keepAliveStateForTesting(
                controller: controller, extensionID: ext.id)?.connectedHosts == 1
                && host.processCount() == 1
        }
    }

    // MARK: - TASK-8: relayed WebSockets through the production wiring

    /// A background worker that opens, uses and closes one relayed WebSocket on
    /// command, so the test can look at Detour's registry while the socket is
    /// live. It also answers `keepAliveStatus`, so the keep-alive an open relayed
    /// socket is supposed to hold can be read from the worker's own side.
    ///
    /// `permissions` defaults to none: a worker may open a socket whether or not
    /// it declares `nativeMessaging`, and the relay host is accepted without the
    /// manifest gate. With `nativeMessaging` the worker also holds a keep-alive
    /// port, which is what makes the arming observable.
    private func makeWebSocketTestExtension(permissions: [String] = []) async throws -> WebExtension {
        let permissionsJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: permissions), as: UTF8.self)
        let backgroundJS = ExtensionAPIPolyfill.polyfillJS + """

        let probeSocket = null;
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message && message.type === 'keepAliveStatus') {
                const status = globalThis.__detourNativePortKeepAlive;
                sendResponse(status ? {
                    installMode: status.installMode,
                    installDetail: status.installDetail,
                    armed: status.armed,
                    active: status.active
                } : { installMode: 'missing' });
                return true;
            }
            // Warm-up round trip: a message sent while the worker is still waking
            // gets an empty reply, so the test pings until this answers.
            if (message && message.type === 'ping') {
                sendResponse({ type: 'pong' });
                return true;
            }
            if (message && message.type === 'wsOpen') {
                const out = { opened: false, protocol: null, mode: null, error: null };
                try {
                    const socket = new WebSocket(message.url);
                    socket.binaryType = 'arraybuffer';
                    probeSocket = socket;
                    socket.received = [];
                    socket.onmessage = (e) => {
                        socket.received.push(typeof e.data === 'string'
                            ? { text: e.data }
                            : { bytes: Array.from(new Uint8Array(e.data)) });
                    };
                    socket.onopen = () => {
                        out.opened = true;
                        out.protocol = socket.protocol;
                        out.mode = globalThis.__detourWebSocketRelay.mode;
                        sendResponse(out);
                    };
                    socket.onclose = (e) => {
                        socket.closeEvent = { code: e.code, reason: e.reason, wasClean: e.wasClean };
                        if (!out.opened) {
                            out.error = 'closed before open: ' + e.code;
                            out.mode = globalThis.__detourWebSocketRelay.mode;
                            sendResponse(out);
                        }
                    };
                } catch (e) {
                    out.error = String(e && e.message ? e.message : e);
                    sendResponse(out);
                }
                return true;
            }
            if (message && message.type === 'wsEcho') {
                probeSocket.send('hello');
                probeSocket.send(new Uint8Array([1, 2, 3, 4]));
                const deadline = Date.now() + 5000;
                const poll = () => {
                    if (probeSocket.received.length >= 2 || Date.now() > deadline) {
                        sendResponse({ received: probeSocket.received, readyState: probeSocket.readyState });
                        return;
                    }
                    setTimeout(poll, 25);
                };
                poll();
                return true;
            }
            if (message && message.type === 'wsClose') {
                probeSocket.close(1000, 'done');
                const deadline = Date.now() + 5000;
                const poll = () => {
                    if (probeSocket.closeEvent || Date.now() > deadline) {
                        sendResponse({
                            closeEvent: probeSocket.closeEvent || null,
                            readyState: probeSocket.readyState,
                            openSockets: globalThis.__detourWebSocketRelay.openSockets
                        });
                        return;
                    }
                    setTimeout(poll, 25);
                };
                poll();
                return true;
            }
            return false;
        });
        """
        return try await makeTestExtension(
            idPrefix: "websocket-wiring",
            manifest: """
            {
                "manifest_version": 3,
                "name": "WebSocket Relay Wiring Test",
                "version": "1.0.0",
                "permissions": \(permissionsJSON),
                "background": {"service_worker": "background.js", "type": "module"}
            }
            """,
            extraFiles: ["background.js": backgroundJS])
    }

    /// End to end through the production wiring (a real Profile, its own
    /// controller, ExtensionManager as delegate): the worker's `new WebSocket()`
    /// becomes a relay port and a real socket, Detour holds one session while it
    /// is open, and the session is released when the socket closes.
    func testWorkerWebSocketIsRelayedAndReleasedThroughTheProductionWiring() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let serverPort = try await server.start()

        let ext = try await makeWebSocketTestExtension()
        let profile = makeProfile("WebSocket Relay Profile")
        let controller = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id],
                                    "the context should be loaded in the profile's controller")
        let webView = try await makeExtensionWebView(for: context)

        let manager = ExtensionManager.shared
        func relayCount() -> Int {
            manager.webSocketRelayCountForTesting(controller: controller, extensionID: ext.id)
        }
        XCTAssertEqual(relayCount(), 0, "nothing is relayed before the worker opens a socket")

        // The worker is started on demand and answers nothing until it is up.
        try await waitUntil("the background worker to wake") {
            let ping = try await askWorker(from: webView, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }

        let opened = try await askWorker(
            from: webView, message: ["type": "wsOpen", "url": "ws://127.0.0.1:\(serverPort)/"], timeout: 15)
        XCTAssertNil(opened["lastError"] as? String)
        let openReply = try XCTUnwrap(opened["reply"] as? [String: Any], "\(opened)")
        XCTAssertEqual(openReply["opened"] as? Bool, true, "the socket never opened: \(openReply)")
        XCTAssertEqual(openReply["mode"] as? String, "relay", "\(openReply)")
        XCTAssertEqual(relayCount(), 1, "Detour must hold one relay session while the socket is open")

        // The socket counts towards the keep-alive (TASK-16) even though this
        // extension declares nothing and so has no port to be told about it: the
        // state machine simply has nowhere to send, and sends nothing. The armed
        // case is `testARelayedSocketKeepsTheWorkerAlive`.
        let openState = try XCTUnwrap(manager.keepAliveStateForTesting(controller: controller,
                                                                       extensionID: ext.id))
        XCTAssertEqual(openState.connectedHosts, 1, "an open relayed socket is a live connection")
        XCTAssertFalse(openState.portOpen, "no nativeMessaging permission, so no keep-alive port")
        XCTAssertFalse(openState.armed, "nothing to arm without a port")
        XCTAssertEqual(manager.keepAlivePingCountForTesting(controller: controller, extensionID: ext.id), 0)

        let echoed = try await askWorker(from: webView, message: ["type": "wsEcho"], timeout: 15)
        let echoReply = try XCTUnwrap(echoed["reply"] as? [String: Any], "\(echoed)")
        let received = try XCTUnwrap(echoReply["received"] as? [[String: Any]], "\(echoReply)")
        XCTAssertEqual(received.count, 2, "expected a text and a binary echo: \(echoReply)")
        XCTAssertEqual(received.first?["text"] as? String, "hello")
        XCTAssertEqual(received.last?["bytes"] as? [Int], [1, 2, 3, 4])

        let closed = try await askWorker(from: webView, message: ["type": "wsClose"], timeout: 15)
        let closeReply = try XCTUnwrap(closed["reply"] as? [String: Any], "\(closed)")
        let closeEvent = try XCTUnwrap(closeReply["closeEvent"] as? [String: Any], "\(closeReply)")
        XCTAssertEqual(closeEvent["code"] as? Int, 1000)
        XCTAssertEqual(closeEvent["wasClean"] as? Bool, true)
        XCTAssertEqual(closeReply["openSockets"] as? Int, 0)

        try await waitUntil("the relay session to be released") { relayCount() == 0 }
        XCTAssertNil(manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id),
                     "the closed socket released its keep-alive hold, so nothing is tracked")
    }

    /// An open relayed socket must hold the worker up exactly as a native host
    /// does (TASK-16). Without this a quiet long-lived socket — 1Password's
    /// notifier — dies with the worker WebKit unloads after ~2.5 minutes idle,
    /// and the extension sees an error and a 1006 every few minutes.
    func testARelayedSocketKeepsTheWorkerAlive() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let serverPort = try await server.start()

        // `nativeMessaging` is what gives the worker a keep-alive port to be armed
        // on; the relay itself never needed the permission.
        let ext = try await makeWebSocketTestExtension(permissions: ["nativeMessaging"])
        let profile = makeProfile("WebSocket Keep-alive Profile")
        let controller = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let webView = try await makeExtensionWebView(for: context)

        let manager = ExtensionManager.shared
        func state() -> NativeHostKeepAliveState? {
            manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id)
        }

        try await waitUntil("the worker's keep-alive port to reach ExtensionManager") {
            state()?.portOpen == true
        }
        XCTAssertEqual(state()?.armed, false, "nothing is connected yet")

        let opened = try await askWorker(
            from: webView, message: ["type": "wsOpen", "url": "ws://127.0.0.1:\(serverPort)/"], timeout: 15)
        let openReply = try XCTUnwrap(opened["reply"] as? [String: Any], "\(opened)")
        XCTAssertEqual(openReply["opened"] as? Bool, true, "the socket never opened: \(openReply)")
        XCTAssertEqual(state()?.armed, true, "an open relayed socket must arm the keep-alive")

        var armedStatus: [String: Any]?
        try await waitUntil("the worker to report itself armed") {
            armedStatus = try await self.workerKeepAliveStatus(from: webView)
            return armedStatus?["armed"] as? Bool == true
        }
        XCTAssertEqual(armedStatus?["active"] as? Bool, true)
        try await waitUntil("the worker's reply to Detour's first ping") {
            manager.keepAlivePingCountForTesting(controller: controller, extensionID: ext.id) >= 1
        }

        let closed = try await askWorker(from: webView, message: ["type": "wsClose"], timeout: 15)
        _ = try XCTUnwrap(closed["reply"] as? [String: Any], "\(closed)")

        try await waitUntil("the keep-alive to disarm with the last socket") { state()?.armed == false }
        var disarmedStatus: [String: Any]?
        try await waitUntil("the worker to report itself disarmed") {
            disarmedStatus = try await self.workerKeepAliveStatus(from: webView)
            return disarmedStatus?["armed"] as? Bool == false
        }
        XCTAssertEqual(disarmedStatus?["installMode"] as? String, "port",
                       "the worker keeps its idle port after the pings stop")
        XCTAssertEqual(state()?.portOpen, true)
    }

    // MARK: - TASK-62: the native-port keep-alive in a background *page*

    /// The long legs run for minutes each, so they only run when asked for:
    /// `DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1`. The install-decision tests below
    /// them are fast and always run.
    private var measuringBackgroundPageUnload: Bool {
        ProcessInfo.processInfo.environment["DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD"] == "1"
    }

    /// The background script the TASK-62 legs run.
    ///
    /// It stamps a heartbeat into the extension origin's `localStorage` twice a
    /// second, so an ordinary extension page of that same origin can watch whether
    /// the background context is still running *without* messaging it — a message
    /// wakes a background page, which would destroy the measurement. `loads`
    /// counts page starts the way the TASK-43 reporter does, so a second load is
    /// proof an unload happened.
    ///
    /// `nativeHost` makes it hold one real native messaging port, open and silent,
    /// the way 1Password's background holds its helpers'. What the polyfill's own
    /// keep-alive made of the context is reported next to it.
    private static func measurementBackgroundJS(nativeHost: String? = nil) -> String {
        let host = nativeHost.map { "'\($0)'" } ?? "null"
        return """
        const NATIVE_HOST = \(host);

        let loads = 0;
        try {
            loads = (Number(localStorage.getItem('__detourLoads')) || 0) + 1;
            localStorage.setItem('__detourLoads', String(loads));
        } catch (e) {}
        const startedAt = Date.now();
        const state = { nativePort: 'none' };

        function status() {
            const keepAlive = globalThis.__detourNativePortKeepAlive;
            return {
                loads: loads,
                at: Date.now(),
                aliveMs: Date.now() - startedAt,
                isWorker: typeof ServiceWorkerGlobalScope !== 'undefined',
                contextKind: globalThis.__detourContextKind || 'none',
                nativePort: state.nativePort,
                installMode: keepAlive ? keepAlive.installMode : 'missing',
                installDetail: keepAlive ? keepAlive.installDetail : 'missing',
                armed: keepAlive ? keepAlive.armed : false
            };
        }

        function beat() {
            try { localStorage.setItem('__detourHeartbeat', JSON.stringify(status())); } catch (e) {}
        }

        if (NATIVE_HOST) {
            try {
                const nativePort = chrome.runtime.connectNative(NATIVE_HOST);
                state.nativePort = 'open';
                nativePort.onDisconnect.addListener(() => { state.nativePort = 'disconnected'; beat(); });
                // Held on the global so nothing collects the port under us.
                globalThis.__detourMeasurementNativePort = nativePort;
            } catch (e) {
                state.nativePort = 'error: ' + (e && e.message ? e.message : e);
            }
        }

        beat();
        setInterval(beat, 500);

        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (!message || message.type !== 'report') return false;
            sendResponse(status());
            return true;
        });
        """
    }

    /// An id for a measurement extension, minted before the extension exists so a
    /// fake native host can be installed for it first (its manifest lists the
    /// allowed origin by extension id).
    private func measurementExtensionID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// An extension whose background content is the measurement script above.
    private func makeMeasurementExtension(
        id: String,
        permissions: [String] = ["nativeMessaging"],
        manifestVersion: Int = 3,
        persistent: Bool? = false,
        nativeHost: String? = nil
    ) async throws -> WebExtension {
        try await makeBackgroundPageExtension(
            .scripts, id: id,
            permissions: permissions, manifestVersion: manifestVersion, persistent: persistent,
            backgroundJS: Self.measurementBackgroundJS(nativeHost: nativeHost))
    }

    /// Put `source` in front of the polyfill user script that
    /// `Profile.extensionController` installed, so it runs at document start
    /// *before* the polyfill and can set the globals the polyfill reads once at
    /// install. `WKUserContentController` only appends, so the scripts already
    /// there are removed and added again behind this one — as fresh
    /// `WKUserScript`s, because WebKit traps (`EXC_BREAKPOINT` inside
    /// `WebUserContentControllerProxy::addUserScript`) if the very same script
    /// object is added twice. Every script here is a page-world one, which is all
    /// `Profile.extensionController` installs; `WKUserScript` does not expose the
    /// world it was made in, so a non-page-world script could not be rebuilt.
    ///
    /// The scripts are snapshotted into plain Swift values *before* anything is
    /// mutated: `userScripts` bridges to a live view of the controller's scripts,
    /// so iterating it while adding grew the very array being iterated and the
    /// loop never ended (a test host went from 337 MB to 36 GB in 90 s).
    private func prependUserScript(_ source: String, to profile: Profile) {
        let ucc = profile.extensionController.configuration.webViewConfiguration.userContentController
        let existing: [(source: String, injectionTime: WKUserScriptInjectionTime, mainFrameOnly: Bool)] =
            ucc.userScripts.map { ($0.source, $0.injectionTime, $0.isForMainFrameOnly) }
        guard existing.count < 64 else {
            XCTFail("unexpectedly many user scripts (\(existing.count)); refusing to rebuild them")
            return
        }
        guard existing.contains(where: { $0.source == ExtensionAPIPolyfill.polyfillJS }) else {
            XCTFail("this must be the user content controller Profile added the polyfill to")
            return
        }
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        for script in existing {
            ucc.addUserScript(WKUserScript(source: script.source,
                                           injectionTime: script.injectionTime,
                                           forMainFrameOnly: script.mainFrameOnly))
        }
        let rebuilt = ucc.userScripts.count
        XCTAssertEqual(rebuilt, existing.count + 1, "the rebuilt user scripts must be the snapshot plus one")
        XCTAssertEqual(ucc.userScripts.first?.source, source, "the prepended script must run first")
    }

    /// The background context's last heartbeat, read out of the extension
    /// origin's `localStorage` through an ordinary extension page — the same
    /// origin, so nothing here touches (or wakes) the background context.
    private func backgroundHeartbeat(from webView: WKWebView) async throws -> [String: Any]? {
        let raw = try await webView.callAsyncJavaScript(
            "return localStorage.getItem('__detourHeartbeat');", arguments: [:], contentWorld: .page)
        guard let json = raw as? String,
              let beat = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        return beat
    }

    private struct BackgroundPageLifetime {
        /// The heartbeat stopped advancing: WebKit unloaded the page.
        let unloaded: Bool
        /// Seconds from the page's own start to the last heartbeat it wrote.
        let lastAliveSeconds: Double
        /// That last heartbeat, whatever it says about ports and the keep-alive.
        let lastBeat: [String: Any]
    }

    /// Watch the background context's heartbeat until it stops advancing for
    /// `stallFor` seconds (WebKit unloaded the page) or `limit` elapses.
    private func watchBackgroundPage(
        _ label: String, from webView: WKWebView, limit: TimeInterval, stallFor: TimeInterval = 6
    ) async throws -> BackgroundPageLifetime {
        try await waitUntil("\(label): the background page's first heartbeat", timeout: 30) {
            try await self.backgroundHeartbeat(from: webView) != nil
        }
        let firstBeat = try await backgroundHeartbeat(from: webView)
        var lastBeat = try XCTUnwrap(firstBeat, "\(label): no heartbeat to watch")
        var lastAdvance = Date()
        var lastReport = Date()
        let deadline = Date().addingTimeInterval(limit)

        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let beat = try await backgroundHeartbeat(from: webView) else { continue }
            if (beat["at"] as? Double ?? 0) > (lastBeat["at"] as? Double ?? 0) {
                lastBeat = beat
                lastAdvance = Date()
            } else if Date().timeIntervalSince(lastAdvance) >= stallFor {
                let alive = (lastBeat["aliveMs"] as? Double ?? 0) / 1000
                print("TASK-62 measurement [\(label)]: heartbeat stopped at +\(String(format: "%.1f", alive)) s — \(lastBeat)")
                return BackgroundPageLifetime(unloaded: true, lastAliveSeconds: alive, lastBeat: lastBeat)
            }
            if Date().timeIntervalSince(lastReport) >= 15 {
                lastReport = Date()
                print("TASK-62 measurement [\(label)]: still beating at +\(String(format: "%.1f", (lastBeat["aliveMs"] as? Double ?? 0) / 1000)) s — \(lastBeat)")
            }
        }
        let alive = (lastBeat["aliveMs"] as? Double ?? 0) / 1000
        print("TASK-62 measurement [\(label)]: still beating at +\(String(format: "%.1f", alive)) s after the \(limit) s limit — \(lastBeat)")
        return BackgroundPageLifetime(unloaded: false, lastAliveSeconds: alive, lastBeat: lastBeat)
    }

    /// Profile + loaded context + an ordinary extension page to observe from, with
    /// the background content started through the production wake.
    private func startMeasurement(
        _ ext: WebExtension, profileName: String, prepending source: String? = nil
    ) async throws -> (profile: Profile, context: WKWebExtensionContext, page: WKWebView) {
        let profile = makeProfile(profileName)
        _ = profile.extensionController
        if let source { prependUserScript(source, to: profile) }
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let page = try await makeExtensionWebView(for: context)
        context.loadBackgroundContent { error in
            if let error { print("loadBackgroundContent failed: \(error)") }
        }
        return (profile, context, page)
    }

    /// Leg (a): a non-persistent background page with no port at all — the
    /// extension declares no `nativeMessaging`, so the keep-alive installs nothing
    /// and the page holds nothing open. WebKit's 30 s idle unload, and the control
    /// that says the heartbeat's own `localStorage` writes are not what keeps a
    /// page alive.
    func testMeasureIdleBackgroundPageUnload() async throws {
        try XCTSkipUnless(measuringBackgroundPageUnload,
                          "long measurement leg; set DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1")
        let ext = try await makeMeasurementExtension(
            id: measurementExtensionID("task62-idle"), permissions: [])
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }
        let started = try await startMeasurement(ext, profileName: "TASK-62 Idle Page")

        let life = try await watchBackgroundPage("a: idle, no port", from: started.page, limit: 120)
        XCTAssertTrue(life.unloaded, "WebKit must unload an idle non-persistent background page")
        XCTAssertEqual(life.lastBeat["nativePort"] as? String, "none")
        XCTAssertEqual(life.lastBeat["installDetail"] as? String, "no-nativeMessaging-permission",
                       "this leg must hold no port at all, the keep-alive's included")

        // The message that asks for a report wakes the page again: a second load
        // is independent proof the first one really went away.
        let report = try await reportFromBackgroundContext(page: started.page, what: "the woken page")
        print("TASK-62 measurement [a: idle, no port]: report after waking: \(report)")
        XCTAssertEqual(report["loads"] as? Int, 2, "the report must have woken a second page")
    }

    /// Leg (b): the same page holding one real native messaging port, open and
    /// silent, and nothing posting on any port. The polyfill's own keep-alive port
    /// is kept out of the way by pre-defining the shared native-runtime resolver
    /// to report none — the one seam that stops the keep-alive opening a port
    /// without touching production code — so this leg measures WebKit alone.
    func testMeasureBackgroundPageUnloadHoldingASilentNativePort() async throws {
        try XCTSkipUnless(measuringBackgroundPageUnload,
                          "long measurement leg; set DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1")
        let id = measurementExtensionID("task62-port")
        let host = try FakeNativeMessagingHost(allowing: [id])
        fakeNativeHosts.append(host)
        let ext = try await makeMeasurementExtension(id: id, nativeHost: host.name)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let started = try await startMeasurement(
            ext, profileName: "TASK-62 Silent Native Port",
            prepending: """
            globalThis.__detourResolveNativeRuntime = function() {
                return { runtime: null, detail: 'no-runtime' };
            };
            """)
        let controller = started.profile.extensionController

        try await waitUntil("the fake host to be spawned for the background page", timeout: 30) {
            ExtensionManager.shared.liveNativeHostCountForTesting(
                controller: controller, extensionID: ext.id) == 1 && host.processCount() == 1
        }

        let life = try await watchBackgroundPage(
            "b: silent native port", from: started.page, limit: 300)
        print("TASK-62 measurement [b: silent native port]: unloaded=\(life.unloaded) at +\(life.lastAliveSeconds) s; live hosts now \(ExtensionManager.shared.liveNativeHostCountForTesting(controller: controller, extensionID: ext.id)), host processes \(host.processCount())")
        // Measured 2026-09-13: unloaded at +120.0 s, 2 minutes after load (the page
        // never posted anything), past the 30 s idle unload of leg (a). The port's
        // onDisconnect fired during the teardown — the last heartbeat says
        // 'disconnected' — and Detour killed the host with it.
        XCTAssertTrue(life.unloaded,
                      "a silent native port alone must not keep the page past the inactive-ports unload")
        XCTAssertGreaterThan(life.lastAliveSeconds, 60,
                             "an open port must move the page off the 30 s idle unload")
        XCTAssertEqual(life.lastBeat["installDetail"] as? String, "no-runtime",
                       "the polyfill's own keep-alive port must be out of the way for this leg")
        try await waitUntil("the native host to go away with the page", timeout: 15) {
            ExtensionManager.shared.liveNativeHostCountForTesting(
                controller: controller, extensionID: ext.id) == 0 && host.processCount() == 0
        }
    }

    /// Leg (c): the same page, same silent native port, plus the production
    /// keep-alive — the polyfill opens its `detourPolyfill` port and Detour arms
    /// it because a real native host is connected, so Detour pings the page every
    /// `ExtensionManager.keepAlivePingInterval` (15 s here) and the page answers
    /// each one. If those round trips defer a page unload the way they defer a
    /// worker's, this page outlives leg (b). Measured 2026-09-13 (with the pings
    /// still worker-driven): still running at +300.9 s, host connected, 21 replies
    /// received.
    func testMeasureBackgroundPageWithTheKeepAliveArmed() async throws {
        try XCTSkipUnless(measuringBackgroundPageUnload,
                          "long measurement leg; set DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1")
        let id = measurementExtensionID("task62-keepalive")
        let host = try FakeNativeMessagingHost(allowing: [id])
        fakeNativeHosts.append(host)
        let ext = try await makeMeasurementExtension(id: id, nativeHost: host.name)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        ExtensionManager.shared.keepAlivePingInterval = 15
        let started = try await startMeasurement(ext, profileName: "TASK-62 Armed Keep-alive")
        let controller = started.profile.extensionController

        try await waitUntil("the fake host to be spawned for the background page", timeout: 30) {
            ExtensionManager.shared.liveNativeHostCountForTesting(
                controller: controller, extensionID: ext.id) == 1 && host.processCount() == 1
        }
        try await waitUntil("Detour to arm the background page's keep-alive", timeout: 30) {
            ExtensionManager.shared.keepAliveStateForTesting(
                controller: controller, extensionID: ext.id)?.armed == true
        }

        let life = try await watchBackgroundPage(
            "c: keep-alive armed", from: started.page, limit: 300)
        print("TASK-62 measurement [c: keep-alive armed]: unloaded=\(life.unloaded) at +\(life.lastAliveSeconds) s; pings received by Detour: \(ExtensionManager.shared.keepAlivePingCountForTesting(controller: controller, extensionID: ext.id))")
        XCTAssertFalse(life.unloaded,
                       "the armed keep-alive must hold the background page past leg (b)'s unload")
        XCTAssertEqual(life.lastBeat["armed"] as? Bool, true)
        XCTAssertEqual(life.lastBeat["nativePort"] as? String, "open")
        XCTAssertEqual(host.processCount(), 1, "the native host must still be connected")
        XCTAssertGreaterThanOrEqual(
            ExtensionManager.shared.keepAlivePingCountForTesting(
                controller: controller, extensionID: ext.id), 2)
    }

    /// The helper legs (b) and (c) depend on, run fast and on its own: the
    /// prepended script runs before the polyfill (it sees no keep-alive status
    /// yet) and the polyfill still runs after it, with nothing duplicated.
    func testPrependedUserScriptRunsBeforeThePolyfill() async throws {
        let ext = try await makeMeasurementExtension(id: measurementExtensionID("task62-prepend"))
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }
        let profile = makeProfile("TASK-62 Prepend")
        prependUserScript(
            "globalThis.__detourTask62SawPolyfill = typeof globalThis.__detourNativePortKeepAlive;",
            to: profile)
        let ucc = profile.extensionController.configuration.webViewConfiguration.userContentController
        XCTAssertEqual(ucc.userScripts.filter { $0.source == ExtensionAPIPolyfill.polyfillJS }.count, 1,
                       "the polyfill must be installed exactly once after the rebuild")

        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let page = try await makeExtensionWebView(for: context)
        let raw = try await page.callAsyncJavaScript("""
            return JSON.stringify({
                sawPolyfill: globalThis.__detourTask62SawPolyfill || 'not-run',
                polyfillNow: typeof globalThis.__detourNativePortKeepAlive
            });
            """, arguments: [:], contentWorld: .page)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(raw as? String).utf8)) as? [String: String])
        XCTAssertEqual(report["sawPolyfill"], "undefined", "the prepended script must run first")
        XCTAssertEqual(report["polyfillNow"], "object", "the polyfill must still run after it")
    }

    // MARK: - TASK-68: a worker whose only port traffic is the keep-alive

    /// The long leg runs for minutes, so it only runs when asked for:
    /// `DETOUR_MEASURE_WORKER_UNLOAD=1`, for
    /// `DETOUR_MEASURE_WORKER_UNLOAD_SECONDS` (default 300) seconds.
    private var measuringWorkerUnload: Bool {
        ProcessInfo.processInfo.environment["DETOUR_MEASURE_WORKER_UNLOAD"] == "1"
    }

    private var workerUnloadMeasurementSeconds: TimeInterval {
        ProcessInfo.processInfo.environment["DETOUR_MEASURE_WORKER_UNLOAD_SECONDS"]
            .flatMap(Double.init) ?? 300
    }

    /// The worker the TASK-68 leg runs: the polyfill and a start counter, and
    /// nothing else. Its only native port is the keep-alive, and its only traffic
    /// on it is answering Detour's pings — the production shape of a 1Password
    /// worker whose helpers are connected but silent and which has no relayed
    /// socket.
    ///
    /// The counter goes into `chrome.storage.local`, which an ordinary page of the
    /// same extension can read *without messaging the worker* — a message would
    /// wake it and destroy the measurement. (A worker has no `localStorage`, which
    /// is what the TASK-62 page legs use.)
    private static let workerUnloadMeasurementJS = """

    (async function() {
        try {
            const stored = await chrome.storage.local.get('starts');
            const starts = (Number(stored && stored.starts) || 0) + 1;
            await chrome.storage.local.set({ starts: starts, startedAt: Date.now() });
        } catch (e) {}
    })();
    """

    /// How many times the probe worker has started, read out of the extension's
    /// own storage through an ordinary page — nothing here wakes the worker.
    /// -1 when the page cannot read it at all.
    private func workerStartCount(from webView: WKWebView) async -> Int {
        let raw = try? await webView.callAsyncJavaScript("""
            try {
                const stored = await chrome.storage.local.get('starts');
                return String(stored && stored.starts !== undefined ? stored.starts : -1);
            } catch (e) { return '-1'; }
            """, arguments: [:], contentWorld: .page)
        return Int((raw as? String) ?? "") ?? -1
    }

    /// AC #2/#3/#4 of TASK-68. A worker with `nativeMessaging`, armed with a
    /// simulated host so that *nothing but the keep-alive* ever crosses a port,
    /// at the production ping interval: for the whole leg the port must stay
    /// open, replies must keep arriving, and the worker must have started exactly
    /// once. Then the hold is released and WebKit's idle unload must take it —
    /// the disarmed path is unchanged.
    ///
    /// In production (2026-09-13) exactly this worker was unloaded ~170 s after
    /// starting with the keep-alive armed the whole time. If that happens here the
    /// leg fails loudly with the timings rather than quietly passing.
    ///
    /// Measured 2026-09-13 with Detour driving the pings (300 s leg): the port
    /// stayed open for the whole 300.9 s, 11 pings sent and 11 replies received
    /// (round trips 0–3 ms), never one ping awaiting a reply, one keep-alive port
    /// opened — so one worker, well past the ~170 s at which production's
    /// worker-driven pings stopped counting. Released, WebKit closed the port
    /// 149.4 s later.
    func testMeasureWorkerUnloadWithOnlyTheKeepAliveOnItsPort() async throws {
        try XCTSkipUnless(measuringWorkerUnload,
                          "long measurement leg; set DETOUR_MEASURE_WORKER_UNLOAD=1")
        let id = measurementExtensionID("task68-worker")
        let ext = try await makeWorkerExtension(
            id: id, permissions: ["nativeMessaging", "storage"],
            backgroundJS: ExtensionAPIPolyfill.polyfillJS + Self.workerUnloadMeasurementJS)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let profile = makeProfile("TASK-68 Worker Unload")
        let controller = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let page = try await makeExtensionWebView(for: context)

        let manager = ExtensionManager.shared
        XCTAssertEqual(manager.keepAlivePingInterval, 30,
                       "this leg only means anything at the production ping interval")
        func state() -> NativeHostKeepAliveState? {
            manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id)
        }
        func replies() -> Int {
            manager.keepAlivePingCountForTesting(controller: controller, extensionID: ext.id)
        }
        func portsOpened() -> Int {
            manager.keepAlivePortOpenCountForTesting(controller: controller, extensionID: ext.id)
        }

        context.loadBackgroundContent { error in
            if let error { print("TASK-68 measurement: loadBackgroundContent failed: \(error)") }
        }
        try await waitUntil("the worker's keep-alive port to reach ExtensionManager", timeout: 30) {
            state()?.portOpen == true
        }
        // No real host is spawned: the simulated hold is what makes the keep-alive
        // round trips the only traffic on the worker's only port.
        manager.simulateNativeHostForTesting(connected: true, controller: controller, extensionID: ext.id)
        try await waitUntil("Detour to arm the worker", timeout: 10) { state()?.armed == true }

        let armedAt = Date()
        let limit = workerUnloadMeasurementSeconds
        var lastReport = Date.distantPast
        var closedAt: TimeInterval?
        while Date().timeIntervalSince(armedAt) < limit {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let elapsed = Date().timeIntervalSince(armedAt)
            if state()?.portOpen != true {
                closedAt = elapsed
                break
            }
            if Date().timeIntervalSince(lastReport) >= 30 {
                lastReport = Date()
                let sent = manager.keepAlivePingsSentForTesting(controller: controller, extensionID: ext.id)
                let starts = await workerStartCount(from: page)
                print("TASK-68 measurement: +\(String(format: "%.1f", elapsed)) s — port open, pings sent \(sent?.sent ?? -1), awaiting reply \(sent?.awaiting.map(String.init) ?? "none"), replies \(replies()), worker starts \(starts), keep-alive ports opened \(portsOpened())")
            }
        }

        let starts = await workerStartCount(from: page)
        let sent = manager.keepAlivePingsSentForTesting(controller: controller, extensionID: ext.id)
        print("TASK-68 measurement: leg ended at +\(String(format: "%.1f", Date().timeIntervalSince(armedAt))) s — closed \(closedAt.map { String(format: "%.1f", $0) } ?? "no"), pings sent \(sent?.sent ?? -1), replies \(replies()), worker starts \(starts), keep-alive ports opened \(portsOpened())")

        XCTAssertNil(closedAt,
                     "the keep-alive port closed at +\(closedAt ?? -1) s with the keep-alive armed and replies flowing — WebKit unloaded the worker anyway (the TASK-68 production symptom)")
        XCTAssertEqual(state()?.armed, true, "the keep-alive must still be armed")
        XCTAssertGreaterThanOrEqual(
            replies(), Int(limit / manager.keepAlivePingInterval) - 1,
            "a reply must have come back for essentially every ping")
        XCTAssertEqual(sent?.awaiting, nil, "no ping may be left unanswered at the end of the leg")
        XCTAssertEqual(portsOpened(), 1, "the worker must have started exactly once")
        if starts >= 0 {
            XCTAssertEqual(starts, 1, "the worker must have started exactly once")
        }

        // AC #4: released, the worker is WebKit's again — the idle unload must
        // still take it. Its port is still open, so this is the inactive-ports
        // path: 2 minutes after the last activity (the final reply, which went out
        // just before the release), evaluated on WebKit's own 30 s timer, so
        // anything up to ~150 s. Measured 2026-09-13: 149.4 s.
        manager.simulateNativeHostForTesting(connected: false, controller: controller, extensionID: ext.id)
        let releasedAt = Date()
        try await waitUntil("WebKit to unload the released worker", timeout: 200, pollInterval: 1) {
            state()?.portOpen != true
        }
        let unloadedAfter = Date().timeIntervalSince(releasedAt)
        print("TASK-68 measurement: released at +\(String(format: "%.1f", releasedAt.timeIntervalSince(armedAt))) s; the keep-alive port closed \(String(format: "%.1f", unloadedAfter)) s later")
        XCTAssertLessThan(unloadedAfter, 180,
                          "a released worker must go back to WebKit's idle unload")
    }

    // MARK: - TASK-68: a background that stops answering is restarted

    /// The probe for the TASK-68 recovery legs: a worker that can open and close
    /// an offscreen document — through WebKit's own `chrome.offscreen` and through
    /// Detour's polyfilled one, which are kept apart deliberately (see
    /// `nativeOffscreenCaptureJS`) — and can be told to stop answering Detour's
    /// keep-alive pings, which is what a worker WebKit terminated under a hidden
    /// page that is still loaded looks like from Detour's side.
    ///
    /// Every answer goes through `chrome.runtime.sendMessage` from an ordinary
    /// extension page, so "the worker no longer answers" is observable from the
    /// test as well as from the keep-alive ledger.
    private static let keepAliveProbeJS = """

    let offscreenLog = [];

    function describe(fn) {
        try { return String(fn); } catch (e) { return 'error: ' + e; }
    }

    async function useOffscreen(api, action) {
        const out = { action: action, ok: false, error: null, hasDocument: null };
        if (!api) {
            out.error = 'no offscreen namespace';
            return out;
        }
        try {
            if (action === 'create') {
                await api.createDocument({
                    url: 'offscreen.html', reasons: ['BLOBS'], justification: 'TASK-68 harness'
                });
            } else {
                await api.closeDocument();
            }
            out.ok = true;
        } catch (e) {
            out.error = String(e && e.message !== undefined ? e.message : e);
        }
        try { out.hasDocument = await api.hasDocument(); } catch (e) { out.hasDocument = 'error'; }
        offscreenLog.push(out);
        return out;
    }

    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) return false;
        if (message.type === 'ping') {
            const keepAlive = globalThis.__detourNativePortKeepAlive;
            sendResponse({
                type: 'pong',
                installMode: keepAlive ? keepAlive.installMode : 'missing',
                installDetail: keepAlive ? keepAlive.installDetail : 'missing',
                armed: keepAlive ? keepAlive.armed : false,
                repliesSent: keepAlive ? keepAlive.repliesSent : -1,
                offscreen: offscreenLog
            });
            return true;
        }
        if (message.type === 'offscreenInfo') {
            const polyfilled = describe(chrome.offscreen && chrome.offscreen.createDocument);
            const native = globalThis.__detourNativeOffscreen;
            sendResponse({
                chromeOffscreen: typeof chrome.offscreen,
                createDocument: typeof (chrome.offscreen && chrome.offscreen.createDocument),
                goesThroughDetour: polyfilled.indexOf('__detourPolyfillRequest') !== -1,
                capturedNative: !!native,
                nativeIsChromeOffscreen: !!native && native === chrome.offscreen,
                nativeCreateDocument: native ? typeof native.createDocument : 'none',
                nativeSource: native ? describe(native.createDocument).slice(0, 160) : ''
            });
            return true;
        }
        if (message.type === 'offscreen') {
            const api = message.api === 'native'
                ? globalThis.__detourNativeOffscreen : chrome.offscreen;
            useOffscreen(api, message.action).then(sendResponse);
            return true;
        }
        if (message.type === 'unregister') {
            // A service worker can clear its own registration. WebKit answers a
            // cleared registration the way it answered the one 1Password's
            // offscreen document took down: SWServerRegistration::clear in the
            // Networking process, SWContextManager::terminateWorker in this one —
            // while the hidden background page this worker lives under stays
            // loaded, with every port on it still open.
            sendResponse({ ok: true });
            setTimeout(() => {
                try { globalThis.registration.unregister(); } catch (e) {}
            }, 50);
            return true;
        }
        if (message.type === 'ignorePings') {
            globalThis.__detourKeepAliveIgnorePings =
                message.count === undefined ? true : message.count;
            sendResponse({ ok: true, ignoring: globalThis.__detourKeepAliveIgnorePings });
            return true;
        }
        return false;
    });
    """

    /// Runs *before* the polyfill in the probe worker and keeps WebKit's own
    /// `chrome.offscreen` — the polyfill defines its own over it, and the
    /// production kill (2026-09-13) came from WebKit's native implementation,
    /// which creates the document as a page in the worker's own process. Held on
    /// the global so a leg can pick which of the two implementations it exercises.
    private static let nativeOffscreenCaptureJS = """
    globalThis.__detourNativeOffscreen =
        (typeof chrome !== 'undefined' && chrome.offscreen) ? chrome.offscreen : null;

    """

    private func makeKeepAliveProbeExtension(id: String) async throws -> WebExtension {
        try await makeWorkerExtension(
            id: id, permissions: ["nativeMessaging", "offscreen"],
            backgroundJS: Self.nativeOffscreenCaptureJS + ExtensionAPIPolyfill.polyfillJS
                + Self.keepAliveProbeJS,
            extraFiles: ["offscreen.html":
                            "<html><body><div id=\"offscreen\">offscreen</div></body></html>"])
    }

    /// Start the probe in a fresh profile with the keep-alive armed by a simulated
    /// host, so the round trips Detour drives are the only traffic on the worker's
    /// only port — and shorten the ping interval so a leg takes seconds.
    private func startKeepAliveProbe(
        _ ext: WebExtension, profileName: String, pingInterval: TimeInterval
    ) async throws -> (profile: Profile, context: WKWebExtensionContext, page: WKWebView,
                       controller: WKWebExtensionController) {
        let manager = ExtensionManager.shared
        manager.keepAlivePingInterval = pingInterval
        let started = try await startMeasurement(ext, profileName: profileName)
        let controller = started.profile.extensionController
        try await waitUntil("the worker's keep-alive port to reach ExtensionManager", timeout: 30) {
            manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id)?.portOpen == true
        }
        manager.simulateNativeHostForTesting(connected: true, controller: controller, extensionID: ext.id)
        try await waitUntil("Detour to arm the worker", timeout: 10) {
            manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id)?.armed == true
        }
        try await waitUntil("the first keep-alive replies to flow", timeout: 20) {
            manager.keepAlivePingCountForTesting(controller: controller, extensionID: ext.id) >= 2
        }
        return (started.profile, started.context, started.page, controller)
    }

    /// One line of the keep-alive ledger, for the measurement legs' output.
    private func keepAliveLedger(_ ext: WebExtension,
                                 _ controller: WKWebExtensionController) -> String {
        let manager = ExtensionManager.shared
        let sent = manager.keepAlivePingsSentForTesting(controller: controller, extensionID: ext.id)
        let missed = manager.keepAliveMissedRepliesForTesting(controller: controller, extensionID: ext.id)
        let state = manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id)
        return "pings sent \(sent?.sent ?? -1), awaiting \(sent?.awaiting.map(String.init) ?? "none"), replies \(manager.keepAlivePingCountForTesting(controller: controller, extensionID: ext.id)), missed run \(missed.missed), restarting \(missed.restarting), ports opened \(manager.keepAlivePortOpenCountForTesting(controller: controller, extensionID: ext.id)), state \(String(describing: state))"
    }

    /// Part 1 (a)/(c) of the TASK-68 production finding: does closing an
    /// offscreen document take the worker with it, as it did in production on
    /// 2026-09-13?
    ///
    /// Not in this harness, and the reason is in the report the probe prints:
    /// there is no *native* `chrome.offscreen` here to reach. The probe captures
    /// `chrome.offscreen` in its worker before the polyfill runs
    /// (`nativeOffscreenCaptureJS`) and finds nothing (`capturedNative` false), so
    /// `chrome.offscreen` is Detour's polyfill and `createDocument` goes to
    /// `OffscreenDocumentHost` — a WKWebView of Detour's own, not a page WebKit
    /// created inside the worker's process, which is what 1Password got (its
    /// document became page 577 in the worker's WebContent process and the
    /// Networking process cleared the worker's service-worker registration 14 ms
    /// after that page closed). Detour's offscreen document opens and closes with
    /// the worker none the wiser, which is what this asserts.
    ///
    /// What *does* reproduce the production kill here is
    /// `testClosingTheLastExtensionPageKillsTheWorker` below: a page close, of the
    /// kind WebKit's own offscreen implementation performs.
    func testADetourHostedOffscreenDocumentDoesNotKillTheWorker() async throws {
        let id = measurementExtensionID("task68-offscreen")
        let ext = try await makeKeepAliveProbeExtension(id: id)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }
        let manager = ExtensionManager.shared
        // Observe, do not recover: this leg is about what the offscreen document
        // does to the worker, not about the safety net.
        manager.keepAliveMissedReplyLimit = 1000
        let started = try await startKeepAliveProbe(
            ext, profileName: "TASK-68 Offscreen", pingInterval: 1)
        let controller = started.controller

        let info = try await askWorker(from: started.page, message: ["type": "offscreenInfo"],
                                       timeout: 10)
        let report = try XCTUnwrap(info["reply"] as? [String: Any], "\(info)")
        print("TASK-68 [offscreen]: \(report)")
        XCTAssertEqual(report["goesThroughDetour"] as? Bool, true,
                       "chrome.offscreen must be Detour's polyfill in this harness: \(report)")
        XCTAssertEqual(report["capturedNative"] as? Bool, false,
                       "no native chrome.offscreen exists before the polyfill here, so the WebKit-hosted document production hit cannot be exercised: \(report)")

        let created = try await askWorker(
            from: started.page, message: ["type": "offscreen", "api": "detour", "action": "create"],
            timeout: 30)
        XCTAssertEqual((created["reply"] as? [String: Any])?["ok"] as? Bool, true, "\(created)")
        let closed = try await askWorker(
            from: started.page, message: ["type": "offscreen", "api": "detour", "action": "close"],
            timeout: 30)
        XCTAssertEqual((closed["reply"] as? [String: Any])?["ok"] as? Bool, true, "\(closed)")

        let repliesAfterClose = manager.keepAlivePingCountForTesting(
            controller: controller, extensionID: ext.id)
        try await waitUntil("the keep-alive replies to keep coming after the document closed",
                            timeout: 15) {
            manager.keepAlivePingCountForTesting(
                controller: controller, extensionID: ext.id) >= repliesAfterClose + 3
        }
        print("TASK-68 [offscreen]: \(keepAliveLedger(ext, controller))")
        XCTAssertEqual(manager.keepAlivePortOpenCountForTesting(
            controller: controller, extensionID: ext.id), 1, "the worker must not have restarted")
        let answered = try await askWorker(from: started.page, message: ["type": "ping"], timeout: 10)
        XCTAssertEqual((answered["reply"] as? [String: Any])?["type"] as? String, "pong", "\(answered)")
    }

    /// Part 1, the production finding reproduced: a worker WebKit terminated
    /// under a background page that is still loaded, with every port on that page
    /// still open — and the recovery that gets a working background back.
    ///
    /// The production *trigger* cannot be reached here: 1Password's worker opened
    /// a WebKit-hosted `chrome.offscreen` document (a page in the worker's own
    /// WebContent process) and closing it made the Networking process clear the
    /// worker's service-worker registration 14 ms later, but this harness has no
    /// native `chrome.offscreen` at all (see
    /// `testADetourHostedOffscreenDocumentDoesNotKillTheWorker`). What this test
    /// does instead is reach the same WebKit teardown from the other end: the
    /// worker clears its own registration (`registration.unregister()`), so the
    /// Networking process runs `SWServerRegistration::clear` and the content
    /// process `SWContextManager::terminateWorker` — the same two lines, in the
    /// same order, that production logged 14 ms after the offscreen page closed.
    /// (The symptom first appeared in the harness by accident on 2026-09-13, when
    /// a website-data deletion cleared another test's registration and left
    /// Detour pinging a worker that had been terminated under a page that was
    /// still loaded.)
    ///
    /// What Detour sees is what matters, and it is identical to production: the
    /// keep-alive port stays open and registered, `portOpen` and `armed` stay
    /// true, alarms and messages are silently lost, and the only sign of death is
    /// that the pings stop coming back.
    func testAWorkerTerminatedUnderItsLiveBackgroundPageIsRestarted() async throws {
        let id = measurementExtensionID("task68-terminated")
        let ext = try await makeKeepAliveProbeExtension(id: id)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }
        let manager = ExtensionManager.shared
        manager.keepAliveMissedReplyLimit = 2
        let started = try await startKeepAliveProbe(
            ext, profileName: "TASK-68 Terminated Worker", pingInterval: 2)
        let controller = started.controller
        XCTAssertEqual(manager.keepAlivePortOpenCountForTesting(
            controller: controller, extensionID: ext.id), 1, "precondition: one worker start")

        let unregistered = try await askWorker(
            from: started.page, message: ["type": "unregister"], timeout: 10)
        XCTAssertEqual((unregistered["reply"] as? [String: Any])?["ok"] as? Bool, true,
                       "\(unregistered)")

        try await waitUntil("Detour to see the worker stop answering", timeout: 30,
                            pollInterval: 0.2) {
            manager.keepAliveMissedRepliesForTesting(
                controller: controller, extensionID: ext.id).missed >= 1
        }
        let dying = try XCTUnwrap(manager.keepAliveStateForTesting(
            controller: controller, extensionID: ext.id))
        XCTAssertTrue(dying.portOpen,
                      "the production symptom: the hidden background page and its port outlive the worker")
        XCTAssertTrue(dying.armed)
        print("TASK-68 [terminated worker]: silent — \(keepAliveLedger(ext, controller))")

        // Two silent intervals: Detour declares the background dead, tears its
        // connections down and drops the keep-alive port with them, which is what
        // lets WebKit's own 30 s tick collect the zombie page.
        let tornDownAt = Date()
        try await waitUntil("Detour to tear the dead background down", timeout: 30,
                            pollInterval: 0.2) {
            manager.keepAliveStateForTesting(
                controller: controller, extensionID: ext.id)?.portOpen != true
        }
        print("TASK-68 [terminated worker]: torn down after \(String(format: "%.1f", Date().timeIntervalSince(tornDownAt))) s — \(keepAliveLedger(ext, controller))")
        XCTAssertNil(manager.keepAliveStateForTesting(
            controller: controller, extensionID: ext.id),
                     "the teardown resets the keep-alive to nothing tracked")

        // And then a fresh background context, with a fresh keep-alive port.
        try await waitUntil("Detour to start a fresh background context",
                            timeout: manager.keepAliveRestartDelay + 90, pollInterval: 0.5) {
            manager.keepAlivePortOpenCountForTesting(
                controller: controller, extensionID: ext.id) > 1
        }
        print("TASK-68 [terminated worker]: restarted — \(keepAliveLedger(ext, controller))")

        // The restarted background answers again. Nothing arms it here: the
        // simulated host went with the context Detour tore down, as a real
        // context's hosts do, so arming stands in for the hosts a real background
        // reconnects at startup.
        manager.simulateNativeHostForTesting(connected: true, controller: controller, extensionID: ext.id)
        try await waitUntil("Detour to arm the restarted background", timeout: 10) {
            manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id)?.armed == true
        }
        let repliesAfterRestart = manager.keepAlivePingCountForTesting(
            controller: controller, extensionID: ext.id)
        try await waitUntil("the restarted background to answer pings", timeout: 20) {
            manager.keepAlivePingCountForTesting(
                controller: controller, extensionID: ext.id) >= repliesAfterRestart + 2
        }
        XCTAssertNil(manager.keepAlivePingsSentForTesting(
            controller: controller, extensionID: ext.id)?.awaiting)
        print("TASK-68 [terminated worker]: recovered — \(keepAliveLedger(ext, controller))")
    }

    /// Part 1 (b): the control for the page-close kill above. An extension page
    /// opened and released *while another extension page of the same context is
    /// still open* does not take the worker with it — so it is not "a page closed"
    /// that kills the worker but the last client of its service-worker
    /// registration going away, which is why closing WebKit's own offscreen
    /// document was enough in production and why an ordinary popup is not.
    func testAnOrdinaryExtensionPageClosingDoesNotKillTheWorker() async throws {
        let id = measurementExtensionID("task68-page-close")
        let ext = try await makeKeepAliveProbeExtension(id: id)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }
        let manager = ExtensionManager.shared
        manager.keepAliveMissedReplyLimit = 1000
        let started = try await startKeepAliveProbe(
            ext, profileName: "TASK-68 Page Close", pingInterval: 1)
        let controller = started.controller

        var page: WKWebView? = try await makeExtensionWebView(for: started.context)
        XCTAssertNotNil(page)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        page = nil
        // The web view's page is closed on dealloc; give WebKit a moment to act on it.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let repliesAfterClose = manager.keepAlivePingCountForTesting(
            controller: controller, extensionID: ext.id)
        try await waitUntil("the keep-alive replies to keep coming after the page closed",
                            timeout: 15) {
            manager.keepAlivePingCountForTesting(
                controller: controller, extensionID: ext.id) >= repliesAfterClose + 2
        }
        print("TASK-68 [page close]: \(keepAliveLedger(ext, controller))")
        let answered = try await askWorker(from: started.page, message: ["type": "ping"], timeout: 10)
        XCTAssertEqual((answered["reply"] as? [String: Any])?["type"] as? String, "pong",
                       "the worker must still answer after an ordinary page closed: \(answered)")
        XCTAssertEqual(manager.keepAlivePortOpenCountForTesting(
            controller: controller, extensionID: ext.id), 1,
                       "the worker must not have restarted")
    }

    /// Part 2: a background that has stopped answering Detour's pings for two
    /// intervals is torn down and started again.
    ///
    /// The worker here is alive and simply ignores the pings
    /// (`__detourKeepAliveIgnorePings`, a test-only hook in the keep-alive JS) —
    /// from Detour's side that is exactly the production shape: a hidden page
    /// still loaded, its port still open, and nothing ever coming back. The
    /// recovery must disconnect what it holds (which drops the port, so WebKit can
    /// collect the page) and let a fresh keep-alive port take its place.
    func testASilentBackgroundIsTornDownAndRestarted() async throws {
        let id = measurementExtensionID("task68-silent")
        let ext = try await makeKeepAliveProbeExtension(id: id)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }
        let manager = ExtensionManager.shared
        manager.keepAliveMissedReplyLimit = 2
        manager.keepAliveRestartDelay = 3
        let started = try await startKeepAliveProbe(
            ext, profileName: "TASK-68 Silent Worker", pingInterval: 1)
        let controller = started.controller

        XCTAssertEqual(manager.keepAlivePortOpenCountForTesting(
            controller: controller, extensionID: ext.id), 1, "precondition: one worker start")

        // Two pings dropped is exactly the limit: the tick after them declares the
        // background dead. The worker answers again from the third, so the port it
        // reconnects is a working one.
        let ignoring = try await askWorker(
            from: started.page, message: ["type": "ignorePings", "count": 2], timeout: 10)
        XCTAssertEqual((ignoring["reply"] as? [String: Any])?["ok"] as? Bool, true, "\(ignoring)")

        try await waitUntil("Detour to tear the silent background down and restart it",
                            timeout: 30, pollInterval: 0.2) {
            manager.keepAlivePortOpenCountForTesting(
                controller: controller, extensionID: ext.id) > 1
        }
        print("TASK-68 [silent worker]: after the restart — \(keepAliveLedger(ext, controller))")

        // The teardown treats the background as gone, so the simulated host went
        // with it — a real restarted background connects its own hosts, which is
        // what this stands in for.
        let state = try XCTUnwrap(manager.keepAliveStateForTesting(
            controller: controller, extensionID: ext.id))
        XCTAssertTrue(state.portOpen, "the fresh keep-alive port must be registered")
        XCTAssertEqual(state.connectedHosts, 0,
                       "the unresponsive background's connections must have been torn down")
        XCTAssertFalse(state.armed, "nothing holds the fresh background up yet")

        manager.simulateNativeHostForTesting(connected: true, controller: controller, extensionID: ext.id)
        try await waitUntil("Detour to arm the restarted background", timeout: 10) {
            manager.keepAliveStateForTesting(controller: controller, extensionID: ext.id)?.armed == true
        }
        let repliesAfterRestart = manager.keepAlivePingCountForTesting(
            controller: controller, extensionID: ext.id)
        try await waitUntil("the restarted background to answer pings again", timeout: 20) {
            manager.keepAlivePingCountForTesting(
                controller: controller, extensionID: ext.id) >= repliesAfterRestart + 2
        }
        XCTAssertNil(manager.keepAlivePingsSentForTesting(
            controller: controller, extensionID: ext.id)?.awaiting,
                     "the restarted background must be answering every ping")
        XCTAssertEqual(manager.keepAliveMissedRepliesForTesting(
            controller: controller, extensionID: ext.id).missed, 0)
        print("TASK-68 [silent worker]: recovered — \(keepAliveLedger(ext, controller))")
    }

    /// The negative: one missed reply is a hiccup, not a death. Detour logs it,
    /// keeps pinging on the same port, and tears nothing down.
    func testASingleMissedKeepAliveReplyDoesNotRestartTheBackground() async throws {
        let id = measurementExtensionID("task68-one-miss")
        let ext = try await makeKeepAliveProbeExtension(id: id)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }
        let manager = ExtensionManager.shared
        manager.keepAliveMissedReplyLimit = 2
        manager.keepAliveRestartDelay = 3
        let started = try await startKeepAliveProbe(
            ext, profileName: "TASK-68 One Miss", pingInterval: 1)
        let controller = started.controller

        let ignoring = try await askWorker(
            from: started.page, message: ["type": "ignorePings", "count": 1], timeout: 10)
        XCTAssertEqual((ignoring["reply"] as? [String: Any])?["ok"] as? Bool, true, "\(ignoring)")

        let repliesBefore = manager.keepAlivePingCountForTesting(
            controller: controller, extensionID: ext.id)
        try await waitUntil("the background to answer again after the missed ping", timeout: 20) {
            manager.keepAlivePingCountForTesting(
                controller: controller, extensionID: ext.id) >= repliesBefore + 3
        }
        print("TASK-68 [one miss]: \(keepAliveLedger(ext, controller))")

        XCTAssertEqual(manager.keepAlivePortOpenCountForTesting(
            controller: controller, extensionID: ext.id), 1,
                       "one missed reply must not restart the background")
        let state = try XCTUnwrap(manager.keepAliveStateForTesting(
            controller: controller, extensionID: ext.id))
        XCTAssertTrue(state.armed, "the keep-alive must still be armed")
        XCTAssertEqual(state.connectedHosts, 1, "nothing may have been torn down")
        let missed = manager.keepAliveMissedRepliesForTesting(
            controller: controller, extensionID: ext.id)
        XCTAssertEqual(missed.missed, 0, "the missed run ended with the next reply")
        XCTAssertFalse(missed.restarting, "no restart may be pending")
        let answered = try await askWorker(from: started.page, message: ["type": "ping"], timeout: 10)
        XCTAssertEqual((answered["reply"] as? [String: Any])?["type"] as? String, "pong", "\(answered)")
    }

    // MARK: - TASK-62: which contexts install the keep-alive

    /// What the polyfill's keep-alive made of a background context, asked through
    /// an ordinary page of the same extension.
    private func keepAliveReport(_ ext: WebExtension, profileName: String,
                                 wakeBackground: Bool = true) async throws -> [String: Any] {
        let profile = makeProfile(profileName)
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let page = try await makeExtensionWebView(for: context)
        if wakeBackground {
            context.loadBackgroundContent { _ in }
        }
        return try await reportFromBackgroundContext(
            page: page, what: "the background context's keep-alive report")
    }

    /// A non-persistent `background.scripts` page that declares `nativeMessaging`
    /// installs the keep-alive, exactly as a service worker does.
    func testKeepAliveInstallsInANonPersistentBackgroundPage() async throws {
        let ext = try await makeMeasurementExtension(id: measurementExtensionID("task62-install-page"))
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let report = try await keepAliveReport(ext, profileName: "TASK-62 Install Page")
        print("TASK-62 install decision (non-persistent page): \(report)")
        XCTAssertEqual(report["isWorker"] as? Bool, false)
        XCTAssertEqual(report["contextKind"] as? String, "background-page")
        XCTAssertEqual(report["installMode"] as? String, "port")
        XCTAssertEqual(report["installDetail"] as? String, "")
    }

    /// A *persistent* MV2 background page is never unloaded, so it has nothing to
    /// keep alive and must not hold a port in Detour for nothing.
    func testKeepAliveIsNotInstalledInAPersistentBackgroundPage() async throws {
        let ext = try await makeMeasurementExtension(
            id: measurementExtensionID("task62-install-persistent"),
            manifestVersion: 2, persistent: nil)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }
        let wkExt = try XCTUnwrap(ext.wkExtension)
        XCTAssertTrue(wkExt.hasPersistentBackgroundContent,
                      "precondition: WebKit runs this manifest's background persistently")

        let report = try await keepAliveReport(ext, profileName: "TASK-62 Install Persistent")
        print("TASK-62 install decision (persistent MV2 page): \(report)")
        XCTAssertEqual(report["contextKind"] as? String, "background-page")
        XCTAssertEqual(report["installMode"] as? String, "none")
        XCTAssertEqual(report["installDetail"] as? String, "persistent-background-page")
    }

    /// An extension page that is not the background context installs nothing:
    /// Detour keeps one keep-alive port per extension, so a popup or options page
    /// opening its own would evict the background's.
    func testKeepAliveIsNotInstalledInAnOrdinaryExtensionPage() async throws {
        let ext = try await makeMeasurementExtension(id: measurementExtensionID("task62-install-ordinary"))
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }
        let profile = makeProfile("TASK-62 Install Ordinary Page")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let page = try await makeExtensionWebView(for: context)

        let status = try await page.callAsyncJavaScript("""
            const keepAlive = globalThis.__detourNativePortKeepAlive;
            return JSON.stringify({
                contextKind: globalThis.__detourContextKind,
                installMode: keepAlive ? keepAlive.installMode : 'missing',
                installDetail: keepAlive ? keepAlive.installDetail : 'missing'
            });
            """, arguments: [:], contentWorld: .page)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(status as? String).utf8)) as? [String: Any])
        print("TASK-62 install decision (ordinary extension page): \(report)")
        XCTAssertEqual(report["contextKind"] as? String, "page")
        XCTAssertEqual(report["installMode"] as? String, "none")
        XCTAssertEqual(report["installDetail"] as? String, "not-a-background-context")
    }

    /// A background page whose extension cannot ever have a native host holds no
    /// port either — the permission gate is unchanged by the context relaxation.
    func testKeepAliveIsNotInstalledInABackgroundPageWithoutNativeMessaging() async throws {
        let ext = try await makeMeasurementExtension(
            id: measurementExtensionID("task62-install-nopermission"), permissions: [])
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let report = try await keepAliveReport(ext, profileName: "TASK-62 Install No Permission")
        print("TASK-62 install decision (page without nativeMessaging): \(report)")
        XCTAssertEqual(report["contextKind"] as? String, "background-page")
        XCTAssertEqual(report["installMode"] as? String, "none")
        XCTAssertEqual(report["installDetail"] as? String, "no-nativeMessaging-permission")
    }

    // MARK: - TASK-62: a second keep-alive port supersedes the first

    /// The background script for the contest below. Every context running it —
    /// the real background page and a tab at the background path alike — stamps
    /// its own keep-alive status into the origin's `localStorage` under its own
    /// instance key, so both can be read from either one without messaging (a
    /// `runtime.sendMessage` could be answered by either context at this path).
    private static let keepAliveContestBackgroundJS = """
        const instance = Math.random().toString(36).slice(2) + '-' + Date.now().toString(36);
        globalThis.__detourKeepAliveInstance = instance;
        function beat() {
            const keepAlive = globalThis.__detourNativePortKeepAlive;
            try {
                localStorage.setItem('__detourKeepAliveBeat:' + instance, JSON.stringify({
                    instance: instance,
                    at: Date.now(),
                    installMode: keepAlive ? keepAlive.installMode : 'missing',
                    installDetail: keepAlive ? keepAlive.installDetail : 'missing'
                }));
            } catch (e) {}
        }
        beat();
        setInterval(beat, 250);
        """

    /// Every context's latest keep-alive beat, keyed by instance, read through
    /// `webView` (any page of the extension's origin).
    private func keepAliveBeats(from webView: WKWebView) async throws -> [String: [String: Any]] {
        let raw = try await webView.callAsyncJavaScript("""
            const beats = {};
            for (let i = 0; i < localStorage.length; i++) {
                const key = localStorage.key(i);
                if (!key || key.indexOf('__detourKeepAliveBeat:') !== 0) continue;
                try { beats[key.slice('__detourKeepAliveBeat:'.length)] = JSON.parse(localStorage.getItem(key)); } catch (e) {}
            }
            return JSON.stringify(beats);
            """, arguments: [:], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string, got \(String(describing: raw))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]])
    }

    /// A tab navigated to the background document's path passes the polyfill's
    /// background gate and opens its own keep-alive port, which replaces the real
    /// background page's (one port per extension per controller). Before the fix
    /// the evicted context reconnected, evicting the other in turn, and the two
    /// took the port from each other forever. Now the newest port wins and the
    /// evicted context stops (`installDetail` 'superseded') until its next start.
    func testASupersededKeepAlivePortStopsInsteadOfReconnecting() async throws {
        let id = measurementExtensionID("task62-superseded")
        let ext = try await makeBackgroundPageExtension(
            .scripts, id: id, permissions: ["nativeMessaging"],
            backgroundJS: Self.keepAliveContestBackgroundJS)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let profile = makeProfile("TASK-62 Superseded Keep-alive")
        _ = profile.extensionController
        // A short reconnect base, so a context that did reconnect would do so many
        // times inside the observation window.
        prependUserScript("globalThis.__detourKeepAliveReconnectBaseMs = 100;", to: profile)
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let controller = profile.extensionController
        let configuration = try XCTUnwrap(context.webViewConfiguration,
                                          "webViewConfiguration is nil — context not loaded in a controller")

        context.loadBackgroundContent { _ in }
        try await waitUntil("the real background page to open its keep-alive port", timeout: 30) {
            ExtensionManager.shared.keepAliveStateForTesting(
                controller: controller, extensionID: ext.id)?.portOpen == true
        }
        XCTAssertEqual(ExtensionManager.shared.keepAlivePortOpenCountForTesting(
            controller: controller, extensionID: ext.id), 1, "precondition: only the background holds a port")

        let space = addSpace(for: profile, name: "TASK-62 Superseded Keep-alive Space")
        let backgroundPagePath = ExtensionPolyfillHandler.generatedBackgroundPagePath
        let tab = TabStore.shared.addExtensionTab(
            in: space,
            url: context.baseURL.appendingPathComponent(String(backgroundPagePath.dropFirst())),
            configuration: configuration)
        let tabView = try XCTUnwrap(tab.webView)
        var tabInstance = ""
        try await waitUntil("the extension tab to run the background script", timeout: 20) {
            guard tabView.isLoading == false, tabView.url?.path == backgroundPagePath else { return false }
            let instance = try? await tabView.callAsyncJavaScript(
                "return globalThis.__detourKeepAliveInstance || '';", arguments: [:], contentWorld: .page)
            tabInstance = instance as? String ?? ""
            return !tabInstance.isEmpty
        }

        func tabKeepAlive() async throws -> [String: Any] {
            let raw = try await tabView.callAsyncJavaScript("""
                const keepAlive = globalThis.__detourNativePortKeepAlive;
                return JSON.stringify({
                    contextKind: globalThis.__detourContextKind || 'none',
                    installMode: keepAlive ? keepAlive.installMode : 'missing',
                    installDetail: keepAlive ? keepAlive.installDetail : 'missing'
                });
                """, arguments: [:], contentWorld: .page)
            let json = try XCTUnwrap(raw as? String)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        func backgroundKeepAlive() async throws -> [String: Any]? {
            try await keepAliveBeats(from: tabView).first { $0.key != tabInstance }?.value
        }

        try await waitUntil("a second keep-alive port to connect", timeout: 20) {
            ExtensionManager.shared.keepAlivePortOpenCountForTesting(
                controller: controller, extensionID: ext.id) >= 2
        }

        // The observation window: a context that reconnected after being evicted
        // would open a new port every ~100 ms here.
        try await Task.sleep(nanoseconds: 5_000_000_000)

        let tabState = try await tabKeepAlive()
        let backgroundBeat = try await backgroundKeepAlive()
        let backgroundState = try XCTUnwrap(backgroundBeat, "no heartbeat from the real background page")
        XCTAssertEqual(tabState["contextKind"] as? String, "background-page",
                       "precondition: the polyfill cannot tell this tab from the background page")

        let states = [tabState, backgroundState]
        let superseded = states.filter {
            $0["installDetail"] as? String == "superseded" && $0["installMode"] as? String == "none"
        }
        let holding = states.filter { $0["installMode"] as? String == "port" }
        XCTAssertEqual(superseded.count, 1, "exactly one context must stop as superseded: tab \(tabState), background \(backgroundState)")
        XCTAssertEqual(holding.count, 1, "the other context must hold the port: tab \(tabState), background \(backgroundState)")
        XCTAssertEqual(ExtensionManager.shared.keepAliveStateForTesting(
            controller: controller, extensionID: ext.id)?.portOpen, true, "Detour must still hold a port")

        let opens = ExtensionManager.shared.keepAlivePortOpenCountForTesting(
            controller: controller, extensionID: ext.id)
        XCTAssertLessThanOrEqual(opens, 2,
                                 "an evicted context must not reconnect and take the port back (\(opens) ports opened)")
    }

    // MARK: - TASK-29: runtime.onInstalled in extension pages and Private

    /// ExtensionManager wakes a worker for an owed onInstalled in a regular profile
    /// (the positive control) but never in a Private one, where nothing is owed.
    /// The worker script carries no polyfill, so nothing claims during the test.
    func testPrivateProfileWorkerIsNeverWokenForRuntimeOnInstalled() async throws {
        let ext = try await makeTestExtension(
            idPrefix: "oninstalled-wake",
            manifest: """
            {
                "manifest_version": 3,
                "name": "onInstalled Wake Test",
                "version": "1.0.0",
                "background": {"service_worker": "background.js"}
            }
            """,
            extraFiles: ["background.js": "// no polyfill: nothing claims\n"])
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let regular = makeProfile("onInstalled Wake Profile")
        _ = regular.extensionController
        _ = regular.loadExtensionContext(ext)
        XCTAssertNotNil(regular.extensionContexts[ext.id])
        XCTAssertEqual(ExtensionManager.shared.installedEventOwingWake(extensionID: ext.id, in: regular),
                       .init(reason: .install, previousVersion: nil))

        let privateProfile = Profile(name: "onInstalled Wake Private", isIncognito: true)
        defer { privateProfile.unloadAllExtensions() }
        _ = privateProfile.extensionController
        _ = privateProfile.loadExtensionContext(ext)
        XCTAssertNotNil(privateProfile.extensionContexts[ext.id], "precondition: the context loads in Private")
        XCTAssertNil(ExtensionManager.shared.installedEventOwingWake(extensionID: ext.id, in: privateProfile))
    }

    /// WebKit's own `runtime.onInstalled`, fired for real at an extension page, must
    /// not reach a listener the page added through `chrome.runtime.onInstalled`,
    /// while the worker still gets Detour's event exactly once.
    ///
    /// Making WebKit fire: it picks `install` for any load into a controller past
    /// its 5 s "freshly created" window (TASK-22), so a throwaway context is loaded
    /// first to start that window and the extension is loaded after it. The
    /// event goes out once the background content has loaded; the worker's top
    /// level busy-waits so the page is open and listening by then.
    ///
    /// The control is a second page listener registered through WebKit's native
    /// `addListener` (the class's prototype method, which the shadowing leaves in
    /// place): it receiving `install` is what shows WebKit really dispatched to
    /// this page, so the shadowed listener's silence means something.
    func testRealExtensionPageDoesNotSeeWebKitsRuntimeOnInstalled() async throws {
        let workerDelayMS = 2500
        let backgroundJS = ExtensionAPIPolyfill.polyfillJS + """

        const received = [];
        chrome.runtime.onInstalled.addListener((details) => received.push(details));
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message && message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
            if (!message || message.type !== 'installedLog') return false;
            const status = globalThis.__detourRuntimeOnInstalled;
            sendResponse({ received: received, mode: status.mode, detail: status.detail,
                           claimCount: status.claimCount, lastDispatched: status.lastDispatched });
            return true;
        });
        {
            const until = Date.now() + \(workerDelayMS);
            while (Date.now() < until) {}
        }
        """
        let throwaway = try await makeTestExtension(idPrefix: "oninstalled-window")
        let ext = try await makeTestExtension(
            idPrefix: "oninstalled-page",
            manifest: """
            {
                "manifest_version": 3,
                "name": "onInstalled Page Test",
                "version": "1.0.0",
                "background": {"service_worker": "background.js"}
            }
            """,
            extraFiles: ["background.js": backgroundJS])
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let profile = makeProfile("onInstalled Page Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(throwaway)
        try await Task.sleep(nanoseconds: 5_500_000_000)
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let webView = try await makeExtensionWebView(for: context)

        func evalObject(_ js: String) async throws -> [String: Any] {
            let raw = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
            let json = try XCTUnwrap(raw as? String, "expected a JSON string, got \(String(describing: raw))")
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }

        let setup = try await evalObject("""
            globalThis.__shadowedCalls = [];
            globalThis.__nativeCalls = [];
            const event = chrome.runtime.onInstalled;
            event.addListener((d) => globalThis.__shadowedCalls.push(d));
            let proto = Object.getPrototypeOf(event);
            while (proto && !Object.prototype.hasOwnProperty.call(proto, 'addListener')) proto = Object.getPrototypeOf(proto);
            const nativeAdd = proto ? proto.addListener : null;
            if (nativeAdd) nativeAdd.call(event, (d) => globalThis.__nativeCalls.push(d));
            const status = globalThis.__detourRuntimeOnInstalled;
            return JSON.stringify({
                mode: status.mode, detail: status.detail, holdsEvent: status.holdsEvent,
                ownShadow: Object.prototype.hasOwnProperty.call(event, 'addListener'),
                hasNativeAdd: typeof nativeAdd === 'function',
                listenerCount: status.listenerCount,
                claimCount: status.claimCount
            });
        """)
        XCTAssertEqual(setup["mode"] as? String, "suppressed", "page shadowing did not install: \(setup)")
        XCTAssertEqual(setup["holdsEvent"] as? Bool, true)
        XCTAssertEqual(setup["ownShadow"] as? Bool, true)
        XCTAssertEqual(setup["hasNativeAdd"] as? Bool, true, "WebKit's addListener should live on the prototype")
        XCTAssertEqual(setup["listenerCount"] as? Int, 1)
        XCTAssertEqual(setup["claimCount"] as? Int, 0, "a page must never claim Detour's event")

        try await waitUntil("the background worker to wake", timeout: 20) {
            let ping = try await askWorker(from: webView, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }

        // Churn the heap, then read the event afresh: the shadowing must still be
        // what `chrome.runtime.onInstalled` returns.
        var page: [String: Any] = [:]
        try await waitUntil("WebKit's install to reach the page's native control listener", timeout: 10) {
            page = try await evalObject("""
                for (let i = 0; i < 2000; i++) { new Array(1000).fill(i); }
                const event = chrome.runtime.onInstalled;
                return JSON.stringify({
                    shadowed: globalThis.__shadowedCalls, native: globalThis.__nativeCalls,
                    stillShadowed: event.addListener === Object.getOwnPropertyDescriptor(event, 'addListener')?.value
                        && event.hasListeners() === true && globalThis.__detourRuntimeOnInstalled.listenerCount === 1,
                    claimCount: globalThis.__detourRuntimeOnInstalled.claimCount
                });
            """)
            return !((page["native"] as? [Any]) ?? []).isEmpty
        }
        print("TASK-29 page measurement: setup=\(setup) page=\(page)")
        XCTAssertEqual(page["native"] as? [[String: String]], [["reason": "install"]],
                       "control: WebKit must really have fired install at this page")
        XCTAssertEqual(page["shadowed"] as? [[String: String]], [],
                       "WebKit's event must not reach a listener added through chrome.runtime.onInstalled")
        XCTAssertEqual(page["stillShadowed"] as? Bool, true)
        XCTAssertEqual(page["claimCount"] as? Int, 0)

        // NEGATIVE: the worker still gets Detour's event, once.
        let log = try await askWorker(from: webView, message: ["type": "installedLog"])
        let worker = try XCTUnwrap(log["reply"] as? [String: Any], "the worker must answer: \(log)")
        print("TASK-29 worker measurement: \(worker)")
        XCTAssertEqual(worker["mode"] as? String, "detour")
        XCTAssertEqual(worker["claimCount"] as? Int, 1)
        XCTAssertEqual(worker["lastDispatched"] as? [String: String], ["reason": "install"],
                       "the delivery must be Detour's claim")
        XCTAssertEqual(worker["received"] as? [[String: String]], [["reason": "install"]],
                       "the worker must get Detour's install exactly once, and not WebKit's as well")
    }

    // MARK: - TASK-43: runtime.onInstalled in a background page

    /// The shapes of background content a test extension can declare: the three
    /// WebKit runs as a page, plus the MV3 service worker. Each carries the path
    /// WebKit loads it at — measured against a real context by the probe these
    /// tests grew out of, and re-asserted here so a WebKit change that moves the
    /// generated page fails the suite rather than silently costing every such
    /// extension its event.
    private enum BackgroundPage {
        /// `background.scripts`: WebKit hosts them in a page it generates.
        case scripts
        /// `background.page`: the author's own page, at its manifest path.
        case page
        /// The same page declared './bg.html' — a spelling Chrome accepts, so
        /// the polyfill has to *resolve* the manifest path against the extension
        /// root rather than compare it with a leading slash bolted on (which
        /// would make '/./bg.html' and classify the real background page as an
        /// ordinary one, suppressing its event for good).
        case dotSlashPage
        /// `background.service_worker`: not a page at all. The polyfill has to
        /// travel in the worker's own script — the user script
        /// `Profile.extensionController` installs reaches web views, not workers.
        case serviceWorker

        var manifestEntry: String { manifestEntry(persistent: false) }

        /// The `background` entry, with `persistent` set to `persistent` or left
        /// out entirely when it is nil — which is how a *persistent* MV2
        /// background page is spelled (TASK-62). A service worker has no such
        /// flag, so it ignores `persistent`.
        func manifestEntry(persistent: Bool?) -> String {
            let flag = persistent.map { ", \"persistent\": \($0)" } ?? ""
            switch self {
            case .scripts: return #"{"scripts": ["background.js"]"# + flag + "}"
            case .page: return #"{"page": "bg.html""# + flag + "}"
            case .dotSlashPage: return #"{"page": "./bg.html""# + flag + "}"
            case .serviceWorker: return #"{"service_worker": "background.js", "type": "module"}"#
            }
        }

        /// Where the background context loads, relative to the context's base URL.
        var pathname: String {
            switch self {
            case .scripts: return "/_generated_background_page.html"
            case .page, .dotSlashPage: return "/bg.html"
            // No page: the worker's own script is where the context lives.
            case .serviceWorker: return "/background.js"
            }
        }

        /// Names the profile and extension a leg builds — two shapes load their
        /// background page at the same path, so the path cannot do it.
        var label: String {
            switch self {
            case .scripts: return "scripts"
            case .page: return "page"
            case .dotSlashPage: return "dot-slash-page"
            case .serviceWorker: return "service-worker"
            }
        }

        var ownFiles: [String: String] {
            switch self {
            case .scripts, .serviceWorker: return [:]
            case .page, .dotSlashPage:
                return ["bg.html": "<html><body><script src=\"background.js\"></script></body></html>"]
            }
        }
    }

    /// The background script both shapes run: it registers its `onInstalled`
    /// listener at top level (as Chrome requires) and answers a `report` message
    /// with everything the test needs to see — what it received, and what the
    /// polyfill made of the context it is in. It carries no polyfill of its own:
    /// a background page is a web view, so the polyfill user script
    /// `Profile.extensionController` installs is what must reach it.
    private static let backgroundPageReporterJS = """
    // A non-persistent background page can be torn down and started again
    // (a message to it starts one), so what it received is also written to the
    // origin's localStorage: `allReceived` is every dispatch this extension's
    // background context ever got in this profile, which is what "exactly once"
    // is about, and `loads` says how many instances there have been.
    const received = [];
    let loads = 0;
    try {
        loads = (Number(localStorage.getItem('__detourLoads')) || 0) + 1;
        localStorage.setItem('__detourLoads', String(loads));
    } catch (e) {}
    function allReceived() {
        try { return JSON.parse(localStorage.getItem('__detourReceived') || '[]'); } catch (e) { return []; }
    }
    chrome.runtime.onInstalled.addListener((details) => {
        received.push(details);
        try {
            const all = allReceived();
            all.push(details);
            localStorage.setItem('__detourReceived', JSON.stringify(all));
        } catch (e) {}
    });
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message || message.type !== 'report') return false;
        const status = globalThis.__detourRuntimeOnInstalled;
        sendResponse({
            href: location.href,
            pathname: location.pathname,
            isWorker: typeof ServiceWorkerGlobalScope !== 'undefined',
            hasPolyfill: typeof status === 'object',
            mode: status ? status.mode : 'none',
            contextKind: status ? status.contextKind : 'none',
            detail: status ? status.detail : 'none',
            // The content-script responder is background-context-only too, so a
            // background page must have installed it (TASK-43).
            contentBridge: globalThis.__detourContentBridge || 'none',
            claimCount: status ? status.claimCount : -1,
            listenerCount: status ? status.listenerCount : -1,
            loads: loads,
            received: received,
            allReceived: allReceived()
        });
        return true;
    });
    // A background page iframed by another extension page must not claim: it
    // reports its own view of itself to the embedder instead.
    if (typeof window !== 'undefined' && window.top !== window) {
        const framed = globalThis.__detourRuntimeOnInstalled;
        window.top.postMessage({ __detourFramedStatus: {
            pathname: location.pathname,
            mode: framed ? framed.mode : 'none',
            contextKind: framed ? framed.contextKind : 'none',
            claimCount: framed ? framed.claimCount : -1
        } }, '*');
    }
    """

    /// An MV3 extension whose background content is a page, registered the way
    /// an installed one is. `id` lets a test rebuild the same extension at a new
    /// version; only the newest build stays registered.
    ///
    /// `permissions`, `manifestVersion`, `persistent` and `backgroundJS` are the
    /// TASK-62 knobs: an extension that declares `nativeMessaging`, a persistent
    /// MV2 page (`manifestVersion: 2`, `persistent: nil` — the key left out, which
    /// is what makes an MV2 background persistent), and a background script other
    /// than the onInstalled reporter.
    private func makeBackgroundPageExtension(
        _ shape: BackgroundPage, id: String, version: String = "1.0.0",
        permissions: [String] = [],
        manifestVersion: Int = 3,
        persistent: Bool? = false,
        backgroundJS: String? = nil,
        extraFiles: [String: String] = [:]
    ) async throws -> WebExtension {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(id)-v\(version)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let permissionsJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: permissions), as: UTF8.self)
        try """
        {
            "manifest_version": \(manifestVersion),
            "name": "Background Page Test",
            "version": "\(version)",
            "permissions": \(permissionsJSON),
            "background": \(shape.manifestEntry(persistent: persistent))
        }
        """.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><body><div id=\"test\">wiring test page</div></body></html>"
            .write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)
        try (backgroundJS ?? Self.backgroundPageReporterJS)
            .write(to: dir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        for (name, contents) in shape.ownFiles.merging(extraFiles, uniquingKeysWith: { _, new in new }) {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.removeAll { $0.id == id }
        ExtensionManager.shared.extensions.append(ext)
        if !registeredExtensionIDs.contains(id) { registeredExtensionIDs.append(id) }
        return ext
    }

    /// What the background context reports, asked through an extension page of
    /// the same extension (the only way into it from a test), once the report
    /// satisfies `until` — the claim is a round trip to native, so a report can
    /// arrive with the claim counted and its dispatch still in flight.
    private func reportFromBackgroundContext(
        page webView: WKWebView, what: String,
        until: ([String: Any]) -> Bool = { _ in true }
    ) async throws -> [String: Any] {
        var report: [String: Any] = [:]
        try await waitUntil(what, timeout: 20) {
            let envelope = try await askWorker(from: webView, message: ["type": "report"], timeout: 5)
            guard let reply = envelope["reply"] as? [String: Any], until(reply) else { return false }
            report = reply
            return true
        }
        return report
    }

    /// The report has been dispatched `count` events — the predicate the install
    /// and update legs wait on.
    private static func dispatched(_ count: Int) -> ([String: Any]) -> Bool {
        { ($0["allReceived"] as? [Any])?.count == count }
    }

    /// What the polyfill made of an ordinary extension page, plus anything an
    /// iframe of that page reported to it.
    private func polyfillStatus(ofPage webView: WKWebView) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript("""
            const status = globalThis.__detourRuntimeOnInstalled;
            return JSON.stringify({
                pathname: location.pathname,
                hasPolyfill: typeof status === 'object',
                mode: status ? status.mode : 'none',
                contextKind: status ? status.contextKind : 'none',
                contentBridge: globalThis.__detourContentBridge || 'none',
                claimCount: status ? status.claimCount : -1,
                framed: globalThis.__detourFramedStatus || null
            });
        """, arguments: [:], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string, got \(String(describing: raw))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testMV3BackgroundScriptsPageGetsRuntimeOnInstalledOnce() async throws {
        try await assertBackgroundPageGetsTheInstallExactlyOnce(.scripts)
    }

    func testMV3BackgroundPageGetsRuntimeOnInstalledOnce() async throws {
        try await assertBackgroundPageGetsTheInstallExactlyOnce(.page)
    }

    /// The same `background.page`, declared './bg.html': a relative spelling
    /// Chrome accepts, which the polyfill must resolve against the extension root
    /// to recognise the page WebKit loads at /bg.html as the background context.
    func testBackgroundPageDeclaredWithARelativePathGetsRuntimeOnInstalledOnce() async throws {
        try await assertBackgroundPageGetsTheInstallExactlyOnce(.dotSlashPage)
    }

    /// AC #1 and AC #2 for an MV3 extension with no service worker: its
    /// background *page* is woken by the production path
    /// (`wakeForPendingInstalledEvent`, which before TASK-43 declined to wake
    /// anything without `background.service_worker`), the polyfill treats that
    /// page as the claiming context, and the event arrives there exactly once —
    /// while an ordinary extension page of the same extension stays `suppressed`
    /// and claims nothing.
    private func assertBackgroundPageGetsTheInstallExactlyOnce(_ shape: BackgroundPage) async throws {
        let id = "oninstalled-bgpage-\(shape.label)-\(UUID().uuidString.prefix(8))"
        let ext = try await makeBackgroundPageExtension(shape, id: id)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let wkExt = try XCTUnwrap(ext.wkExtension)
        XCTAssertTrue(wkExt.hasBackgroundContent,
                      "precondition: WebKit runs this manifest's background content")
        XCTAssertFalse(wkExt.hasPersistentBackgroundContent)
        XCTAssertNil(ext.manifest.background?.serviceWorker, "precondition: no service worker")
        XCTAssertEqual(ext.manifest.background?.hasBackgroundContent, true)

        let profile = makeProfile("onInstalled Background Page \(shape.label)")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])

        XCTAssertEqual(ExtensionManager.shared.installedEventOwingWake(extensionID: ext.id, in: profile),
                       .init(reason: .install, previousVersion: nil),
                       "a background page is owed the install like a worker is")
        // The production wake: it loads the background content, whose polyfill claims.
        ExtensionManager.shared.wakeForPendingInstalledEvent(extensionID: ext.id, in: profile)

        let webView = try await makeExtensionWebView(for: context)
        let report = try await reportFromBackgroundContext(
            page: webView, what: "the background page to be dispatched the install",
            until: Self.dispatched(1))
        print("TASK-43 background page measurement (\(shape.pathname)): \(report)")

        XCTAssertEqual(report["pathname"] as? String, shape.pathname,
                       "WebKit loads this shape's background context at \(shape.pathname)")
        XCTAssertEqual(report["href"] as? String,
                       context.baseURL.absoluteString + shape.pathname.dropFirst())
        XCTAssertEqual(report["isWorker"] as? Bool, false, "this is a page, not a worker")
        XCTAssertEqual(report["hasPolyfill"] as? Bool, true,
                       "the polyfill user script must reach a background page")
        XCTAssertEqual(report["mode"] as? String, "detour")
        XCTAssertEqual(report["contextKind"] as? String, "background-page")
        XCTAssertEqual(report["detail"] as? String, "")
        XCTAssertEqual(report["contentBridge"] as? String, "installed:background-page",
                       "content scripts' polyfill round trips need a responder in the background page")
        XCTAssertEqual(report["claimCount"] as? Int, 1, "the background page claims once")
        XCTAssertEqual(report["allReceived"] as? [[String: String]], [["reason": "install"]],
                       "the background page must get Detour's install exactly once")

        // Nothing is owed any more: every later background-page start claims and
        // is told nothing, so no second install is ever dispatched.
        XCTAssertNil(ExtensionManager.shared.installedEventOwingWake(extensionID: ext.id, in: profile),
                     "the claim advanced the ledger")
        let again = try await reportFromBackgroundContext(
            page: webView, what: "the background page to answer again")
        XCTAssertEqual(again["claimCount"] as? Int, 1)
        XCTAssertEqual(again["allReceived"] as? [[String: String]], [["reason": "install"]])

        // AC #2: an ordinary extension page of the same extension is suppressed.
        let pageStatus = try await polyfillStatus(ofPage: webView)
        print("TASK-43 ordinary page measurement: \(pageStatus)")
        XCTAssertEqual(pageStatus["pathname"] as? String, "/test.html")
        XCTAssertEqual(pageStatus["hasPolyfill"] as? Bool, true)
        XCTAssertEqual(pageStatus["mode"] as? String, "suppressed")
        XCTAssertEqual(pageStatus["contextKind"] as? String, "page")
        XCTAssertEqual(pageStatus["contentBridge"] as? String, "skipped:page",
                       "an ordinary extension page must not register a second content-script responder")
        XCTAssertEqual(pageStatus["claimCount"] as? Int, 0, "an ordinary page must never claim")
    }

    /// A version change is delivered to the background page as one `update`
    /// carrying the version the install was delivered for — the same ledger step
    /// a worker gets, now reaching a page.
    func testMV3BackgroundPageGetsTheUpdateAfterAVersionChange() async throws {
        let id = "oninstalled-bgpage-update-\(UUID().uuidString.prefix(8))"
        let first = try await makeBackgroundPageExtension(.scripts, id: id, version: "1.0.0")
        defer { AppDatabase.shared.deleteExtension(id: id) }

        let profile = makeProfile("onInstalled Background Page Update")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(first)
        let firstContext = try XCTUnwrap(profile.extensionContexts[id])
        ExtensionManager.shared.wakeForPendingInstalledEvent(extensionID: id, in: profile)
        let installReport = try await reportFromBackgroundContext(
            page: try await makeExtensionWebView(for: firstContext),
            what: "the 1.0.0 background page to be dispatched the install",
            until: Self.dispatched(1))
        XCTAssertEqual(installReport["allReceived"] as? [[String: String]], [["reason": "install"]])

        // The same extension, rebuilt at a new version and loaded again, the way
        // an update installs it over the old one.
        _ = profile.unloadExtension(id: id)
        let bumped = try await makeBackgroundPageExtension(.scripts, id: id, version: "1.1.0")
        XCTAssertEqual(ExtensionManager.shared.extension(withID: id)?.manifest.version, "1.1.0")
        _ = profile.loadExtensionContext(bumped)
        let secondContext = try XCTUnwrap(profile.extensionContexts[id])
        XCTAssertEqual(ExtensionManager.shared.installedEventOwingWake(extensionID: id, in: profile),
                       .init(reason: .update, previousVersion: "1.0.0"))
        ExtensionManager.shared.wakeForPendingInstalledEvent(extensionID: id, in: profile)

        let updateReport = try await reportFromBackgroundContext(
            page: try await makeExtensionWebView(for: secondContext),
            what: "the 1.1.0 background page to be dispatched the update",
            until: Self.dispatched(2))
        print("TASK-43 update measurement: \(updateReport)")
        XCTAssertEqual(updateReport["claimCount"] as? Int, 1)
        // The origin's localStorage outlives the reload, so this is the whole
        // history of what this profile's background context was dispatched: the
        // install for 1.0.0, then exactly one update carrying that version.
        XCTAssertEqual(updateReport["allReceived"] as? [[String: String]],
                       [["reason": "install"], ["reason": "update", "previousVersion": "1.0.0"]],
                       "the background page must get one update carrying the delivered version")
        XCTAssertNil(ExtensionManager.shared.installedEventOwingWake(extensionID: id, in: profile))
    }

    /// An extension page that iframes the background page's own path is not the
    /// background context: it stays `suppressed`, so it cannot consume the
    /// install the real background page is waiting for.
    func testAnIframeOfTheBackgroundPagePathDoesNotClaimTheInstalledEvent() async throws {
        let id = "oninstalled-bgpage-iframe-\(UUID().uuidString.prefix(8))"
        let ext = try await makeBackgroundPageExtension(
            .page, id: id,
            extraFiles: [
                // MV3's default CSP forbids inline scripts in an extension page,
                // so the embedder's listener has to be its own file.
                "embedder.js": """
                globalThis.__detourFramedStatus = null;
                window.addEventListener('message', (event) => {
                    if (event.data && event.data.__detourFramedStatus) {
                        globalThis.__detourFramedStatus = event.data.__detourFramedStatus;
                    }
                });
                """,
                "test.html": """
                <html><body><div id="test">embedder</div>
                <script src="embedder.js"></script>
                <iframe src="bg.html"></iframe>
                </body></html>
                """
            ])
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let profile = makeProfile("onInstalled Background Page Iframe")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        ExtensionManager.shared.wakeForPendingInstalledEvent(extensionID: ext.id, in: profile)

        let webView = try await makeExtensionWebView(for: context)
        var framed: [String: Any] = [:]
        try await waitUntil("the iframed background path to report itself") {
            let status = try await polyfillStatus(ofPage: webView)
            guard let reported = status["framed"] as? [String: Any] else { return false }
            framed = reported
            return true
        }
        print("TASK-43 iframed background path measurement: \(framed)")
        XCTAssertEqual(framed["pathname"] as? String, "/bg.html")
        XCTAssertEqual(framed["mode"] as? String, "suppressed",
                       "an iframe of the background path is not the background context")
        XCTAssertEqual(framed["contextKind"] as? String, "page")
        XCTAssertEqual(framed["claimCount"] as? Int, 0)

        // And the real background page still got the install.
        let report = try await reportFromBackgroundContext(
            page: webView, what: "the background page to be dispatched the install",
            until: Self.dispatched(1))
        XCTAssertEqual(report["contextKind"] as? String, "background-page")
        XCTAssertEqual(report["allReceived"] as? [[String: String]], [["reason": "install"]])
    }

    /// TASK-64: an ordinary extension page cannot take the install by calling
    /// the polyfill's own request bridge directly. The polyfill never claims
    /// from such a page, but nothing stops extension code from posting the
    /// request itself, so the *native* side refuses it: the page is told no and
    /// is handed no event, and the install goes to the real background context
    /// exactly once.
    ///
    /// The claim is fired with the install still pending — the background
    /// context is only woken afterwards. It cannot be asserted *at that moment*
    /// that the ledger is still pending, because loading any extension web view
    /// also starts the background page, whose own (legitimate) claim races this
    /// one; that a refused claim leaves the ledger alone is pinned
    /// deterministically by
    /// `ExtensionPolyfillTests.testClaimInstalledEventThroughTheNativeBridgeIsRefusedWithoutABackgroundContext`.
    /// What this test pins is the end state: the page got nothing, the
    /// background context got the one install.
    func testAnOrdinaryExtensionPageCannotClaimTheInstalledEventThroughTheBridge() async throws {
        let id = "oninstalled-page-claim-\(UUID().uuidString.prefix(8))"
        let ext = try await makeBackgroundPageExtension(.scripts, id: id)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let profile = makeProfile("onInstalled Page Claim")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])

        // The install is owed, and nothing has been woken to take it yet.
        XCTAssertEqual(ExtensionManager.shared.installedEventOwingWake(extensionID: ext.id, in: profile),
                       .init(reason: .install, previousVersion: nil),
                       "precondition: the install is owed")

        // An ordinary extension page of the same extension, asking directly.
        let webView = try await makeExtensionWebView(for: context)
        let raw = try await webView.callAsyncJavaScript("""
            return await globalThis.__detourPolyfillRequest('runtime.claimInstalledEvent', {})
                .then(r => ({ ok: true, reply: r }), e => ({ ok: false, error: String(e) }));
        """, arguments: [:], contentWorld: .page)
        let outcome = try XCTUnwrap(raw as? [String: Any],
                                    "expected a dictionary, got \(String(describing: raw))")
        XCTAssertEqual(outcome["ok"] as? Bool, false,
                       "an ordinary extension page's claim must be rejected, got \(outcome)")
        XCTAssertNil(outcome["reply"], "no event may be handed to an ordinary page: \(outcome)")

        // The install the page tried to take reaches the background context
        // (woken by the production path if its own start has not already done
        // so), exactly once.
        ExtensionManager.shared.wakeForPendingInstalledEvent(extensionID: ext.id, in: profile)
        let report = try await reportFromBackgroundContext(
            page: webView, what: "the background page to be dispatched the install",
            until: Self.dispatched(1))
        XCTAssertEqual(report["contextKind"] as? String, "background-page")
        XCTAssertEqual(report["claimCount"] as? Int, 1)
        XCTAssertEqual(report["allReceived"] as? [[String: String]], [["reason": "install"]])
        XCTAssertNil(ExtensionManager.shared.installedEventOwingWake(extensionID: ext.id, in: profile))
    }

    /// What the polyfill and the reporter make of a page, read in that page's own
    /// web view rather than through a `runtime.sendMessage` round trip — the only
    /// way to ask a *specific* context when two of them are at the same path.
    /// `allReceived` is the origin's localStorage, shared by every context of the
    /// extension in this profile.
    private func polyfillClaimState(of webView: WKWebView) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript("""
            const status = globalThis.__detourRuntimeOnInstalled;
            let allReceived = [];
            try { allReceived = JSON.parse(localStorage.getItem('__detourReceived') || '[]'); } catch (e) {}
            return JSON.stringify({
                pathname: location.pathname,
                hasPolyfill: typeof status === 'object',
                mode: status ? status.mode : 'none',
                contextKind: status ? status.contextKind : 'none',
                claimCount: status ? status.claimCount : -1,
                lastDispatched: status ? status.lastDispatched : 'none',
                allReceived: allReceived
            });
        """, arguments: [:], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string, got \(String(describing: raw))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// TASK-66, through the production tab path: an extension page *navigated to*
    /// the background document's own path — `chrome.tabs.create({url:
    /// chrome.runtime.getURL('_generated_background_page.html')})`, or a page
    /// setting `location.href` there — is at the path the gate checks, and its own
    /// polyfill classifies it as a background context, so before TASK-66 it could
    /// consume its extension's install and leave WebKit's real background page
    /// with nothing. The tab's web view is one Detour created
    /// (`ExtensionPageHostRegistry`), which is what the native gate now refuses on.
    ///
    /// The tab is opened *before* the wake, so the claim really does race the
    /// pending install. As in
    /// `testAnOrdinaryExtensionPageCannotClaimTheInstalledEventThroughTheBridge`,
    /// the ledger cannot be asserted still-pending at that moment — loading any
    /// extension web view also starts the background page, whose own legitimate
    /// claim may land first — so what is pinned is who ended up with the event:
    /// the tab was dispatched nothing at all, and the extension's background
    /// context recorded exactly one install.
    func testAnExtensionTabNavigatedToTheBackgroundPathCannotClaimTheInstalledEvent() async throws {
        let id = "oninstalled-tab-claim-\(UUID().uuidString.prefix(8))"
        let ext = try await makeBackgroundPageExtension(.scripts, id: id)
        defer { AppDatabase.shared.deleteExtension(id: ext.id) }

        let profile = makeProfile("onInstalled Tab Claim")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let configuration = try XCTUnwrap(context.webViewConfiguration,
                                          "webViewConfiguration is nil — context not loaded in a controller")

        XCTAssertEqual(ExtensionManager.shared.installedEventOwingWake(extensionID: ext.id, in: profile),
                       .init(reason: .install, previousVersion: nil),
                       "precondition: the install is owed and nothing has been woken to take it")

        // A real tab, opened at the background document's path the way an
        // extension can open one.
        let space = addSpace(for: profile, name: "onInstalled Tab Claim Space")
        let backgroundPagePath = ExtensionPolyfillHandler.generatedBackgroundPagePath
        let tab = TabStore.shared.addExtensionTab(
            in: space,
            url: context.baseURL.appendingPathComponent(String(backgroundPagePath.dropFirst())),
            configuration: configuration)
        let tabView = try XCTUnwrap(tab.webView)
        XCTAssertTrue(ExtensionPageHostRegistry.isDetourHosted(tabView),
                      "precondition: a tab's web view is one Detour hosts")
        try await waitUntil("the extension tab to load the background document path", timeout: 20) {
            guard tabView.isLoading == false, tabView.url?.path == backgroundPagePath else { return false }
            let ready = try? await tabView.callAsyncJavaScript(
                "return document.readyState === 'complete' && typeof globalThis.__detourPolyfillRequest === 'function';",
                arguments: [:], contentWorld: .page)
            return (ready as? Bool) == true
        }

        // The tab asking for the event directly, as extension code can.
        let raw = try await tabView.callAsyncJavaScript("""
            return await globalThis.__detourPolyfillRequest('runtime.claimInstalledEvent', {})
                .then(r => ({ ok: true, reply: r }), e => ({ ok: false, error: String(e) }));
        """, arguments: [:], contentWorld: .page)
        let outcome = try XCTUnwrap(raw as? [String: Any],
                                    "expected a dictionary, got \(String(describing: raw))")
        XCTAssertEqual(outcome["ok"] as? Bool, false,
                       "a tab at the background path must be refused the claim, got \(outcome)")
        XCTAssertNil(outcome["reply"], "no event may be handed to a tab: \(outcome)")

        // The install reaches the extension's background context, exactly once.
        // The report round trip can be answered by either context at this path,
        // so it pins the count; which of the two got it is pinned below by the
        // tab's own state.
        ExtensionManager.shared.wakeForPendingInstalledEvent(extensionID: ext.id, in: profile)
        let page = try await makeExtensionWebView(for: context)
        let report = try await reportFromBackgroundContext(
            page: page, what: "the background page to be dispatched the install",
            until: Self.dispatched(1))
        XCTAssertEqual(report["allReceived"] as? [[String: String]], [["reason": "install"]],
                       "the background context must get the install exactly once")
        XCTAssertNil(ExtensionManager.shared.installedEventOwingWake(extensionID: ext.id, in: profile))

        // The tab: its polyfill classified it as a background context and claimed
        // once on start (and once more above), and every one of those claims was
        // refused — it dispatched nothing, so the one recorded install belongs to
        // WebKit's own background page, the only other context running this
        // script.
        let tabState = try await polyfillClaimState(of: tabView)
        XCTAssertEqual(tabState["pathname"] as? String, backgroundPagePath)
        XCTAssertEqual(tabState["contextKind"] as? String, "background-page",
                       "precondition: the polyfill cannot tell this tab from the background page")
        XCTAssertGreaterThanOrEqual(tabState["claimCount"] as? Int ?? -1, 1,
                                    "precondition: the tab did try to claim")
        XCTAssertTrue(tabState["lastDispatched"] is NSNull,
                      "a tab at the background path must never be dispatched an install: \(tabState)")
        XCTAssertEqual(tabState["allReceived"] as? [[String: String]], [["reason": "install"]],
                       "exactly one install was recorded across the extension's contexts")
    }

    // MARK: - TASK-66: the registry of web views Detour hosts

    /// The registry is what tells an extension page Detour is showing from
    /// WebKit's own background view: every web view Detour creates or presents is
    /// in it, and a view the host never touched is not.
    func testExtensionPageHostRegistryHoldsTheViewsDetourCreatesOrPresents() async throws {
        let ext = try await makeTestExtension()
        let profile = makeProfile("Host Registry Profile")
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let configuration = try XCTUnwrap(context.webViewConfiguration)

        // A tab for an extension page: created by TabStore as a plain WKWebView
        // (not a BrowserWebView), so only the registry identifies it.
        let space = addSpace(for: profile, name: "Host Registry Space")
        let tab = TabStore.shared.addExtensionTab(
            in: space, url: context.baseURL.appendingPathComponent("test.html"),
            configuration: configuration)
        let tabView = try XCTUnwrap(tab.webView)
        XCTAssertFalse(tabView is BrowserWebView,
                       "precondition: an extension tab adopts a plain WKWebView, so a class check would miss it")
        XCTAssertTrue(ExtensionPageHostRegistry.isDetourHosted(tabView))

        // An ordinary tab's web view is hosted too.
        let ordinary = TabStore.shared.addTab(in: space)
        XCTAssertTrue(ExtensionPageHostRegistry.isDetourHosted(try XCTUnwrap(ordinary.webView)))

        // An offscreen document, built by the handler through the production path.
        let handler = try XCTUnwrap(profile.polyfillHandler)
        let created = expectation(description: "offscreen.createDocument reply")
        handler.handleNativeMessage(
            ["type": "offscreen.createDocument", "extensionID": ext.id,
             "params": ["url": "offscreen.html"]],
            verifiedExtensionID: ext.id
        ) { _, _ in created.fulfill() }
        await fulfillment(of: [created], timeout: 10)
        let offscreenView = try XCTUnwrap(handler.offscreenHosts[ext.id]?.webView,
                                          "the offscreen host should hold its web view")
        XCTAssertTrue(ExtensionPageHostRegistry.isDetourHosted(offscreenView))

        // A web view nobody registered — what WebKit's background page runs in.
        let unhosted = WKWebView(frame: .zero, configuration: configuration)
        XCTAssertFalse(ExtensionPageHostRegistry.isDetourHosted(unhosted))
    }
}
