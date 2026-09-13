import XCTest
import GRDB
import WebKit
@testable import Detour

/// Deleting a profile removes its on-disk WebKit data (TASK-32).
///
/// The unit tests inject a fake remover and never reach WebKit. The one
/// integration test goes through the real `WKWebsiteDataStore` API, and only
/// for storage it creates itself: the test host shares the production app's
/// bundle id, and so its WebKit directory. In the test data directory every
/// identifier is derived and recorded (`WebKitStorageScope`, TASK-36).
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

    /// The default data directory's scope over `db`: WebKit identifiers are the
    /// profile ids and nothing is recorded, so a fake remover sees profile ids.
    private func defaultDirectoryScope(_ db: AppDatabase) -> WebKitStorageScope {
        WebKitStorageScope(dataDirectoryName: defaultDetourDataDirectoryName, registry: db, productionProfileIDs: { [] })
    }

    /// An isolated data directory's scope over `db`.
    private func isolatedScope(_ db: AppDatabase, name: String = "DetourUnitTest",
                               productionProfileIDs: @escaping () -> Set<UUID>? = { [] }) -> WebKitStorageScope {
        WebKitStorageScope(dataDirectoryName: name, registry: db, productionProfileIDs: productionProfileIDs)
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
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01],
                             webKitStorageScope: defaultDirectoryScope(db))
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
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01],
                             webKitStorageScope: defaultDirectoryScope(db))
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
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01],
                             webKitStorageScope: defaultDirectoryScope(db))
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
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01],
                             webKitStorageScope: defaultDirectoryScope(db))
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
        let store = TabStore(appDB: db, profileDataRemover: failing.remover, profileDataRemovalRetryDelays: retryDelays,
                             webKitStorageScope: defaultDirectoryScope(db))
        let keeper = store.addProfile(name: "Keeper").id
        let doomed = store.addProfile(name: "Doomed").id

        let outcome = await store.deleteProfile(id: doomed)?.value

        guard case .failed = outcome else { return XCTFail("expected a failure, got \(String(describing: outcome))") }
        XCTAssertEqual(failing.calls.map(\.step), ["extension", "store", "store", "store"],
                       "the store removal is retried; the extension data step, once done, is not repeated")
        XCTAssertEqual(pendingIDs(db), [doomed.uuidString], "a failed removal stays pending")

        // Next launch: a new store over the same database, before any profile loads.
        let succeeding = FakeRemover()
        let relaunched = TabStore(appDB: db, profileDataRemover: succeeding.remover, profileDataRemovalRetryDelays: retryDelays,
                             webKitStorageScope: defaultDirectoryScope(db))
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
        let removal = ProfileDataRemoval(appDB: db, remover: fake.remover, retryDelays: [0.01],
                                         storageScope: defaultDirectoryScope(db))
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
        let removal = ProfileDataRemoval(appDB: db, remover: fake.remover, retryDelays: [0.01],
                                         storageScope: defaultDirectoryScope(db))
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
        let removal = ProfileDataRemoval(appDB: db, remover: fake.remover, retryDelays: [0.01],
                                         storageScope: defaultDirectoryScope(db))

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
        let removal = ProfileDataRemoval(appDB: db, remover: fake.remover, retryDelays: [0.01],
                                         storageScope: defaultDirectoryScope(db))

        let outcome = await removal.removeDataOfDeletedProfile(id: profile.id).value

        XCTAssertEqual(outcome, .refusedLiveProfile)
        XCTAssertEqual(fake.calls.map(\.step), ["extension"], "the store removal is never attempted")
    }

    // MARK: - Isolated data directories (TASK-36)

    /// The production profiles on the machine this was written on. In the
    /// default data directory the identifier is the profile id itself, so the
    /// existing production stores keep being used.
    func testTheDefaultDataDirectoryUsesTheProfileIDAsTheWebKitIdentifier() throws {
        let personal = try XCTUnwrap(UUID(uuidString: "B0E91083-1EE3-4280-A675-132391F8AE01"))
        let work = try XCTUnwrap(UUID(uuidString: "CA8C2B61-B63B-4577-8EB3-89470FF077DD"))
        for id in [personal, work, UUID()] {
            XCTAssertEqual(WebKitStorageScope.identifier(profileID: id, dataDirectoryName: "Detour"), id)
        }
        XCTAssertEqual(detourDataDirectoryName(environment: [:]), "Detour", "DETOUR_DATA_DIR unset is the default")
        XCTAssertEqual(detourDataDirectoryName(environment: ["DETOUR_DATA_DIR": "Detour"]), "Detour")
        XCTAssertEqual(detourDataDirectoryName(environment: ["DETOUR_DATA_DIR": "DetourVerify"]), "DetourVerify")

        let db = try makeDatabase()
        let scope = defaultDirectoryScope(db)
        XCTAssertTrue(scope.isDefaultDataDirectory)
        XCTAssertEqual(scope.identifierForCreatingStorage(forProfile: personal), personal)
        XCTAssertEqual(db.recordedWebKitStorageIdentifiers(), [], "the default data directory records nothing")
        XCTAssertNotNil(scope.refusalToRemove(identifier: personal), "and never cleans up through the scope")
    }

    func testIsolatedDataDirectoriesDeriveStableVersion5Identifiers() throws {
        // RFC 4122 test vector (Python's uuid.uuid5(NAMESPACE_DNS, "python.org")).
        let dns = try XCTUnwrap(UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"))
        XCTAssertEqual(WebKitStorageScope.nameBasedUUIDv5(namespace: dns, name: "python.org"),
                       UUID(uuidString: "886313E1-3B8A-5372-9B90-0C9AEE199E5D"))

        let profile = UUID()
        let tests = WebKitStorageScope.identifier(profileID: profile, dataDirectoryName: "DetourTests")
        XCTAssertEqual(tests, WebKitStorageScope.identifier(profileID: profile, dataDirectoryName: "DetourTests"),
                       "the same data directory gets the same store across launches")
        XCTAssertNotEqual(tests, profile)
        XCTAssertNotEqual(tests, WebKitStorageScope.identifier(profileID: profile, dataDirectoryName: "DetourVerify"))
        XCTAssertNotEqual(tests, WebKitStorageScope.identifier(profileID: UUID(), dataDirectoryName: "DetourTests"))
        XCTAssertEqual(WebKitStorageScope.version(of: tests), 5)
        XCTAssertEqual(WebKitStorageScope.version(of: UUID()), 4, "profile ids are random, so they never equal a derived id")
    }

    func testAnIsolatedDataDirectoryRecordsIdentifiersItCreatesStorageFor() throws {
        let db = try makeDatabase()
        let scope = isolatedScope(db)
        let profile = UUID()

        let identifier = scope.identifierForCreatingStorage(forProfile: profile)
        _ = scope.identifierForCreatingStorage(forProfile: profile)

        XCTAssertEqual(identifier, scope.identifier(forProfile: profile))
        XCTAssertEqual(db.recordedWebKitStorageIdentifiers(), [identifier])
        XCTAssertEqual(db.recordedWebKitStorageProfileID(for: identifier), profile)
        db.forgetWebKitStorageIdentifier(identifier)
        XCTAssertEqual(db.recordedWebKitStorageIdentifiers(), [])
    }

    /// A profile in the test host's data directory creates its store and
    /// controller under the derived identifier, recorded in the data directory's
    /// database. The storage is removed by the test bundle's cleanup.
    func testAProfileInTheTestDataDirectoryUsesTheDerivedRecordedIdentifier() throws {
        guard !WebKitStorageScope.current.isDefaultDataDirectory else {
            throw XCTSkip("DETOUR_DATA_DIR is unset or \"Detour\"")
        }
        let profile = Profile(name: "TASK-36 derived")
        let identifier = profile.webKitStorageIdentifier
        XCTAssertNotEqual(identifier, profile.id)
        XCTAssertEqual(WebKitStorageScope.version(of: identifier), 5)

        XCTAssertEqual(profile.dataStore.identifier, identifier)
        XCTAssertEqual(profile.extensionController.configuration.identifier, identifier)
        XCTAssertEqual(AppDatabase.shared.recordedWebKitStorageProfileID(for: identifier), profile.id)
    }

    func testTheRemovalGuardOnlyAllowsRecordedIdentifiersDerivedFromThisDataDirectory() throws {
        let db = try makeDatabase()
        let profile = UUID()
        var productionIDs: Set<UUID>? = []
        let scope = isolatedScope(db, productionProfileIDs: { productionIDs })
        let derived = scope.identifierForCreatingStorage(forProfile: profile)
        XCTAssertNil(scope.refusalToRemove(identifier: derived), "recorded, derived, not a production id")

        XCTAssertNotNil(scope.refusalToRemove(identifier: scope.identifier(forProfile: UUID())), "not recorded")

        // A random (version 4) id recorded under a profile, e.g. a production id.
        let random = UUID()
        db.recordWebKitStorageIdentifier(random, profileID: profile)
        XCTAssertNotNil(scope.refusalToRemove(identifier: random), "not derived")

        // Derived from another data directory's name.
        let other = WebKitStorageScope.identifier(profileID: profile, dataDirectoryName: "DetourVerify")
        db.recordWebKitStorageIdentifier(other, profileID: profile)
        XCTAssertNotNil(scope.refusalToRemove(identifier: other), "derived from another data directory")

        productionIDs = [derived]
        XCTAssertEqual(scope.refusalToRemove(identifier: derived), "equals a production profile id")
        productionIDs = nil
        XCTAssertEqual(scope.refusalToRemove(identifier: derived), "the production profile table could not be read")
    }

    func testProductionProfileIDsAreReadFromACopyOfTheDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-task36-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("browser.db")
        XCTAssertEqual(WebKitStorageScope.readProductionProfileIDs(databaseURL: databaseURL), [],
                       "no production database, no production profiles")

        let stored = Profile(name: "Production")
        do {
            let db = try AppDatabase(dbQueue: DatabaseQueue(path: databaseURL.path))
            db.saveProfile(stored.toRecord())
        }
        XCTAssertEqual(WebKitStorageScope.readProductionProfileIDs(databaseURL: databaseURL), [stored.id])

        try Data("not a database".utf8).write(to: databaseURL)
        XCTAssertNil(WebKitStorageScope.readProductionProfileIDs(databaseURL: databaseURL))
    }

    /// Deleting a profile in an isolated data directory removes its storage
    /// under the derived identifier when the data directory recorded creating
    /// it, and forgets the record. A profile that never created storage there
    /// has nothing to remove: no WebKit call, the pending row is cleared.
    func testDeletingAProfileInAnIsolatedDataDirectoryRemovesOnlyRecordedStorage() async throws {
        let db = try makeDatabase()
        let fake = FakeRemover()
        let scope = isolatedScope(db)
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01],
                             webKitStorageScope: scope)
        _ = store.addProfile(name: "Keeper")
        let created = store.addProfile(name: "Created storage").id
        let never = store.addProfile(name: "Never created storage").id
        let createdIdentifier = scope.identifierForCreatingStorage(forProfile: created)

        let createdOutcome = await store.deleteProfile(id: created)?.value

        XCTAssertEqual(createdOutcome, .removed)
        XCTAssertEqual(fake.calls.map(\.step), ["extension", "store"])
        XCTAssertEqual(fake.removedIDs, [createdIdentifier], "the derived identifier, never the profile id")
        XCTAssertEqual(db.recordedWebKitStorageIdentifiers(), [], "the record is forgotten")
        XCTAssertEqual(pendingIDs(db), [])

        let neverOutcome = await store.deleteProfile(id: never)?.value

        XCTAssertEqual(neverOutcome, .skippedUnrecordedStorage)
        XCTAssertEqual(fake.calls.count, 2, "no WebKit removal is attempted")
        XCTAssertEqual(pendingIDs(db), [], "the pending row is cleared, not retried every launch")
        XCTAssertFalse(db.loadProfiles().contains { $0.id == never.uuidString }, "the rows are still deleted")
    }

    /// When the production profile table cannot be read, nothing is removed and
    /// the removal stays pending for the next launch.
    func testIsolatedRemovalWaitsWhileTheProductionProfileTableIsUnreadable() async throws {
        let db = try makeDatabase()
        let fake = FakeRemover()
        let scope = isolatedScope(db, productionProfileIDs: { nil })
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01],
                             webKitStorageScope: scope)
        _ = store.addProfile(name: "Keeper")
        let doomed = store.addProfile(name: "Doomed").id
        let identifier = scope.identifierForCreatingStorage(forProfile: doomed)

        let outcome = await store.deleteProfile(id: doomed)?.value

        guard case .failed = outcome else { return XCTFail("expected a failure, got \(String(describing: outcome))") }
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(pendingIDs(db), [doomed.uuidString])
        XCTAssertEqual(db.recordedWebKitStorageIdentifiers(), [identifier])
    }

    /// TabStore's defaults are the real remover and the process's data
    /// directory. In the test data directory a profile that never created
    /// storage is skipped without any WebKit call.
    func testTabStoreDefaultsSkipUnrecordedStorageInTheTestDataDirectory() async throws {
        let name = WebKitStorageScope.currentDataDirectoryName
        guard name != defaultDetourDataDirectoryName else {
            throw XCTSkip("DETOUR_DATA_DIR is unset or \"Detour\"; the default scope would remove real data")
        }
        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        _ = store.addProfile(name: "Keeper")
        let doomed = store.addProfile(name: "Doomed").id

        let outcome = await store.deleteProfile(id: doomed)?.value

        XCTAssertEqual(outcome, .skippedUnrecordedStorage, "data dir \(name)")
    }

    func testCleanupRemovesRecordedStorageExceptLiveAndRefusedIdentifiers() async throws {
        let db = try makeDatabase()
        let scope = isolatedScope(db)
        let live = UUID(), idle = UUID(), busy = UUID()
        let liveIdentifier = scope.identifierForCreatingStorage(forProfile: live)
        let idleIdentifier = scope.identifierForCreatingStorage(forProfile: idle)
        let busyIdentifier = scope.identifierForCreatingStorage(forProfile: busy)
        let bogus = UUID()
        db.recordWebKitStorageIdentifier(bogus, profileID: idle)

        var calls: [(String, UUID)] = []
        var busyFailuresLeft = 1
        let remover = ProfileDataRemoval.Remover(
            removeExtensionData: { calls.append(("extension", $0)) },
            removeWebsiteDataStore: { identifier in
                calls.append(("store", identifier))
                if identifier == busyIdentifier, busyFailuresLeft > 0 {
                    busyFailuresLeft -= 1
                    throw SimulatedInUse()
                }
            }
        )

        let report = await scope.removeRecordedStorage(excludingProfileIDs: [live], remover: remover, retryDelays: [0.01])

        XCTAssertEqual(report.removed, [idleIdentifier, busyIdentifier])
        XCTAssertEqual(Set(report.kept.keys), [liveIdentifier, bogus])
        XCTAssertFalse(calls.contains { $0.1 == liveIdentifier || $0.1 == bogus }, "never reaches WebKit")
        XCTAssertEqual(calls.filter { $0.1 == idleIdentifier }.map(\.0), ["store", "extension"],
                       "the store first: WebKit refuses it while a controller still uses it")
        XCTAssertEqual(calls.filter { $0.1 == busyIdentifier }.map(\.0), ["store", "store", "extension"])
        XCTAssertEqual(Set(db.recordedWebKitStorageIdentifiers()), [liveIdentifier, bogus])

        let defaultReport = await defaultDirectoryScope(db).removeRecordedStorage(remover: remover)
        XCTAssertEqual(defaultReport, WebKitStorageScope.CleanupReport(), "never in the default data directory")
    }

    func testCleanupRemovesNothingWhileTheProductionProfileTableIsUnreadable() async throws {
        let db = try makeDatabase()
        let scope = isolatedScope(db, productionProfileIDs: { nil })
        let identifier = scope.identifierForCreatingStorage(forProfile: UUID())
        var calls = 0
        let remover = ProfileDataRemoval.Remover(
            removeExtensionData: { _ in calls += 1 }, removeWebsiteDataStore: { _ in calls += 1 })

        let report = await scope.removeRecordedStorage(remover: remover, retryDelays: [0.01])

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(report.removed, [])
        XCTAssertEqual(report.kept, [identifier: "the production profile table could not be read"])
        XCTAssertEqual(db.recordedWebKitStorageIdentifiers(), [identifier])
    }

    /// A restored dormant favourite's favicon callback captured its profile
    /// strongly while the profile held the favourite: the cycle kept every
    /// restored profile with a favourite alive, and with it the website data
    /// store, so a deleted profile's store stayed in use (found by TASK-36's
    /// cleanup).
    func testARestoredProfileWithADormantFavoriteIsReleased() throws {
        let db = try makeDatabase()
        let profileID: UUID
        do {
            let store = TabStore(appDB: db, webKitStorageScope: defaultDirectoryScope(db))
            let profile = store.addProfile(name: "Favourites")
            profileID = profile.id
            let space = store.addSpace(name: "S", emoji: "S", colorHex: "007AFF", profileID: profile.id)
            let tab = BrowserTab(id: UUID(), title: "Fav", url: URL(string: "https://fav.example/")!,
                                 faviconURL: nil, cachedInteractionState: nil, spaceID: space.id)
            store.addFavorite(from: tab, profileID: profile.id)
            profile.favorites.first?.tab = nil   // saved without a backing tab: dormant
            store.saveNow()
        }

        weak var restoredProfile: Profile?
        do {
            let relaunched = TabStore(appDB: db, webKitStorageScope: defaultDirectoryScope(db))
            _ = relaunched.restoreSession()
            let profile = try XCTUnwrap(relaunched.profile(withID: profileID))
            XCTAssertEqual(profile.favorites.count, 1, "precondition: the favourite is restored")
            XCTAssertNil(profile.favorites.first?.tab, "precondition: dormant, so the favicon callback is set")
            restoredProfile = profile
        }

        XCTAssertNil(restoredProfile, "nothing but the store retains a restored profile")
    }

    // MARK: - Session-less launch (TASK-32, TASK-33)

    /// `loadSession` returns nil whenever the space table is empty — deleting the
    /// last persistent space while a Private window is open gets there — and on
    /// any read error. Such a launch must still load every saved profile: a store
    /// that had not would sweep their rows out at the first save (`saveProfiles`)
    /// and, while that sweep armed data removals, irreversibly wipe the user's
    /// cookies, logins and extension storage at the launch after that.
    func testSessionLessLaunchKeepsSavedProfilesAndRemovesNoData() async throws {
        let db = try makeDatabase()
        let orphan = Profile(name: "Saved, never loaded")
        db.saveProfile(orphan.toRecord())
        let fake = FakeRemover()
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01],
                             webKitStorageScope: defaultDirectoryScope(db))

        XCTAssertNil(store.restoreSession(), "precondition: no saved spaces, so there is no session to restore")
        store.ensureDefaultSpace()
        store.saveNow()

        XCTAssertTrue(store.profiles.contains { $0.id == orphan.id }, "the saved profile is held in memory")
        XCTAssertTrue(db.loadProfiles().contains { $0.id == orphan.id.uuidString }, "so its row survives the save")
        XCTAssertEqual(pendingIDs(db), [], "and no data removal is scheduled")
        XCTAssertTrue(fake.calls.isEmpty)

        let outcomes = await store.retryPendingProfileDataRemovals().value

        XCTAssertEqual(outcomes, [:])
        XCTAssertTrue(fake.removedIDs.isEmpty)
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

        let scope = WebKitStorageScope.current
        guard !scope.isDefaultDataDirectory else {
            throw XCTSkip("DETOUR_DATA_DIR is unset or \"Detour\"; this test removes only derived test storage")
        }
        let db = try makeDatabase()
        // The real remover and the test data directory's scope (the defaults):
        // the profiles' storage is created under identifiers derived from the
        // test data directory and recorded in its database, and only those are
        // removed (TASK-36).
        let store = TabStore(appDB: db, profileDataRemover: .webKit)
        let doomedProfileID = store.addProfile(name: "TASK-32 doomed").id
        let otherProfileID = store.addProfile(name: "TASK-32 other").id
        _ = store.addProfile(name: "TASK-32 spare")   // keeps two profiles deletable; never touches WebKit
        let doomed = scope.identifier(forProfile: doomedProfileID)
        let other = scope.identifier(forProfile: otherProfileID)
        XCTAssertNotEqual(doomed, doomedProfileID, "precondition: a derived identifier")

        let doomedProfile = try await populateWebKitData(of: doomedProfileID, in: store, extensionDirectory: extensionDirectory)
        do {
            let otherProfile = try XCTUnwrap(store.profile(withID: otherProfileID))
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: websiteDataStoreDirectory(doomedProfileID).path),
                       "nothing is created under the profile id")
        XCTAssertEqual(AppDatabase.shared.recordedWebKitStorageProfileID(for: doomed), doomedProfileID)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: doomedExtensionDirectory.appendingPathComponent("task32-storage/LocalStorage.db").path),
            "precondition: extension storage.local is on disk")

        let doomedOutcome = await store.deleteProfile(id: doomedProfileID)?.value

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
        XCTAssertNil(AppDatabase.shared.recordedWebKitStorageProfileID(for: doomed), "the record is forgotten")
        XCTAssertNotNil(AppDatabase.shared.recordedWebKitStorageProfileID(for: other))

        // Clean up the other store, which this test created, through the same path.
        let otherOutcome = await store.deleteProfile(id: otherProfileID)?.value
        XCTAssertEqual(otherOutcome, .removed)
        let otherListedAtEnd = await dataStoreIsListed(other)
        XCTAssertFalse(otherListedAtEnd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: websiteDataStoreDirectory(other).path))
        XCTAssertNil(AppDatabase.shared.recordedWebKitStorageProfileID(for: other))
    }
}
