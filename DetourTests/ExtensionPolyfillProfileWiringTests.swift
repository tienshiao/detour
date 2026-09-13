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

    override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
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
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
        }
        registeredExtensionIDs.removeAll()
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
        XCTAssertGreaterThanOrEqual(
            manager.keepAlivePingCountForTesting(controller: controller, extensionID: ext.id), 1,
            "arming must produce an immediate ping on the keep-alive port")

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
        XCTAssertGreaterThanOrEqual(
            manager.keepAlivePingCountForTesting(controller: controller, extensionID: ext.id), 1,
            "arming must produce an immediate ping on the keep-alive port")

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

    /// The shapes of background content WebKit runs as a page rather than a
    /// service worker, with the path WebKit loads each at — measured against a
    /// real context by the probe these tests grew out of, and re-asserted here so
    /// a WebKit change that moves the generated page fails the suite rather than
    /// silently costing every such extension its event.
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

        var manifestEntry: String {
            switch self {
            case .scripts: return #"{"scripts": ["background.js"], "persistent": false}"#
            case .page: return #"{"page": "bg.html", "persistent": false}"#
            case .dotSlashPage: return #"{"page": "./bg.html", "persistent": false}"#
            }
        }

        /// Where the background context loads, relative to the context's base URL.
        var pathname: String {
            switch self {
            case .scripts: return "/_generated_background_page.html"
            case .page, .dotSlashPage: return "/bg.html"
            }
        }

        /// Names the profile and extension a leg builds — two shapes load their
        /// background page at the same path, so the path cannot do it.
        var label: String {
            switch self {
            case .scripts: return "scripts"
            case .page: return "page"
            case .dotSlashPage: return "dot-slash-page"
            }
        }

        var ownFiles: [String: String] {
            switch self {
            case .scripts: return [:]
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
    private func makeBackgroundPageExtension(
        _ shape: BackgroundPage, id: String, version: String = "1.0.0",
        extraFiles: [String: String] = [:]
    ) async throws -> WebExtension {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(id)-v\(version)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        try """
        {
            "manifest_version": 3,
            "name": "Background Page Test",
            "version": "\(version)",
            "background": \(shape.manifestEntry)
        }
        """.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><body><div id=\"test\">wiring test page</div></body></html>"
            .write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)
        try Self.backgroundPageReporterJS
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
}
