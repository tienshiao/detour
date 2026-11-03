import XCTest
import WebKit
import UserNotifications
@testable import Detour

/// TASK-234: from a real extension context, `notifications.clear` and
/// `notifications.update` called without awaiting the `notifications.create`
/// before them take effect.
///
/// These go through the production wiring (`Profile.extensionController`,
/// `Profile.loadExtensionContext`, the `ExtensionManager` delegate for the
/// worker transport), so both an extension page (`webkit.messageHandlers`) and
/// the service worker (`runtime.sendNativeMessage`) reach the profile's own
/// polyfill handler. The handler's manager is swapped for one around
/// `HeldNotificationCenter`, which holds every `add` until the test releases
/// it: the real center is never touched, and the test decides that the
/// `create` is still in flight when the `clear` or `update` arrives. The
/// orderings themselves are covered in `ExtensionNotificationManagerTests`.
///
/// TASK-238: the same extension loaded into two profiles — two persistent
/// ones, or a persistent one and the built-in Private profile — never sees,
/// clears or updates the other's notifications, from either transport, and a
/// click or close resolves only to the profile that created the notification.
/// Both profiles' handlers share one manager, as production's do (`shared`),
/// so what keeps them apart is the profile in each request's owner.
/// `ExtensionPolyfillIntegrationTests` cannot host these: its contexts are
/// built by hand on one controller, served by one handler for one profile,
/// so it has no second profile to load the extension into.
nonisolated final class ExtensionNotificationOrderingTests: XCTestCase {

    // MARK: - Fixture bookkeeping

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var openWebViews: [WKWebView] = []
    private var centers: [HeldNotificationCenter] = []
    /// Handlers whose manager a test swapped, set back to the shared one in
    /// tearDown — the built-in Private profile's outlives the test.
    private var overriddenHandlers: [ExtensionPolyfillHandler] = []
    /// Extensions loaded into the built-in Private profile, which tearDown
    /// unloads but does not delete.
    private var privateLoadedExtensionIDs: [String] = []
    /// Extensions saved in the shared database (for their Private row).
    private var databaseExtensionIDs: [String] = []
    /// Private windows' spaces a test opened in the shared store; tearDown
    /// removes any still there, which ends the Private session.
    private var incognitoSpaceIDs: [UUID] = []
    private var previousLastActiveSpaceID: UUID?

    /// Profiles whose extension controller hosted a web view are kept alive for
    /// the rest of the test process: releasing one takes its process pool down
    /// with it, and WebKit traps when that happens inside an IPC dispatch (see
    /// `ExtensionPrivateStoreTests`).
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
    }

    @MainActor override func tearDown() async throws {
        // A failed test can leave an add held; answer it so its task finishes.
        for center in centers { center.releaseAll() }
        centers.removeAll()
        for id in incognitoSpaceIDs { TabStore.shared.removeIncognitoSpace(id: id) }
        incognitoSpaceIDs.removeAll()
        for webView in openWebViews {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        openWebViews.removeAll()
        let privateProfile = TabStore.shared.profiles.first { $0.id == TabStore.incognitoProfileID }
        for id in privateLoadedExtensionIDs { _ = privateProfile?.unloadExtension(id: id) }
        privateLoadedExtensionIDs.removeAll()
        // The row's deletion cascades to its `profileExtension` rows.
        for id in databaseExtensionIDs { AppDatabase.shared.deleteExtension(id: id) }
        databaseExtensionIDs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        // After the unloads, so the notifications they take away are the test
        // manager's, never the shared one's.
        for handler in overriddenHandlers { handler.notificationManagerOverride = nil }
        overriddenHandlers.removeAll()
        for id in createdSpaceIDs {
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
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The orderings under test, run the same way from the page and the worker.
    /// No call is awaited before the next one is made.
    private static let raceJS = """
    async function notificationRace(mode, id) {
        const options = (title) => ({ type: 'basic', title: title, message: 'ordering test' });
        const out = { mode: mode };
        if (mode === 'clear') {
            const created = chrome.notifications.create(id, options('Hello'));
            const cleared = chrome.notifications.clear(id);
            out.cleared = await cleared;
            out.createdID = await created;
        } else if (mode === 'update') {
            const created = chrome.notifications.create(id, options('Before'));
            const updated = chrome.notifications.update(id, options('After'));
            out.createdID = await created;
            out.updated = await updated;
        } else if (mode === 'clearCallback') {
            const created = chrome.notifications.create(id, options('Hello'));
            out.cleared = await new Promise((resolve) => chrome.notifications.clear(id, (wasCleared) => {
                out.lastError = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
                resolve(wasCleared);
            }));
            out.createdID = await created;
        } else if (mode === 'clearThenCreate') {
            const first = chrome.notifications.create(id, options('First'));
            const cleared = chrome.notifications.clear(id);
            const second = chrome.notifications.create(id, options('Second'));
            out.cleared = await cleared;
            out.createdID = await first;
            out.secondID = await second;
        } else {
            throw new Error('unknown mode ' + mode);
        }
        out.all = await chrome.notifications.getAll();
        return out;
    }
    """

    /// The worker: the polyfill (a test loads the context straight into the
    /// profile, so nothing has prepended it the way an install does), the
    /// orderings, and a listener that runs one and answers with its outcome.
    /// One call, for the isolation tests: what the extension asked and what it
    /// was answered, run the same way from the page and the worker.
    private static let opJS = """
    async function notificationOp(op, id, title) {
        const options = { type: 'basic', title: title || '', message: 'isolation test' };
        if (op === 'create') { return { result: await chrome.notifications.create(id, options) }; }
        if (op === 'createNullID') { return { result: await chrome.notifications.create(null, options) }; }
        if (op === 'update') { return { result: await chrome.notifications.update(id, options) }; }
        if (op === 'clear') { return { result: await chrome.notifications.clear(id) }; }
        if (op === 'getAll') { return { result: await chrome.notifications.getAll() }; }
        throw new Error('unknown op ' + op);
    }
    """

    /// What `clear` answers, and what `update` merges, in the promise and the
    /// callback forms (TASK-240). Run the same way from the page and the
    /// worker, with the center answering every add at once.
    private static let answersJS = """
    async function notificationAnswers(prefix) {
        const options = { type: 'basic', title: 'Kept title', message: 'First', contextMessage: 'Context',
                          iconUrl: 'icon.png' };
        const viaCallback = (call) => new Promise((resolve) => call((answer) => resolve({
            answer: answer,
            lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
        })));
        const out = {};
        out.promiseMissing = await chrome.notifications.clear(prefix + 'missing');
        await chrome.notifications.create(prefix + 'p', options);
        out.promiseUpdated = await chrome.notifications.update(prefix + 'p', { message: 'Second' });
        out.promiseExisting = await chrome.notifications.clear(prefix + 'p');
        out.promiseAgain = await chrome.notifications.clear(prefix + 'p');
        out.callbackMissing = await viaCallback((cb) => chrome.notifications.clear(prefix + 'missing', cb));
        await chrome.notifications.create(prefix + 'c', options);
        out.callbackUpdated = await viaCallback(
            (cb) => chrome.notifications.update(prefix + 'c', { message: 'Third' }, cb));
        out.callbackExisting = await viaCallback((cb) => chrome.notifications.clear(prefix + 'c', cb));
        out.callbackAgain = await viaCallback((cb) => chrome.notifications.clear(prefix + 'c', cb));
        const rejection = (promise) => promise.then(
            (value) => ({ resolved: value === undefined ? null : value }),
            (e) => ({ rejected: String(e && e.message ? e.message : e) }));
        out.promiseClearNoID = await rejection(chrome.notifications.clear());
        out.promiseUpdateNoID = await rejection(chrome.notifications.update(undefined, { message: 'x' }));
        out.callbackClearNoID = await viaCallback((cb) => chrome.notifications.clear(undefined, cb));
        out.callbackUpdateNoID = await viaCallback(
            (cb) => chrome.notifications.update(undefined, { message: 'x' }, cb));
        return out;
    }
    """

    /// What the extension can see of the API, and what a request made past
    /// the namespace — straight to the polyfill's transport — is answered, for
    /// the permission gate (TASK-239). Run the same way from the page and the
    /// worker.
    private static let gateJS = """
    async function notificationGate(id) {
        const out = {
            chrome: typeof chrome.notifications,
            browser: typeof browser === 'undefined' ? 'no browser' : typeof browser.notifications,
            diag: __detourPolyfillDiag.apis.notifications
        };
        try {
            const reply = await globalThis.__detourPolyfillRequest('notifications.create', {
                notificationId: id,
                options: { type: 'basic', title: 'Gate', message: 'gate test' }
            });
            out.direct = { resolved: reply };
        } catch (e) {
            out.direct = { rejected: String(e && e.message ? e.message : e) };
        }
        return out;
    }
    """

    @MainActor private static let workerJS = ExtensionAPIPolyfill.polyfillJS + "\n" + raceJS + "\n" + opJS + "\n" + gateJS + "\n" + answersJS + """

    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
        if (message.type === 'notificationRace') {
            notificationRace(message.mode, message.id).then(
                (outcome) => sendResponse(outcome),
                (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            return true;
        }
        if (message.type === 'notificationAnswers') {
            notificationAnswers(message.prefix).then(
                (outcome) => sendResponse(outcome),
                (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            return true;
        }
        if (message.type === 'notificationGate') {
            notificationGate(message.id).then(
                (outcome) => sendResponse(outcome),
                (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            return true;
        }
        if (message.type === 'notificationOp') {
            notificationOp(message.op, message.id, message.title).then(
                (outcome) => sendResponse(outcome),
                (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            return true;
        }
        return false;
    });
    """

    /// An extension with the polyfill in its worker, declaring `permissions`.
    @MainActor private func makeExtension(permissions: [String] = ["notifications"],
                                          optionalPermissions: [String] = []) async throws -> WebExtension {
        let id = "notif-ordering-\(UUID().uuidString.prefix(8))"
        let permissionsJSON = String(decoding: try JSONSerialization.data(withJSONObject: permissions), as: UTF8.self)
        let optionalJSON = String(decoding: try JSONSerialization.data(withJSONObject: optionalPermissions),
                                  as: UTF8.self)
        let ext = try await makeTestExtension(
            id: id,
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Notification Ordering Test",
                "version": "1.0.0",
                "permissions": \(permissionsJSON),
                "optional_permissions": \(optionalJSON),
                "background": { "service_worker": "background.js", "type": "module" }
            }
            """,
            files: [
                "background.js": Self.workerJS,
                "test.html": "<html><body><div id=\"test\">notification ordering page</div></body></html>",
            ])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    /// A manager around a held center, to hand to one or more profiles.
    @MainActor private func makeManager() -> (manager: ExtensionNotificationManager, center: HeldNotificationCenter) {
        let center = HeldNotificationCenter()
        centers.append(center)
        return (ExtensionNotificationManager(center: center), center)
    }

    /// Builds `profile`'s extension controller, and with it the polyfill
    /// handler, and points the handler at `manager`.
    @MainActor private func use(_ manager: ExtensionNotificationManager, in profile: Profile) throws {
        _ = profile.extensionController
        let handler = try XCTUnwrap(profile.polyfillHandler, "extensionController must build a polyfill handler")
        handler.notificationManagerOverride = manager
        overriddenHandlers.append(handler)
    }

    /// A persistent profile with one space, its handler on `manager`.
    @MainActor private func makeProfile(_ name: String, manager: ExtensionNotificationManager) throws -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        let space = TabStore.shared.addSpace(name: "\(name) Space", emoji: "N", colorHex: "#000000",
                                             profileID: profile.id)
        createdSpaceIDs.append(space.id)
        ExtensionManager.shared.lastActiveSpaceID = space.id
        try use(manager, in: profile)
        return profile
    }

    /// A persistent profile whose handler's notification manager runs on a
    /// held center of its own.
    @MainActor private func makeProfile(_ name: String) throws -> (profile: Profile, center: HeldNotificationCenter) {
        let (manager, center) = makeManager()
        return (try makeProfile(name, manager: manager), center)
    }

    /// The built-in Private profile with `ext` allowed in it — installed, with
    /// its Private `profileExtension` row on, as "Allow in Private" leaves it —
    /// and its handler on `manager`. tearDown unloads the context and deletes
    /// the row; the profile itself stays, as it does in the app.
    @MainActor private func privateProfile(allowing ext: WebExtension,
                                           manager: ExtensionNotificationManager) throws -> Profile {
        let profile = TabStore.shared.ensureIncognitoProfile()
        XCTAssertTrue(profile.isIncognito)
        installTestExtension(ext, in: AppDatabase.shared,
                             manifestJSON: (try? testExtensionManifestData(ext)) ?? Data("{}".utf8))
        databaseExtensionIDs.append(ext.id)
        // The row's foreign key wants the Private profile's own row first.
        AppDatabase.shared.saveProfile(profile.toRecord())
        AppDatabase.shared.setProfileExtensionEnabled(
            extensionID: ext.id, profileID: TabStore.incognitoProfileID.uuidString, enabled: true)
        XCTAssertTrue(AppDatabase.shared.isExtensionEnabled(extensionID: ext.id, profileID: profile.id.uuidString),
                      "precondition: the extension is allowed in Private")
        privateLoadedExtensionIDs.append(ext.id)
        try use(manager, in: profile)
        return profile
    }

    /// The extension loaded into `profile`, an extension page of it, and its
    /// worker awake.
    @MainActor private func loadPage(_ ext: WebExtension, in profile: Profile) async throws -> WKWebView {
        let context = try loadTestContext(ext, in: profile)
        if profile.isIncognito {
            XCTAssertTrue(context.hasAccessToPrivateData, "precondition: a Private-profile context")
        }
        let config = try XCTUnwrap(context.webViewConfiguration,
                                   "webViewConfiguration is nil — context not loaded in a controller")
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        openWebViews.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        context.loadBackgroundContent { error in
            if let error { print("notification ordering: loadBackgroundContent failed: \(error)") }
        }
        try await waitUntil("the background worker of \(profile.name) to wake", timeout: 30) {
            let ping = try await askWorker(from: page, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }
        return page
    }

    private enum Transport: String {
        case page, worker
    }

    /// Runs one ordering from `transport`. Once the center holds an add for
    /// each of `heldTitles` and has seen `removals` removals — so every call
    /// the ordering makes has arrived while the first create is still in
    /// flight — releases the held adds in call order and returns what the
    /// extension saw. Whether the first create's own add is among them
    /// depends on timing: a clear or update that arrives while it still waits
    /// for authorization means it never adds (TASK-253), so only the adds the
    /// ordering always makes are waited for.
    @MainActor private func race(_ mode: String, id: String, via transport: Transport, in page: WKWebView,
                                 center: HeldNotificationCenter, heldTitles: [String], removals: Int,
                                 file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let removalsBefore = center.removals.count
        // Both legs hand back JSON text: a task's result has to be Sendable.
        let outcome: Task<String?, any Error>
        switch transport {
        case .page:
            let js = Self.raceJS + "\nreturn JSON.stringify(await notificationRace(mode, id));"
            outcome = Task {
                try await page.callAsyncJavaScript(js, arguments: ["mode": mode, "id": id],
                                                   contentWorld: .page) as? String
            }
        case .worker:
            outcome = Task {
                let envelope = try await askWorker(
                    from: page, message: ["type": "notificationRace", "mode": mode, "id": id], timeout: 20)
                return String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
            }
        }
        try await waitUntil("\(transport) \(mode): adds \(heldTitles) held and \(removals) removal(s)",
                            timeout: 10, pollInterval: 0.02, file: file, line: line) {
            Set(heldTitles).isSubset(of: center.heldTitles)
                && center.removals.count - removalsBefore >= removals
        }
        center.releaseAll()
        let answered = try await outcome.value
        let json = try XCTUnwrap(answered, "\(transport) \(mode) answered nothing", file: file, line: line)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                                   "not an object: \(json)", file: file, line: line)
        switch transport {
        case .page:
            return object
        case .worker:
            XCTAssertTrue(object["lastError"] is NSNull || object["lastError"] == nil,
                          "the page could not reach the worker: \(object)", file: file, line: line)
            return try XCTUnwrap(object["reply"] as? [String: Any], "the worker must answer: \(object)",
                                 file: file, line: line)
        }
    }

    /// One `notifications` call from `transport`, answering what the extension
    /// was told. The center must not be holding adds.
    @MainActor private func call(_ op: String, _ id: String = "", title: String = "", via transport: Transport,
                                 in page: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws -> Any? {
        let object: [String: Any]
        switch transport {
        case .page:
            let js = Self.opJS + "\nreturn JSON.stringify(await notificationOp(op, id, title));"
            let json = try await page.callAsyncJavaScript(js, arguments: ["op": op, "id": id, "title": title],
                                                          contentWorld: .page) as? String
            object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any],
                                   file: file, line: line)
        case .worker:
            let envelope = try await askWorker(
                from: page, message: ["type": "notificationOp", "op": op, "id": id, "title": title], timeout: 20)
            XCTAssertTrue(envelope["lastError"] is NSNull || envelope["lastError"] == nil,
                          "the page could not reach the worker: \(envelope)", file: file, line: line)
            object = try XCTUnwrap(envelope["reply"] as? [String: Any], "the worker must answer: \(envelope)",
                                   file: file, line: line)
        }
        XCTAssertNil(object["error"], "\(transport) \(op) \(id): \(object)", file: file, line: line)
        return object["result"]
    }

    /// The ids `getAll` lists from `transport` that start with `prefix`.
    @MainActor private func listed(_ prefix: String, via transport: Transport, in page: WKWebView,
                                   file: StaticString = #filePath, line: UInt = #line) async throws -> [String] {
        let all = try await call("getAll", via: transport, in: page, file: file, line: line) as? [String: Any]
        return (all ?? [:]).keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// The identifier `ext`'s notification `id` in `profile` is shown under.
    /// Identifiers are opaque, so only the profile's manager knows it, and
    /// only while the notification exists.
    @MainActor private func identifier(_ id: String, of ext: WebExtension, in profile: Profile) -> String {
        profile.polyfillHandler?.notificationManagerOverride?.identifier(
            for: .init(profileID: profile.id, extensionID: ext.id), notificationID: id) ?? "no notification \(id)"
    }

    /// From `transport`, `owner` creates two notifications and `other` — the
    /// same extension in another profile — tries to see, update and clear
    /// them, then creates and clears one with the same id as one of `owner`'s.
    @MainActor private func assertIsolated(_ ext: WebExtension, owner: (profile: Profile, page: WKWebView),
                                           other: (profile: Profile, page: WKWebView),
                                           center: HeldNotificationCenter, via transport: Transport,
                                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let label = "\(transport) \(owner.profile.name) vs \(other.profile.name)"
        let prefix = "iso-\(transport)-\(owner.profile.id.uuidString.prefix(8))-"
        let shared = prefix + "shared", ownerOnly = prefix + "owner-only"
        _ = try await call("create", shared, title: "Owner", via: transport, in: owner.page, file: file, line: line)
        _ = try await call("create", ownerOnly, title: "Owner only", via: transport, in: owner.page,
                           file: file, line: line)
        let ownerShared = identifier(shared, of: ext, in: owner.profile)
        let ownerOnlyID = identifier(ownerOnly, of: ext, in: owner.profile)
        var ownerListed = try await listed(prefix, via: transport, in: owner.page, file: file, line: line)
        XCTAssertEqual(ownerListed, [ownerOnly, shared].sorted(), label, file: file, line: line)

        var otherListed = try await listed(prefix, via: transport, in: other.page, file: file, line: line)
        XCTAssertEqual(otherListed, [], "\(label): getAll must not list the other profile's notifications",
                       file: file, line: line)

        let updated = try await call("update", ownerOnly, title: "Hijacked", via: transport, in: other.page,
                                     file: file, line: line)
        XCTAssertEqual(updated as? Bool, false, "\(label): no such notification in this profile",
                       file: file, line: line)
        XCTAssertEqual(center.shown[ownerOnlyID], "Owner only", "\(label): the update must not apply",
                       file: file, line: line)

        let clearedByOther = try await call("clear", ownerOnly, via: transport, in: other.page,
                                            file: file, line: line)
        XCTAssertEqual(clearedByOther as? Bool, false, "\(label): no such notification in this profile (TASK-240)",
                       file: file, line: line)
        XCTAssertEqual(center.shown[ownerOnlyID], "Owner only", "\(label): the clear must not remove it",
                       file: file, line: line)

        _ = try await call("create", shared, title: "Other", via: transport, in: other.page, file: file, line: line)
        XCTAssertEqual(center.shown[ownerShared], "Owner", "\(label): the same id must not replace the banner",
                       file: file, line: line)
        XCTAssertEqual(center.shown[identifier(shared, of: ext, in: other.profile)], "Other", label,
                       file: file, line: line)
        otherListed = try await listed(prefix, via: transport, in: other.page, file: file, line: line)
        XCTAssertEqual(otherListed, [shared], label, file: file, line: line)

        let clearedOwnCopy = try await call("clear", shared, via: transport, in: other.page,
                                            file: file, line: line)
        XCTAssertEqual(clearedOwnCopy as? Bool, true, "\(label): its own copy existed", file: file, line: line)
        XCTAssertEqual(center.shown[ownerShared], "Owner", "\(label): clearing its own copy leaves the owner's",
                       file: file, line: line)

        ownerListed = try await listed(prefix, via: transport, in: owner.page, file: file, line: line)
        XCTAssertEqual(ownerListed, [ownerOnly, shared].sorted(), "\(label): the owner still has both",
                       file: file, line: line)
        XCTAssertFalse(center.removals.contains(ownerShared) || center.removals.contains(ownerOnlyID),
                       "\(label): nothing the other profile did removed the owner's notifications",
                       file: file, line: line)
    }

    @MainActor private func listed(_ outcome: [String: Any]) -> [String] {
        ((outcome["all"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    // MARK: - Tests

    @MainActor func testClearWhileCreateInFlightTakesEffect() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Ordering Clear")
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let id = "clear-\(transport)"
            let outcome = try await race("clear", id: id, via: transport, in: page, center: center,
                                         heldTitles: [], removals: 1)
            XCTAssertNil(outcome["error"], "\(transport): \(outcome)")
            XCTAssertEqual(outcome["createdID"] as? String, id, "\(transport): create still answers its id")
            XCTAssertEqual(outcome["cleared"] as? Bool, true, "\(transport)")
            XCTAssertEqual(listed(outcome), [], "\(transport): getAll must not list a cleared notification")
            XCTAssertTrue(center.shown.isEmpty, "\(transport): the notification must not stay on screen")
        }
    }

    /// The callback form of `clear` answers true for a notification whose
    /// create is still in flight, without a `runtime.lastError` (TASK-240).
    @MainActor func testClearCallbackWhileCreateInFlightAnswersTrue() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Ordering Clear Callback")
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let id = "clear-cb-\(transport)"
            let outcome = try await race("clearCallback", id: id, via: transport, in: page, center: center,
                                         heldTitles: [], removals: 1)
            XCTAssertNil(outcome["error"], "\(transport): \(outcome)")
            XCTAssertEqual(outcome["cleared"] as? Bool, true, "\(transport): in flight counts as existing")
            XCTAssertTrue(outcome["lastError"] is NSNull, "\(transport): \(outcome)")
            XCTAssertEqual(outcome["createdID"] as? String, id, "\(transport)")
            XCTAssertEqual(listed(outcome), [], "\(transport)")
        }
    }

    /// `clear` answers whether the notification existed and `update` merges
    /// into it, in the promise and the callback forms, from the page and the
    /// worker (TASK-240).
    @MainActor func testClearAnswersAndUpdateMergesFromBothTransports() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Answers")
        center.holdsAdds = false
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let prefix = "answers-\(transport)-"
            let requestsBefore = center.addedRequests.count
            let object: [String: Any]
            switch transport {
            case .page:
                let js = Self.answersJS + "\nreturn JSON.stringify(await notificationAnswers(prefix));"
                let json = try await page.callAsyncJavaScript(js, arguments: ["prefix": prefix],
                                                              contentWorld: .page) as? String
                object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any])
            case .worker:
                let envelope = try await askWorker(
                    from: page, message: ["type": "notificationAnswers", "prefix": prefix], timeout: 20)
                XCTAssertTrue(envelope["lastError"] is NSNull || envelope["lastError"] == nil, "\(envelope)")
                object = try XCTUnwrap(envelope["reply"] as? [String: Any], "the worker must answer: \(envelope)")
            }
            let label = "\(transport)"
            XCTAssertNil(object["error"], "\(label): \(object)")
            XCTAssertEqual(object["promiseMissing"] as? Bool, false, "\(label): \(object)")
            XCTAssertEqual(object["promiseUpdated"] as? Bool, true, label)
            XCTAssertEqual(object["promiseExisting"] as? Bool, true, label)
            XCTAssertEqual(object["promiseAgain"] as? Bool, false, "\(label): already cleared")
            for key in ["callbackMissing", "callbackUpdated", "callbackExisting", "callbackAgain"] {
                let answer = try XCTUnwrap(object[key] as? [String: Any], "\(label) \(key): \(object)")
                XCTAssertTrue(answer["lastError"] is NSNull, "\(label) \(key): no lastError: \(answer)")
            }
            XCTAssertEqual((object["callbackMissing"] as? [String: Any])?["answer"] as? Bool, false, label)
            XCTAssertEqual((object["callbackUpdated"] as? [String: Any])?["answer"] as? Bool, true, label)
            XCTAssertEqual((object["callbackExisting"] as? [String: Any])?["answer"] as? Bool, true, label)
            XCTAssertEqual((object["callbackAgain"] as? [String: Any])?["answer"] as? Bool, false, label)

            // Without a notification id: the promise rejects and the callback
            // gets runtime.lastError, with the handler's text on every leg
            // (no WebKit "Invalid call to runtime.sendNativeMessage()."
            // prefix since TASK-255).
            for key in ["promiseClearNoID", "promiseUpdateNoID"] {
                let outcome = try XCTUnwrap(object[key] as? [String: Any], "\(label) \(key): \(object)")
                let message = try XCTUnwrap(outcome["rejected"] as? String, "\(label) \(key): \(outcome)")
                XCTAssertEqual(message, "notificationId required", "\(label) \(key)")
            }
            for key in ["callbackClearNoID", "callbackUpdateNoID"] {
                let outcome = try XCTUnwrap(object[key] as? [String: Any], "\(label) \(key): \(object)")
                let message = try XCTUnwrap(outcome["lastError"] as? String, "\(label) \(key): \(outcome)")
                XCTAssertEqual(message, "notificationId required", "\(label) \(key)")
            }

            // create p, update p, create c, update c: each update kept the
            // title and context message and changed only the message.
            let requests = Array(center.addedRequests.dropFirst(requestsBefore))
            XCTAssertEqual(requests.map(\.content.body), ["First", "Second", "First", "Third"], label)
            XCTAssertEqual(Set(requests.map(\.content.title)), ["Kept title"], label)
            XCTAssertEqual(Set(requests.map(\.content.subtitle)), ["Context"],
                           "\(label): contextMessage is the subtitle, never the icon URL")
            XCTAssertTrue(center.shown.isEmpty, "\(label): every notification was cleared")
        }
    }

    /// create(null, options) treats the null id as absent: the options are
    /// used and an id is generated (TASK-254), from the page and the worker.
    @MainActor func testCreateWithANullIDUsesTheOptionsFromBothTransports() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Null ID")
        center.holdsAdds = false
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let title = "Null id \(transport)"
            let id = try await call("createNullID", title: title, via: transport, in: page) as? String
            let generated = try XCTUnwrap(id, "\(transport): create answers an id")
            XCTAssertFalse(generated.isEmpty, "\(transport): a generated id")
            XCTAssertEqual(center.addedRequests.last?.content.title, title, "\(transport): the given options show")
            XCTAssertEqual(center.shown[identifier(generated, of: ext, in: profile)], title, "\(transport)")
            let all = try await call("getAll", via: transport, in: page) as? [String: Any]
            XCTAssertNotNil(all?[generated], "\(transport): getAll lists it: \(all ?? [:])")
        }
    }

    @MainActor func testUpdateWhileCreateInFlightTakesEffect() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Ordering Update")
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let id = "update-\(transport)"
            let outcome = try await race("update", id: id, via: transport, in: page, center: center,
                                         heldTitles: ["After"], removals: 0)
            XCTAssertNil(outcome["error"], "\(transport): \(outcome)")
            XCTAssertEqual(outcome["updated"] as? Bool, true,
                           "\(transport): the notification being created exists, so the update applies")
            XCTAssertTrue(listed(outcome).contains(id), "\(transport): \(listed(outcome))")
            XCTAssertEqual(center.shown[identifier(id, of: ext, in: profile)], "After", "\(transport): the update's content shows")
        }
    }

    @MainActor func testCreateClearCreateShowsTheSecondNotification() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Ordering Recreate")
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let id = "again-\(transport)"
            let outcome = try await race("clearThenCreate", id: id, via: transport, in: page, center: center,
                                         heldTitles: ["Second"], removals: 1)
            XCTAssertNil(outcome["error"], "\(transport): \(outcome)")
            XCTAssertEqual(outcome["cleared"] as? Bool, true, "\(transport)")
            XCTAssertEqual(outcome["secondID"] as? String, id, "\(transport)")
            XCTAssertTrue(listed(outcome).contains(id), "\(transport): the second create stands: \(listed(outcome))")
            XCTAssertEqual(center.shown[identifier(id, of: ext, in: profile)], "Second", "\(transport)")
        }
    }

    /// Another extension in the same profile clearing the same notification id
    /// while this one's create is in flight cancels nothing.
    @MainActor func testAnotherExtensionsClearDoesNotCancelTheCreate() async throws {
        let extA = try await makeExtension()
        let extB = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Ordering Isolation")
        let pageA = try await loadPage(extA, in: profile)
        let pageB = try await loadPage(extB, in: profile)

        let created = Task {
            try await pageA.callAsyncJavaScript(
                "return await chrome.notifications.create('shared-id', { type: 'basic', title: 'A', message: 'm' });",
                arguments: [:], contentWorld: .page) as? String
        }
        try await waitUntil("A's add held", timeout: 10, pollInterval: 0.02) { center.heldCount == 1 }
        let clearedByB = try await pageB.callAsyncJavaScript(
            "return await chrome.notifications.clear('shared-id');", arguments: [:], contentWorld: .page)
        XCTAssertEqual(clearedByB as? Bool, false, "B has no notification shared-id (TASK-240)")
        XCTAssertEqual(center.removals, [], "B has no such notification, so its clear takes nothing away")

        center.releaseAll()
        let createdID = try await created.value
        XCTAssertEqual(createdID, "shared-id")
        let listedForA = try await pageA.callAsyncJavaScript(
            "return JSON.stringify(await chrome.notifications.getAll());", arguments: [:], contentWorld: .page)
        XCTAssertEqual(listedForA as? String, #"{"shared-id":true}"#)
        let listedForB = try await pageB.callAsyncJavaScript(
            "return JSON.stringify(await chrome.notifications.getAll());", arguments: [:], contentWorld: .page)
        XCTAssertEqual(listedForB as? String, "{}")
        XCTAssertEqual(center.shown[identifier("shared-id", of: extA, in: profile)], "A")
    }

    // MARK: - Permission gate (TASK-239)

    /// `notificationGate` from `transport`.
    @MainActor private func gate(_ id: String, via transport: Transport, in page: WKWebView,
                                 file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let object: [String: Any]
        switch transport {
        case .page:
            let js = Self.gateJS + "\nreturn JSON.stringify(await notificationGate(id));"
            let json = try await page.callAsyncJavaScript(js, arguments: ["id": id], contentWorld: .page) as? String
            object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any],
                                   file: file, line: line)
        case .worker:
            let envelope = try await askWorker(
                from: page, message: ["type": "notificationGate", "id": id], timeout: 20)
            XCTAssertTrue(envelope["lastError"] is NSNull || envelope["lastError"] == nil,
                          "the page could not reach the worker: \(envelope)", file: file, line: line)
            object = try XCTUnwrap(envelope["reply"] as? [String: Any], "the worker must answer: \(envelope)",
                                   file: file, line: line)
        }
        XCTAssertNil(object["error"], "\(transport): \(object)", file: file, line: line)
        return object
    }

    /// NEGATIVE: an extension that does not declare `notifications` gets no
    /// `chrome.notifications` or `browser.notifications` in its page or its
    /// worker, and a request it makes past the namespace is refused before
    /// anything is shown. A worker's refusal crosses
    /// `runtime.sendNativeMessage`, which rewrites the text, so it is matched
    /// as a substring, ignoring case.
    @MainActor func testWithoutThePermissionThereIsNoNotificationsAPI() async throws {
        let ext = try await makeExtension(permissions: ["storage"])
        let (profile, center) = try makeProfile("Notification Gate Denied")
        center.holdsAdds = false
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let outcome = try await gate("gate-\(transport)", via: transport, in: page)
            XCTAssertEqual(outcome["chrome"] as? String, "undefined", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["browser"] as? String, "undefined", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["diag"] as? String, "absent", "\(transport): \(outcome)")
            let direct = try XCTUnwrap(outcome["direct"] as? [String: Any], "\(transport): \(outcome)")
            XCTAssertNil(direct["resolved"], "\(transport): the request must be refused: \(outcome)")
            let rejected = try XCTUnwrap(direct["rejected"] as? String, "\(transport): \(outcome)")
            XCTAssertEqual(rejected, "notifications permission not declared", "\(transport)")
        }
        XCTAssertTrue(center.addedIdentifiers.isEmpty, "nothing was shown")
    }

    /// POSITIVE: an extension that declares `notifications` gets Detour's
    /// namespace under both names in its page and its worker, and its
    /// requests are served.
    @MainActor func testWithThePermissionTheNotificationsAPIIsThere() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Gate Allowed")
        center.holdsAdds = false
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let id = "gate-\(transport)"
            let outcome = try await gate(id, via: transport, in: page)
            XCTAssertEqual(outcome["chrome"] as? String, "object", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["browser"] as? String, "object", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["diag"] as? String, "function", "\(transport): \(outcome)")
            let direct = try XCTUnwrap(outcome["direct"] as? [String: Any], "\(transport): \(outcome)")
            XCTAssertEqual((direct["resolved"] as? [String: Any])?["notificationId"] as? String, id,
                           "\(transport): \(outcome)")
            let created = try await call("create", "\(id)-api", title: "Through the API", via: transport, in: page)
            XCTAssertEqual(created as? String, "\(id)-api", "\(transport)")
        }
        XCTAssertEqual(center.shown.values.sorted(), ["Gate", "Gate", "Through the API", "Through the API"])
    }

    // MARK: - Optional permission granted at runtime (TASK-250)

    /// `notificationGate` from both transports, refused or served. The
    /// namespace is there either way: an optional permission installs it at
    /// injection and the handler decides each call.
    @MainActor private func assertOptionalGate(served: Bool, _ label: String, in page: WKWebView,
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        for transport in [Transport.page, .worker] {
            let id = "optional-\(label.replacingOccurrences(of: " ", with: "-"))-\(transport)"
            let outcome = try await gate(id, via: transport, in: page, file: file, line: line)
            let where_ = "\(label), \(transport): \(outcome)"
            XCTAssertEqual(outcome["chrome"] as? String, "object", where_, file: file, line: line)
            XCTAssertEqual(outcome["browser"] as? String, "object", where_, file: file, line: line)
            let direct = try XCTUnwrap(outcome["direct"] as? [String: Any], where_, file: file, line: line)
            if served {
                XCTAssertEqual((direct["resolved"] as? [String: Any])?["notificationId"] as? String, id,
                               where_, file: file, line: line)
            } else {
                XCTAssertNil(direct["resolved"], "must be refused: \(where_)", file: file, line: line)
                XCTAssertEqual(direct["rejected"] as? String, "notifications permission not declared",
                               where_, file: file, line: line)
            }
        }
    }

    /// NEGATIVE, POSITIVE, NEGATIVE in one running context: an optional
    /// `notifications` is refused until granted, served by the same page and
    /// worker once the grant lands (through `setPermissionDecision`, the
    /// Settings path, which a test can script; WebKit's own
    /// `permissions.request` prompt grants the same context entry), and
    /// refused again after the extension gives it up with
    /// `chrome.permissions.remove`.
    @MainActor func testOptionalNotificationsFollowTheGrantAndPermissionsRemove() async throws {
        let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["notifications"])
        let (profile, center) = try makeProfile("Optional Notifications Live")
        center.holdsAdds = false
        installTestExtension(ext, in: AppDatabase.shared)
        databaseExtensionIDs.append(ext.id)
        let page = try await loadPage(ext, in: profile)

        try await assertOptionalGate(served: false, "before", in: page)
        XCTAssertTrue(center.addedIdentifiers.isEmpty, "nothing is shown before the grant")

        ExtensionManager.shared.setPermissionDecision(
            extensionID: ext.id, key: "notifications", type: .apiPermission, granted: true)
        try await assertOptionalGate(served: true, "granted", in: page)
        XCTAssertEqual(center.addedIdentifiers.count, 2, "one from each transport")

        let removed = try await page.callAsyncJavaScript("""
            const removed = await chrome.permissions.remove({ permissions: ['notifications'] });
            const still = await chrome.permissions.contains({ permissions: ['notifications'] });
            return JSON.stringify({ removed, still });
            """, arguments: [:], contentWorld: .page) as? String
        XCTAssertEqual(removed, #"{"removed":true,"still":false}"#)
        try await assertOptionalGate(served: false, "removed", in: page)
        XCTAssertEqual(center.addedIdentifiers.count, 2, "nothing more is shown after the removal")

        // TASK-258: the removal is saved, so a reloaded context stays refused.
        try await waitUntil("the saved notifications grant to be cleared") {
            AppDatabase.shared.permissionStatus(extensionID: ext.id, key: "notifications",
                                                type: .apiPermission) == nil
        }
        profile.unloadExtension(id: ext.id)
        try await assertOptionalGate(served: false, "after a reload", in: try await loadPage(ext, in: profile))
    }

    /// POSITIVE, new context: a saved grant of the optional permission is
    /// restored when the context loads, so a fresh page and worker are served.
    /// NEGATIVE: a saved denial is restored as a refusal.
    @MainActor func testSavedOptionalNotificationsDecisionIsAppliedToANewContext() async throws {
        for granted in [true, false] {
            let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["notifications"])
            installTestExtension(ext, in: AppDatabase.shared)
            databaseExtensionIDs.append(ext.id)
            AppDatabase.shared.savePermission(ExtensionPermissionRecord(
                extensionID: ext.id, key: "notifications", type: .apiPermission,
                status: granted ? .granted : .denied))
            let (profile, center) = try makeProfile("Optional Notifications Saved \(granted)")
            center.holdsAdds = false
            let page = try await loadPage(ext, in: profile)
            try await assertOptionalGate(served: granted, granted ? "saved grant" : "saved denial", in: page)
        }
    }

    // MARK: - Required permission switched off in Settings (TASK-259)

    /// POSITIVE, NEGATIVE, POSITIVE, NEGATIVE: a required `notifications` is
    /// served while its install-time grant stands, refused from the page and
    /// the worker once the Settings switch (`setPermissionDecision`) turns it
    /// off, served again once it is back on, and still refused after a context
    /// reload once switched off. Nothing is shown while it is off.
    @MainActor func testRequiredNotificationsFollowTheSettingsSwitch() async throws {
        let ext = try await makeExtension(permissions: ["notifications"])
        let (profile, center) = try makeProfile("Required Notifications Switch")
        center.holdsAdds = false
        installTestExtension(ext, in: AppDatabase.shared)
        databaseExtensionIDs.append(ext.id)
        // What install records for the manifest's permissions.
        AppDatabase.shared.savePermission(ExtensionPermissionRecord(
            extensionID: ext.id, key: "notifications", type: .apiPermission, status: .granted))
        let page = try await loadPage(ext, in: profile)

        try await assertOptionalGate(served: true, "install grant", in: page)
        XCTAssertEqual(center.addedIdentifiers.count, 2, "one from each transport")

        func setSwitch(_ on: Bool) {
            ExtensionManager.shared.setPermissionDecision(
                extensionID: ext.id, key: "notifications", type: .apiPermission, granted: on)
        }
        setSwitch(false)
        try await assertOptionalGate(served: false, "switched off", in: page)
        XCTAssertEqual(center.addedIdentifiers.count, 2, "nothing is shown while it is off")

        setSwitch(true)
        try await assertOptionalGate(served: true, "switched on again", in: page)
        XCTAssertEqual(center.addedIdentifiers.count, 4)

        setSwitch(false)
        profile.unloadExtension(id: ext.id)
        try await assertOptionalGate(served: false, "switched off, after a reload",
                                     in: try await loadPage(ext, in: profile))
        XCTAssertEqual(AppDatabase.shared.permissionStatus(extensionID: ext.id, key: "notifications",
                                                           type: .apiPermission), .denied)
    }

    // MARK: - Profile isolation (TASK-238)

    @MainActor func testTwoPersistentProfilesKeepTheirNotificationsApart() async throws {
        let ext = try await makeExtension()
        let (manager, center) = makeManager()
        center.holdsAdds = false
        let first = try makeProfile("Notification Isolation One", manager: manager)
        let second = try makeProfile("Notification Isolation Two", manager: manager)
        let firstPage = try await loadPage(ext, in: first)
        let secondPage = try await loadPage(ext, in: second)

        for transport in [Transport.page, .worker] {
            try await assertIsolated(ext, owner: (first, firstPage), other: (second, secondPage),
                                     center: center, via: transport)
            try await assertIsolated(ext, owner: (second, secondPage), other: (first, firstPage),
                                     center: center, via: transport)
        }
    }

    @MainActor func testPersistentAndPrivateProfilesKeepTheirNotificationsApart() async throws {
        let ext = try await makeExtension()
        let (manager, center) = makeManager()
        center.holdsAdds = false
        let persistent = try makeProfile("Notification Isolation Persistent", manager: manager)
        let privateProfile = try privateProfile(allowing: ext, manager: manager)
        let persistentPage = try await loadPage(ext, in: persistent)
        let privatePage = try await loadPage(ext, in: privateProfile)

        for transport in [Transport.page, .worker] {
            try await assertIsolated(ext, owner: (persistent, persistentPage), other: (privateProfile, privatePage),
                                     center: center, via: transport)
            try await assertIsolated(ext, owner: (privateProfile, privatePage), other: (persistent, persistentPage),
                                     center: center, via: transport)
        }
    }

    /// A click or close on a notification resolves to the profile that created
    /// it, and a close drops only that profile's entry. (Nothing delivers it to
    /// `onClicked` / `onClosed` yet; see `handleResponse`.)
    @MainActor func testResponsesResolveOnlyToTheCreatingProfile() async throws {
        let ext = try await makeExtension()
        let (manager, center) = makeManager()
        center.holdsAdds = false
        let persistent = try makeProfile("Notification Response Persistent", manager: manager)
        let privateProfile = try privateProfile(allowing: ext, manager: manager)
        let persistentPage = try await loadPage(ext, in: persistent)
        let privatePage = try await loadPage(ext, in: privateProfile)

        for transport in [Transport.page, .worker] {
            let id = "response-\(transport)"
            _ = try await call("create", id, title: "Persistent", via: transport, in: persistentPage)
            _ = try await call("create", id, title: "Private", via: transport, in: privatePage)

            let closed = manager.handleResponse(identifier: identifier(id, of: ext, in: persistent),
                                                action: UNNotificationDismissActionIdentifier)
            XCTAssertEqual(closed?.owner.profileID, persistent.id, "\(transport): the close is the persistent profile's")
            XCTAssertEqual(closed?.owner.extensionID, ext.id)
            XCTAssertEqual(closed?.notificationID, id)
            let persistentListed = try await listed(id, via: transport, in: persistentPage)
            XCTAssertEqual(persistentListed, [], "\(transport): the close drops the persistent profile's entry")
            var privateListed = try await listed(id, via: transport, in: privatePage)
            XCTAssertEqual(privateListed, [id], "\(transport): and leaves the Private one's")

            let clicked = manager.handleResponse(identifier: identifier(id, of: ext, in: privateProfile),
                                                 action: UNNotificationDefaultActionIdentifier)
            XCTAssertEqual(clicked, .init(owner: .init(profileID: TabStore.incognitoProfileID, extensionID: ext.id),
                                          notificationID: id, kind: .clicked), "\(transport)")

            // A notification a build before TASK-238 delivered carries no
            // profile and matches no entry.
            XCTAssertNil(manager.handleResponse(identifier: "\(ext.id):\(id)",
                                                action: UNNotificationDismissActionIdentifier))
            privateListed = try await listed(id, via: transport, in: privatePage)
            XCTAssertEqual(privateListed, [id], "\(transport)")
        }
    }

    // MARK: - Lifecycle (TASK-238)

    /// The Private profile's id is a constant and its extension contexts stay
    /// loaded between sessions, so when the last Private window closes its
    /// notifications go — from `getAll` and off screen — and the next Private
    /// session starts with none. The persistent profile's stay.
    @MainActor func testThePrivateSessionEndingTakesItsNotifications() async throws {
        let ext = try await makeExtension()
        let (manager, center) = makeManager()
        center.holdsAdds = false
        let persistent = try makeProfile("Notification Session Persistent", manager: manager)
        let privateProfile = try privateProfile(allowing: ext, manager: manager)
        let persistentPage = try await loadPage(ext, in: persistent)
        let privatePage = try await loadPage(ext, in: privateProfile)

        XCTAssertFalse(TabStore.shared.hasLivePrivateSession, "precondition: no Private session yet")
        let window = TabStore.shared.addIncognitoSpace()
        incognitoSpaceIDs.append(window.id)
        var privateIdentifiers: [String] = []
        for transport in [Transport.page, .worker] {
            let id = "session-\(transport)"
            _ = try await call("create", id, title: "Private", via: transport, in: privatePage)
            _ = try await call("create", id, title: "Persistent", via: transport, in: persistentPage)
            privateIdentifiers.append(identifier(id, of: ext, in: privateProfile))
        }
        let privateListed = try await listed("session-", via: .worker, in: privatePage)
        XCTAssertEqual(privateListed, ["session-page", "session-worker"], "precondition")

        TabStore.shared.removeIncognitoSpace(id: window.id)
        incognitoSpaceIDs.removeAll()
        XCTAssertFalse(TabStore.shared.hasLivePrivateSession)

        for transport in [Transport.page, .worker] {
            let privateAfter = try await listed("session-", via: transport, in: privatePage)
            XCTAssertEqual(privateAfter, [], "\(transport): the ended session's notifications are gone")
            let persistentAfter = try await listed("session-", via: transport, in: persistentPage)
            XCTAssertEqual(persistentAfter, ["session-page", "session-worker"], "\(transport)")
        }
        for identifier in privateIdentifiers {
            XCTAssertTrue(center.removals.contains(identifier), "taken off screen")
        }
        XCTAssertEqual(center.shown.values.sorted(), ["Persistent", "Persistent"])

        // The next session: the same ids are new notifications, under new
        // identifiers, and nothing of the last session's is listed.
        let next = TabStore.shared.addIncognitoSpace()
        incognitoSpaceIDs.append(next.id)
        _ = try await call("create", "session-page", title: "Next", via: .page, in: privatePage)
        XCTAssertFalse(privateIdentifiers.contains(identifier("session-page", of: ext, in: privateProfile)))
        let nextListed = try await listed("session-", via: .worker, in: privatePage)
        XCTAssertEqual(nextListed, ["session-page"])
    }

    /// Unloading the extension from one profile (as disabling it there does)
    /// takes its notifications in that profile, and leaves the same
    /// extension's in another profile.
    @MainActor func testUnloadingTheExtensionFromAProfileTakesItsNotifications() async throws {
        let ext = try await makeExtension()
        let (manager, center) = makeManager()
        center.holdsAdds = false
        let first = try makeProfile("Notification Unload One", manager: manager)
        let second = try makeProfile("Notification Unload Two", manager: manager)
        let firstPage = try await loadPage(ext, in: first)
        let secondPage = try await loadPage(ext, in: second)

        for transport in [Transport.page, .worker] {
            _ = try await call("create", "unload-\(transport)", title: "First", via: transport, in: firstPage)
            _ = try await call("create", "unload-\(transport)", title: "Second", via: transport, in: secondPage)
        }
        let firstIdentifiers = ["unload-page", "unload-worker"].map { identifier($0, of: ext, in: first) }

        XCTAssertNotNil(first.unloadExtension(id: ext.id), "precondition: the context was loaded")
        let firstOwner = ExtensionNotificationManager.Owner(profileID: first.id, extensionID: ext.id)
        XCTAssertEqual(manager.getAll(owner: firstOwner), [:])
        XCTAssertEqual(Set(center.removals), Set(firstIdentifiers))
        XCTAssertEqual(center.shown.values.sorted(), ["Second", "Second"])
        let secondListed = try await listed("unload-", via: .worker, in: secondPage)
        XCTAssertEqual(secondListed, ["unload-page", "unload-worker"])
    }

    /// With notifications denied (TASK-253), `create` from the page and the
    /// worker resolves with its id as Chrome's does when the OS blocks
    /// notifications, while nothing is shown, `getAll` does not list it, and
    /// `clear` and `update` answer false for it.
    @MainActor func testDeniedCreateAnswersItsIDFromBothTransportsAndIsNotListed() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Denied")
        center.holdsAdds = false
        center.authorization = .denied
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let id = "denied-\(transport)"
            let created = try await call("create", id, title: "Blocked", via: transport, in: page)
            XCTAssertEqual(created as? String, id, "\(transport): create succeeds silently with its id")
            let listedIDs = try await listed("denied-", via: transport, in: page)
            XCTAssertEqual(listedIDs, [], "\(transport)")
            let updated = try await call("update", id, title: "Still blocked", via: transport, in: page)
            XCTAssertEqual(updated as? Bool, false, "\(transport)")
            let cleared = try await call("clear", id, via: transport, in: page)
            XCTAssertEqual(cleared as? Bool, false, "\(transport)")
        }
        XCTAssertTrue(center.addedIdentifiers.isEmpty, "nothing reaches the center")
        XCTAssertEqual(center.authorizationRequests, 0, "a denied app is not prompted")
    }

    /// Not determined (TASK-253): the first `create`, from whichever
    /// transport, asks the user once; once allowed, it and every later one
    /// are shown and listed.
    @MainActor func testNotDeterminedCreateAsksOnceThenShowsFromBothTransports() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Not Determined")
        center.holdsAdds = false
        center.authorization = .notDetermined
        center.grantsAuthorization = true
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let id = "asked-\(transport)"
            let created = try await call("create", id, title: "Allowed", via: transport, in: page)
            XCTAssertEqual(created as? String, id, "\(transport)")
            XCTAssertEqual(center.shown[identifier(id, of: ext, in: profile)], "Allowed", "\(transport)")
            let listedIDs = try await listed("asked-\(transport)", via: transport, in: page)
            XCTAssertEqual(listedIDs, [id], "\(transport)")
        }
        XCTAssertEqual(center.authorizationRequests, 1, "the user is asked once, at the first create")
    }

    /// A request that reaches a handler whose profile has been released names
    /// no owner, so every `notifications.*` call is refused rather than acted
    /// on for nobody (TASK-238).
    @MainActor func testRequestsAfterTheProfileIsGoneAreRefused() async throws {
        let (manager, center) = makeManager()
        center.holdsAdds = false
        // Declares the permission, so what refuses the requests is the
        // missing profile, not the gate (TASK-239).
        let ext = try await makeExtension()
        var profile: Profile? = Profile(name: "Notification Profile Gone")
        let handler = ExtensionPolyfillHandler(profile: try XCTUnwrap(profile))
        handler.notificationManagerOverride = manager
        profile = nil
        XCTAssertNil(handler.profile, "precondition: nothing else holds the profile")

        for type in ["notifications.create", "notifications.update", "notifications.clear", "notifications.getAll"] {
            let answered = expectation(description: "\(type) answers")
            var reply: (result: Any?, error: (any Error)?) = (nil, nil)
            let params: [String: Any] = ["notificationId": "gone", "options": ["title": "t"]]
            handler.handleNativeMessage(
                ["type": type, "params": params],
                verifiedExtensionID: ext.id
            ) { result, error in
                reply = (result, error)
                answered.fulfill()
            }
            await fulfillment(of: [answered], timeout: 5)
            XCTAssertNil(reply.result, type)
            XCTAssertEqual((reply.error as NSError?)?.localizedDescription,
                           ExtensionPolyfillHandler.notificationsProfileGone, type)
        }
        XCTAssertTrue(center.addedIdentifiers.isEmpty, "nothing was shown")
        XCTAssertTrue(center.removals.isEmpty, "nothing was taken away")
    }
}
