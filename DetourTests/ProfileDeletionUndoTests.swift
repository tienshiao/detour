import XCTest
import GRDB
import WebKit
@testable import Detour

/// Undo after a profile was deleted (TASK-35).
///
/// `TabStore.deleteProfile` refuses a profile a space uses, so the usual
/// sequence is to delete a space (or move it to another profile with Edit
/// Space), then delete its old profile. The Delete Space and Edit Space undos
/// captured that profile's id, and undoing either used to rebuild the space on
/// a profile that no longer exists and crash in `Space.dataStore`.
///
/// The fix clears the undo stack on profile deletion; as defence in depth the
/// two undos are no-ops for a profile that is gone, and a space without a usable
/// profile never creates (or crashes creating) persistent WebKit storage. The
/// stack-clearing tests go through `deleteProfile` with a fake remover; the
/// guard tests remove the profile with `forceRemoveProfile`, which leaves the
/// undo stack alone, to reach the closures.
@MainActor
final class ProfileDeletionUndoTests: XCTestCase {

    private final class FakeRemover {
        var removedIDs: [UUID] = []
        var remover: ProfileDataRemoval.Remover {
            ProfileDataRemoval.Remover(
                removeExtensionData: { _ in },
                removeWebsiteDataStore: { [self] id in removedIDs.append(id) }
            )
        }
    }

    private struct Fixture {
        let db: AppDatabase
        let fake: FakeRemover
        let store: TabStore
        let keeperID: UUID
        let doomedID: UUID
        /// The space that stays, on the keeper profile.
        let homeSpaceID: UUID
    }

