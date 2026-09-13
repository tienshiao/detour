import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-27: a profile created mid-session gets its enabled extensions loaded
/// straight away — through `TabStore.shared.addProfile`, the observer
/// `ExtensionManager.initialize` registers, and `loadExtensionsIntoProfile` —
/// instead of only after a relaunch. It follows TASK-26's per-profile rule and
/// gets TASK-22's `runtime.onInstalled` delivery.
///
/// The whole suite runs with `loadsExtensionsIntoAddedProfiles` off
/// (`TestEnvironmentSetup`), so other tests' `addProfile` calls load nothing;
/// these tests turn it on for their own duration.
@MainActor
final class NewProfileExtensionLoadTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var probes: [(probe: (window: ProbeExtensionWindow, tab: ProbeExtensionTab), context: WKWebExtensionContext)] = []

    override func setUp() async throws {
        try await super.setUp()
        // Launch's loadInstalledExtensions runs in the test host too; until it has
        // reached its per-profile loop a new profile is left to that loop.
        try await waitUntil("the host app's installed extensions to load") {
            ExtensionManager.shared.hasLoadedInstalledExtensions
        }
        ExtensionManager.shared.loadsExtensionsIntoAddedProfiles = true
    }

    override func tearDown() async throws {
        ExtensionManager.shared.loadsExtensionsIntoAddedProfiles = false
        for entry in probes.reversed() {
            unregisterProbeTab(entry.probe, in: entry.context)
        }
        probes.removeAll()
        for id in registeredExtensionIDs {
            // A global enable reaches every profile in the store, including the
            // host app's own.
            for profile in TabStore.shared.profiles {
                profile.unloadExtension(id: id)
            }
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            Self.deleteRows(forExtension: id)
        }
        registeredExtensionIDs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
        }
        createdProfiles.removeAll()
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The extension's per-profile rows, its onInstalled ledger and its own row.
    private nonisolated static func deleteRows(forExtension id: String) {
        try? AppDatabase.shared.dbQueue.write { db in
            _ = try ProfileExtensionRecord.filter(Column("extensionID") == id).deleteAll(db)
            _ = try ExtensionInstalledEventRecord.filter(Column("extensionID") == id).deleteAll(db)
        }
        AppDatabase.shared.deleteExtension(id: id)
    }

    private nonisolated static func ledgerVersions(extensionID: String, profileID: String) throws -> [String] {
        try AppDatabase.shared.dbQueue.read { db in
            try ExtensionInstalledEventRecord
                .filter(Column("extensionID") == extensionID && Column("profileID") == profileID)
                .fetchAll(db)
                .map(\.deliveredVersion)
        }
    }

    /// Write an extension to a temp directory, register it in ExtensionManager and
    /// save its DB row as globally enabled — what an installed extension looks like.
    private func installTestExtension(named name: String, manifest: String,
                                      files: [String: String]) async throws -> WebExtension {
        let id = "new-profile-\(name)-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        for (file, contents) in files {
            try contents.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let parsed = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: parsed, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        AppDatabase.shared.saveExtension(ExtensionRecord(
            id: id, name: parsed.name, version: parsed.version,
            manifestJSON: manifest.data(using: .utf8)!, basePath: dir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970
        ))
        ExtensionManager.shared.invalidateEnabledExtensionsCache()
        return ext
    }

    /// An extension with an action and a content script on test.example.com, and
    /// no background content.
    private func installContentScriptExtension() async throws -> WebExtension {
        try await installTestExtension(named: "content", manifest: """
        {
            "manifest_version": 3,
            "name": "New Profile Content Script Test",
            "version": "1.0.0",
            "permissions": ["activeTab"],
            "action": { "default_title": "New Profile Action" },
            "content_scripts": [
                { "matches": ["https://test.example.com/*"], "js": ["content.js"], "run_at": "document_end" }
            ]
        }
        """, files: [
            "content.js": "document.documentElement.setAttribute('data-new-profile-extension', 'ran');"
        ])
    }

    private func addProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    private func isLoaded(_ ext: WebExtension, in profile: Profile) -> Bool {
        profile.extensionContext(for: ext.id) != nil
    }

    /// Load an https page in a web view on the profile's controller, registered as
    /// a tab of `context` (content scripts need that before the load).
    private func loadPage(in profile: Profile, context: WKWebExtensionContext) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.webExtensionController = profile.extensionController
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        probes.append((registerProbeTab(for: webView, in: context), context))
        try await loadHTMLStringAndWait(webView, html: "<html><body>page</body></html>",
                                        baseURL: URL(string: "https://test.example.com/")!)
        return webView
    }

    // MARK: - AC #1: loads without a relaunch

    func testGloballyEnabledExtensionLoadsIntoAProfileCreatedMidSession() async throws {
        let ext = try await installContentScriptExtension()

        let profile = addProfile("New Profile Loads")

        let context = try XCTUnwrap(profile.extensionContext(for: ext.id),
                                    "addProfile must load the enabled extension without a relaunch")
        XCTAssertEqual(context.webExtensionController, profile.extensionController,
                       "the context must live in the new profile's own controller")
        XCTAssertNotNil(context.action(for: nil), "the toolbar action comes from the loaded context")
        XCTAssertTrue(ExtensionManager.shared.enabledExtensions(for: profile.id).contains { $0.id == ext.id })

        let webView = try await loadPage(in: profile, context: context)
        try await waitUntil("the content script to run on a page in the new profile") {
            let marker = try await webView.evaluateJavaScript(
                "document.documentElement.getAttribute('data-new-profile-extension')") as? String
            return marker == "ran"
        }
    }

    // MARK: - AC #2: the per-profile rule is respected

    func testGloballyDisabledExtensionDoesNotLoadIntoANewProfileUntilEnabled() async throws {
        let ext = try await installContentScriptExtension()
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: false)

        let profile = addProfile("New Profile Global Off")
        XCTAssertFalse(isLoaded(ext, in: profile), "a globally disabled extension must not load into a new profile")

        ExtensionManager.shared.setEnabled(id: ext.id, enabled: true)
        XCTAssertTrue(isLoaded(ext, in: profile), "the global enable must reach the new profile")
    }

    /// The per-profile Settings toggle (`setEnabled(id:profileID:enabled:)`) works
    /// on the new profile at once.
    func testPerProfileToggleWorksOnANewProfileImmediately() async throws {
        let ext = try await installContentScriptExtension()
        let profile = addProfile("New Profile Toggle")
        let other = addProfile("New Profile Toggle Other")
        XCTAssertTrue(isLoaded(ext, in: profile))

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: false)
        XCTAssertFalse(isLoaded(ext, in: profile), "turning it off for the new profile must unload it there")
        XCTAssertFalse(ExtensionManager.shared.isEnabled(extensionID: ext.id, inProfile: profile.id))
        XCTAssertTrue(isLoaded(ext, in: other), "another new profile keeps its context")

        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: true)
        XCTAssertTrue(isLoaded(ext, in: profile), "turning it back on must load it again")
    }

    // MARK: - AC #4: other tests do not load contexts

    /// With the suite-wide opt-out in place (the state every other test runs in),
    /// `TabStore.shared.addProfile` loads nothing.
    func testAddProfileLoadsNothingWhileTheTestOptOutIsOff() async throws {
        let ext = try await installContentScriptExtension()
        ExtensionManager.shared.loadsExtensionsIntoAddedProfiles = false

        let profile = addProfile("New Profile Opted Out")

        XCTAssertFalse(isLoaded(ext, in: profile))
        XCTAssertTrue(profile.extensionContexts.isEmpty)
    }

    /// A TabStore other than the shared one (what TabStore tests build) never
    /// reaches ExtensionManager, whatever the switch says.
    func testAProfileAddedToAnotherTabStoreLoadsNothing() async throws {
        let ext = try await installContentScriptExtension()
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))

        let profile = store.addProfile(name: "Private Store Profile")

        XCTAssertFalse(isLoaded(ext, in: profile))
        XCTAssertTrue(profile.extensionContexts.isEmpty)
    }

    // MARK: - AC #3: runtime.onInstalled is delivered once

    /// A new profile has no ledger row, so its first worker start — the one
    /// `loadExtensionsIntoProfile` wakes — gets `install`, and the claim advances
    /// the ledger. A later worker start in that profile (a fresh context after a
    /// per-profile disable → enable) gets nothing.
    func testNewProfilesWorkerGetsInstallExactlyOnce() async throws {
        let backgroundJS = ExtensionAPIPolyfill.polyfillJS + """

        const installEvents = [];
        chrome.runtime.onInstalled.addListener((details) => { installEvents.push(details); });
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (!message || message.type !== 'installEvents') return false;
            const status = globalThis.__detourRuntimeOnInstalled;
            sendResponse({ events: installEvents, mode: status.mode, detail: status.detail,
                           claimCount: status.claimCount });
            return true;
        });
        """
        let ext = try await installTestExtension(named: "worker", manifest: """
        {
            "manifest_version": 3,
            "name": "New Profile Worker Test",
            "version": "1.0.0",
            "background": { "service_worker": "background.js" }
        }
        """, files: [
            "background.js": backgroundJS,
            "page.html": "<html><body>page</body></html>"
        ])

        // Loading the extension here would start workers in the host's own
        // profiles too; it only needs to be installed. The new profile starts with
        // no ledger row.
        let profile = addProfile("New Profile Worker")
        let profileID = profile.id.uuidString
        XCTAssertTrue(isLoaded(ext, in: profile))

        // The woken worker claims on its own; the claim advances the ledger.
        try await waitUntil("the new profile's worker to claim runtime.onInstalled", timeout: 20) {
            AppDatabase.shared.pendingRuntimeInstalledEvent(
                extensionID: ext.id, profileID: profileID, isPrivateProfile: false, currentVersion: "1.0.0") == nil
        }
        XCTAssertEqual(try Self.ledgerVersions(extensionID: ext.id, profileID: profileID), ["1.0.0"])

        let first = try await installEvents(of: ext, in: profile) { reply in
            // The ledger advances before the worker has the reply in hand.
            !((reply["events"] as? [Any]) ?? []).isEmpty
        }
        XCTAssertEqual(first["mode"] as? String, "detour", "the polyfill must own the event: \(first)")
        XCTAssertEqual(first["events"] as? [[String: String]], [["reason": "install"]],
                       "the first worker start must get install, once: \(first)")
        XCTAssertEqual(first["claimCount"] as? Int, 1)

        // A second worker start in the same profile.
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: false)
        XCTAssertFalse(isLoaded(ext, in: profile))
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: true)
        XCTAssertTrue(isLoaded(ext, in: profile))

        // Give a (wrong) claim time to dispatch before reading what arrived.
        let second = try await installEvents(of: ext, in: profile, settle: 0.5)
        XCTAssertEqual(second["mode"] as? String, "detour", "\(second)")
        XCTAssertEqual(second["claimCount"] as? Int, 1, "the restarted worker claims once: \(second)")
        XCTAssertEqual(second["events"] as? [[String: String]], [],
                       "a restarted worker must not get install again: \(second)")
    }

    /// Ask the extension's worker in `profile` what `runtime.onInstalled` it saw,
    /// from one of the extension's own pages. The worker answers nothing until it
    /// is up, so wait for a reply.
    private func installEvents(of ext: WebExtension, in profile: Profile, settle: TimeInterval = 0,
                               until ready: @escaping ([String: Any]) -> Bool = { _ in true }) async throws -> [String: Any] {
        let context = try XCTUnwrap(profile.extensionContext(for: ext.id))
        let config = try XCTUnwrap(context.webViewConfiguration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        try await loadAndWait(webView, URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        var reply: [String: Any]?
        try await waitUntil("the worker to answer", timeout: 20) {
            let envelope = try await askWorker(from: webView, message: ["type": "installEvents"], timeout: 5)
            reply = envelope["reply"] as? [String: Any]
            return reply.map(ready) ?? false
        }
        if settle > 0 {
            try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            let envelope = try await askWorker(from: webView, message: ["type": "installEvents"], timeout: 5)
            reply = envelope["reply"] as? [String: Any]
        }
        return try XCTUnwrap(reply, "the worker must answer")
    }
}
