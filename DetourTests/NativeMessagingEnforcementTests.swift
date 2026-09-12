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
@MainActor
final class NativeMessagingEnforcementTests: XCTestCase {

    private static let hostName = "com.detour.task25_enforcement_test"

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var webViews: [WKWebView] = []
    private var previousHostsDir: String?
    /// The fake host's `sleep` argument: unique per test so a stray process from
    /// another run (or another agent) can never be counted, or killed, by this one.
    private var sleepToken = ""

    override func setUp() async throws {
        try await super.setUp()
        previousHostsDir = getenv("DETOUR_NATIVE_MESSAGING_HOSTS_DIR").map { String(cString: $0) }
        sleepToken = String(Int.random(in: 300_000...899_999))
    }

    override func tearDown() {
        webViews.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            try? AppDatabase.shared.dbQueue.write { db in
                _ = try ExtensionPermissionRecord.filter(Column("extensionID") == id).deleteAll(db)
            }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        if let previousHostsDir {
            setenv("DETOUR_NATIVE_MESSAGING_HOSTS_DIR", previousHostsDir, 1)
        } else {
            unsetenv("DETOUR_NATIVE_MESSAGING_HOSTS_DIR")
        }
        // Belt and braces: nothing this test spawned may outlive it.
        _ = runTool("/usr/bin/pkill", ["-f", "sleep \(sleepToken)"])
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(label)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// Install the silent fake host for `extensionID` and point the host search at it.
    private func installFakeHost(allowing extensionID: String) throws {
        let dir = try makeTempDir("nm-hosts")
        let script = dir.appendingPathComponent("fake-host.sh")
        try "#!/bin/sh\nexec sleep \(sleepToken)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let manifest: [String: Any] = [
            "name": Self.hostName,
            "description": "TASK-25 fake host",
            "path": script.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: dir.appendingPathComponent("\(Self.hostName).json"))
        setenv("DETOUR_NATIVE_MESSAGING_HOSTS_DIR", dir.path, 1)
    }

    /// An MV3 extension declaring nativeMessaging, with one page to run calls from,
    /// registered in ExtensionManager and the DB the way an installed one is.
    private func makeExtension() async throws -> WebExtension {
        let id = "nm-enforce-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = try makeTempDir(id)
        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Native Messaging Enforcement Test",
            "version": "1.0.0",
            "permissions": ["nativeMessaging"]
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

    private struct Loaded {
        let profile: Profile
        let context: WKWebExtensionContext
        let webView: WKWebView
    }

    private func load(_ ext: WebExtension, profileName: String) async throws -> Loaded {
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

    private func saveNativeMessagingDecision(_ ext: WebExtension, _ status: ExtensionPermissionStatus) {
        AppDatabase.shared.savePermission(ExtensionPermissionRecord(
            extensionID: ext.id, key: "nativeMessaging", type: .apiPermission, status: status))
    }

    @discardableResult
    private func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Fake host processes currently alive for this test.
    private func fakeHostProcessCount() -> Int {
        let result = runTool("/usr/bin/pgrep", ["-f", "sleep \(sleepToken)"])
        return result.output.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    /// Evaluate `body` (an async function body returning a JSON-able value) in the page.
    private func evalJSON(_ body: String, in webView: WKWebView,
                          arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript(
            "return JSON.stringify(await (async () => { \(body) })());",
            arguments: arguments, contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// `runtime.sendNativeMessage` from the page, settled or timed out.
    private func sendNativeMessage(_ host: String, _ message: [String: Any], in webView: WKWebView,
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
    private func connectNative(_ host: String, as name: String, in webView: WKWebView) async throws {
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

    private func portState(_ name: String, in webView: WKWebView) async throws -> [String: Any] {
        try await evalJSON("""
            const record = (window.__ports || {})[name];
            return record ? { disconnected: record.disconnected, lastError: record.lastError, portError: record.portError } : { missing: true };
            """, in: webView, arguments: ["name": name])
    }

    // MARK: - Denied: real hosts blocked (negative)

    /// A saved denial refuses `sendNativeMessage` with Chrome's forbidden error and
    /// spawns nothing.
    func testDeniedNativeMessagingRejectsSendNativeMessageWithoutSpawning() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: ext.id)
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
    func testDeniedNativeMessagingRefusesConnectNativeWithoutSpawning() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: ext.id)
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
    func testAbsentDecisionAllowsConnectNativeAndDenialDisconnectsIt() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: ext.id)
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
    func testGrantedDecisionAllowsSendNativeMessageAndDenialRejectsThePendingReply() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: ext.id)
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
    func testRegrantingLiftsTheBlockWithoutReload() async throws {
        let ext = try await makeExtension()
        try installFakeHost(allowing: ext.id)
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
    func testDenialOnlyDisconnectsThatExtensionsHosts() async throws {
        let denied = try await makeExtension()
        let other = try await makeExtension()
        // One host manifest may list both origins.
        let dir = try makeTempDir("nm-hosts-shared")
        let script = dir.appendingPathComponent("fake-host.sh")
        try "#!/bin/sh\nexec sleep \(sleepToken)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try JSONSerialization.data(withJSONObject: [
            "name": Self.hostName, "path": script.path, "type": "stdio",
            "allowed_origins": ["chrome-extension://\(denied.id)/", "chrome-extension://\(other.id)/"],
        ] as [String: Any]).write(to: dir.appendingPathComponent("\(Self.hostName).json"))
        setenv("DETOUR_NATIVE_MESSAGING_HOSTS_DIR", dir.path, 1)

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

    // MARK: - Built-in hosts ignore the decision (positive)

    /// Detour's polyfill host still answers an envelope from an extension whose
    /// nativeMessaging is denied — it is the bridge, not the capability.
    func testDeniedNativeMessagingKeepsPolyfillHostWorking() async throws {
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
    func testDeniedNativeMessagingKeepsBuiltInPortsWorking() async throws {
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
}
