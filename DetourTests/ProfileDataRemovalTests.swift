import XCTest
import GRDB
import WebKit
@testable import Detour

/// Deleting a profile removes its on-disk WebKit data (TASK-32).
///
/// The unit tests inject a fake remover and never reach WebKit. The one
/// integration test goes through the real `WKWebsiteDataStore` API, and only
/// for identifiers it creates itself: the test host shares the production app's
/// bundle id, and so its WebKit data directory.
@MainActor
final class ProfileDataRemovalTests: XCTestCase {

    private struct SimulatedInUse: LocalizedError {
        var errorDescription: String? { "Data store is in use (simulated)" }
    }

    /// Records every remover call, and what the world looked like at that moment.
    private final class FakeRemover {
        var calls: [(step: String, id: UUID)] = []
        var extensionFailuresLeft = 0
        var storeFailuresLeft = 0
        /// Run at each call before it succeeds or fails.
        var onCall: ((String, UUID) -> Void)?

        var remover: ProfileDataRemoval.Remover {
            ProfileDataRemoval.Remover(
                removeExtensionData: { [self] id in
                    calls.append(("extension", id))
                    onCall?("extension", id)
                    if extensionFailuresLeft > 0 {
                        extensionFailuresLeft -= 1
                        throw SimulatedInUse()
                    }
                },
                removeWebsiteDataStore: { [self] id in
                    calls.append(("store", id))
                    onCall?("store", id)
                    if storeFailuresLeft > 0 {
                        storeFailuresLeft -= 1
                        throw SimulatedInUse()
                    }
                }
            )
        }

