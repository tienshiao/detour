import XCTest
import GRDB
import WebKit
@testable import Detour

/// Undo actions registered before a Delete Space, undone after it (TASK-40).
///
/// `deleteSpace`'s undo used to rebuild the space as a *new* `Space` object with
/// the same id, so every undo action registered earlier — Close Tab, Move Tab,
/// Pin/Unpin, Edit Space, the pinned entry and folder actions — kept mutating
/// the discarded instance it had captured: the visible space never changed and
/// observers were handed an object no window shows.
///
/// The fix keeps the instance: the delete empties the space's three lists and
/// the undo repopulates and re-inserts that same object. The space's *contents*
/// are still rebuilt as fresh objects of the same ids, so the closures that
/// touch a tab, entry or folder resolve it by id at undo time.
@MainActor
final class UndoAfterDeleteSpaceTests: XCTestCase {

    private struct Fixture {
        let db: AppDatabase
        let store: TabStore
        let profileID: UUID
        /// The space under test.
        let spaceID: UUID
        /// A second space, so `deleteSpace`'s "keep at least one" guard passes.
        let keeperSpaceID: UUID
    }

    /// A store with one profile and two spaces, with an empty undo stack.
    ///
    /// The profile gets throwaway WebKit objects: an undone Close Tab rebuilds
    /// its tab live, so the test must not leave persistent storage behind.
    private func makeFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let store = TabStore(appDB: db)
        // Group by hand, before anything registers an undo — see `act`.
        store.undoManager.groupsByEvent = false
        let profile = store.addProfile(name: "Test")
        profile.dataStore = .nonPersistent()
        profile.extensionController = WKWebExtensionController(configuration: .nonPersistent())
        store.undoManager.beginUndoGrouping()
        let keeper = store.addSpace(name: "Keeper", emoji: "K", colorHex: "007AFF", profileID: profile.id)
        let space = store.addSpace(name: "Work", emoji: "W", colorHex: "FF3B30", profileID: profile.id)
        store.undoManager.endUndoGrouping()
        store.undoManager.removeAllActions()
        return Fixture(db: db, store: store, profileID: profile.id, spaceID: space.id,
                       keeperSpaceID: keeper.id)
    }

    /// Runs one user action as its own undo group, so the sequences below can be
    /// undone a step at a time.
    ///
    /// In the app `UndoManager.groupsByEvent` closes the open group when the run
    /// loop turns, which is what makes each user action separately undoable. A
    /// test body never turns the run loop, so the fixture switches event
    /// grouping off and every mutation goes through here; otherwise a sequence's
    /// registrations pile into one group and a single undo runs them all.
    private func act(_ store: TabStore, _ body: () -> Void) {
        store.undoManager.beginUndoGrouping()
        body()
        store.undoManager.endUndoGrouping()
    }

    /// The page every sleeping tab below is built on (`sleepingTab`).
    private let exampleURL = URL(string: "https://example.com/")!

    /// Releases the web views an undone Close Tab rebuilds live.
    private func teardownTabs(of space: Space?) {
        guard let space else { return }
        for tab in space.tabs { tab.teardown() }
        for tab in space.pinnedTabs { tab.teardown() }
    }

    // MARK: - Undo Delete Space restores the same object

    func testUndoDeleteSpaceRestoresTheSameSpaceObject() throws {
        let f = try makeFixture()
        let space = try XCTUnwrap(f.store.space(withID: f.spaceID))
        let tab = sleepingTab(exampleURL, in: space)
        let pinned = sleepingTab(exampleURL, title: "Pinned", in: space)
        space.tabs.append(contentsOf: [tab, pinned])
        var folderID: UUID?
        act(f.store) {
            f.store.pinTab(id: pinned.id, in: space)
            folderID = f.store.addPinnedFolder(name: "Folder", in: space).id
        }

        act(f.store) { f.store.deleteSpace(id: f.spaceID) }

        XCTAssertNil(f.store.space(withID: f.spaceID))
        XCTAssertTrue(space.tabs.isEmpty, "the deleted space's lists are emptied")
        XCTAssertTrue(space.pinnedEntries.isEmpty)
        XCTAssertTrue(space.pinnedFolders.isEmpty)

        f.store.undoManager.undo()

        let restored = try XCTUnwrap(f.store.space(withID: f.spaceID))
        XCTAssertTrue(restored === space, "the space comes back as the object the older undo actions captured")
        XCTAssertEqual(restored.name, "Work")
        XCTAssertEqual(restored.emoji, "W")
        XCTAssertEqual(restored.colorHex, "FF3B30")
        XCTAssertTrue(restored.profile === f.store.profile(withID: f.profileID))
        XCTAssertEqual(restored.tabs.map(\.id), [tab.id], "contents come back with their ids")
        XCTAssertEqual(restored.pinnedEntries.map(\.id), [pinned.id])
        XCTAssertEqual(restored.pinnedEntries.first?.tab?.id, pinned.id)
        XCTAssertEqual(restored.pinnedFolders.map(\.id), [folderID])
        XCTAssertEqual(f.store.spaces.map(\.id), [f.keeperSpaceID, f.spaceID], "re-inserted at its old index")
        teardownTabs(of: restored)
    }

    // MARK: - Older undo actions act on the listed space

    /// AC #1: close a tab, delete the space, undo the delete, undo the close.
    func testUndoCloseTabAfterUndoDeleteSpaceRestoresIntoTheListedSpace() throws {
        let f = try makeFixture()
        let space = try XCTUnwrap(f.store.space(withID: f.spaceID))
        let keep = sleepingTab(exampleURL, title: "Keep", in: space)
        let closing = sleepingTab(exampleURL, title: "Closed", in: space)
        space.tabs.append(contentsOf: [keep, closing])

        act(f.store) { f.store.closeTab(id: closing.id, in: space) }
        XCTAssertEqual(space.tabs.map(\.id), [keep.id], "precondition: the tab is closed")

        act(f.store) { f.store.deleteSpace(id: f.spaceID) }
        f.store.undoManager.undo()  // Undo Delete Space
        let restored = try XCTUnwrap(f.store.space(withID: f.spaceID))
        XCTAssertTrue(restored === space, "precondition: the same space object is listed")
        XCTAssertEqual(restored.tabs.map(\.id), [keep.id])

        f.store.undoManager.undo()  // Undo Close Tab

        let listed = try XCTUnwrap(f.store.space(withID: f.spaceID))
        XCTAssertTrue(listed === space, "the close undo did not fork a second space object")
        XCTAssertEqual(listed.tabs.count, 2, "the tab is back in the space the store lists")
        XCTAssertEqual(listed.tabs.first?.id, keep.id, "the rebuilt tab kept its id and its place")
        // Close Tab's undo mints a fresh tab id (it rebuilds from a snapshot), so
        // the reopened pane is identified by its page.
        let reopened = try XCTUnwrap(listed.tabs.last)
        XCTAssertNotEqual(reopened.id, keep.id)
        XCTAssertEqual(reopened.url?.absoluteString, "https://example.com/")
        teardownTabs(of: listed)
    }

    /// AC #3, a pinned action: the Pin Tab undo resolves the entry the rebuild
    /// replaced, and unpins it in the listed space.
    func testUndoPinTabAfterUndoDeleteSpaceUnpinsInTheListedSpace() throws {
        let f = try makeFixture()
        let space = try XCTUnwrap(f.store.space(withID: f.spaceID))
        let tab = sleepingTab(exampleURL, in: space)
        space.tabs.append(tab)

        act(f.store) { f.store.pinTab(id: tab.id, in: space) }
        XCTAssertEqual(space.pinnedEntries.map(\.id), [tab.id], "precondition: pinned")

        act(f.store) { f.store.deleteSpace(id: f.spaceID) }
        f.store.undoManager.undo()  // Undo Delete Space
        let restored = try XCTUnwrap(f.store.space(withID: f.spaceID))
        // The entry the Pin Tab undo captured is gone — this one is a fresh
        // object with the same id.
        let rebuiltEntry = try XCTUnwrap(restored.pinnedEntries.first)
        XCTAssertEqual(rebuiltEntry.id, tab.id, "precondition: the entry was rebuilt")

        f.store.undoManager.undo()  // Undo Pin Tab

        let listed = try XCTUnwrap(f.store.space(withID: f.spaceID))
        XCTAssertTrue(listed === space)
        XCTAssertTrue(listed.pinnedEntries.isEmpty, "the pin was undone in the space the store lists")
        XCTAssertEqual(listed.tabs.map(\.id), [tab.id])
        teardownTabs(of: listed)
    }

    /// The Unpin Tab undo captured the backing tab; the rebuild replaces it with
    /// a fresh tab of the same id, which the undo now resolves.
    func testUndoUnpinTabAfterUndoDeleteSpaceRepinsInTheListedSpace() throws {
        let f = try makeFixture()
        let space = try XCTUnwrap(f.store.space(withID: f.spaceID))
        let tab = sleepingTab(exampleURL, in: space)
        space.tabs.append(tab)
        act(f.store) { f.store.pinTab(id: tab.id, in: space) }
        f.store.undoManager.removeAllActions()

        act(f.store) { XCTAssertTrue(f.store.unpinTab(id: tab.id, in: space)) }
        XCTAssertEqual(space.tabs.map(\.id), [tab.id], "precondition: unpinned")

        act(f.store) { f.store.deleteSpace(id: f.spaceID) }
        f.store.undoManager.undo()  // Undo Delete Space
        f.store.undoManager.undo()  // Undo Unpin Tab

        let listed = try XCTUnwrap(f.store.space(withID: f.spaceID))
        XCTAssertTrue(listed === space)
        XCTAssertTrue(listed.tabs.isEmpty, "the unpin was undone in the space the store lists")
        XCTAssertEqual(listed.pinnedEntries.map(\.id), [tab.id])
        XCTAssertEqual(listed.pinnedEntries.first?.tab?.id, tab.id)
        teardownTabs(of: listed)
    }

    /// A folder action: the New Folder undo deletes the folder the rebuild
    /// replaced, in the listed space.
    func testUndoNewFolderAfterUndoDeleteSpaceDeletesTheRebuiltFolder() throws {
        let f = try makeFixture()
        let space = try XCTUnwrap(f.store.space(withID: f.spaceID))
        var folder: PinnedFolder?
        act(f.store) { folder = f.store.addPinnedFolder(name: "Folder", in: space) }
        let created = try XCTUnwrap(folder)

        act(f.store) { f.store.deleteSpace(id: f.spaceID) }
        f.store.undoManager.undo()  // Undo Delete Space
        let restored = try XCTUnwrap(f.store.space(withID: f.spaceID))
        let rebuilt = try XCTUnwrap(restored.pinnedFolders.first)
        XCTAssertEqual(rebuilt.id, created.id)
        XCTAssertFalse(rebuilt === created, "precondition: the rebuild replaced the folder object")

        f.store.undoManager.undo()  // Undo New Folder

        let listed = try XCTUnwrap(f.store.space(withID: f.spaceID))
        XCTAssertTrue(listed === space)
        XCTAssertTrue(listed.pinnedFolders.isEmpty, "the folder was removed from the space the store lists")
    }

    /// AC #3, Edit Space: its undo already resolved the space by id, and the
    /// restored space takes back the identity it had when it was deleted.
    func testUndoEditSpaceAfterUndoDeleteSpaceEditsTheListedSpace() throws {
        let f = try makeFixture()

        act(f.store) {
            f.store.updateSpace(id: f.spaceID, name: "Renamed", emoji: "R", colorHex: "34C759",
                                profileID: f.profileID)
        }
        act(f.store) { f.store.deleteSpace(id: f.spaceID) }
        f.store.undoManager.undo()  // Undo Delete Space

        let restored = try XCTUnwrap(f.store.space(withID: f.spaceID))
        XCTAssertEqual(restored.name, "Renamed", "the space comes back as it was when deleted")
        XCTAssertEqual(restored.emoji, "R")
        XCTAssertEqual(restored.colorHex, "34C759")

        f.store.undoManager.undo()  // Undo Edit Space

        let listed = try XCTUnwrap(f.store.space(withID: f.spaceID))
        XCTAssertTrue(listed === restored)
        XCTAssertEqual(listed.name, "Work", "the edit was undone on the space the store lists")
        XCTAssertEqual(listed.emoji, "W")
        XCTAssertEqual(listed.colorHex, "FF3B30")
    }

    // MARK: - Ordinary undo is unchanged

    func testUndoCloseTabWithoutADeleteStillRestoresTheTab() throws {
        let f = try makeFixture()
        let space = try XCTUnwrap(f.store.space(withID: f.spaceID))
        let tab = sleepingTab(exampleURL, in: space)
        space.tabs.append(tab)

        act(f.store) { f.store.closeTab(id: tab.id, in: space) }
        f.store.undoManager.undo()

        XCTAssertEqual(space.tabs.count, 1)
        XCTAssertEqual(space.tabs.first?.url?.absoluteString, "https://example.com/")
        XCTAssertNotNil(space.tabs.first?.webView, "the reopened tab is rebuilt live")
        teardownTabs(of: space)
    }

    /// Delete, undo, redo, undo: the second delete re-snapshots and empties the
    /// same object, so the space comes back once, not doubled.
    func testRedoDeleteSpaceThenUndoAgainRestoresTheSpaceOnce() throws {
        let f = try makeFixture()
        let space = try XCTUnwrap(f.store.space(withID: f.spaceID))
        let tab = sleepingTab(exampleURL, in: space)
        space.tabs.append(tab)

        act(f.store) { f.store.deleteSpace(id: f.spaceID) }
        f.store.undoManager.undo()
        XCTAssertEqual(f.store.space(withID: f.spaceID)?.tabs.count, 1)

        f.store.undoManager.redo()  // Delete Space again
        XCTAssertNil(f.store.space(withID: f.spaceID))
        f.store.undoManager.undo()

        let listed = try XCTUnwrap(f.store.space(withID: f.spaceID))
        XCTAssertTrue(listed === space)
        XCTAssertEqual(listed.tabs.map(\.id), [tab.id], "no duplicate tabs after a second rebuild")
        XCTAssertEqual(f.store.spaces.map(\.id), [f.keeperSpaceID, f.spaceID])
        teardownTabs(of: listed)
    }
}
