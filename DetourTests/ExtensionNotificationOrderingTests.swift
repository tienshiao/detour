import XCTest
import WebKit
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
nonisolated final class ExtensionNotificationOrderingTests: XCTestCase {

    // MARK: - Fixture bookkeeping

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var openWebViews: [WKWebView] = []
    private var centers: [HeldNotificationCenter] = []
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
    @MainActor private static let workerJS = ExtensionAPIPolyfill.polyfillJS + "\n" + raceJS + """

    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
        if (message.type === 'notificationRace') {
            notificationRace(message.mode, message.id).then(
                (outcome) => sendResponse(outcome),
                (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            return true;
        }
        return false;
    });
    """

    @MainActor private func makeExtension() async throws -> WebExtension {
        let id = "notif-ordering-\(UUID().uuidString.prefix(8))"
        let ext = try await makeTestExtension(
            id: id,
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Notification Ordering Test",
                "version": "1.0.0",
                "permissions": ["notifications"],
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

    /// A persistent profile with one space, its extension controller built and
    /// its handler's notification manager running on a held center.
    @MainActor private func makeProfile(_ name: String) throws -> (profile: Profile, center: HeldNotificationCenter) {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        let space = TabStore.shared.addSpace(name: "\(name) Space", emoji: "N", colorHex: "#000000",
                                             profileID: profile.id)
        createdSpaceIDs.append(space.id)
        ExtensionManager.shared.lastActiveSpaceID = space.id
        // Force the lazy controller, and with it the polyfill handler.
        _ = profile.extensionController
        let handler = try XCTUnwrap(profile.polyfillHandler, "extensionController must build a polyfill handler")
        let center = HeldNotificationCenter()
        centers.append(center)
        handler.notificationManager = ExtensionNotificationManager(center: center)
        return (profile, center)
    }

    /// The extension loaded into `profile`, an extension page of it, and its
    /// worker awake.
    @MainActor private func loadPage(_ ext: WebExtension, in profile: Profile) async throws -> WKWebView {
        let context = try loadTestContext(ext, in: profile)
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

    /// Runs one ordering from `transport`. Once the center holds `adds` adds
    /// and has seen `removals` removals — so every call the ordering makes has
    /// arrived while the first create is still in flight — releases them in
    /// call order and returns what the extension saw.
    @MainActor private func race(_ mode: String, id: String, via transport: Transport, in page: WKWebView,
                                 center: HeldNotificationCenter, adds: Int, removals: Int,
                                 file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let addsBefore = center.addedIdentifiers.count
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
        try await waitUntil("\(transport) \(mode): \(adds) add(s) held and \(removals) removal(s)",
                            timeout: 10, pollInterval: 0.02, file: file, line: line) {
            center.addedIdentifiers.count - addsBefore >= adds
                && center.heldCount >= adds
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
                                         adds: 1, removals: 1)
            XCTAssertNil(outcome["error"], "\(transport): \(outcome)")
            XCTAssertEqual(outcome["createdID"] as? String, id, "\(transport): create still answers its id")
            XCTAssertEqual(outcome["cleared"] as? Bool, true, "\(transport)")
            XCTAssertEqual(listed(outcome), [], "\(transport): getAll must not list a cleared notification")
            XCTAssertNil(center.shown["\(ext.id):\(id)"], "\(transport): the notification must not stay on screen")
        }
    }

    @MainActor func testUpdateWhileCreateInFlightTakesEffect() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Ordering Update")
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let id = "update-\(transport)"
            let outcome = try await race("update", id: id, via: transport, in: page, center: center,
                                         adds: 2, removals: 0)
            XCTAssertNil(outcome["error"], "\(transport): \(outcome)")
            XCTAssertEqual(outcome["updated"] as? Bool, true,
                           "\(transport): the notification being created exists, so the update applies")
            XCTAssertTrue(listed(outcome).contains(id), "\(transport): \(listed(outcome))")
            XCTAssertEqual(center.shown["\(ext.id):\(id)"], "After", "\(transport): the update's content shows")
        }
    }

    @MainActor func testCreateClearCreateShowsTheSecondNotification() async throws {
        let ext = try await makeExtension()
        let (profile, center) = try makeProfile("Notification Ordering Recreate")
        let page = try await loadPage(ext, in: profile)

        for transport in [Transport.page, .worker] {
            let id = "again-\(transport)"
            let outcome = try await race("clearThenCreate", id: id, via: transport, in: page, center: center,
                                         adds: 2, removals: 1)
            XCTAssertNil(outcome["error"], "\(transport): \(outcome)")
            XCTAssertEqual(outcome["cleared"] as? Bool, true, "\(transport)")
            XCTAssertEqual(outcome["secondID"] as? String, id, "\(transport)")
            XCTAssertTrue(listed(outcome).contains(id), "\(transport): the second create stands: \(listed(outcome))")
            XCTAssertEqual(center.shown["\(ext.id):\(id)"], "Second", "\(transport)")
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
        XCTAssertEqual(clearedByB as? Bool, true)
        XCTAssertEqual(center.removals, ["\(extB.id):shared-id"], "B's clear names only B's notification")

        center.releaseAll()
        let createdID = try await created.value
        XCTAssertEqual(createdID, "shared-id")
        let listedForA = try await pageA.callAsyncJavaScript(
            "return JSON.stringify(await chrome.notifications.getAll());", arguments: [:], contentWorld: .page)
        XCTAssertEqual(listedForA as? String, #"{"shared-id":true}"#)
        let listedForB = try await pageB.callAsyncJavaScript(
            "return JSON.stringify(await chrome.notifications.getAll());", arguments: [:], contentWorld: .page)
        XCTAssertEqual(listedForB as? String, "{}")
        XCTAssertEqual(center.shown["\(extA.id):shared-id"], "A")
    }
}