        var removedIDs: Set<UUID> { Set(calls.map(\.id)) }
    }

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(dbQueue: DatabaseQueue())
    }

    private func pendingIDs(_ db: AppDatabase) -> Set<String> {
        Set(db.pendingProfileDataRemovals())
    }

    // MARK: - Delete ordering

    /// Adds a profile with a live favourite whose backing tab has a web view, and
    /// returns only its id and weak references, so the test itself does not keep
    /// the profile alive.
    private func addProfileWithLiveFavorite(to store: TabStore, name: String)
        -> (id: UUID, profile: () -> Profile?, tab: BrowserTab)
    {
        let profile = store.addProfile(name: name)
        let tab = BrowserTab(configuration: WKWebViewConfiguration())
        profile.favorites.append(Favorite(url: URL(string: "https://fav.example/")!, title: "Fav", tab: tab))
        weak var weakProfile = profile
        return (profile.id, { weakProfile }, tab)
    }

    func testDeleteProfileTearsDownAndReleasesEverythingBeforeRemovingItsData() async throws {
        let db = try makeDatabase()
        let fake = FakeRemover()
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01])
        let keeper = store.addProfile(name: "Keeper")
        let doomed = addProfileWithLiveFavorite(to: store, name: "Doomed")
        XCTAssertNotNil(doomed.tab.webView, "precondition: the favourite is live")

        var observations: [String] = []
        fake.onCall = { step, id in
            XCTAssertEqual(id, doomed.id)
            if doomed.profile() != nil { observations.append("\(step): profile still alive") }
            if doomed.tab.webView != nil { observations.append("\(step): favourite web view still alive") }
            if store.profile(withID: id) != nil { observations.append("\(step): profile still in the store") }
            if db.loadProfiles().contains(where: { $0.id == id.uuidString }) {
                observations.append("\(step): profile row still present")
            }
            if !db.pendingProfileDataRemovals().contains(id.uuidString) {
                observations.append("\(step): removal not recorded as pending")
            }
        }

        let task = try XCTUnwrap(store.deleteProfile(id: doomed.id))
        XCTAssertNil(doomed.tab.webView, "the favourite's backing tab is torn down synchronously")
        XCTAssertTrue(fake.calls.isEmpty, "removal waits for a later main-actor turn")
        XCTAssertEqual(pendingIDs(db), [doomed.id.uuidString], "recorded before the removal is attempted")

        let outcome = await task.value

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(observations, [], "everything is released before WebKit is asked to remove the data")
        XCTAssertEqual(fake.calls.map(\.step), ["extension", "store"])
        XCTAssertEqual(pendingIDs(db), [], "the pending row is cleared on success")
        XCTAssertEqual(store.profiles.map(\.id), [keeper.id])
    }

    func testDeleteProfileRemovesOnlyThatProfilesData() async throws {
        let db = try makeDatabase()
        let fake = FakeRemover()
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01])
        let first = store.addProfile(name: "First").id
        let doomed = store.addProfile(name: "Doomed").id
        let third = store.addProfile(name: "Third").id

        let outcome = await store.deleteProfile(id: doomed)?.value

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(fake.removedIDs, [doomed], "no other profile's data is touched")
        XCTAssertEqual(Set(store.profiles.map(\.id)), [first, third])
        XCTAssertEqual(Set(db.loadProfiles().map(\.id)), [first.uuidString, third.uuidString])
    }

    func testDeleteProfileRefusedByTheGuardsRemovesNothing() async throws {
        let db = try makeDatabase()
        let fake = FakeRemover()
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01])
        let used = store.addProfile(name: "Used")
        _ = store.addSpace(name: "S", emoji: "S", colorHex: "007AFF", profileID: used.id)
        let other = store.addProfile(name: "Other")
        let incognito = store.ensureIncognitoProfile()

        XCTAssertNil(store.deleteProfile(id: used.id), "a profile a space uses")
        XCTAssertNil(store.deleteProfile(id: incognito.id), "the Private profile")
        // Let any stray removal task run before checking nothing happened.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(pendingIDs(db), [])
        XCTAssertEqual(Set(store.profiles.map(\.id)), [used.id, other.id, incognito.id])
    }

    /// A space moved off the profile moments ago still references it in the
    /// database until the next session save; the delete must not be refused
    /// (and the data left behind) because of that.
    func testDeleteProfileRightAfterItsLastSpaceMovedAwayStillRemovesItsData() async throws {
        let db = try makeDatabase()
        let fake = FakeRemover()
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01])
        let keeperID = store.addProfile(name: "Keeper").id
        let doomedID = store.addProfile(name: "Doomed").id
        let space = store.addSpace(name: "S", emoji: "S", colorHex: "007AFF", profileID: doomedID)
        store.saveNow()
        store.updateSpace(id: space.id, name: "S", emoji: "S", colorHex: "007AFF", profileID: keeperID)
        XCTAssertFalse(db.deleteProfile(id: doomedID.uuidString),
                       "precondition: the saved session still references the profile")

        let outcome = await store.deleteProfile(id: doomedID)?.value

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(fake.removedIDs, [doomedID])
        XCTAssertFalse(db.loadProfiles().contains { $0.id == doomedID.uuidString })
    }

    // MARK: - Failure and the launch retry

    func testFailedRemovalStaysPendingAndIsRetriedAtTheNextLaunch() async throws {
        let db = try makeDatabase()
        let failing = FakeRemover()
        failing.storeFailuresLeft = .max
        let retryDelays: [TimeInterval] = [0.01, 0.01]
        let store = TabStore(appDB: db, profileDataRemover: failing.remover, profileDataRemovalRetryDelays: retryDelays)
        let keeper = store.addProfile(name: "Keeper").id
        let doomed = store.addProfile(name: "Doomed").id

        let outcome = await store.deleteProfile(id: doomed)?.value

        guard case .failed = outcome else { return XCTFail("expected a failure, got \(String(describing: outcome))") }
        XCTAssertEqual(failing.calls.map(\.step), ["extension", "store", "store", "store"],
                       "the store removal is retried; the extension data step, once done, is not repeated")
        XCTAssertEqual(pendingIDs(db), [doomed.uuidString], "a failed removal stays pending")

        // Next launch: a new store over the same database, before any profile loads.
        let succeeding = FakeRemover()
        let relaunched = TabStore(appDB: db, profileDataRemover: succeeding.remover, profileDataRemovalRetryDelays: retryDelays)
        XCTAssertTrue(relaunched.profiles.isEmpty, "precondition: nothing restored yet")

        let outcomes = await relaunched.retryPendingProfileDataRemovals().value

        XCTAssertEqual(outcomes, [doomed: .removed])
        XCTAssertEqual(succeeding.calls.map(\.step), ["extension", "store"])
        XCTAssertEqual(succeeding.removedIDs, [doomed])
        XCTAssertFalse(succeeding.removedIDs.contains(keeper))
        XCTAssertEqual(pendingIDs(db), [])
    }

    func testExtensionDataFailureIsRetriedBeforeTheStoreIsRemoved() async throws {
        let db = try makeDatabase()
        let fake = FakeRemover()
        fake.extensionFailuresLeft = 1
        let removal = ProfileDataRemoval(appDB: db, remover: fake.remover, retryDelays: [0.01])
        let id = UUID()
        db.recordPendingProfileDataRemoval(profileID: id.uuidString)

        let outcome = await removal.removeDataOfDeletedProfile(id: id).value

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(fake.calls.map(\.step), ["extension", "extension", "store"])
        XCTAssertEqual(pendingIDs(db), [])
    }

    func testLaunchRetryNeverTouchesAnExistingProfileOrThePrivateProfile() async throws {
        let db = try makeDatabase()
        let stored = Profile(name: "Stored")
        db.saveProfile(stored.toRecord())
        let inMemoryOnly = UUID()
        let deleted = UUID()
        let incognito = TabStore.incognitoProfileID.uuidString
        // Rows that should never have been recorded, written directly: a stored
        // profile, a profile alive only in memory, the Private profile (which
        // recordPendingProfileDataRemoval refuses), a lower-case spelling of the
        // stored id, and an unparsable id.
        try await db.dbQueue.write { d in
            for (i, key) in [stored.id.uuidString, stored.id.uuidString.lowercased(), inMemoryOnly.uuidString,
                             incognito, deleted.uuidString, "not-a-uuid"].enumerated() {
                try d.execute(sql: "INSERT INTO pendingProfileDataRemoval (profileID, requestedAt) VALUES (?, ?)",
                              arguments: [key, Double(i)])
            }
        }
        let fake = FakeRemover()
        let removal = ProfileDataRemoval(appDB: db, remover: fake.remover, retryDelays: [0.01])
        removal.inMemoryProfileIDs = { [inMemoryOnly] }

        let outcomes = await removal.retryPendingRemovals().value

        XCTAssertEqual(fake.removedIDs, [deleted], "only the deleted profile's data is removed")
        XCTAssertEqual(outcomes[stored.id], .refusedLiveProfile)
        XCTAssertEqual(outcomes[inMemoryOnly], .refusedLiveProfile)
        XCTAssertEqual(outcomes[TabStore.incognitoProfileID], .refusedLiveProfile)
        XCTAssertEqual(outcomes[deleted], .removed)
        XCTAssertEqual(pendingIDs(db), [], "refused and unparsable rows are dropped, the removed one is cleared")
        XCTAssertEqual(db.loadProfiles().map(\.id), [stored.id.uuidString], "the stored profile is untouched")
    }

    /// AppDelegate skips the launch retry in the test host, which shares the
    /// production app's WebKit data directory.
    func testTheTestHostIsDetectedSoTheLaunchRetryIsSkipped() {
        XCTAssertTrue(AppDelegate.isRunningUnitTests)
    }

    func testRecordingAPendingRemovalForThePrivateProfileIsIgnored() throws {
        let db = try makeDatabase()
        db.recordPendingProfileDataRemoval(profileID: TabStore.incognitoProfileID.uuidString)
        db.recordPendingProfileDataRemoval(profileID: TabStore.incognitoProfileID.uuidString.lowercased())
        XCTAssertEqual(pendingIDs(db), [])
    }

    /// The guard is re-checked right before each WebKit call, not only when the
    /// removal is scheduled: a profile row that is back by then is left alone.
    func testRemovalIsRefusedIfTheProfileExistsWhenTheAttemptRuns() async throws {
        let db = try makeDatabase()
        let profile = Profile(name: "Back again")
        db.recordPendingProfileDataRemoval(profileID: profile.id.uuidString)
        let fake = FakeRemover()
        let removal = ProfileDataRemoval(appDB: db, remover: fake.remover, retryDelays: [0.01])

        let task = removal.removeDataOfDeletedProfile(id: profile.id)
        db.saveProfile(profile.toRecord())
        let outcome = await task.value

        XCTAssertEqual(outcome, .refusedLiveProfile)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    /// Between the extension step and the store step, too.
    func testRemovalStopsIfTheProfileAppearsBetweenSteps() async throws {
        let db = try makeDatabase()
        let profile = Profile(name: "Appears")
        db.recordPendingProfileDataRemoval(profileID: profile.id.uuidString)
        let fake = FakeRemover()
        fake.onCall = { step, _ in
            if step == "extension" { db.saveProfile(profile.toRecord()) }
        }
        let removal = ProfileDataRemoval(appDB: db, remover: fake.remover, retryDelays: [0.01])

        let outcome = await removal.removeDataOfDeletedProfile(id: profile.id).value

        XCTAssertEqual(outcome, .refusedLiveProfile)
        XCTAssertEqual(fake.calls.map(\.step), ["extension"], "the store removal is never attempted")
    }

    // MARK: - Real WebKit

    private var webKitDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKit", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "", isDirectory: true)
    }

    private func websiteDataStoreDirectory(_ id: UUID) -> URL {
        webKitDirectory.appendingPathComponent("WebsiteDataStore/\(id.uuidString.lowercased())", isDirectory: true)
    }

    private func dataStoreIsListed(_ id: UUID) async -> Bool {
        await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id)
    }

    /// Writes real data into `profile`'s store (a cookie, and local storage from
    /// a page shown in a live favourite's web view) and into its extension
    /// controller (an extension whose worker writes `storage.local`, loaded and
    /// registered as the profile's context). Scoped so that nothing but the
    /// store's own objects retains the profile afterwards.
    private func populateWebKitData(
        of profileID: UUID, in store: TabStore, extensionDirectory: URL
    ) async throws -> () -> Profile? {
        let profile = try XCTUnwrap(store.profile(withID: profileID))
        weak var weakProfile = profile

        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "task32.example", .path: "/", .name: "session", .value: "secret",
            .expires: Date().addingTimeInterval(3600),
        ]))
        await profile.dataStore.httpCookieStore.setCookie(cookie)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.dataStore
        let tab = BrowserTab(configuration: configuration)
        let webView = try XCTUnwrap(tab.webView)
        try await loadHTMLStringAndWait(webView, html: "<html><body>task32</body></html>",
                                        baseURL: URL(string: "https://task32.example/"))
        _ = try await webView.evaluateJavaScript("localStorage.setItem('k', 'v'); true")
        profile.favorites.append(Favorite(url: URL(string: "https://task32.example/")!, title: "Fav", tab: tab))

        let wkExtension = try await WKWebExtension(resourceBaseURL: extensionDirectory)
        let context = WKWebExtensionContext(for: wkExtension)
        context.uniqueIdentifier = "task32-storage"
        for permission in wkExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        try profile.extensionController.load(context)
        profile.extensionContexts["task32-storage"] = context
        try await context.loadBackgroundContent()
        try await waitUntil("the worker's storage.local write") {
            let record = await profile.extensionController.dataRecord(
                ofTypes: WKWebExtensionController.allExtensionDataTypes, for: context)
            return (record?.totalSizeInBytes ?? 0) > 0
        }
        return { weakProfile }
    }

    func testDeletingAProfileRemovesItsWebKitDataFromDisk() async throws {
        let extensionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-task32-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extensionDirectory) }
        try """
        {"manifest_version": 3, "name": "TASK-32 storage", "version": "1.0",
         "permissions": ["storage"], "background": {"service_worker": "background.js"}}
        """.write(to: extensionDirectory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "chrome.storage.local.set({ secret: 'x'.repeat(512) });"
            .write(to: extensionDirectory.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        // Every identifier below is created by this test; nothing else is removed.
        let doomed = store.addProfile(name: "TASK-32 doomed").id
        let other = store.addProfile(name: "TASK-32 other").id
        _ = store.addProfile(name: "TASK-32 spare")   // keeps two profiles deletable; never touches WebKit

        let doomedProfile = try await populateWebKitData(of: doomed, in: store, extensionDirectory: extensionDirectory)
        do {
            let otherProfile = try XCTUnwrap(store.profile(withID: other))
            let cookie = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "other.example", .path: "/", .name: "c", .value: "1",
                .expires: Date().addingTimeInterval(3600),
            ]))
            await otherProfile.dataStore.httpCookieStore.setCookie(cookie)
        }
        let doomedExtensionDirectory = try XCTUnwrap(ProfileDataRemoval.webExtensionControllerDirectory(for: doomed))
        let doomedListedBefore = await dataStoreIsListed(doomed)
        let otherListedBefore = await dataStoreIsListed(other)
        XCTAssertTrue(doomedListedBefore, "precondition: the profile's store exists")
        XCTAssertTrue(otherListedBefore, "precondition: the other profile's store exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: websiteDataStoreDirectory(doomed).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: doomedExtensionDirectory.appendingPathComponent("task32-storage/LocalStorage.db").path),
            "precondition: extension storage.local is on disk")

        let doomedOutcome = await store.deleteProfile(id: doomed)?.value

        XCTAssertEqual(doomedOutcome, .removed)
        XCTAssertNil(doomedProfile(), "nothing retains the deleted profile")
        let doomedListedAfter = await dataStoreIsListed(doomed)
        let otherListedAfter = await dataStoreIsListed(other)
        XCTAssertFalse(doomedListedAfter, "allDataStoreIdentifiers no longer lists the deleted profile")
        XCTAssertFalse(FileManager.default.fileExists(atPath: websiteDataStoreDirectory(doomed).path),
                       "the website data store directory is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomedExtensionDirectory.path),
                       "the extension controller directory is gone")
        XCTAssertTrue(otherListedAfter, "the other profile's store is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: websiteDataStoreDirectory(other).path))
        XCTAssertEqual(db.pendingProfileDataRemovals(), [])

        // Clean up the other store, which this test created, through the same path.
        let otherOutcome = await store.deleteProfile(id: other)?.value
        XCTAssertEqual(otherOutcome, .removed)
        let otherListedAtEnd = await dataStoreIsListed(other)
        XCTAssertFalse(otherListedAtEnd)
    }
}