    /// A store with two profiles, Keeper and Doomed, and one space on Keeper.
    /// Returns ids only, so the test does not retain the doomed profile.
    private func makeFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let fake = FakeRemover()
        let scope = WebKitStorageScope(dataDirectoryName: defaultDetourDataDirectoryName, registry: db,
                                       productionProfileIDs: { [] })
        let store = TabStore(appDB: db, profileDataRemover: fake.remover, profileDataRemovalRetryDelays: [0.01],
                             webKitStorageScope: scope)
        let keeper = store.addProfile(name: "Keeper")
        useNonPersistentStorage(keeper)
        let doomed = store.addProfile(name: "Doomed")
        let home = store.addSpace(name: "Home", emoji: "H", colorHex: "007AFF", profileID: keeper.id)
        return Fixture(db: db, fake: fake, store: store, keeperID: keeper.id, doomedID: doomed.id,
                       homeSpaceID: home.id)
    }

    /// A profile the test does build web views for gets throwaway WebKit objects,
    /// so the test leaves no persistent storage behind.
    private func useNonPersistentStorage(_ profile: Profile) {
        profile.dataStore = .nonPersistent()
        profile.extensionController = WKWebExtensionController(configuration: .nonPersistent())
    }

    /// Adds a space on `profileID` with one selected tab (undoing its deletion
    /// rebuilds that tab live, through `makeWebViewConfiguration`) and returns
    /// its id.
    private func addSpaceWithSelectedTab(to store: TabStore, profileID: UUID) -> UUID {
        let space = store.addSpace(name: "Doomed space", emoji: "D", colorHex: "FF0000", profileID: profileID)
        let tab = BrowserTab(id: UUID(), title: "Tab", url: URL(string: "https://example.com/")!,
                             faviconURL: nil, cachedInteractionState: nil, spaceID: space.id)
        space.tabs.append(tab)
        space.selectedTabID = tab.id
        return space.id
    }

    /// Whether this data directory recorded creating WebKit storage for
    /// `profileID`. Profiles create their storage through
    /// `WebKitStorageScope.current`, which records every identifier before WebKit
    /// creates it, in any data directory but the production one.
    private func recordedStorage(forProfile profileID: UUID) -> Bool {
        let scope = WebKitStorageScope.current
        return scope.registry.recordedWebKitStorageIdentifiers().contains(scope.identifier(forProfile: profileID))
    }

    private func assertProfileGone(_ id: UUID, _ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(f.store.profile(withID: id), "the profile is not resurrected in memory", file: file, line: line)
        XCTAssertFalse(f.db.loadProfiles().contains { $0.id == id.uuidString },
                       "the profile row is not resurrected", file: file, line: line)
        if !WebKitStorageScope.current.isDefaultDataDirectory {
            XCTAssertFalse(recordedStorage(forProfile: id), "no WebKit storage was created for the deleted profile",
                           file: file, line: line)
        }
    }

    // MARK: - deleteProfile clears the undo stack

    func testUndoDeleteSpaceAfterItsProfileWasDeletedDoesNothing() async throws {
        let f = try makeFixture()
        let spaceID = addSpaceWithSelectedTab(to: f.store, profileID: f.doomedID)
        f.store.undoManager.removeAllActions()

        f.store.deleteSpace(id: spaceID)
        XCTAssertTrue(f.store.undoManager.canUndo, "precondition: Delete Space is undoable")
        let outcome = await f.store.deleteProfile(id: f.doomedID)?.value
        XCTAssertEqual(outcome, .removed)

        XCTAssertFalse(f.store.undoManager.canUndo, "deleting a profile clears the undo stack")
        f.store.undoManager.undo()

        XCTAssertNil(f.store.space(withID: spaceID), "the space is not restored")
        XCTAssertEqual(f.store.spaces.map(\.id), [f.homeSpaceID])
        assertProfileGone(f.doomedID, f)
    }

    func testUndoEditSpaceAfterItsOldProfileWasDeletedLeavesTheSpaceOnItsCurrentProfile() async throws {
        let f = try makeFixture()
        let spaceID = addSpaceWithSelectedTab(to: f.store, profileID: f.doomedID)
        f.store.undoManager.removeAllActions()

        f.store.updateSpace(id: spaceID, name: "Moved", emoji: "M", colorHex: "00FF00", profileID: f.keeperID)
        XCTAssertTrue(f.store.undoManager.canUndo, "precondition: Edit Space is undoable")
        let outcome = await f.store.deleteProfile(id: f.doomedID)?.value
        XCTAssertEqual(outcome, .removed)

        XCTAssertFalse(f.store.undoManager.canUndo)
        f.store.undoManager.undo()

        let space = try XCTUnwrap(f.store.space(withID: spaceID))
        XCTAssertEqual(space.profileID, f.keeperID)
        XCTAssertTrue(space.profile === f.store.profile(withID: f.keeperID))
        XCTAssertEqual(space.name, "Moved")
        _ = space.makeWebViewConfiguration()
        assertProfileGone(f.doomedID, f)
    }

    /// The reverse: the space was moved to a profile, the move was undone, and
    /// that profile was deleted. Redo must not move the space onto it.
    func testRedoEditSpaceOntoAProfileDeletedSinceDoesNothing() async throws {
        let f = try makeFixture()
        let spaceID = addSpaceWithSelectedTab(to: f.store, profileID: f.keeperID)
        f.store.undoManager.removeAllActions()

        f.store.updateSpace(id: spaceID, name: "Moved", emoji: "M", colorHex: "00FF00", profileID: f.doomedID)
        f.store.undoManager.undo()
        XCTAssertEqual(f.store.space(withID: spaceID)?.profileID, f.keeperID, "precondition: undone")
        XCTAssertTrue(f.store.undoManager.canRedo, "precondition: the move is redoable")

        let outcome = await f.store.deleteProfile(id: f.doomedID)?.value
        XCTAssertEqual(outcome, .removed)
        XCTAssertFalse(f.store.undoManager.canRedo, "the redo stack is cleared too")
        f.store.undoManager.redo()

        XCTAssertEqual(f.store.space(withID: spaceID)?.profileID, f.keeperID)
        assertProfileGone(f.doomedID, f)
    }

    func testDeleteProfileClearsTheUndoStack() throws {
        let f = try makeFixture()
        let home = try XCTUnwrap(f.store.space(withID: f.homeSpaceID))
        _ = f.store.addPinnedFolder(name: "Folder", in: home)
        XCTAssertTrue(f.store.undoManager.canUndo, "precondition")

        XCTAssertNotNil(f.store.deleteProfile(id: f.doomedID))

        XCTAssertFalse(f.store.undoManager.canUndo)
        XCTAssertFalse(f.store.undoManager.canRedo)
    }

    func testDeleteProfileRefusedByItsGuardsKeepsTheUndoStack() throws {
        let f = try makeFixture()
        let home = try XCTUnwrap(f.store.space(withID: f.homeSpaceID))
        _ = f.store.addPinnedFolder(name: "Folder", in: home)

        XCTAssertNil(f.store.deleteProfile(id: f.keeperID), "a profile a space uses is not deleted")

        XCTAssertTrue(f.store.undoManager.canUndo, "a refused delete leaves the undo stack alone")
    }

    /// Undo actions retained the spaces they act on, and so their profiles: a
    /// deleted profile, and its data store, stayed alive until the app quit.
    func testTheDeletedProfileIsDeallocated() async throws {
        let f = try makeFixture()
        weak var weakProfile = f.store.profile(withID: f.doomedID)
        XCTAssertNotNil(weakProfile, "precondition")
        // Add Space's undo captures the space, which holds the profile strongly.
        let spaceID = addSpaceWithSelectedTab(to: f.store, profileID: f.doomedID)
        f.store.deleteSpace(id: spaceID)
        XCTAssertNotNil(weakProfile, "precondition: undo actions still retain the profile")

        let task = try XCTUnwrap(f.store.deleteProfile(id: f.doomedID))

        XCTAssertNil(weakProfile, "nothing retains the deleted profile once deleteProfile returns")
        let outcome = await task.value
        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(f.fake.removedIDs, [f.doomedID])
    }

    // MARK: - The undo closures refuse a missing profile

    func testDeleteSpaceUndoIsANoOpWhenItsProfileIsGone() throws {
        let f = try makeFixture()
        let spaceID = addSpaceWithSelectedTab(to: f.store, profileID: f.doomedID)
        f.store.undoManager.removeAllActions()
        // The undo holds the space object itself now (TASK-40), so the refusal
        // must leave that instance detached and empty, not half-rebuilt.
        let doomedSpace = try XCTUnwrap(f.store.space(withID: spaceID))
        f.store.deleteSpace(id: spaceID)

        // Leaves the undo stack in place, unlike deleteProfile.
        f.store.forceRemoveProfile(id: f.doomedID)
        XCTAssertTrue(f.store.undoManager.canUndo, "precondition: the Delete Space undo is still registered")
        f.store.undoManager.undo()

        XCTAssertNil(f.store.space(withID: spaceID), "no space is rebuilt for a profile that is gone")
        XCTAssertEqual(f.store.spaces.map(\.id), [f.homeSpaceID])
        XCTAssertTrue(doomedSpace.tabs.isEmpty, "the retained space is left empty, not repopulated")
        XCTAssertFalse(f.store.undoManager.canRedo, "nothing was restored, so there is nothing to redo")
        XCTAssertNil(f.store.profile(withID: f.doomedID))
        if !WebKitStorageScope.current.isDefaultDataDirectory {
            XCTAssertFalse(recordedStorage(forProfile: f.doomedID))
        }
    }

    func testEditSpaceUndoIsANoOpWhenTheOldProfileIsGone() throws {
        let f = try makeFixture()
        let spaceID = addSpaceWithSelectedTab(to: f.store, profileID: f.doomedID)
        f.store.undoManager.removeAllActions()
        f.store.updateSpace(id: spaceID, name: "Moved", emoji: "M", colorHex: "00FF00", profileID: f.keeperID)

        f.store.forceRemoveProfile(id: f.doomedID)
        XCTAssertTrue(f.store.undoManager.canUndo, "precondition: the Edit Space undo is still registered")
        f.store.undoManager.undo()

        let space = try XCTUnwrap(f.store.space(withID: spaceID))
        XCTAssertEqual(space.profileID, f.keeperID, "the space stays on its current profile")
        XCTAssertNotNil(space.profile)
        XCTAssertEqual(space.name, "Moved", "the whole edit is left in place")
        XCTAssertFalse(f.store.undoManager.canRedo)
    }

    func testEditSpaceRefusesAProfileThatDoesNotExist() throws {
        let f = try makeFixture()
        f.store.undoManager.removeAllActions()

        f.store.updateSpace(id: f.homeSpaceID, name: "Renamed", emoji: "R", colorHex: "00FF00", profileID: UUID())

        let space = try XCTUnwrap(f.store.space(withID: f.homeSpaceID))
        XCTAssertEqual(space.profileID, f.keeperID)
        XCTAssertEqual(space.name, "Home")
        XCTAssertFalse(f.store.undoManager.canUndo)
    }

    // MARK: - A space without a usable profile never crashes or creates storage

    func testASpaceWithoutAProfileGetsANonPersistentConfiguration() {
        let space = Space(name: "Orphan", emoji: "O", colorHex: "007AFF", profileID: UUID())
        XCTAssertNil(space.profile)

        let config = space.makeWebViewConfiguration()

        XCTAssertFalse(config.websiteDataStore.isPersistent)
        XCTAssertNil(config.webExtensionController)
    }

    func testASpaceStillHoldingADeletedProfileNeverCreatesItsStorage() async throws {
        let f = try makeFixture()
        let doomed = try XCTUnwrap(f.store.profile(withID: f.doomedID))
        let orphan = Space(name: "Orphan", emoji: "O", colorHex: "007AFF", profileID: doomed.id)
        orphan.profile = doomed

        let outcome = await f.store.deleteProfile(id: f.doomedID)?.value
        XCTAssertEqual(outcome, .removed)
        XCTAssertTrue(doomed.isDeleted)
        XCTAssertNil(orphan.usableProfile)

        let config = orphan.makeWebViewConfiguration()

        XCTAssertFalse(config.websiteDataStore.isPersistent)
        XCTAssertNil(config.webExtensionController)
        XCTAssertFalse(doomed.dataStore.isPersistent, "a deleted profile's lazy store is never persistent")
        assertProfileGone(f.doomedID, f)
    }

    // MARK: - Ordinary undo

    func testUndoDeleteSpaceStillRestoresTheSpaceWhenNoProfileWasDeleted() throws {
        let f = try makeFixture()
        let spaceID = addSpaceWithSelectedTab(to: f.store, profileID: f.keeperID)
        f.store.undoManager.removeAllActions()

        f.store.deleteSpace(id: spaceID)
        XCTAssertNil(f.store.space(withID: spaceID))
        f.store.undoManager.undo()

        let restored = try XCTUnwrap(f.store.space(withID: spaceID))
        XCTAssertTrue(restored.profile === f.store.profile(withID: f.keeperID))
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertNotNil(restored.tabs.first?.webView, "the selected tab is rebuilt live")
        XCTAssertTrue(f.store.undoManager.canRedo)
        for tab in restored.tabs { tab.teardown() }
    }

    func testUndoEditSpaceStillMovesTheSpaceBackWhenNoProfileWasDeleted() throws {
        let f = try makeFixture()
        let spaceID = addSpaceWithSelectedTab(to: f.store, profileID: f.keeperID)
        let doomed = try XCTUnwrap(f.store.profile(withID: f.doomedID))
        useNonPersistentStorage(doomed)
        f.store.undoManager.removeAllActions()

        f.store.updateSpace(id: spaceID, name: "Moved", emoji: "M", colorHex: "00FF00", profileID: f.doomedID)
        f.store.undoManager.undo()

        let space = try XCTUnwrap(f.store.space(withID: spaceID))
        XCTAssertEqual(space.profileID, f.keeperID)
        XCTAssertEqual(space.name, "Doomed space")
        XCTAssertTrue(f.store.undoManager.canRedo)
    }
}
