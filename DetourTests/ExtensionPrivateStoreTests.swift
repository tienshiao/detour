import XCTest
import WebKit
@testable import Detour

/// TASK-73: the Private (incognito) profile's extension pages — background
/// worker, popup, options, offscreen — run in the profile's own
/// `.nonPersistent()` store, not in WebKit's shared default one, so nothing an
/// extension writes in Private reaches the disk or outlives the process.
///
/// The shipped WebKit (7624) builds a controller configuration's
/// `webViewConfiguration` as a plain `WKWebViewConfiguration()` and never
/// copies `defaultWebsiteDataStore` into it, so `Profile` sets the store there
/// by hand. Doing that for the incognito profile was tried once before
/// (2026-09-13) and reverted: 1Password's worker never answered keep-alive ping
/// #1 and WebKit unloaded and re-registered it every 60 s. The cause was not
/// the store but the *private-data gate*:
/// `WebExtensionContext::processes()` — the process set every extension event
/// and port message is dispatched to — skips every page for which
/// `!hasAccessToPrivateData() && page->sessionID().isEphemeral()` (WebKit main
/// excepts pages on the controller's `defaultWebsiteDataStore`; 7624 does not),
/// and `WebExtensionContext::websiteDataStore(sessionID)` fails the same test.
/// With the worker itself in an ephemeral session and no private-data access on
/// the context, no event could reach it at all — including the keep-alive ping,
/// which is a native-port message — so nothing ever replied and WebKit's unload
/// timer took the worker. TASK-74 now sets `hasAccessToPrivateData` for every
/// context loaded into an incognito profile.
///
/// So these tests are in three parts:
///  1. the wiring — which store the controller and a loaded context's web views
///     actually use, in both profile kinds;
///  2. the positive leg — a probe worker in an ephemeral store receives a
///     `runtime.onMessage` event and answers it, at once and again after a
///     delay (the ≥60 s delay is env-gated like TASK-62's long legs);
///  3. the negative control that pins the cause — the same setup with
///     `hasAccessToPrivateData` never set must *not* deliver the message.
@MainActor
final class ExtensionPrivateStoreTests: XCTestCase {

    // MARK: - Fixture bookkeeping

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    /// Contexts loaded into a controller by hand (the negative control), which
    /// `Profile.unloadAllExtensions` does not know about.
    private var manuallyLoadedContexts: [(profile: Profile, context: WKWebExtensionContext)] = []
    private var openWebViews: [WKWebView] = []

    /// Profiles whose extension controller hosted a web view are kept alive for
    /// the rest of the test process: releasing one takes its `WKProcessPool`
    /// (and the web process behind the page) down with it, and WebKit traps
    /// when that happens inside an IPC dispatch — the same hazard
    /// `ExtensionOriginTrackingPreventionTests` works around.
    private static var retainedProfiles: [Profile] = []

