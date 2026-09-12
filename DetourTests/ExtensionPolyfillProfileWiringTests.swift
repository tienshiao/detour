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
}
