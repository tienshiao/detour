import XCTest
import WebKit
@testable import Detour

/// Records every interaction the production path hands to WebKit. A file-scope
/// class rather than a captured local so the recording closure — which WebKit's
/// caller invokes with no actor of its own — has something plain to touch.
private final class InteractionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    private var recordedStores: [WKWebsiteDataStore] = []

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// The store each interaction was logged into, in call order.
    var stores: [WKWebsiteDataStore] {
        lock.lock(); defer { lock.unlock() }
        return recordedStores
    }

    func install() {
        ExtensionOriginInteractionKeeper.interactionLogHookForTesting = { [weak self] url, store in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.recorded.append(url)
            self.recordedStores.append(store)
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        recordedStores = []
    }
}

/// WebKit's tracking prevention (ITP) deletes the *script-written storage* —
/// service worker registration, IndexedDB, localStorage — of every observed
/// registrable domain whose statistics record holds no unexpired user
/// interaction. An extension origin (`webkit-extension://<uuid>/`) becomes such
/// a domain the moment a page loads one of the extension's cross-host
/// resources, which is how 1Password's background worker was being killed at
/// launch (TASK-70): the Networking log showed
/// `deleteAndRestrictWebsiteDataForRegistrableDomains ... 706
/// domainsToDeleteAllScriptWrittenStorageFor` followed at once by
/// `SWServerRegistration::clear` for the extension.
///
/// `ExtensionOriginInteractionKeeper` claims a user interaction for every
/// loaded context's origin, so the pass leaves it alone. These tests cover both
/// halves: the production wiring (`Profile.loadExtensionContext` logs exactly
/// one interaction per loaded context, and none at all for a non-persistent
/// store), and a real ITP pass that empties an origin with no interaction while
/// sparing both an origin the keeper logged and a loaded extension's.
@MainActor
final class ExtensionOriginTrackingPreventionTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var openWebViews: [WKWebView] = []

    /// Profiles whose extension controller hosted a web view are kept alive for
    /// the rest of the test process: releasing one takes its `WKProcessPool`
    /// (and the web process behind the page) down with it, and WebKit traps
    /// when that happens inside an IPC dispatch — see
    /// `ExtensionMenuPopupDecisionTests`. The contexts are still unloaded and
    /// the store row removed; only the object outlives the test.
    private static var retainedProfiles: [Profile] = []

    override func tearDown() async throws {
        ExtensionOriginInteractionKeeper.interactionLogHookForTesting = nil
        for webView in openWebViews {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        openWebViews.removeAll()
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

    private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    /// The probe extension: an MV3 service worker that keeps one IndexedDB
    /// marker and answers three messages —
    ///  - `ping` → `{ ok: true }` once the worker is running,
    ///  - `writeMarker` → stores `{ key: 'marker', value: 'alive' }` in
    ///    `probe-db`,
    ///  - `readMarker` → the stored value, or null.
    ///
    /// The write is deliberately *not* done at startup: a worker WebKit
    /// restarts after the ITP pass would otherwise re-create the very marker
    /// whose absence proves the storage was purged.
    private static let probeBackgroundJS = """
    const DB_NAME = 'probe-db';
    const STORE = 'markers';

    function openDB() {
        return new Promise((resolve, reject) => {
            const request = indexedDB.open(DB_NAME, 1);
            request.onupgradeneeded = () => {
                const db = request.result;
                if (!db.objectStoreNames.contains(STORE)) {
                    db.createObjectStore(STORE, { keyPath: 'key' });
                }
            };
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
            request.onblocked = () => reject(new Error('indexedDB.open blocked'));
        });
    }

    async function writeMarker() {
        const db = await openDB();
        try {
            await new Promise((resolve, reject) => {
                const tx = db.transaction(STORE, 'readwrite');
                tx.objectStore(STORE).put({ key: 'marker', value: 'alive' });
                tx.oncomplete = () => resolve();
                tx.onerror = () => reject(tx.error);
                tx.onabort = () => reject(tx.error || new Error('aborted'));
            });
        } finally {
            db.close();
        }
    }

    async function readMarker() {
        const db = await openDB();
        try {
            return await new Promise((resolve, reject) => {
                const tx = db.transaction(STORE, 'readonly');
                const get = tx.objectStore(STORE).get('marker');
                get.onsuccess = () => resolve(get.result ? get.result.value : null);
                get.onerror = () => reject(get.error);
            });
        } finally {
            db.close();
        }
    }

    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'ping') {
            sendResponse({ ok: true });
            return false;
        }
        if (message.type === 'writeMarker') {
            writeMarker().then(() => sendResponse({ ok: true }))
                .catch((e) => sendResponse({ ok: false, error: String(e && e.message ? e.message : e) }));
            return true;
        }
        if (message.type === 'readMarker') {
            readMarker().then((value) => sendResponse({ value: value === undefined ? null : value }))
                .catch((e) => sendResponse({ value: null, error: String(e && e.message ? e.message : e) }));
            return true;
        }
        return false;
    });
    """

    /// Write the probe extension to a fresh temp directory and register it the
    /// way an installed extension is registered.
    private func makeProbeExtension(idPrefix: String) async throws -> WebExtension {
        let id = "\(idPrefix)-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        try """
        {
            "manifest_version": 3,
            "name": "ITP Probe",
            "version": "1.0.0",
            "background": { "service_worker": "background.js", "type": "module" }
        }
        """.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><body><div id=\"probe\">itp probe</div></body></html>"
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

    /// An extension page of the context, loaded from the controller's own
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

    /// Load the probe into `profile`, start its worker, and wait until it
    /// answers. Returns the context and the page the test asks through.
    private func startProbe(_ ext: WebExtension, in profile: Profile)
        async throws -> (context: WKWebExtensionContext, page: WKWebView) {
        _ = profile.extensionController
        _ = profile.loadExtensionContext(ext)
        let context = try XCTUnwrap(profile.extensionContexts[ext.id],
                                    "the probe's context should load")
        let page = try await makeExtensionPage(for: context)
        context.loadBackgroundContent { error in
            if let error { print("ITP probe: loadBackgroundContent failed: \(error)") }
        }
        try await waitUntil("the probe worker to answer a ping", timeout: 30) {
            let envelope = try await askWorker(from: page, message: ["type": "ping"], timeout: 5)
            return (envelope["reply"] as? [String: Any])?["ok"] as? Bool == true
        }
        return (context, page)
    }

    /// The marker the probe's worker has in IndexedDB, or nil when there is
    /// none — including when the worker cannot be reached at all, which is the
    /// other face of a purged origin (its registration went with the storage).
    private func marker(from page: WKWebView) async throws -> String? {
        let envelope = try await askWorker(from: page, message: ["type": "readMarker"], timeout: 15)
        guard let reply = envelope["reply"] as? [String: Any] else { return nil }
        if let error = reply["error"] as? String {
            print("ITP probe: readMarker failed: \(error)")
            return nil
        }
        return reply["value"] as? String
    }

    // MARK: - The keeper's own contract

    /// A non-persistent store has no statistics database and loses its storage
    /// at teardown: the keeper must not call into WebKit for one, and must not
    /// trip over it either.
    func testKeeperSkipsANonPersistentDataStore() async throws {
        let recorder = InteractionRecorder()
        recorder.install()

        let finished = expectation(description: "logInteraction completes")
        ExtensionOriginInteractionKeeper.logInteraction(
            for: URL(string: "webkit-extension://11111111-2222-3333-4444-555555555555/")!,
            on: .nonPersistent(), extensionID: "skip-me"
        ) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertTrue(recorder.urls.isEmpty,
                      "a non-persistent store must never reach WebKit's interaction log")
    }

    /// Since TASK-73 an incognito profile's extension pages run in the same
    /// ephemeral store its browsing does, so there is no ITP database to keep
    /// anything in and the keeper must log nothing for it — and must not trip
    /// over it either.
    ///
    /// The decision is still the store's, never `isIncognito` (TASK-90): while
    /// those pages were on WebKit's default *persistent* store, skipping them
    /// for being incognito let ITP delete 1Password's IndexedDB under its
    /// running Private-profile worker. The premise below is what tells the two
    /// situations apart, so if it ever fails again, turn these assertions back
    /// around rather than deleting them.
    func testIncognitoProfilesPagesRunInItsEphemeralStoreSoNothingIsLogged() async throws {
        let recorder = InteractionRecorder()
        recorder.install()

        let ext = try await makeProbeExtension(idPrefix: "itp-incognito")
        let profile = Profile(name: "ITP Incognito", isIncognito: true)
        defer { profile.unloadAllExtensions() }
        let pagesStore = profile.extensionController.configuration.webViewConfiguration.websiteDataStore
        XCTAssertFalse(profile.dataStore.isPersistent, "its browsing store is non-persistent")
        XCTAssertTrue(pagesStore === profile.dataStore,
                      "premise: the Private profile's extension pages run in its own ephemeral store")

        _ = profile.loadExtensionContext(ext)
        XCTAssertNotNil(profile.extensionContexts[ext.id], "precondition: the context should load")

        XCTAssertTrue(recorder.urls.isEmpty,
                      "an ephemeral store has no statistics database: nothing to log, got \(recorder.urls)")

        profile.originInteractionKeeper.refreshNow()
        XCTAssertTrue(recorder.urls.isEmpty, "and the daily refresh must stay out of it too")
    }

    /// A deleted profile's storage is being removed: nothing of it is kept,
    /// whatever store its pages would have used.
    func testDeletedProfileLogsNoInteraction() async throws {
        let recorder = InteractionRecorder()
        recorder.install()

        let profile = makeProfile("ITP Deleted Profile")
        profile.isDeleted = true
        profile.originInteractionKeeper.refreshNow()

        XCTAssertTrue(recorder.urls.isEmpty,
                      "a deleted profile must not log interactions, got \(recorder.urls)")
    }

    /// The production path: loading a context logs one interaction, for that
    /// context's own base URL — and `refreshNow` (the daily timer's work)
    /// re-logs every context still loaded, and only those.
    func testLoadingAContextLogsExactlyOneInteractionForItsOrigin() async throws {
        let recorder = InteractionRecorder()
        recorder.install()

        let profile = makeProfile("ITP Wiring Profile")
        _ = profile.extensionController

        let first = try await makeProbeExtension(idPrefix: "itp-wiring-a")
        _ = profile.loadExtensionContext(first)
        let firstContext = try XCTUnwrap(profile.extensionContexts[first.id])
        XCTAssertEqual(recorder.urls, [firstContext.baseURL],
                       "loading one context must log exactly one interaction, for its own origin")

        let second = try await makeProbeExtension(idPrefix: "itp-wiring-b")
        _ = profile.loadExtensionContext(second)
        let secondContext = try XCTUnwrap(profile.extensionContexts[second.id])
        XCTAssertEqual(recorder.urls.count, 2)

        recorder.reset()
        profile.originInteractionKeeper.refreshNow()
        XCTAssertEqual(Set(recorder.urls), [firstContext.baseURL, secondContext.baseURL],
                       "the daily refresh must re-log every loaded context")

        profile.unloadExtension(id: second.id)
        recorder.reset()
        profile.originInteractionKeeper.refreshNow()
        XCTAssertEqual(recorder.urls, [firstContext.baseURL],
                       "an unloaded context's origin must not be re-logged")
    }

    // MARK: - A real tracking-prevention pass

    /// The shipped WebKit never copies `defaultWebsiteDataStore` into the
    /// controller's `webViewConfiguration`, and every extension web view is a
    /// copy of that configuration: without Detour setting the store itself, all
    /// profiles' extension pages, workers and IndexedDB share the default data
    /// store — where the ITP purge ran, out of reach of an interaction logged
    /// into the profile store (production, 2026-09-13).
    func testExtensionWebViewsUseTheProfileStore() {
        let profile = makeProfile("Extension Store Profile")
        let store = profile.extensionController.configuration.webViewConfiguration.websiteDataStore
        XCTAssertTrue(store === profile.dataStore, "extension web views must use the profile's data store")
        XCTAssertFalse(store === WKWebsiteDataStore.default(), "extension web views must not fall back to the default store")
    }

    /// Drives one real ITP processing pass over a profile and watches what it
    /// spares.
    ///
    /// Leg A is the mechanism itself, on two ordinary http origins so the
    /// outcome is fully observable through `fetchDataRecords`: both write
    /// localStorage, both are marked prevalent, and only one is handed to
    /// `ExtensionOriginInteractionKeeper.logInteraction` — the very call
    /// `Profile.loadExtensionContext` makes for a loaded extension. The logged
    /// one keeps its localStorage; its twin loses it.
    ///
    /// Leg B puts a real extension through the same pass, loaded the production
    /// way so the keeper claims its origin at context load: its worker and
    /// IndexedDB must come out the other side intact.
    ///
    /// Marking domains prevalent is the only way a test can *insert* one into
    /// the statistics table — a page loaded with `loadHTMLString` makes no
    /// network request for ITP to observe — and prevalence is not what spares
    /// the kept origins: an unexpired interaction is. The clock is then
    /// advanced a day, because
    /// `registrableDomainsToDeleteOrRestrictWebsiteDataFor` throws the whole
    /// script-written-storage list away unless an hour has passed since the
    /// *oldest* recorded interaction, and WebKit's testing clock only steps in
    /// whole days.
    ///
    /// What the pass decides about an *extension* origin is visible only in
    /// WebKit's own ITPDebug channel (`_setResourceLoadStatisticsDebugMode`),
    /// which during development read `About to remove data records for ...
    /// itp-control.example(all but cookies), <uuid of the extension whose
    /// statistics had been cleared>(all but cookies)` — with the extension
    /// whose interaction had been logged absent from the list.
    /// `fetchDataRecords` never reports `webkit-extension://` origins at all,
    /// not even after `_allowWebsiteDataRecordsForAllOrigins`, so leg A carries
    /// the negative control and leg B asserts the extension survives.
    func testTrackingPreventionPassSparesOriginsWithALoggedInteraction() async throws {
        let profile = makeProfile("ITP Pass Profile")
        let store = profile.dataStore
        try XCTSkipUnless(store.respondsToITPTestingSelectors,
                          "WKWebsiteDataStore's private ITP testing API is unavailable in this SDK")
        WKWebsiteDataStore.allowWebsiteDataRecordsForAllOrigins()
        store.setResourceLoadStatisticsEnabled(true)

        let started = Date()

        // Leg A: two ordinary origins with script-written storage.
        let keptOrigin = URL(string: "http://itp-kept.example/")!
        let purgedOrigin = URL(string: "http://itp-purged.example/")!
        for url in [keptOrigin, purgedOrigin] {
            try await writeLocalStorage(at: url, on: store)
        }
        try await waitUntil("both control origins' localStorage records") {
            let names = await self.displayNames(in: store, ofTypes: [WKWebsiteDataTypeLocalStorage])
            return names.contains { $0.contains("itp-kept.example") }
                && names.contains { $0.contains("itp-purged.example") }
        }
        // The production call, on an origin whose fate the pass will show.
        await logInteraction(for: keptOrigin, on: store, extensionID: "itp-kept-origin")

        // Leg B: a real extension, loaded through `Profile.loadExtensionContext`
        // — which is the only thing that logs an interaction for its origin.
        let probe = try await makeProbeExtension(idPrefix: "itp-probe")
        let probeRun = try await startProbe(probe, in: profile)
        try await assertMarkerWritten(through: probeRun.page, what: "the probe")

        print("ITP pass: records before the pass: \(await recordDescriptions(in: store))")

        for url in [keptOrigin, purgedOrigin, probeRun.context.baseURL] {
            await store.setPrevalentDomain(url)
            let isPrevalent = await store.isPrevalentDomain(url)
            XCTAssertTrue(isPrevalent,
                          "\(url.host ?? "?") should be in the statistics table as prevalent")
        }

        // No interaction may be logged after this point: the kept origin's is
        // the oldest one, and the hour-old guard is measured against it. There
        // is no way back either — `setTimeAdvanceForTesting` only steps forward
        // — but the advanced clock lives in this profile's own ITP session,
        // which is discarded with the profile in tearDown.
        await store.setResourceLoadStatisticsTimeAdvanceForTesting(24 * 60 * 60)
        await store.processStatisticsAndDataRecords()

        try await waitUntil("the uninteracted origin's localStorage to be deleted", timeout: 30) {
            let names = await self.displayNames(in: store, ofTypes: [WKWebsiteDataTypeLocalStorage])
            return !names.contains { $0.contains("itp-purged.example") }
        }

        let remaining = await displayNames(in: store, ofTypes: [WKWebsiteDataTypeLocalStorage])
        print("ITP pass: records after the pass: \(await recordDescriptions(in: store))")

        // Leg A's positive half: the interaction the keeper logs is exactly what
        // holds script-written storage back from a pass that emptied its twin.
        XCTAssertTrue(remaining.contains { $0.contains("itp-kept.example") },
                      "an origin with a logged interaction must keep its localStorage; records were \(remaining)")

        // Leg B: the extension origin Detour claimed at context load came
        // through the same pass with its IndexedDB — and the worker that reads
        // it — intact.
        let marker = try await marker(from: probeRun.page)
        XCTAssertEqual(marker, "alive",
                       "the extension origin Detour logged an interaction for must keep its script-written storage")

        print("ITP pass: finished in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    }

    // MARK: - Helpers

    /// Give `url`'s origin some script-written storage, in a web view on the
    /// profile's own store.
    private func writeLocalStorage(at url: URL, on store: WKWebsiteDataStore) async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200),
                                configuration: config)
        openWebViews.append(webView)
        try await loadHTMLStringAndWait(
            webView,
            html: "<html><body><script>localStorage.setItem('k', 'v');</script></body></html>",
            baseURL: url)
    }

    /// `ExtensionOriginInteractionKeeper.logInteraction`, awaited — WebKit has
    /// to have written the record before the pass reads it.
    private func logInteraction(for url: URL, on store: WKWebsiteDataStore,
                                extensionID: String) async {
        await withCheckedContinuation { continuation in
            ExtensionOriginInteractionKeeper.logInteraction(
                for: url, on: store, extensionID: extensionID) { continuation.resume() }
        }
    }

    private func assertMarkerWritten(through page: WKWebView, what: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) async throws {
        let written = try await askWorker(from: page, message: ["type": "writeMarker"], timeout: 20)
        let reply = written["reply"] as? [String: Any]
        XCTAssertEqual(reply?["ok"] as? Bool, true,
                       "\(what) could not write its marker: \(written)", file: file, line: line)
        let readBack = try await marker(from: page)
        XCTAssertEqual(readBack, "alive", "\(what) could not read its marker back",
                       file: file, line: line)
    }

    private func displayNames(in store: WKWebsiteDataStore,
                              ofTypes types: Set<String>) async -> [String] {
        await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { records in
                continuation.resume(returning: records.map(\.displayName))
            }
        }
    }

    /// Everything the store will admit to holding, for the log: how WebKit
    /// names a `webkit-extension://` record is documented nowhere.
    private func recordDescriptions(
        in store: WKWebsiteDataStore,
        ofTypes types: Set<String> = [
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeServiceWorkerRegistrations,
        ]
    ) async -> String {
        return await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { records in
                continuation.resume(returning: records
                    .map { "\($0.displayName) \($0.dataTypes.sorted())" }
                    .sorted().joined(separator: "; "))
            }
        }
    }
}

// MARK: - Private ITP testing API

/// The private `WKWebsiteDataStore` hooks the ITP pass is driven through
/// (WKWebsiteDataStorePrivate.h). Reached through an `@objc` protocol rather
/// than `perform`, which can pass neither a `BOOL`, an `NSTimeInterval`, nor a
/// completion block.
@objc private protocol ITPTestingShim {
    @objc(_setResourceLoadStatisticsEnabled:)
    func setResourceLoadStatisticsEnabled(_ enabled: Bool)

    @objc(_setPrevalentDomain:completionHandler:)
    func setPrevalentDomain(_ url: URL, completionHandler: @escaping () -> Void)

    @objc(_getIsPrevalentDomain:completionHandler:)
    func getIsPrevalentDomain(_ url: URL, completionHandler: @escaping (Bool) -> Void)

    @objc(_setResourceLoadStatisticsTimeAdvanceForTesting:completionHandler:)
    func setResourceLoadStatisticsTimeAdvanceForTesting(
        _ time: TimeInterval, completionHandler: @escaping () -> Void)

    @objc(_processStatisticsAndDataRecords:)
    func processStatisticsAndDataRecords(_ completionHandler: @escaping () -> Void)
}

extension WKWebsiteDataStore {

    fileprivate static let itpTestingSelectors = [
        "_setResourceLoadStatisticsEnabled:",
        "_setPrevalentDomain:completionHandler:",
        "_getIsPrevalentDomain:completionHandler:",
        "_setResourceLoadStatisticsTimeAdvanceForTesting:completionHandler:",
        "_processStatisticsAndDataRecords:",
    ]

    fileprivate var respondsToITPTestingSelectors: Bool {
        Self.itpTestingSelectors.allSatisfy { responds(to: NSSelectorFromString($0)) }
    }

    private var itp: ITPTestingShim { unsafeBitCast(self, to: ITPTestingShim.self) }

    /// Without this, `fetchDataRecords` hides every non-http origin — which is
    /// every extension origin. Process-wide and one-way; no production code and
    /// no other suite reads data records, so it is called where it is needed.
    fileprivate static func allowWebsiteDataRecordsForAllOrigins() {
        guard let metaclass = WKWebsiteDataStore.self as AnyObject as? NSObjectProtocol else { return }
        let selector = NSSelectorFromString("_allowWebsiteDataRecordsForAllOrigins")
        guard metaclass.responds(to: selector) else { return }
        _ = metaclass.perform(selector)
    }

    fileprivate func setResourceLoadStatisticsEnabled(_ enabled: Bool) {
        itp.setResourceLoadStatisticsEnabled(enabled)
    }

    fileprivate func isPrevalentDomain(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            itp.getIsPrevalentDomain(url) { continuation.resume(returning: $0) }
        }
    }

    fileprivate func setPrevalentDomain(_ url: URL) async {
        await withCheckedContinuation { continuation in
            itp.setPrevalentDomain(url) { continuation.resume() }
        }
    }

    fileprivate func setResourceLoadStatisticsTimeAdvanceForTesting(_ time: TimeInterval) async {
        await withCheckedContinuation { continuation in
            itp.setResourceLoadStatisticsTimeAdvanceForTesting(time) { continuation.resume() }
        }
    }

    fileprivate func processStatisticsAndDataRecords() async {
        await withCheckedContinuation { continuation in
            itp.processStatisticsAndDataRecords { continuation.resume() }
        }
    }
}