    override func tearDown() async throws {
        for webView in openWebViews {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        openWebViews.removeAll()
        for (profile, context) in manuallyLoadedContexts {
            try? profile.extensionController.unload(context)
        }
        manuallyLoadedContexts.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// An incognito profile of its own — a random id, so it is never the
    /// built-in Private profile whose rows other suites share, but the same
    /// `isIncognito` wiring.
    private func makeIncognitoProfile(_ name: String) -> Profile {
        let profile = Profile(name: name, isIncognito: true)
        createdProfiles.append(profile)
        return profile
    }

    private func makePersistentProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    /// The probe: an MV3 service worker that answers `ping` with `{ ok: true }`
    /// and the number of times it has started. The counter lives in
    /// `chrome.storage.local` — in an ephemeral controller that is memory only
    /// — so a reply that says `starts: 2` means WebKit unloaded and restarted
    /// the worker between the two asks, which is fine: what is being tested is
    /// that the *event* arrives.
    private static let probeBackgroundJS = """
    const started = (async () => {
        try {
            const stored = await chrome.storage.local.get('starts');
            const starts = (Number(stored && stored.starts) || 0) + 1;
            await chrome.storage.local.set({ starts: starts });
            return { starts: starts, error: null };
        } catch (e) {
            return { starts: -1, error: String(e && e.message ? e.message : e) };
        }
    })();

    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message || message.type !== 'ping') { return false; }
        started.then((s) => sendResponse({ ok: true, starts: s.starts, startsError: s.error }));
        return true;
    });
    """

    private func makeProbeExtension(idPrefix: String) async throws -> WebExtension {
        let id = "\(idPrefix)-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        try """
        {
            "manifest_version": 3,
            "name": "Private Store Probe",
            "version": "1.0.0",
            "permissions": ["storage"],
            "background": { "service_worker": "background.js", "type": "module" }
        }
        """.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><body><div id=\"probe\">private store probe</div></body></html>"
            .write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)
        try Self.probeBackgroundJS
            .write(to: dir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    /// Grant the probe's manifest permissions on `context`. Nothing in the app
    /// grants API permissions up front — `Profile.loadExtensionContext` only
    /// restores decisions the database already holds, and the fixture saves none
    /// — so without this the worker has no `chrome.storage` to count its starts
    /// in. Profile-independent, and unrelated to which store the pages run in.
    private func grantRequestedPermissions(of ext: WebExtension, on context: WKWebExtensionContext) {
        for permission in ext.wkExtension?.requestedPermissions ?? [] {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
    }

    /// An extension page of the context, built from the controller's own
    /// configuration — the only place a test can talk to the worker from.
    private func makeExtensionPage(for context: WKWebExtensionContext) async throws -> WKWebView {
        let config = try XCTUnwrap(context.webViewConfiguration,
                                   "webViewConfiguration is nil — context not loaded in a controller")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                configuration: config)
        openWebViews.append(webView)
        try await loadAndWait(webView,
                              URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        return webView
    }

    /// What one `chrome.runtime.sendMessage({type:'ping'})` from `page` did.
    /// Everything that is not an answer is distinguished rather than collapsed,
    /// because the negative control's whole value is in *which* silence it got:
    ///  - `answered` with `starts` — the worker got the event and replied;
    ///  - `empty` — the callback fired with nothing (WebKit's answer when it
    ///    could not reach the worker at all), with `lastError` if there was one;
    ///  - `timeout` — the callback never fired;
    ///  - `threw` — the page could not ask at all (no `chrome.runtime`, or the
    ///    script failed), with the error.
    private struct PingOutcome {
        var outcome: String
        var starts: Int?
        var startsError: String?
        var lastError: String?
        var error: String?
        var answered: Bool { outcome == "answered" }
        var describe: String {
            "outcome=\(outcome) starts=\(starts.map(String.init) ?? "-") "
                + "startsError=\(startsError ?? "-") "
                + "lastError=\(lastError ?? "-") error=\(error ?? "-")"
        }
    }

    /// One `askWorker` round trip (`ExtensionTestSupport`), sorted into the
    /// outcomes above.
    private func ping(_ page: WKWebView, timeout: TimeInterval = 10) async -> PingOutcome {
        do {
            let envelope = try await askWorker(from: page, message: ["type": "ping"], timeout: timeout)
            let lastError = envelope["lastError"] as? String
            if let reply = envelope["reply"] as? [String: Any], reply["ok"] as? Bool == true {
                return PingOutcome(outcome: "answered",
                                   starts: reply["starts"] as? Int,
                                   startsError: reply["startsError"] as? String,
                                   lastError: lastError)
            }
            if envelope["reply"] as? String == "timeout" {
                return PingOutcome(outcome: "timeout")
            }
            return PingOutcome(outcome: "empty", lastError: lastError)
        } catch {
            return PingOutcome(outcome: "threw", error: String(describing: error))
        }
    }

    /// The long leg is minutes of waiting, so the delay it uses is env-gated the
    /// way TASK-62's measurement legs are (`DETOUR_MEASURE_*`; the test runner
    /// only passes a variable through when it is given as `TEST_RUNNER_…`).
    /// Default: a few seconds, which still crosses a worker's idle window often
    /// enough to be worth asserting.
    private var secondPingDelay: TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["DETOUR_MEASURE_PRIVATE_WORKER_SECONDS"], let seconds = Double(raw) {
            return seconds
        }
        return environment["DETOUR_MEASURE_PRIVATE_WORKER"] == "1" ? 90 : 5
    }

    // MARK: - 1. Which store the pages run in

    /// AC #4, the wiring half: the incognito profile's controller builds its
    /// extension web views on the profile's own non-persistent store, and a
    /// loaded context's configuration carries it.
    func testIncognitoExtensionPagesUseTheProfilesNonPersistentStore() async throws {
        let profile = makeIncognitoProfile("Private Store Wiring")
        let pagesStore = profile.extensionController.configuration.webViewConfiguration.websiteDataStore

        XCTAssertTrue(pagesStore === profile.dataStore,
                      "the extension pages' store must be the profile's own store")
        XCTAssertFalse(pagesStore.isPersistent, "and it must be non-persistent")
        XCTAssertFalse(pagesStore === WKWebsiteDataStore.default(),
                       "never WebKit's shared default store")
        XCTAssertTrue(profile.extensionController.configuration.defaultWebsiteDataStore === profile.dataStore)

        let ext = try await makeProbeExtension(idPrefix: "private-store-wiring")
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id], "the context should load")

        XCTAssertTrue(context.webViewConfiguration?.websiteDataStore === profile.dataStore,
                      "the loaded context's web views must be built on the same ephemeral store")
        XCTAssertEqual(context.webViewConfiguration?.websiteDataStore.isPersistent, false)
        // The other half of TASK-74, which is what makes the ephemeral store
        // usable at all (see the negative control below).
        XCTAssertTrue(context.hasAccessToPrivateData,
                      "a context in an incognito profile must have private-data access")
    }

    /// The other side of the same line: a persistent profile is unchanged — its
    /// pages run in its own identifier-backed store, still not the default one.
    func testPersistentProfileExtensionPagesStillUseItsOwnStore() async throws {
        let profile = makePersistentProfile("Private Store Persistent")
        let pagesStore = profile.extensionController.configuration.webViewConfiguration.websiteDataStore

        XCTAssertTrue(pagesStore === profile.dataStore, "its own store, as before")
        XCTAssertTrue(pagesStore.isPersistent)
        XCTAssertFalse(pagesStore === WKWebsiteDataStore.default(),
                       "extension web views must not fall back to the default store")

        let ext = try await makeProbeExtension(idPrefix: "private-store-persistent")
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id], "the context should load")
        XCTAssertTrue(context.webViewConfiguration?.websiteDataStore === profile.dataStore)
        XCTAssertFalse(context.hasAccessToPrivateData,
                       "private-data access is for incognito profiles only")
    }

    // MARK: - 2. The positive leg: events reach a worker in the ephemeral store

    /// AC #4, the behaviour half. A probe worker loaded into an incognito
    /// profile — so its own session is ephemeral — receives a
    /// `runtime.onMessage` event from an extension page and answers it: at once,
    /// and again after a delay (≥60 s with
    /// `TEST_RUNNER_DETOUR_MEASURE_PRIVATE_WORKER=1`, a few seconds otherwise).
    ///
    /// This is the leg that was impossible before TASK-74: every dispatch to the
    /// background went through `WebExtensionContext::processes()`, which dropped
    /// the worker's ephemeral page for want of private-data access.
    ///
    /// Measured 2026-09-20 with the 90 s delay: the first ping was answered by
    /// worker start #1 and the one after the wait by start #2 — WebKit idle-
    /// unloaded the worker while the test waited and the message woke it again,
    /// with its `chrome.storage.local` counter intact across the restart in the
    /// ephemeral store. Which start answers is deliberately not asserted; that
    /// the event arrives is.
    func testWorkerInAnEphemeralStoreReceivesEventsNowAndAfterADelay() async throws {
        let ext = try await makeProbeExtension(idPrefix: "private-store-positive")
        let profile = makeIncognitoProfile("Private Store Positive")
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id], "the probe's context should load")
        XCTAssertTrue(context.hasAccessToPrivateData, "precondition: TASK-74's private-data access")
        XCTAssertEqual(context.webViewConfiguration?.websiteDataStore.isPersistent, false,
                       "precondition: the worker's own session is ephemeral")
        grantRequestedPermissions(of: ext, on: context)

        let page = try await makeExtensionPage(for: context)
        context.loadBackgroundContent { error in
            if let error { print("private-store probe: loadBackgroundContent failed: \(error)") }
        }

        var first = PingOutcome(outcome: "never asked")
        try await waitUntil("the worker in the ephemeral store to answer a ping", timeout: 30) {
            first = await self.ping(page, timeout: 5)
            return first.answered
        }
        XCTAssertTrue(first.answered, "the worker must answer: \(first.describe)")

        try await Task.sleep(nanoseconds: UInt64(secondPingDelay * 1_000_000_000))

        // A worker WebKit unloaded while we waited must still be reachable: the
        // message wakes it, and `starts` says whether it had to be restarted.
        var second = PingOutcome(outcome: "never asked")
        try await waitUntil("the worker to answer again after \(secondPingDelay) s", timeout: 30) {
            second = await self.ping(page, timeout: 10)
            return second.answered
        }
        XCTAssertTrue(second.answered,
                      "the worker must still be reachable after \(secondPingDelay) s: \(second.describe)")
        print("private-store probe: first \(first.describe); after \(secondPingDelay) s \(second.describe)")
    }

    // MARK: - 3. The negative control that pins the cause

    /// One ping to a probe whose context is loaded into an incognito profile by
    /// hand — `Profile.loadExtensionContext` always grants private-data access
    /// there (TASK-74), so the flag can only be varied from outside it.
    /// `privateDataAccess` is the single difference between the two legs below;
    /// everything else — profile kind, store, extension, page, worker — is the
    /// same.
    ///
    /// A page that will not come up is recorded rather than failed: a page
    /// WebKit refuses to dispatch to is no use either way, and the outcome
    /// string says which happened.
    private func pingManuallyLoadedProbe(
        privateDataAccess: Bool, label: String
    ) async throws -> PingOutcome {
        let ext = try await makeProbeExtension(idPrefix: "private-store-\(label)")
        let profile = makeIncognitoProfile("Private Store \(label)")
        let wkExt = try XCTUnwrap(ext.wkExtension)

        let context = WKWebExtensionContext(for: wkExt)
        context.uniqueIdentifier = ext.id
        context.isInspectable = true
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        grantRequestedPermissions(of: ext, on: context)
        context.hasAccessToPrivateData = privateDataAccess
        XCTAssertEqual(context.hasAccessToPrivateData, privateDataAccess, "precondition: the gate")
        try profile.extensionController.load(context)
        manuallyLoadedContexts.append((profile, context))
        XCTAssertEqual(context.webViewConfiguration?.websiteDataStore.isPersistent, false,
                       "precondition: an ephemeral store on both legs")

        var outcome = PingOutcome(outcome: "page-failed")
        do {
            let page = try await makeExtensionPage(for: context)
            context.loadBackgroundContent { error in
                if let error { print("private-store \(label): loadBackgroundContent failed: \(error)") }
            }
            // Polled by hand rather than with `waitUntil`, which fails the test
            // when it times out: the closed-gate leg *expects* to run out, and
            // needs the last outcome rather than a failure. Long enough that a
            // reachable worker answers many times over — with the gate open it
            // replies in well under a second once it is up.
            let deadline = Date().addingTimeInterval(20)
            repeat {
                outcome = await ping(page, timeout: 5)
                if outcome.answered { break }
                // `empty` comes back at once: without a pause the closed-gate
                // leg would flood the context with messages for 20 s.
                try? await Task.sleep(nanoseconds: 250_000_000)
            } while Date() < deadline
        } catch {
            print("private-store \(label): \(error)")
        }
        print("private-store \(label): \(outcome.describe)")
        return outcome
    }

    /// The negative control. The same worker in the same ephemeral store as the
    /// positive leg, with the one difference that its context has no
    /// `hasAccessToPrivateData`: WebKit's gate then drops every ephemeral page
    /// from the context's process set, so the message must not be delivered —
    /// which is exactly what the 2026-09-13 keep-alive failure was.
    ///
    /// If this ever *passes* the message through, the private-data gate is not
    /// the cause and TASK-73's explanation has to be reopened (worker console
    /// with `ExtensionConsoleLogPublic`; next suspects IndexedDB / Cache Storage
    /// in a non-persistent session, the `_renameOrigin` LastSeenBaseURL
    /// migration, and the relay / native-port setup).
    func testWithoutPrivateDataAccessTheWorkerNeverHearsTheMessage() async throws {
        let outcome = try await pingManuallyLoadedProbe(privateDataAccess: false, label: "control-closed")
        XCTAssertFalse(outcome.answered,
                       "REFUTES TASK-73's cause: a worker in an ephemeral session answered without "
                           + "private-data access — \(outcome.describe)")
        // Silence must be WebKit's, not the fixture's: a page that never loaded
        // or a script that threw would "not answer" without sending one message.
        XCTAssertTrue(["empty", "timeout"].contains(outcome.outcome),
                      "the control never reached the gate — \(outcome.describe)")
    }

    /// The matched positive for that control: the identical hand-built load with
    /// the flag set does deliver, so the silence above is the flag and nothing
    /// else about loading a context by hand.
    func testTheSameLoadWithPrivateDataAccessDoesDeliver() async throws {
        let outcome = try await pingManuallyLoadedProbe(privateDataAccess: true, label: "control-open")
        XCTAssertTrue(outcome.answered,
                      "the only difference from the control is hasAccessToPrivateData — \(outcome.describe)")
    }
}
