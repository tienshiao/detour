import XCTest
import WebKit
import UserNotifications
@testable import Detour

/// TASK-247: the manager's side of `notifications.onClicked` / `onClosed`.
/// The background context parks a `notifications.awaitEvent` request; the
/// manager answers it with the owner's unacknowledged events, keeps them
/// until the next park acknowledges them, bounds the backlog, and lets a newer
/// incarnation supersede an older one. The same from a real worker is in
/// `ExtensionNotificationEventDeliveryTests`.
nonisolated final class ExtensionNotificationEventManagerTests: XCTestCase {

    private static let profile1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let profile2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let ownerA = ExtensionNotificationManager.Owner(profileID: profile1, extensionID: "notif-events-a")
    /// The same extension in another profile.
    private static let ownerA2 = ExtensionNotificationManager.Owner(profileID: profile2, extensionID: "notif-events-a")

    private var center: HeldNotificationCenter!
    private var manager: ExtensionNotificationManager!
    private var wakes: [ExtensionNotificationManager.Owner] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        center = HeldNotificationCenter()
        center.holdsAdds = false
        manager = ExtensionNotificationManager(center: center)
        manager.wakeBackground = { [weak self] owner in self?.wakes.append(owner) }
        wakes = []
    }

    @MainActor override func tearDown() async throws {
        center.releaseAll()
        manager = nil
        center = nil
        try await super.tearDown()
    }

    /// What one parked request was answered.
    @MainActor private final class Answer {
        var replies: [(value: Any?, error: String?)] = []
        var answered: Bool { !replies.isEmpty }
        var error: String? { replies.first?.error }
        /// The events of the first answer, as `[kind, id, byUser?]` strings.
        var events: [String] {
            guard let reply = replies.first?.value as? [String: Any],
                  let events = reply["events"] as? [[String: Any]] else { return [] }
            return events.map { event in
                let base = "\(event["kind"] as? String ?? "?"):\(event["notificationId"] as? String ?? "?")"
                if let byUser = event["byUser"] as? Bool { return base + ":\(byUser)" }
                return base
            }
        }
        var lastSeq: Int? {
            ((replies.first?.value as? [String: Any])?["events"] as? [[String: Any]])?.last?["seq"] as? Int
        }
    }

    @MainActor private func park(_ owner: ExtensionNotificationManager.Owner = ownerA, instance: String? = "i1",
                                 ack: Int? = nil) -> Answer {
        let answer = Answer()
        manager.awaitEvent(owner: owner, instance: instance, ack: ack) { value, error in
            answer.replies.append((value, error))
        }
        return answer
    }

    @MainActor private func create(_ id: String, owner: ExtensionNotificationManager.Owner = ownerA) -> String {
        manager.create(owner: owner, notificationID: id, options: ["title": id]) { _ in }
        return manager.identifier(for: owner, notificationID: id) ?? "missing \(id)"
    }

    @MainActor private func click(_ identifier: String) {
        manager.handleResponse(identifier: identifier, action: UNNotificationDefaultActionIdentifier)
    }

    /// A click or a dismissal reaches the parked owner only: the same id in
    /// the same extension of another profile is another notification.
    @MainActor func testEventsReachOnlyTheOwnersPark() {
        let identifierA = create("x")
        let identifierA2 = create("x", owner: Self.ownerA2)
        let parkedA = park()
        let parkedA2 = park(Self.ownerA2)

        click(identifierA)
        XCTAssertEqual(parkedA.events, ["clicked:x"])
        XCTAssertFalse(parkedA2.answered, "another profile's park hears nothing")

        manager.handleResponse(identifier: identifierA2, action: UNNotificationDismissActionIdentifier)
        XCTAssertEqual(parkedA2.events, ["closed:x:true"], "a dismissal is the user's")
        XCTAssertEqual(parkedA.replies.count, 1)
    }

    /// The extension's own clear fires `onClosed` with `byUser` false, as
    /// Chrome's does; a clear that finds nothing fires nothing.
    @MainActor func testClearFiresClosedNotByUser() {
        _ = create("x")
        let parked = park()
        manager.clear(owner: Self.ownerA, notificationID: "missing") { XCTAssertFalse($0) }
        XCTAssertFalse(parked.answered)
        manager.clear(owner: Self.ownerA, notificationID: "x") { XCTAssertTrue($0) }
        XCTAssertEqual(parked.events, ["closed:x:false"])
    }

    /// A dismissal drops the entry (AC #5): clear and update answer false and
    /// getAll does not list it.
    @MainActor func testADismissalDropsTheEntry() async {
        let identifier = create("x")
        manager.handleResponse(identifier: identifier, action: UNNotificationDismissActionIdentifier)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
        var cleared: Bool?
        manager.clear(owner: Self.ownerA, notificationID: "x") { cleared = $0 }
        XCTAssertEqual(cleared, false)
        let updated = await withCheckedContinuation { continuation in
            manager.update(owner: Self.ownerA, notificationID: "x", options: ["title": "y"]) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertFalse(updated)
        let backlog = manager.eventChannelForTesting(Self.ownerA).backlog
        XCTAssertEqual(backlog.map(\.kind), [.closed], "the clear after the dismissal fires nothing more")
    }

    /// Events while nothing is parked wait in the backlog; the next park gets
    /// them at once, and they stay until a park acknowledges them, so a
    /// worker that died before dispatching them hands them to the next one.
    @MainActor func testEventsWaitUntilAcknowledged() {
        let identifier = create("x")
        click(identifier)
        manager.clear(owner: Self.ownerA, notificationID: "x") { _ in }

        let first = park()
        XCTAssertEqual(first.events, ["clicked:x", "closed:x:false"], "the backlog, in order")
        XCTAssertNil(manager.eventChannelForTesting(Self.ownerA).parkedInstance, "answered at once, not parked")

        // The answer went to a worker that was gone: the next incarnation's
        // first park, acknowledging nothing, receives the same events again.
        let again = park(instance: "i2")
        XCTAssertEqual(again.events, ["clicked:x", "closed:x:false"])

        let acknowledged = park(instance: "i2", ack: again.lastSeq)
        XCTAssertFalse(acknowledged.answered, "everything acknowledged: parked")
        XCTAssertEqual(manager.eventChannelForTesting(Self.ownerA).backlog, [])
        XCTAssertEqual(manager.eventChannelForTesting(Self.ownerA).parkedInstance, "i2")
    }

    /// The backlog keeps the newest `eventBacklogLimit` events.
    @MainActor func testTheBacklogIsBounded() {
        let identifier = create("x")
        let total = ExtensionNotificationManager.eventBacklogLimit + 8
        for _ in 0..<total { click(identifier) }
        let backlog = manager.eventChannelForTesting(Self.ownerA).backlog
        XCTAssertEqual(backlog.count, ExtensionNotificationManager.eventBacklogLimit)
        let parked = park()
        XCTAssertEqual(parked.events.count, ExtensionNotificationManager.eventBacklogLimit)
        XCTAssertEqual(parked.lastSeq, backlog.last?.seq, "the oldest went, the newest stayed")
    }

    /// A newer incarnation's park settles the older one's, and the older one
    /// can no longer park: its events go to the newer one.
    @MainActor func testANewerIncarnationSupersedesTheOlder() {
        let identifier = create("x")
        let old = park(instance: "old")
        let new = park(instance: "new")
        XCTAssertEqual(old.error, ExtensionNotificationManager.supersededWaitError)
        XCTAssertFalse(new.answered)

        let oldAgain = park(instance: "old")
        XCTAssertEqual(oldAgain.error, ExtensionNotificationManager.supersededWaitError,
                       "an older incarnation still running cannot take the park back")
        XCTAssertFalse(new.answered, "and the newer one's park stands")

        click(identifier)
        XCTAssertEqual(new.events, ["clicked:x"])
    }

    /// An event wakes the owner's background only once a context of it has
    /// listened: an extension with no listener is never started for one.
    @MainActor func testAnEventWakesTheBackgroundOnceItListens() {
        let identifier = create("x")
        click(identifier)
        XCTAssertEqual(wakes, [], "never listened: not woken")

        let parked = park()
        XCTAssertEqual(parked.events, ["clicked:x"])
        _ = park(ack: parked.lastSeq)
        click(identifier)
        XCTAssertEqual(wakes, [Self.ownerA], "listens: woken, in case its park is a gone worker's")
    }

    /// Unloading the extension from the profile (or the profile going) settles
    /// its park and drops its backlog; another profile's channel stays.
    @MainActor func testRemovingTheOwnerDropsItsChannel() {
        let identifierA2 = create("x", owner: Self.ownerA2)
        let parked = park()
        click(identifierA2)

        manager.removeAll(for: Self.ownerA)
        XCTAssertNotNil(parked.error, "the park is settled")
        XCTAssertFalse(manager.eventChannelForTesting(Self.ownerA).listens)
        XCTAssertEqual(manager.eventChannelForTesting(Self.ownerA2).backlog.count, 1)

        manager.removeAll(profileID: Self.profile2)
        XCTAssertEqual(manager.eventChannelForTesting(Self.ownerA2).backlog, [])
    }

    /// A Private session starting or ending (`removeSession(profileID:)`)
    /// takes the profile's notifications and the events queued for them, but
    /// its contexts stay loaded, so a park stands, unanswered (TASK-264):
    /// answering it "unloaded" would stop the worker parking for good. A
    /// click and a dismissal afterwards reach that park; another profile's
    /// channel is untouched; and removing the owner afterwards still settles
    /// the park.
    @MainActor func testASessionBoundaryKeepsTheParkAndDropsTheQueuedEvents() {
        let ownerB = ExtensionNotificationManager.Owner(profileID: Self.profile1, extensionID: "notif-events-b")
        let old = create("old")
        let oldB = create("old-b", owner: ownerB)
        let otherProfile = create("other", owner: Self.ownerA2)
        let first = park()
        click(old)
        XCTAssertEqual(first.events, ["clicked:old"])
        let parked = park(ack: first.lastSeq)
        click(oldB)
        click(otherProfile)
        XCTAssertEqual(manager.eventChannelForTesting(ownerB).backlog.map(\.notificationID), ["old-b"],
                       "precondition: an unheard event of the ending session")

        manager.removeSession(profileID: Self.profile1)
        XCTAssertFalse(parked.answered, "the park stands: the context is still running")
        XCTAssertEqual(manager.eventChannelForTesting(Self.ownerA).parkedInstance, "i1")
        XCTAssertTrue(manager.eventChannelForTesting(Self.ownerA).listens)
        XCTAssertEqual(manager.eventChannelForTesting(ownerB).backlog, [], "the session's events go with it")
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
        XCTAssertEqual(manager.getAll(owner: ownerB), [:])
        XCTAssertTrue(center.removals.contains(old) && center.removals.contains(oldB))
        XCTAssertEqual(manager.eventChannelForTesting(Self.ownerA2).backlog.map(\.notificationID), ["other"],
                       "another profile's channel is untouched")
        XCTAssertEqual(manager.getAll(owner: Self.ownerA2), ["other": true])
        click(old)
        XCTAssertFalse(parked.answered, "a click on the ended session's notification is ignored")

        let next = create("next")
        click(next)
        XCTAssertEqual(parked.events, ["clicked:next"], "the next session's click reaches the standing park")
        let again = park(ack: parked.lastSeq)
        manager.handleResponse(identifier: next, action: UNNotificationDismissActionIdentifier)
        XCTAssertEqual(again.events, ["closed:next:true"])

        let last = park(ack: again.lastSeq)
        manager.removeSession(profileID: Self.profile1)
        XCTAssertFalse(last.answered)
        manager.removeAll(for: Self.ownerA)
        XCTAssertEqual(last.error, "notifications: the extension was unloaded",
                       "unloading the extension still ends the wait")

        let afterProfile = park(ownerB, instance: "b1")
        manager.removeSession(profileID: Self.profile1)
        XCTAssertFalse(afterProfile.answered)
        manager.removeAll(profileID: Self.profile1)
        XCTAssertEqual(afterProfile.error, "notifications: the extension was unloaded",
                       "removing the profile still ends the wait")
        XCTAssertFalse(manager.eventChannelForTesting(ownerB).listens)
    }

    /// Every notification carries the category whose `.customDismissAction`
    /// makes the center report a dismissal.
    @MainActor func testNotificationsCarryTheDismissCategory() async {
        XCTAssertTrue(ExtensionNotificationManager.dismissCategory.options.contains(.customDismissAction))
        await withCheckedContinuation { continuation in
            manager.create(owner: Self.ownerA, notificationID: "x", options: ["title": "t"]) { _ in
                continuation.resume()
            }
        }
        XCTAssertEqual(center.addedRequests.map(\.content.categoryIdentifier),
                       [ExtensionNotificationManager.dismissCategory.identifier])
    }
}

