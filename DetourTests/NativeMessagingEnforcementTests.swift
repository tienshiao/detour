import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-25: the user's saved nativeMessaging decision is enforced where a real
/// native messaging host is dispatched, not on the context (which always keeps
/// `nativeMessaging` so Detour's own bridge hosts work).
///
/// These run the production path end to end — a real `Profile`, its controller
/// with `ExtensionManager` as delegate, an extension page calling WebKit's own
/// `runtime.connectNative` / `runtime.sendNativeMessage` — against a fake host
/// found through `DETOUR_NATIVE_MESSAGING_HOSTS_DIR` (Debug only). The fake host
/// is a shell script that `exec`s `sleep <unique seconds>`, so whether a process
/// was spawned is read off the process table by that unique argument, and every
/// such process is killed in tearDown.
///
/// The host lifecycle legs at the end (TASK-232, TASK-233) use the same
/// production path with hosts that answer and then exit or stay alive.
nonisolated final class NativeMessagingEnforcementTests: XCTestCase {

    private static let hostName = "com.detour.task25_enforcement_test"

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var webViews: [WKWebView] = []
    /// The shared fake-host fixture, if this test installed one (at most one per test).
    private var fakeHost: FakeNativeMessagingHost?

    @MainActor override func tearDown() async throws {
        webViews.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            try? await AppDatabase.shared.dbQueue.write { db in
                _ = try ExtensionPermissionRecord.filter(Column("extensionID") == id).deleteAll(db)
            }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        // Restores the env var, kills the host processes and removes its directory:
        // nothing this test spawned may outlive it.
        fakeHost?.tearDown()
        fakeHost = nil
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    @MainActor private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(label)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// Install the silent fake host for `extensionIDs` (one manifest may list several
    /// origins) and point the host search at it. Torn down in this suite's tearDown.
    @MainActor private func installFakeHost(allowing extensionIDs: [String],
                                            behavior: FakeNativeMessagingHost.Behavior = .silent) throws {
        let host = try FakeNativeMessagingHost(name: Self.hostName, allowing: extensionIDs, behavior: behavior)
        fakeHost = host
    }

    /// An MV3 extension declaring nativeMessaging, with one page to run calls from,
    /// registered in ExtensionManager and the DB the way an installed one is.
    /// `permissions` is a parameter so a test can make the manifest itself the
    /// thing under test — an extension that never declared nativeMessaging is
    /// the `.denied` half of the gate.
    @MainActor private func makeExtension(permissions: [String] = ["nativeMessaging"]) async throws -> WebExtension {
        let id = "nm-enforce-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = try makeTempDir(id)
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Native Messaging Enforcement Test",
            "version": "1.0.0",
            "permissions": [\(permissions.map { "\"\($0)\"" }.joined(separator: ", "))]
        }
        """
        try manifestJSON.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><body>native messaging test</body></html>"
            .write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        AppDatabase.shared.saveExtension(ExtensionRecord(
            id: id, name: manifest.name, version: manifest.version,
            manifestJSON: Data(manifestJSON.utf8), basePath: dir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970))
        return ext
    }

    @MainActor private struct Loaded {
        let profile: Profile
        let context: WKWebExtensionContext
        let webView: WKWebView
    }

    @MainActor private func load(_ ext: WebExtension, profileName: String) async throws -> Loaded {
        let profile = TabStore.shared.addProfile(name: profileName)
        createdProfiles.append(profile)
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id])
        let config = try XCTUnwrap(context.webViewConfiguration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webViews.append(webView)
        try await loadAndWait(webView, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        return Loaded(profile: profile, context: context, webView: webView)
    }

    @MainActor private func saveNativeMessagingDecision(_ ext: WebExtension, _ status: ExtensionPermissionStatus) {
        AppDatabase.shared.savePermission(ExtensionPermissionRecord(
            extensionID: ext.id, key: "nativeMessaging", type: .apiPermission, status: status))
    }

    /// Fake host processes currently alive for this test.
    @MainActor private func fakeHostProcessCount() -> Int { fakeHost?.processCount() ?? 0 }

    /// Evaluate `body` (an async function body returning a JSON-able value) in the page.
    @MainActor private func evalJSON(_ body: String, in webView: WKWebView,
                          arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript(
            "return JSON.stringify(await (async () => { \(body) })());",
            arguments: arguments, contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// `runtime.sendNativeMessage` from the page, settled or timed out.
    @MainActor private func sendNativeMessage(_ host: String, _ message: [String: Any], in webView: WKWebView,
                                   timeoutMS: Int = 3000) async throws -> [String: Any] {
        try await evalJSON("""
            return await new Promise((resolve) => {
                const timer = setTimeout(() => resolve({ outcome: 'pending' }), timeoutMS);
                chrome.runtime.sendNativeMessage(host, message).then(
                    (reply) => { clearTimeout(timer); resolve({ outcome: 'reply', reply: reply === undefined ? null : reply }); },
                    (error) => { clearTimeout(timer); resolve({ outcome: 'error', error: String(error && error.message ? error.message : error) }); });
            });
            """, in: webView, arguments: ["host": host, "message": message, "timeoutMS": timeoutMS])
    }

    /// Open a `runtime.connectNative` port from the page and record how it ends
    /// on `window.__ports[name]`.
    @MainActor private func connectNative(_ host: String, as name: String, in webView: WKWebView) async throws {
        _ = try await evalJSON("""
            window.__ports = window.__ports || {};
            const record = { disconnected: false, lastError: null, portError: null, port: null };
            window.__ports[name] = record;
            const port = chrome.runtime.connectNative(host);
            record.port = port;
            port.onDisconnect.addListener((p) => {
                record.disconnected = true;
                record.lastError = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
                const err = (p && p.error) || port.error;
                record.portError = err ? String(err.message || err) : null;
            });
            return { ok: true };
            """, in: webView, arguments: ["host": host, "name": name])
    }

    @MainActor private func portState(_ name: String, in webView: WKWebView) async throws -> [String: Any] {
        try await evalJSON("""
            const record = (window.__ports || {})[name];
            return record ? { disconnected: record.disconnected, lastError: record.lastError, portError: record.portError } : { missing: true };
            """, in: webView, arguments: ["name": name])
    }

    // MARK: - Denied: real hosts blocked (negative)

    /// A saved denial refuses `sendNativeMessage` with Chrome's forbidden error and
    /// spawns nothing.
    @MainActor func testDeniedNativeMessagingRejectsSendNativeMessageWithoutSpawning() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: [ext.id])
        saveNativeMessagingDecision(ext, .denied)
        let loaded = try await load(ext, profileName: "NM Denied Send Profile")

        let result = try await sendNativeMessage(Self.hostName, ["ping": 1], in: loaded.webView)

        XCTAssertEqual(result["outcome"] as? String, "error", "\(result)")
        XCTAssertTrue((result["error"] as? String ?? "").contains(ExtensionManager.nativeHostForbiddenMessage),
                      "expected the forbidden error, got: \(result)")
        XCTAssertEqual(fakeHostProcessCount(), 0, "a denied host must not be spawned")
        XCTAssertEqual(ExtensionManager.shared.pendingOneShotNativeMessageCountForTesting(extensionID: ext.id), 0)
    }

    /// A saved denial refuses `connectNative`: the port disconnects with the
    /// forbidden error and no process is spawned or registered.
    @MainActor func testDeniedNativeMessagingRefusesConnectNativeWithoutSpawning() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: [ext.id])
        saveNativeMessagingDecision(ext, .denied)
        let loaded = try await load(ext, profileName: "NM Denied Connect Profile")

        try await connectNative(Self.hostName, as: "real", in: loaded.webView)

        var state: [String: Any] = [:]
        try await waitUntil("the refused port to disconnect") {
            state = try await self.portState("real", in: loaded.webView)
            return state["disconnected"] as? Bool == true
        }
        // WebKit reports a refused connect on the port itself (`port.error`,
        // "Invalid call to runtime.connectNative(). <our message>"), not in
        // runtime.lastError — the same shape as every other refused connect.
        XCTAssertTrue((state["portError"] as? String ?? "").contains(ExtensionManager.nativeHostForbiddenMessage),
                      "expected the forbidden error on the port, got: \(state)")
        XCTAssertEqual(fakeHostProcessCount(), 0, "a denied host must not be spawned")
        XCTAssertEqual(ExtensionManager.shared.liveNativeHostCountForTesting(
            controller: loaded.profile.extensionController, extensionID: ext.id), 0)
    }

    // MARK: - Granted / absent: real hosts allowed (positive)

    /// No saved row: the declared permission is in force and the host is spawned.
    /// Denying from Settings then tears the live connection down at once: the
    /// process is killed, the port disconnects with the forbidden error, and a
    /// reconnect is refused — all on the same loaded context.
    @MainActor func testAbsentDecisionAllowsConnectNativeAndDenialDisconnectsIt() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: [ext.id])
        let loaded = try await load(ext, profileName: "NM Absent Connect Profile")
        let controller = loaded.profile.extensionController

        try await connectNative(Self.hostName, as: "real", in: loaded.webView)
        try await waitUntil("the fake host to be spawned and registered") {
            ExtensionManager.shared.liveNativeHostCountForTesting(controller: controller, extensionID: ext.id) == 1
                && self.fakeHostProcessCount() == 1
        }

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "nativeMessaging", type: .apiPermission, granted: false)

        XCTAssertEqual(ExtensionManager.shared.liveNativeHostCountForTesting(controller: controller, extensionID: ext.id), 0)
        try await waitUntil("the fake host process to exit") { self.fakeHostProcessCount() == 0 }
        var state: [String: Any] = [:]
        try await waitUntil("the extension's port to see the disconnect") {
            state = try await self.portState("real", in: loaded.webView)
            return state["disconnected"] as? Bool == true
        }
        // The extension sees a plain disconnect: WebKit does not surface the error
        // passed to `MessagePort.disconnect(throwing:)` for an established port
        // (neither lastError nor port.error), just as Chrome reports only that the
        // host went away.
        XCTAssertTrue(loaded.profile.extensionContexts[ext.id] === loaded.context, "no reload happened")

        try await connectNative(Self.hostName, as: "again", in: loaded.webView)
        var again: [String: Any] = [:]
        try await waitUntil("the reconnect to be refused") {
            again = try await self.portState("again", in: loaded.webView)
            return again["disconnected"] as? Bool == true
        }
        XCTAssertTrue((again["portError"] as? String ?? "").contains(ExtensionManager.nativeHostForbiddenMessage),
                      "expected the forbidden error on the refused reconnect, got: \(again)")
        XCTAssertEqual(fakeHostProcessCount(), 0, "the denial must hold for new connections")
    }

    /// A saved grant spawns the one-shot host; a denial arriving while it waits
    /// for a reply kills it and rejects the pending promise instead of leaving it
    /// hanging.
    @MainActor func testGrantedDecisionAllowsSendNativeMessageAndDenialRejectsThePendingReply() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: [ext.id])
        saveNativeMessagingDecision(ext, .granted)
        let loaded = try await load(ext, profileName: "NM Granted Send Profile")

        _ = try await loaded.webView.callAsyncJavaScript("""
            window.__oneShot = { outcome: 'pending' };
            chrome.runtime.sendNativeMessage(host, { ping: 1 }).then(
                (reply) => { window.__oneShot = { outcome: 'reply' }; },
                (error) => { window.__oneShot = { outcome: 'error', error: String(error && error.message ? error.message : error) }; });
            return true;
            """, arguments: ["host": Self.hostName], contentWorld: .page)
        try await waitUntil("the one-shot host to be spawned") {
            ExtensionManager.shared.pendingOneShotNativeMessageCountForTesting(extensionID: ext.id) == 1
                && self.fakeHostProcessCount() == 1
        }

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "nativeMessaging", type: .apiPermission, granted: false)

        XCTAssertEqual(ExtensionManager.shared.pendingOneShotNativeMessageCountForTesting(extensionID: ext.id), 0)
        try await waitUntil("the fake host process to exit") { self.fakeHostProcessCount() == 0 }
        var outcome: [String: Any] = [:]
        try await waitUntil("the pending sendNativeMessage to settle") {
            outcome = try await self.evalJSON("return window.__oneShot;", in: loaded.webView)
            return outcome["outcome"] as? String != "pending"
        }
        XCTAssertEqual(outcome["outcome"] as? String, "error", "\(outcome)")
        XCTAssertTrue((outcome["error"] as? String ?? "").contains(ExtensionManager.nativeHostForbiddenMessage),
                      "expected the forbidden error, got: \(outcome)")
    }

    /// Re-granting from Settings lifts the block on the same loaded context.
    @MainActor func testRegrantingLiftsTheBlockWithoutReload() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: [ext.id])
        saveNativeMessagingDecision(ext, .denied)
        let loaded = try await load(ext, profileName: "NM Regrant Profile")
        let controller = loaded.profile.extensionController

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "nativeMessaging", type: .apiPermission, granted: true)

        try await connectNative(Self.hostName, as: "real", in: loaded.webView)
        try await waitUntil("the fake host to be spawned after the re-grant") {
            ExtensionManager.shared.liveNativeHostCountForTesting(controller: controller, extensionID: ext.id) == 1
                && self.fakeHostProcessCount() == 1
        }
        XCTAssertTrue(loaded.profile.extensionContexts[ext.id] === loaded.context, "no reload happened")
    }

    /// Denying one extension leaves another extension's live host alone.
    @MainActor func testDenialOnlyDisconnectsThatExtensionsHosts() async throws {
        let denied = try await makeExtension()
        let other = try await makeExtension()
        // One host manifest may list both origins.
        try installFakeHost(allowing: [denied.id, other.id])

        let loadedDenied = try await load(denied, profileName: "NM Scope Denied Profile")
        let loadedOther = try await load(other, profileName: "NM Scope Other Profile")
        try await connectNative(Self.hostName, as: "real", in: loadedDenied.webView)
        try await connectNative(Self.hostName, as: "real", in: loadedOther.webView)
        try await waitUntil("both fake hosts to be spawned") { self.fakeHostProcessCount() == 2 }

        ExtensionManager.shared.setPermissionDecision(
            extensionID: denied.id, key: "nativeMessaging", type: .apiPermission, granted: false)

        try await waitUntil("only the denied extension's host to exit") { self.fakeHostProcessCount() == 1 }
        XCTAssertEqual(ExtensionManager.shared.liveNativeHostCountForTesting(
            controller: loadedOther.profile.extensionController, extensionID: other.id), 1)
        let otherState = try await portState("real", in: loadedOther.webView)
        XCTAssertEqual(otherState["disconnected"] as? Bool, false, "\(otherState)")
    }

    // MARK: - The context must be one its profile lists (TASK-90)

    /// Both halves of the connect gate on one page: a context the profile lists
    /// gets its port accepted and a live host registered, and the same page —
    /// once its context is no longer listed — is refused and spawns nothing.
    ///
    /// Until TASK-90 the second half was accepted in silence (`completionHandler(nil)`):
    /// a port with no handlers, no host process and no log line, which is the
    /// state the production reconnect-loop investigation had to rule out by hand.
    @MainActor func testConnectNativeIsAcceptedForAListedContextAndRefusedOnceItIsNot() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: [ext.id])
        let loaded = try await load(ext, profileName: "NM Listed Context Profile")
        let controller = loaded.profile.extensionController

        try await connectNative(Self.hostName, as: "listed", in: loaded.webView)
        try await waitUntil("the listed context's host to be spawned and registered") {
            ExtensionManager.shared.liveNativeHostCountForTesting(controller: controller, extensionID: ext.id) == 1
                && self.fakeHostProcessCount() == 1
        }
        let accepted = try await portState("listed", in: loaded.webView)
        XCTAssertEqual(accepted["disconnected"] as? Bool, false, "an accepted port stays open: \(accepted)")

        // The context stays loaded in the controller — the page keeps running and
        // WebKit still routes its connects — but the profile no longer lists it,
        // which is all `extensionIDFromContext` consults. Put back before
        // teardown, which unloads through the profile.
        let context = try XCTUnwrap(loaded.profile.extensionContexts.removeValue(forKey: ext.id))
        defer { loaded.profile.extensionContexts[ext.id] = context }

        try await connectNative(Self.hostName, as: "unlisted", in: loaded.webView)
        var state: [String: Any] = [:]
        try await waitUntil("the unattributable port to be refused") {
            state = try await self.portState("unlisted", in: loaded.webView)
            return state["disconnected"] as? Bool == true
        }
        XCTAssertTrue((state["portError"] as? String ?? "").contains("Unrecognized extension context"),
                      "expected the refusal on the port, got: \(state)")
        XCTAssertEqual(fakeHostProcessCount(), 1, "the refused connect must not spawn a host of its own")
        XCTAssertEqual(ExtensionManager.shared.liveNativeHostCountForTesting(
            controller: controller, extensionID: ext.id), 1, "and must not register anything")
    }

    /// The other half of the gate's refusal: an extension that never declared
    /// nativeMessaging is refused by the manifest check, with the reason that
    /// names the manifest rather than the context.
    @MainActor func testConnectNativeWithoutTheDeclaredPermissionIsRefusedWithoutSpawning() async throws {
        let ext = try await makeExtension(permissions: [])
        try installFakeHost(allowing: [ext.id])
        let loaded = try await load(ext, profileName: "NM Undeclared Profile")

        try await connectNative(Self.hostName, as: "undeclared", in: loaded.webView)

        var state: [String: Any] = [:]
        try await waitUntil("the undeclared connect to be refused") {
            state = try await self.portState("undeclared", in: loaded.webView)
            return state["disconnected"] as? Bool == true
        }
        // WebKit wraps the refusal ("Invalid call to runtime.connectNative(). …")
        // and capitalises what it wraps, so the reason is matched case-insensitively.
        XCTAssertTrue((state["portError"] as? String ?? "")
                        .localizedCaseInsensitiveContains("nativeMessaging permission not declared"),
                      "expected the manifest refusal on the port, got: \(state)")
        XCTAssertEqual(fakeHostProcessCount(), 0, "an undeclared host must not be spawned")
        XCTAssertEqual(ExtensionManager.shared.liveNativeHostCountForTesting(
            controller: loaded.profile.extensionController, extensionID: ext.id), 0)
    }

    // MARK: - Built-in hosts ignore the decision (positive)

    /// Detour's polyfill host still answers an envelope from an extension whose
    /// nativeMessaging is denied — it is the bridge, not the capability.
    @MainActor func testDeniedNativeMessagingKeepsPolyfillHostWorking() async throws {
        let ext = try await makeExtension()
        saveNativeMessagingDecision(ext, .denied)
        let loaded = try await load(ext, profileName: "NM Denied Polyfill Profile")

        let result = try await sendNativeMessage(
            ExtensionPolyfillHandler.handlerName,
            ["type": "idle.queryState", "extensionID": ext.id, "params": ["detectionIntervalInSeconds": 60]],
            in: loaded.webView)

        XCTAssertEqual(result["outcome"] as? String, "reply", "the polyfill host must still answer: \(result)")
        XCTAssertNotNil(result["reply"] as? String, "\(result)")
        XCTAssertTrue(loaded.context.hasPermission(.nativeMessaging))
    }

    /// The keep-alive port and the WebSocket relay port are still accepted.
    @MainActor func testDeniedNativeMessagingKeepsBuiltInPortsWorking() async throws {
        let ext = try await makeExtension()
        saveNativeMessagingDecision(ext, .denied)
        let loaded = try await load(ext, profileName: "NM Denied Ports Profile")
        let controller = loaded.profile.extensionController

        try await connectNative(ExtensionPolyfillHandler.handlerName, as: "keepalive", in: loaded.webView)
        try await connectNative(WebSocketRelaySession.hostName, as: "relay", in: loaded.webView)

        try await waitUntil("the keep-alive port to be accepted") {
            ExtensionManager.shared.keepAliveStateForTesting(controller: controller, extensionID: ext.id)?.portOpen == true
        }
        try await waitUntil("the relay port to be accepted") {
            ExtensionManager.shared.webSocketRelayCountForTesting(controller: controller, extensionID: ext.id) == 1
        }
        let keepAlive = try await portState("keepalive", in: loaded.webView)
        XCTAssertEqual(keepAlive["disconnected"] as? Bool, false, "\(keepAlive)")

        // Denying again from Settings tears down real hosts only.
        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "nativeMessaging", type: .apiPermission, granted: false)
        XCTAssertEqual(ExtensionManager.shared.keepAliveStateForTesting(controller: controller, extensionID: ext.id)?.portOpen, true)
        XCTAssertEqual(ExtensionManager.shared.webSocketRelayCountForTesting(controller: controller, extensionID: ext.id), 1)
    }

    // MARK: - A saved denial survives reinstall and update (TASK-63)

    /// The whole install path: a denial made in Settings after the extension is
    /// installed must outlive both a reinstall of the same version and an update
    /// that re-declares the permission, while a permission the update newly
    /// declares is still recorded as granted.
    @MainActor func testSavedDenialSurvivesReinstallAndUpdate() async throws {
        let source = try makeTempDir("task63-source")
        // A manifest key pins the id, so every install is the same extension.
        let key = Data("detour-task63-\(UUID().uuidString)".utf8).base64EncodedString()
        func writeManifest(version: String, permissions: [String]) throws {
            let list = permissions.map { "\"\($0)\"" }.joined(separator: ", ")
            try """
            {
                "manifest_version": 3,
                "name": "Declared Permission Test",
                "version": "\(version)",
                "key": "\(key)",
                "permissions": [\(list)],
                "host_permissions": ["https://example.com/*"]
            }
            """.write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }
        try writeManifest(version: "1.0.0", permissions: ["nativeMessaging", "storage"])

        let db = AppDatabase.shared
        let first = try ExtensionManager.shared.install(from: source)
        registeredExtensionIDs.append(first.id)
        defer { ExtensionManager.shared.uninstall(id: first.id) }
        // install finishes loading on a later main-actor turn; let it, so the
        // installs' loads never interleave with each other or with the uninstall.
        try await waitUntil("the first install to load") { first.wkExtension != nil }

        let hostPattern = "https://example.com/*"
        XCTAssertEqual(db.permissionStatus(extensionID: first.id, key: "nativeMessaging", type: .apiPermission), .granted)
        XCTAssertEqual(db.permissionStatus(extensionID: first.id, key: "storage", type: .apiPermission), .granted)
        XCTAssertEqual(db.permissionStatus(extensionID: first.id, key: hostPattern, type: .matchPattern), .granted)

        // The user turns both off in Settings.
        ExtensionManager.shared.setPermissionDecision(
            extensionID: first.id, key: "nativeMessaging", type: .apiPermission, granted: false)
        ExtensionManager.shared.setPermissionDecision(
            extensionID: first.id, key: hostPattern, type: .matchPattern, granted: false)

        // Reinstalling the same version re-declares everything; the decisions stand.
        let second = try ExtensionManager.shared.install(from: source)
        XCTAssertEqual(second.id, first.id)
        try await waitUntil("the reinstall to load") { second.wkExtension != nil }

        XCTAssertEqual(db.permissionStatus(extensionID: first.id, key: "nativeMessaging", type: .apiPermission),
                       .denied, "a reinstall must not resurrect the nativeMessaging denial")
        XCTAssertEqual(db.permissionStatus(extensionID: first.id, key: hostPattern, type: .matchPattern),
                       .denied, "nor a host-pattern denial")
        XCTAssertEqual(db.permissionStatus(extensionID: first.id, key: "storage", type: .apiPermission),
                       .granted, "an untouched permission is still granted")
        XCTAssertEqual(ExtensionManager.nativeHostAccess(
            hostName: "com.example.host",
            manifestPermissions: second.manifest.permissions ?? [],
            savedDecision: db.permissionStatus(extensionID: first.id, key: "nativeMessaging", type: .apiPermission)),
            .deniedByUser, "the enforcement point still reads the denial after the reinstall")

        // An update that declares a new permission: the new key is granted, the
        // re-declared denials still stand.
        try writeManifest(version: "1.1.0", permissions: ["nativeMessaging", "storage", "alarms"])
        let third = try ExtensionManager.shared.install(from: source)
        XCTAssertEqual(third.id, first.id)
        try await waitUntil("the update to load") { third.wkExtension != nil }

        XCTAssertEqual(third.manifest.version, "1.1.0")
        XCTAssertEqual(db.permissionStatus(extensionID: first.id, key: "alarms", type: .apiPermission),
                       .granted, "a newly declared permission has no saved decision, so it is granted")
        XCTAssertEqual(db.permissionStatus(extensionID: first.id, key: "nativeMessaging", type: .apiPermission),
                       .denied, "an update must not resurrect the denial either")
        XCTAssertEqual(db.permissionStatus(extensionID: first.id, key: hostPattern, type: .matchPattern), .denied)
    }

    // MARK: - A reply written before the host exits arrives first (TASK-232)

    /// A one-shot host that writes a large reply and exits at once: the
    /// promise resolves with the reply, never with "Native host has exited."
    /// Before the fix the exit could be handled while the read loop was still
    /// parsing the reply.
    @MainActor func testSendNativeMessageResolvesWithAReplyTheHostWroteBeforeExiting() async throws {
        let ext = try await makeExtension()
        let reply = try JSONSerialization.data(withJSONObject: ["pong": 1, "blob": String(repeating: "x", count: 256 * 1024)])
        try installFakeHost(allowing: [ext.id], behavior: .answersThenExits(NativeMessagingHost.encodeMessage(reply), status: 0))
        let loaded = try await load(ext, profileName: "NM Reply Then Exit Profile")

        for iteration in 1...15 {
            let result = try await evalJSON("""
                const reply = await chrome.runtime.sendNativeMessage(host, { ping: iteration })
                    .catch((error) => ({ error: String(error && error.message ? error.message : error) }));
                return { pong: reply.pong ?? null, error: reply.error ?? null };
                """, in: loaded.webView, arguments: ["host": Self.hostName, "iteration": iteration])
            XCTAssertEqual(result["pong"] as? Int, 1, "iteration \(iteration): \(result)")
        }
        XCTAssertEqual(ExtensionManager.shared.pendingOneShotNativeMessageCountForTesting(extensionID: ext.id), 0)
    }

    /// The same host on a `connectNative` port: the page gets the reply, then
    /// the disconnect.
    @MainActor func testAConnectNativePortGetsAReplyTheHostWroteBeforeExitingBeforeTheDisconnect() async throws {
        let ext = try await makeExtension()
        let reply = try JSONSerialization.data(withJSONObject: ["pong": 1, "blob": String(repeating: "x", count: 256 * 1024)])
        try installFakeHost(allowing: [ext.id], behavior: .answersThenExits(NativeMessagingHost.encodeMessage(reply), status: 0))
        let loaded = try await load(ext, profileName: "NM Port Reply Then Exit Profile")
        let controller = loaded.profile.extensionController

        for iteration in 1...8 {
            let result = try await evalJSON("""
                return await new Promise((resolve) => {
                    const events = [];
                    const timer = setTimeout(() => resolve({ events, timedOut: true }), 5000);
                    const port = chrome.runtime.connectNative(host);
                    port.onMessage.addListener((message) => events.push('message:' + message.pong));
                    port.onDisconnect.addListener(() => {
                        events.push('disconnect');
                        // Anything still on its way after the disconnect would land in this window.
                        setTimeout(() => { clearTimeout(timer); resolve({ events }); }, 200);
                    });
                    port.postMessage({ ping: 1 });
                });
                """, in: loaded.webView, arguments: ["host": Self.hostName])
            XCTAssertEqual(result["events"] as? [String], ["message:1", "disconnect"], "iteration \(iteration): \(result)")
        }
        try await waitUntil("the exited hosts to be released") {
            ExtensionManager.shared.liveNativeHostCountForTesting(controller: controller, extensionID: ext.id) == 0
        }
    }

    // MARK: - A one-shot host that stays alive ends with its request (TASK-233)

    /// A one-shot host that answers and then stays alive and silent: once the
    /// reply settles the promise, the request lets go of the host and its
    /// process is terminated. Before TASK-233 the read loop, blocked on the
    /// silent pipe, kept the host object alive, so nothing ended the process.
    @MainActor func testAOneShotHostThatStaysAliveIsTerminatedOnceItHasAnswered() async throws {
        let ext = try await makeExtension()
        let reply = try JSONSerialization.data(withJSONObject: ["pong": 1])
        try installFakeHost(allowing: [ext.id], behavior: .answersThenStaysAlive(NativeMessagingHost.encodeMessage(reply)))
        let loaded = try await load(ext, profileName: "NM Answer Then Stay Profile")

        let result = try await sendNativeMessage(Self.hostName, ["ping": 1], in: loaded.webView)
        XCTAssertEqual(result["outcome"] as? String, "reply", "\(result)")
        XCTAssertEqual((result["reply"] as? [String: Any])?["pong"] as? Int, 1, "\(result)")
        XCTAssertEqual(ExtensionManager.shared.pendingOneShotNativeMessageCountForTesting(extensionID: ext.id), 0)
        try await waitUntil("the answered host's process to be terminated", timeout: 5) {
            self.fakeHostProcessCount() == 0
        }
    }

    /// The same host on a `connectNative` port is not let go: the port owns
    /// it, so after the reply the process keeps running and the port stays
    /// open (the keep-alive depends on it). The page's `disconnect()` ends it.
    @MainActor func testAConnectNativePortKeepsAHostThatStaysAliveUntilThePageDisconnects() async throws {
        let ext = try await makeExtension()
        let reply = try JSONSerialization.data(withJSONObject: ["pong": 1])
        try installFakeHost(allowing: [ext.id], behavior: .answersThenStaysAlive(NativeMessagingHost.encodeMessage(reply)))
        let loaded = try await load(ext, profileName: "NM Port Answer Then Stay Profile")
        let controller = loaded.profile.extensionController

        let result = try await evalJSON("""
            return await new Promise((resolve) => {
                const timer = setTimeout(() => resolve({ timedOut: true }), 5000);
                const port = chrome.runtime.connectNative(host);
                window.__stayPort = { port, disconnected: false };
                port.onDisconnect.addListener(() => { window.__stayPort.disconnected = true; });
                port.onMessage.addListener((message) => { clearTimeout(timer); resolve({ pong: message.pong }); });
                port.postMessage({ ping: 1 });
            });
            """, in: loaded.webView, arguments: ["host": Self.hostName])
        XCTAssertEqual(result["pong"] as? Int, 1, "\(result)")

        // Long enough for a host the port did not own to have been released
        // and terminated (the one-shot leg above takes well under this).
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(fakeHostProcessCount(), 1, "the port's host must keep running while the port is open")
        XCTAssertEqual(ExtensionManager.shared.liveNativeHostCountForTesting(controller: controller, extensionID: ext.id), 1)
        let open = try await evalJSON("return { disconnected: window.__stayPort.disconnected };",
                                      in: loaded.webView, arguments: [:])
        XCTAssertEqual(open["disconnected"] as? Bool, false)

        _ = try await evalJSON("window.__stayPort.port.disconnect(); return { ok: true };",
                               in: loaded.webView, arguments: [:])
        try await waitUntil("the disconnected port's host process to be terminated", timeout: 5) {
            self.fakeHostProcessCount() == 0
        }
        XCTAssertEqual(ExtensionManager.shared.liveNativeHostCountForTesting(controller: controller, extensionID: ext.id), 0)
    }
}