/// TASK-247 from real extension contexts, through the production wiring
/// (`Profile.extensionController`, the `ExtensionManager` delegate for the
/// worker's `runtime.sendNativeMessage`): the worker's `onClicked` /
/// `onClosed` listeners receive the clicks and closes `handleResponse`
/// resolves to its profile, only there, with `byUser`; an event before the
/// worker parks is delivered when it does; a worker restart supersedes the
/// old park. Each profile's handler is pointed at one shared test manager
/// around `HeldNotificationCenter` (answering at once), as production's
/// share `shared`; the real center is never touched.
nonisolated final class ExtensionNotificationEventDeliveryTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var openWebViews: [WKWebView] = []
    private var overriddenHandlers: [ExtensionPolyfillHandler] = []
    private var previousLastActiveSpaceID: UUID?
    private var manager: ExtensionNotificationManager!
    /// Extensions loaded into the built-in Private profile, which tearDown
    /// unloads but does not delete, and saved in the shared database for
    /// their Private row.
    private var privateLoadedExtensionIDs: [String] = []
    /// Private windows' spaces a test opened in the shared store; tearDown
    /// removes any still there, which ends the Private session.
    private var incognitoSpaceIDs: [UUID] = []

    /// Profiles whose controller hosted a web view live for the rest of the
    /// process (see `ExtensionNotificationOrderingTests.retainedProfiles`).
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
        let center = HeldNotificationCenter()
        center.holdsAdds = false
        manager = ExtensionNotificationManager(center: center)
    }

    @MainActor override func tearDown() async throws {
        for id in incognitoSpaceIDs { TabStore.shared.removeIncognitoSpace(id: id) }
        incognitoSpaceIDs.removeAll()
        for webView in openWebViews {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        openWebViews.removeAll()
        let privateProfile = TabStore.shared.profiles.first { $0.id == TabStore.incognitoProfileID }
        for id in privateLoadedExtensionIDs {
            _ = privateProfile?.unloadExtension(id: id)
            // The row's deletion cascades to its `profileExtension` rows.
            AppDatabase.shared.deleteExtension(id: id)
        }
        privateLoadedExtensionIDs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for handler in overriddenHandlers { handler.notificationManagerOverride = nil }
        overriddenHandlers.removeAll()
        for id in createdSpaceIDs { TabStore.shared.forceRemoveSpace(id: id) }
        createdSpaceIDs.removeAll()
        ExtensionManager.shared.lastActiveSpaceID = previousLastActiveSpaceID
        for id in registeredExtensionIDs { ExtensionManager.shared.extensions.removeAll { $0.id == id } }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        manager = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The worker: the polyfill, listeners that record every event with the
    /// incarnation that got it (added at start, or on request), and a message
    /// listener the test drives it through.
    @MainActor private static func workerJS(listensAtStart: Bool) -> String {
        ExtensionAPIPolyfill.polyfillJS + """

        globalThis.__events = [];
        const listen = () => {
            chrome.notifications.onClicked.addListener((id) => {
                __events.push({ kind: 'clicked', id: id, instance: globalThis.__detourContextInstance });
            });
            chrome.notifications.onClosed.addListener((id, byUser) => {
                __events.push({ kind: 'closed', id: id, byUser: byUser, instance: globalThis.__detourContextInstance });
            });
        };
        if (\(listensAtStart)) listen();

        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (!message) return false;
            const instance = globalThis.__detourContextInstance;
            const answer = (promise) => {
                promise.then((result) => sendResponse({ result: result, instance: instance }),
                             (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
                return true;
            };
            if (message.type === 'ping') { sendResponse({ type: 'pong', instance: instance }); return true; }
            if (message.type === 'listen') { listen(); sendResponse({ ok: true }); return true; }
            if (message.type === 'events') { sendResponse({ events: __events, instance: instance }); return true; }
            if (message.type === 'create') {
                return answer(chrome.notifications.create(message.id, { type: 'basic', title: message.id, message: 'm' }));
            }
            if (message.type === 'clear') { return answer(chrome.notifications.clear(message.id)); }
            if (message.type === 'update') { return answer(chrome.notifications.update(message.id, { message: 'u' })); }
            if (message.type === 'getAll') { return answer(chrome.notifications.getAll()); }
            if (message.type === 'reload') {
                sendResponse({ ok: true });
                setTimeout(() => { chrome.runtime.reload(); }, 50);
                return true;
            }
            return false;
        });
        """
    }

    @MainActor private func makeExtension(listensAtStart: Bool = true) async throws -> WebExtension {
        let id = "notif-events-\(UUID().uuidString.prefix(8))"
        let ext = try await makeTestExtension(
            id: id,
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Notification Event Test",
                "version": "1.0.0",
                "permissions": ["notifications"],
                "background": { "service_worker": "background.js", "type": "module" }
            }
            """,
            files: [
                "background.js": Self.workerJS(listensAtStart: listensAtStart),
                "test.html": "<html><body>notification events page</body></html>",
            ])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    /// A persistent profile with one space, its handler on the test manager.
    @MainActor private func makeProfile(_ name: String) throws -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        let space = TabStore.shared.addSpace(name: "\(name) Space", emoji: "N", colorHex: "#000000",
                                             profileID: profile.id)
        createdSpaceIDs.append(space.id)
        ExtensionManager.shared.lastActiveSpaceID = space.id
        _ = profile.extensionController
        let handler = try XCTUnwrap(profile.polyfillHandler)
        handler.notificationManagerOverride = manager
        overriddenHandlers.append(handler)
        return profile
    }

    /// The built-in Private profile with `ext` allowed in it (installed, its
    /// Private `profileExtension` row on), its handler on the test manager.
    /// tearDown unloads the context and deletes the rows; the profile stays,
    /// as it does in the app.
    @MainActor private func privateProfile(allowing ext: WebExtension) throws -> Profile {
        let profile = TabStore.shared.ensureIncognitoProfile()
        installTestExtension(ext, in: AppDatabase.shared,
                             manifestJSON: (try? testExtensionManifestData(ext)) ?? Data("{}".utf8))
        privateLoadedExtensionIDs.append(ext.id)
        // The row's foreign key wants the Private profile's own row first.
        AppDatabase.shared.saveProfile(profile.toRecord())
        AppDatabase.shared.setProfileExtensionEnabled(
            extensionID: ext.id, profileID: TabStore.incognitoProfileID.uuidString, enabled: true)
        XCTAssertTrue(AppDatabase.shared.isExtensionEnabled(extensionID: ext.id, profileID: profile.id.uuidString),
                      "precondition: the extension is allowed in Private")
        _ = profile.extensionController
        let handler = try XCTUnwrap(profile.polyfillHandler)
        handler.notificationManagerOverride = manager
        overriddenHandlers.append(handler)
        return profile
    }

    /// An extension page of `context`, to reach the worker through.
    @MainActor private func openPage(_ context: WKWebExtensionContext) async throws -> WKWebView {
        let config = try XCTUnwrap(context.webViewConfiguration, "context not loaded in a controller")
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        openWebViews.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        return page
    }

    /// The extension loaded into `profile`, a page of it, and its worker awake.
    @MainActor private func start(_ ext: WebExtension, in profile: Profile)
        async throws -> (context: WKWebExtensionContext, page: WKWebView) {
        let context = try loadTestContext(ext, in: profile)
        let page = try await openPage(context)
        context.loadBackgroundContent { _ in }
        try await waitUntil("the worker of \(profile.name) to wake", timeout: 30) {
            let ping = try await askWorker(from: page, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }
        return (context, page)
    }

    @MainActor private func ask(_ page: WKWebView, _ message: [String: Any],
                                file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let envelope = try await askWorker(from: page, message: message, timeout: 20)
        let reply = try XCTUnwrap(envelope["reply"] as? [String: Any], "the worker must answer: \(envelope)",
                                  file: file, line: line)
        XCTAssertNil(reply["error"], "\(message): \(reply)", file: file, line: line)
        return reply
    }

    /// What the worker's listeners recorded, as `kind:id[:byUser]`.
    @MainActor private func events(_ page: WKWebView) async throws -> [String] {
        let reply = try await ask(page, ["type": "events"])
        return (reply["events"] as? [[String: Any]] ?? []).map { event in
            let base = "\(event["kind"] as? String ?? "?"):\(event["id"] as? String ?? "?")"
            if let byUser = event["byUser"] as? Bool { return base + ":\(byUser)" }
            return base
        }
    }

    @MainActor private func owner(_ ext: WebExtension, _ profile: Profile) -> ExtensionNotificationManager.Owner {
        .init(profileID: profile.id, extensionID: ext.id)
    }

    @MainActor private func waitForPark(_ ext: WebExtension, in profile: Profile, otherThan instance: String? = nil,
                                        nudging context: WKWebExtensionContext? = nil) async throws -> String {
        let owner = owner(ext, profile)
        var nudged = Date()
        try await waitUntil("\(profile.name)'s worker to park", timeout: 60) {
            if let parked = self.manager.eventChannelForTesting(owner).parkedInstance, let parked, parked != instance {
                return true
            }
            if let context, Date().timeIntervalSince(nudged) > 5 {
                nudged = Date()
                context.loadBackgroundContent { _ in }
            }
            return false
        }
        return (manager.eventChannelForTesting(owner).parkedInstance ?? nil) ?? ""
    }

    @MainActor private func identifier(_ id: String, of ext: WebExtension, in profile: Profile) -> String {
        manager.identifier(for: owner(ext, profile), notificationID: id) ?? "no notification \(id)"
    }

    // MARK: - Tests

    /// A click fires `onClicked` in the creating profile's worker only (AC #1),
    /// though the same extension in another profile has a notification with
    /// the same id and is listening too.
    @MainActor func testAClickReachesOnlyTheCreatingProfilesWorker() async throws {
        let ext = try await makeExtension()
        let one = try makeProfile("Notification Events One")
        let two = try makeProfile("Notification Events Two")
        let pageOne = try await start(ext, in: one).page
        let pageTwo = try await start(ext, in: two).page
        _ = try await ask(pageOne, ["type": "create", "id": "same"])
        _ = try await ask(pageTwo, ["type": "create", "id": "same"])
        _ = try await waitForPark(ext, in: one)
        _ = try await waitForPark(ext, in: two)

        manager.handleResponse(identifier: identifier("same", of: ext, in: one),
                               action: UNNotificationDefaultActionIdentifier)
        try await waitUntil("profile one's worker to get the click", timeout: 20) {
            try await self.events(pageOne) == ["clicked:same"]
        }
        // Profile one's worker has dispatched and parked again by now; the
        // other profile's was never answered.
        _ = try await waitForPark(ext, in: one)
        let twoEvents = try await events(pageTwo)
        XCTAssertEqual(twoEvents, [], "the other profile's worker hears nothing")
        XCTAssertEqual(manager.eventChannelForTesting(owner(ext, two)).backlog, [])
    }

    /// A dismissal fires `onClosed` with `byUser` true and drops the
    /// notification (AC #2, #5): clear and update answer false and getAll no
    /// longer lists it. The extension's own clear fires it with `byUser` false.
    @MainActor func testCloseAndDismissFireOnClosedWithByUser() async throws {
        let ext = try await makeExtension()
        let profile = try makeProfile("Notification Events Close")
        let page = try await start(ext, in: profile).page
        _ = try await ask(page, ["type": "create", "id": "dismissed"])
        _ = try await ask(page, ["type": "create", "id": "cleared"])
        _ = try await waitForPark(ext, in: profile)

        manager.handleResponse(identifier: identifier("dismissed", of: ext, in: profile),
                               action: UNNotificationDismissActionIdentifier)
        try await waitUntil("the dismissal to reach onClosed", timeout: 20) {
            try await self.events(page) == ["closed:dismissed:true"]
        }
        let all = try await ask(page, ["type": "getAll"])["result"] as? [String: Any]
        XCTAssertEqual(all?.keys.sorted(), ["cleared"], "a dismissed notification is not listed")
        let clearDismissed = try await ask(page, ["type": "clear", "id": "dismissed"])["result"] as? Bool
        XCTAssertEqual(clearDismissed, false)
        let updateDismissed = try await ask(page, ["type": "update", "id": "dismissed"])["result"] as? Bool
        XCTAssertEqual(updateDismissed, false)

        let clearCleared = try await ask(page, ["type": "clear", "id": "cleared"])["result"] as? Bool
        XCTAssertEqual(clearCleared, true)
        try await waitUntil("the clear to reach onClosed", timeout: 20) {
            try await self.events(page) == ["closed:dismissed:true", "closed:cleared:false"]
        }
    }

    /// An event that arrives before the worker has parked waits, and is
    /// delivered once a listener is added and the worker parks (AC #3).
    @MainActor func testAnEventBeforeTheWorkerParksIsDeliveredWhenItDoes() async throws {
        let ext = try await makeExtension(listensAtStart: false)
        let profile = try makeProfile("Notification Events Backlog")
        let page = try await start(ext, in: profile).page
        _ = try await ask(page, ["type": "create", "id": "early"])
        manager.handleResponse(identifier: identifier("early", of: ext, in: profile),
                               action: UNNotificationDefaultActionIdentifier)
        let channel = manager.eventChannelForTesting(owner(ext, profile))
        XCTAssertEqual(channel.backlog.map(\.notificationID), ["early"])
        XCTAssertNil(channel.parkedInstance, "nothing parked yet")

        _ = try await ask(page, ["type": "listen"])
        try await waitUntil("the backlog to reach onClicked", timeout: 20) {
            try await self.events(page) == ["clicked:early"]
        }
        _ = try await waitForPark(ext, in: profile)
        XCTAssertEqual(manager.eventChannelForTesting(owner(ext, profile)).backlog, [],
                       "acknowledged by the next park")
    }

    /// `runtime.reload()` replaces the worker (AC #4): the new incarnation's
    /// park supersedes the old one's, the old incarnation can no longer park,
    /// and the next click reaches the new worker.
    @MainActor func testAWorkerRestartSupersedesTheOldPark() async throws {
        let ext = try await makeExtension()
        let profile = try makeProfile("Notification Events Restart")
        let (context, page) = try await start(ext, in: profile)
        _ = try await ask(page, ["type": "create", "id": "after-restart"])
        let oldInstance = try await waitForPark(ext, in: profile)

        _ = try await ask(page, ["type": "reload"])
        let newInstance = try await waitForPark(ext, in: profile, otherThan: oldInstance, nudging: context)
        XCTAssertNotEqual(newInstance, oldInstance)

        var refused: String?
        manager.awaitEvent(owner: owner(ext, profile), instance: oldInstance, ack: nil) { _, error in refused = error }
        XCTAssertEqual(refused, ExtensionNotificationManager.supersededWaitError)

        manager.handleResponse(identifier: identifier("after-restart", of: ext, in: profile),
                               action: UNNotificationDefaultActionIdentifier)
        let newPage = try await openPage(context)
        try await waitUntil("the new worker to get the click", timeout: 30) {
            let reply = try await self.ask(newPage, ["type": "events"])
            let events = reply["events"] as? [[String: Any]] ?? []
            return events.count == 1 && events.first?["instance"] as? String == newInstance
        }
    }

    /// A Private session starting or ending takes the Private profile's
    /// notifications, but its contexts stay loaded across it, and so does the
    /// worker's park (TASK-264): before, the boundary answered it "unloaded",
    /// the polyfill stopped parking for good, and every later click and close
    /// waited unheard. A click after the start reaches `onClicked`, a
    /// dismissal after the end reaches `onClosed`, in the same incarnation.
    @MainActor func testAPrivateWorkerHearsEventsAcrossSessionBoundaries() async throws {
        let ext = try await makeExtension()
        let profile = try privateProfile(allowing: ext)
        let page = try await start(ext, in: profile).page
        XCTAssertFalse(TabStore.shared.hasLivePrivateSession, "precondition: no Private session yet")
        _ = try await ask(page, ["type": "create", "id": "between"])
        let instance = try await waitForPark(ext, in: profile)

        let window = TabStore.shared.addIncognitoSpace()
        incognitoSpaceIDs.append(window.id)
        let afterStart = try await ask(page, ["type": "getAll"])["result"] as? [String: Any]
        XCTAssertEqual(afterStart?.keys.sorted(), [], "precondition: the session started clean")
        XCTAssertEqual(manager.eventChannelForTesting(owner(ext, profile)).parkedInstance, instance,
                       "the start leaves the park standing")
        _ = try await ask(page, ["type": "create", "id": "in-session"])
        manager.handleResponse(identifier: identifier("in-session", of: ext, in: profile),
                               action: UNNotificationDefaultActionIdentifier)
        try await waitUntil("the click after the start to reach onClicked", timeout: 20) {
            try await self.events(page) == ["clicked:in-session"]
        }
        _ = try await waitForPark(ext, in: profile)

        TabStore.shared.removeIncognitoSpace(id: window.id)
        incognitoSpaceIDs.removeAll()
        XCTAssertFalse(TabStore.shared.hasLivePrivateSession)
        XCTAssertNotNil(manager.eventChannelForTesting(owner(ext, profile)).parkedInstance ?? nil,
                        "the end leaves the park standing")
        _ = try await ask(page, ["type": "create", "id": "after-end"])
        manager.handleResponse(identifier: identifier("after-end", of: ext, in: profile),
                               action: UNNotificationDismissActionIdentifier)
        try await waitUntil("the dismissal after the end to reach onClosed", timeout: 20) {
            try await self.events(page) == ["clicked:in-session", "closed:after-end:true"]
        }
        let reply = try await ask(page, ["type": "events"])
        let instances = (reply["events"] as? [[String: Any]] ?? []).compactMap { $0["instance"] as? String }
        XCTAssertEqual(Set(instances), [instance], "one incarnation heard both: no restart was needed")
    }

    /// An extension page may not park (only the background context gets the
    /// events): its `notifications.awaitEvent` is refused, and the worker's
    /// park stands, so the page cannot take the worker's events.
    @MainActor func testAPagesParkIsRefused() async throws {
        let ext = try await makeExtension()
        let profile = try makeProfile("Notification Events Page")
        let page = try await start(ext, in: profile).page
        let workerInstance = try await waitForPark(ext, in: profile)

        let refusal = try await page.callAsyncJavaScript("""
            try {
                await __detourPolyfillRequest('notifications.awaitEvent', { instance: 'page' });
                return 'resolved';
            } catch (e) {
                return String(e && e.message ? e.message : e);
            }
            """, contentWorld: .page) as? String
        XCTAssertEqual(refusal, "notifications events: only the background context receives them")
        XCTAssertEqual(manager.eventChannelForTesting(owner(ext, profile)).parkedInstance, workerInstance,
                       "the worker's park stands")
    }

    /// Measurement leg, gated (`TEST_RUNNER_NOTIFICATION_UNLOAD_LEG=1`; takes
    /// about a minute): a worker with a parked `awaitEvent` is still unloaded
    /// by WebKit's idle timer — the park keeps nothing alive — and a click
    /// afterwards wakes the background, whose new worker gets the event.
    @MainActor func testAClickAfterTheWorkerUnloadsWakesItAndIsDelivered() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOTIFICATION_UNLOAD_LEG"] == "1",
                          "set TEST_RUNNER_NOTIFICATION_UNLOAD_LEG=1 to run the unload leg")
        let ext = try await makeExtension()
        let profile = try makeProfile("Notification Events Unload")
        let (context, page) = try await start(ext, in: profile)
        _ = try await ask(page, ["type": "create", "id": "while-unloaded"])
        let parkedInstance = try await waitForPark(ext, in: profile)
        // Nothing talks to the worker from here on: WebKit's 30 s timer has
        // to find it idle. The page stays open; it holds no port.
        let started = Date()
        try await Task.sleep(for: .seconds(45))

        manager.wakeBackground = ExtensionNotificationManager.loadBackgroundContent(of:)
        manager.handleResponse(identifier: identifier("while-unloaded", of: ext, in: profile),
                               action: UNNotificationDefaultActionIdentifier)
        let newInstance = try await waitForPark(ext, in: profile, otherThan: parkedInstance)
        print("notification unload leg: parked \(parkedInstance), delivered to \(newInstance) "
              + "\(Date().timeIntervalSince(started)) s after the park")
        XCTAssertEqual(manager.eventChannelForTesting(owner(ext, profile)).backlog, [],
                       "the woken worker acknowledged the click")
        let reply = try await ask(try await openPage(context), ["type": "events"])
        let events = reply["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(events.map { $0["id"] as? String }, ["while-unloaded"])
        XCTAssertEqual(events.first?["instance"] as? String, newInstance,
                       "a new incarnation got it: the parked worker had been unloaded")
        _ = page
    }
}
