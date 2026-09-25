import XCTest
import GRDB
@testable import Detour

final class TabStoreTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        return try AppDatabase(dbQueue: dbQueue)
    }

    private func makeStore() throws -> (TabStore, Space) {
        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Test")
        let space = store.addSpace(name: "Test", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        return (store, space)
    }

    private func makeSleepingTab(spaceID: UUID) -> BrowserTab {
        BrowserTab(
            id: UUID(),
            title: "Tab",
            url: URL(string: "https://example.com"),
            faviconURL: nil,
            cachedInteractionState: nil,
            spaceID: spaceID
        )
    }

    // MARK: - Pin / Unpin

    func testPinTabMovesToPinnedEntries() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)

        store.pinTab(id: tab.id, in: space)

        XCTAssertTrue(space.tabs.isEmpty)
        XCTAssertEqual(space.pinnedEntries.count, 1)
        XCTAssertEqual(space.pinnedEntries[0].pinnedURL, tab.url)
        XCTAssertEqual(space.pinnedEntries[0].pinnedTitle, tab.title)
        XCTAssertTrue(space.pinnedEntries[0].isLive)
    }

    func testUnpinTabMovesBackToTabs() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)
        let entryID = space.pinnedEntries[0].id

        store.unpinTab(id: entryID, in: space)

        XCTAssertTrue(space.pinnedEntries.isEmpty)
        XCTAssertEqual(space.tabs.count, 1)
    }

    func testPinTabAtSpecificIndex() throws {
        let (store, space) = try makeStore()
        let tab1 = makeSleepingTab(spaceID: space.id)
        let tab2 = makeSleepingTab(spaceID: space.id)
        let tab3 = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: [tab1, tab2, tab3])

        store.pinTab(id: tab1.id, in: space)
        store.pinTab(id: tab2.id, in: space)
        // Pin tab3 at index 0 (before tab1)
        store.pinTab(id: tab3.id, in: space, at: 0)

        let entryTabIDs = space.pinnedEntries.compactMap { $0.tab?.id }
        XCTAssertEqual(entryTabIDs, [tab3.id, tab1.id, tab2.id])
    }

    // MARK: - Move Tab

    func testMoveTabReorders() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)

        store.moveTab(from: 0, to: 2, in: space)

        XCTAssertEqual(space.tabs.map(\.id), [tabs[1].id, tabs[2].id, tabs[0].id])
    }

    func testMoveTabSameIndexIsNoOp() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        let originalOrder = space.tabs.map(\.id)

        store.moveTab(from: 1, to: 1, in: space)

        XCTAssertEqual(space.tabs.map(\.id), originalOrder)
    }

    func testMoveTabOutOfBoundsIsNoOp() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)

        store.moveTab(from: 0, to: 5, in: space)

        XCTAssertEqual(space.tabs.count, 1)
        XCTAssertEqual(space.tabs[0].id, tab.id)
    }

    // MARK: - Move Pinned Tab

    func testMovePinnedTabReorders() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        for tab in tabs { store.pinTab(id: tab.id, in: space) }

        // Move entry for tabs[0] to the end
        let entryID = space.pinnedEntries.first(where: { $0.tab?.id == tabs[0].id })!.id
        store.movePinnedTabToFolder(tabID: entryID, folderID: nil, beforeItemID: nil, in: space)

        // entry for tabs[0] should now be last, sorted by sortOrder
        let sorted = space.pinnedEntries.sorted { $0.sortOrder < $1.sortOrder }
        let sortedTabIDs = sorted.compactMap { $0.tab?.id }
        XCTAssertEqual(sortedTabIDs, [tabs[1].id, tabs[2].id, tabs[0].id])
    }

    // MARK: - Move Pinned Folder

    func testMovePinnedFolderToFirstPosition() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)

        let folder = store.addPinnedFolder(name: "Folder", in: space)
        let entry = space.pinnedEntries[0]

        // Move folder before the entry (to first position)
        store.movePinnedFolder(folderID: folder.id, parentFolderID: nil, beforeItemID: entry.id, in: space)

        XCTAssertLessThan(folder.sortOrder, entry.sortOrder,
                          "Folder should have lower sort order than entry after move to first position")

        let items = flattenPinnedTree(entries: space.pinnedEntries, folders: space.pinnedFolders,
                                       collapsedFolderIDs: [], selectedTabID: nil)
        XCTAssertEqual(items.count, 2)
        if case .folder(let f, _) = items[0] {
            XCTAssertEqual(f.id, folder.id, "Folder should appear first")
        } else {
            XCTFail("Expected folder first")
        }
    }

    func testMovePinnedFolderToFirstPositionPersistsAfterSave() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)

        let folder = store.addPinnedFolder(name: "Folder", in: space)
        let entry = space.pinnedEntries[0]

        // Move folder before the entry
        store.movePinnedFolder(folderID: folder.id, parentFolderID: nil, beforeItemID: entry.id, in: space)

        // Force save
        store.saveNow()

        // Verify the saved sort orders are correct
        let items = flattenPinnedTree(entries: space.pinnedEntries, folders: space.pinnedFolders,
                                       collapsedFolderIDs: [], selectedTabID: nil)
        guard items.count == 2 else { XCTFail("Expected 2 items"); return }
        if case .folder(let f, _) = items[0] {
            XCTAssertEqual(f.id, folder.id, "Folder should be first after save")
        } else {
            XCTFail("Expected folder first after save, got entry")
        }
    }

    // MARK: - Sort Order Persistence

    func testMovePinnedTabBeforeFolderSetsCorrectSortOrder() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        let folder = PinnedFolder(name: "Folder", sortOrder: 0)
        space.pinnedFolders.append(folder)

        // Pin the tab (gets sort order after folder)
        store.pinTab(id: tab.id, in: space)
        let entry = space.pinnedEntries[0]

        // Move entry before the folder
        store.movePinnedTabToFolder(tabID: entry.id, folderID: nil, beforeItemID: folder.id, in: space)

        // Entry should have lower sort order than folder
        XCTAssertEqual(entry.sortOrder, 0)
        XCTAssertEqual(folder.sortOrder, 1)

        // Verify the flattened tree reflects the correct order
        let items = flattenPinnedTree(entries: space.pinnedEntries, folders: space.pinnedFolders,
                                       collapsedFolderIDs: [], selectedTabID: nil)
        XCTAssertEqual(items.count, 2)
        if case .entry(let e, _) = items[0] {
            XCTAssertEqual(e.id, entry.id, "Entry should appear before folder")
        } else {
            XCTFail("Expected entry first")
        }
        if case .folder(let f, _) = items[1] {
            XCTAssertEqual(f.id, folder.id, "Folder should appear after entry")
        } else {
            XCTFail("Expected folder second")
        }
    }

    func testAddFolderSortOrderAccountsForEntries() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)
        let entry = space.pinnedEntries[0]

        let folder = store.addPinnedFolder(name: "Folder", in: space)

        // New folder must have sort order higher than existing entries
        XCTAssertGreaterThan(folder.sortOrder, entry.sortOrder,
                             "Newly created folder must have sort order after existing pinned entries")
    }

    func testPinTabSortOrderAccountsForFolders() throws {
        let (store, space) = try makeStore()
        let folder = PinnedFolder(name: "Folder", sortOrder: 5)
        space.pinnedFolders.append(folder)

        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)
        let entry = space.pinnedEntries[0]

        // New entry's sort order must be higher than the folder's
        XCTAssertGreaterThan(entry.sortOrder, folder.sortOrder,
                             "Newly pinned entry must have sort order after existing folders")
    }

    // MARK: - Profile added (TASK-27)

    private final class ProfileAddRecorder: TabStoreObserver {
        var added: [UUID] = []
        func tabStoreDidAddProfile(_ profile: Profile) { added.append(profile.id) }
    }

    /// Every path that creates a profile mid-session tells observers, once; that is
    /// what ExtensionManager loads a new profile's extensions from.
    func testCreatingAProfileNotifiesObserversOnce() throws {
        let store = TabStore(appDB: try makeDatabase())
        let recorder = ProfileAddRecorder()
        store.addObserver(recorder)

        let added = store.addProfile(name: "Added")
        XCTAssertEqual(recorder.added, [added.id])

        let incognito = store.ensureIncognitoProfile()
        store.ensureIncognitoProfile()
        XCTAssertEqual(recorder.added, [added.id, incognito.id],
                       "the Private profile is announced when it is created, not when it is looked up")
    }

    /// The first-launch default profile is announced too.
    func testDefaultProfileCreationNotifiesObservers() throws {
        let store = TabStore(appDB: try makeDatabase())
        let recorder = ProfileAddRecorder()
        store.addObserver(recorder)

        store.ensureDefaultSpace()

        XCTAssertEqual(recorder.added.count, 1)
        XCTAssertEqual(recorder.added.first, store.profiles.first?.id)
    }

    // MARK: - Incognito Profile

    func testIncognitoProfileIsIncognitoAfterRestore() throws {
        // Create a store, trigger incognito profile creation, and save
        let db = try makeDatabase()
        let store1 = TabStore(appDB: db)
        let regularProfile = store1.addProfile(name: "Default")
        let _ = store1.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: regularProfile.id)
        store1.ensureIncognitoProfile()
        store1.saveNow()

        // Create a fresh store from the same DB (simulates app restart)
        let store2 = TabStore(appDB: db)
        let _ = store2.restoreSession()

        let incognito = store2.profiles.first { $0.id == TabStore.incognitoProfileID }
        XCTAssertNotNil(incognito, "Incognito profile should exist after restore")
        XCTAssertTrue(incognito!.isIncognito,
                      "Incognito profile must have isIncognito=true after DB round-trip")
    }

    func testIncognitoProfileDataStoreIsNonPersistent() throws {
        let db = try makeDatabase()
        let store1 = TabStore(appDB: db)
        let regularProfile = store1.addProfile(name: "Default")
        let _ = store1.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: regularProfile.id)
        store1.ensureIncognitoProfile()
        store1.saveNow()

        // Restore into a fresh store
        let store2 = TabStore(appDB: db)
        let _ = store2.restoreSession()

        let incognito = store2.profiles.first { $0.id == TabStore.incognitoProfileID }!
        // A non-persistent data store has isPersistent == false
        XCTAssertFalse(incognito.dataStore.isPersistent,
                       "Incognito profile dataStore must be non-persistent after DB round-trip")
    }

    func testIncognitoSpaceDoesNotRecordHistory() throws {
        let appDB = try makeDatabase()
        let historyDB = try HistoryDatabase(dbQueue: DatabaseQueue())
        let store = TabStore(appDB: appDB, historyDB: historyDB)

        // Set up an incognito space
        let profile = store.ensureIncognitoProfile()
        let space = store.addIncognitoSpace()

        // Create a tab with a URL
        let tab = makeSleepingTab(spaceID: space.id)
        tab.url = URL(string: "https://secret.example.com")
        tab.title = "Secret Page"
        space.tabs.append(tab)

        // Attempt to record history
        store.recordHistoryVisit(tab: tab, spaceID: space.id)

        // Verify nothing was recorded
        let results = historyDB.searchHistory(query: "secret", spaceID: space.id.uuidString)
        XCTAssertTrue(results.isEmpty,
                      "History must not be recorded for incognito spaces")
    }

    func testIncognitoSpaceDoesNotRecordHistoryAfterRestore() throws {
        let appDB = try makeDatabase()
        let historyDB = try HistoryDatabase(dbQueue: DatabaseQueue())

        // Create store, add incognito profile, save, and restore
        let store1 = TabStore(appDB: appDB)
        let regularProfile = store1.addProfile(name: "Default")
        let _ = store1.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: regularProfile.id)
        store1.ensureIncognitoProfile()
        store1.saveNow()

        let store2 = TabStore(appDB: appDB, historyDB: historyDB)
        let _ = store2.restoreSession()

        // Add an incognito space to the restored store
        let space = store2.addIncognitoSpace()
        let tab = makeSleepingTab(spaceID: space.id)
        tab.url = URL(string: "https://private.example.com")
        tab.title = "Private Page"
        space.tabs.append(tab)

        store2.recordHistoryVisit(tab: tab, spaceID: space.id)

        let results = historyDB.searchHistory(query: "private", spaceID: space.id.uuidString)
        XCTAssertTrue(results.isEmpty,
                      "History must not be recorded for incognito spaces after DB round-trip")
    }

    func testTypedNavigationBypassesHistoryDedup() throws {
        let appDB = try makeDatabase()
        let historyDB = try HistoryDatabase(dbQueue: DatabaseQueue())
        let store = TabStore(appDB: appDB, historyDB: historyDB)
        let profile = store.addProfile(name: "Test")
        let space = store.addSpace(name: "Test", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)

        let url = URL(string: "https://example.com")!
        let tab = makeSleepingTab(spaceID: space.id)
        tab.url = url
        tab.title = "Example"
        space.tabs.append(tab)

        // First (untyped) visit records and opens the 30s dedup window.
        store.recordHistoryVisit(tab: tab, spaceID: space.id)

        // A deliberate re-navigation within the window must still record.
        tab.load(url, typed: true)
        store.recordHistoryVisit(tab: tab, spaceID: space.id)

        let visitCount = try historyDB.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM historyVisit")
        }
        XCTAssertEqual(visitCount, 2, "Typed navigation must bypass the 30s history dedup window")
    }

    // MARK: - Observer Tests

    func testPinTabNotifiesObserver() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        let observer = MockTabStoreObserver()
        store.addObserver(observer)

        store.pinTab(id: tab.id, in: space)

        XCTAssertEqual(observer.pinCalls.count, 1)
        XCTAssertEqual(observer.pinCalls[0].fromIndex, 0)
        XCTAssertEqual(observer.pinCalls[0].toIndex, 0)
    }

    func testUnpinTabNotifiesObserver() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)
        let entryID = space.pinnedEntries[0].id
        let observer = MockTabStoreObserver()
        store.addObserver(observer)

        store.unpinTab(id: entryID, in: space)

        XCTAssertEqual(observer.unpinCalls.count, 1)
        XCTAssertEqual(observer.unpinCalls[0].fromIndex, 0)
        XCTAssertEqual(observer.unpinCalls[0].toIndex, 0)
    }

    func testMoveTabNotifiesObserver() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        let observer = MockTabStoreObserver()
        store.addObserver(observer)

        store.moveTab(from: 0, to: 2, in: space)

        XCTAssertEqual(observer.reorderCalls, 1)
    }

    // MARK: - Profile Swap

    private func makeStoreWithTwoProfiles() throws -> (TabStore, Space, old: Profile, new: Profile) {
        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        let oldProfile = store.addProfile(name: "Old")
        let newProfile = store.addProfile(name: "New")
        let space = store.addSpace(name: "Swap", emoji: "🧪", colorHex: "007AFF", profileID: oldProfile.id)
        return (store, space, oldProfile, newProfile)
    }

    private func swapProfile(_ store: TabStore, _ space: Space, to profile: Profile) {
        store.updateSpace(id: space.id, name: space.name, emoji: space.emoji,
                          colorHex: space.colorHex, profileID: profile.id)
    }

    func testProfileSwapForceSleepsAudioPlayingTab() throws {
        let (store, space, _, newProfile) = try makeStoreWithTwoProfiles()
        let tab = store.addTab(in: space, url: URL(string: "https://example.com"))
        XCTAssertNotNil(tab.webView)
        tab.isPlayingAudio = true

        swapProfile(store, space, to: newProfile)

        XCTAssertTrue(tab.isSleeping, "audio playback must not exempt a tab from a profile swap")
        XCTAssertNil(tab.webView, "the old profile's webView must be released")
    }

    func testProfileSwapDeactivatesFavoriteBackedTab() throws {
        let (store, space, oldProfile, newProfile) = try makeStoreWithTwoProfiles()
        store.addFavoriteFromEntry(url: URL(string: "https://example.com")!, title: "Fav",
                                   faviconURL: nil, favicon: nil, profileID: oldProfile.id, at: 0)
        let fav = oldProfile.favorites[0]
        store.activateFavorite(id: fav.id, profileID: oldProfile.id, in: space)
        XCTAssertNotNil(fav.tab?.webView)

        swapProfile(store, space, to: newProfile)

        XCTAssertNil(fav.tab, "favorite backing tab bound to the swapped space must return to a dormant tile")
    }

    func testProfileSwapMovesSelectionOffFavoriteBackedTab() throws {
        let (store, space, oldProfile, newProfile) = try makeStoreWithTwoProfiles()
        let normalTab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(normalTab)
        store.addFavoriteFromEntry(url: URL(string: "https://example.com")!, title: "Fav",
                                   faviconURL: nil, favicon: nil, profileID: oldProfile.id, at: 0)
        let fav = oldProfile.favorites[0]
        store.activateFavorite(id: fav.id, profileID: oldProfile.id, in: space)
        space.selectedTabID = fav.tab?.id

        swapProfile(store, space, to: newProfile)

        XCTAssertEqual(space.selectedTabID, normalTab.id,
                       "selection must move to a surviving tab before the favorite's tab is torn down")
    }

    func testProfileSwapPostsSpaceTabsNeedRehostNotification() throws {
        let (store, space, _, newProfile) = try makeStoreWithTwoProfiles()
        let exp = expectation(forNotification: .spaceTabsNeedRehost, object: nil) { note in
            note.userInfo?["spaceID"] as? UUID == space.id
        }

        swapProfile(store, space, to: newProfile)

        wait(for: [exp], timeout: 1)
    }

    func testProfileSwapLeavesOtherSpacesFavoriteTabsAlone() throws {
        let (store, space, oldProfile, newProfile) = try makeStoreWithTwoProfiles()
        let otherSpace = store.addSpace(name: "Other", emoji: "🅾️", colorHex: "FF0000",
                                        profileID: oldProfile.id)
        store.addFavoriteFromEntry(url: URL(string: "https://example.com")!, title: "Fav",
                                   faviconURL: nil, favicon: nil, profileID: oldProfile.id, at: 0)
        let fav = oldProfile.favorites[0]
        store.activateFavorite(id: fav.id, profileID: oldProfile.id, in: otherSpace)
        XCTAssertNotNil(fav.tab?.webView)

        swapProfile(store, space, to: newProfile)

        XCTAssertNotNil(fav.tab?.webView,
                        "a favorite tab bound to a different space on the old profile must stay live")
    }

    // MARK: - Archive vs close records (TASK-115)

    /// A store whose undo manager groups manually, so `canUndo` reads what one
    /// close registered: a test body never turns the run loop that closes an
    /// event group. Every closing call goes through `inUndoGroup`.
    private func makeArchiveFixture() throws -> (AppDatabase, TabStore, Space) {
        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Archive")
        let space = store.addSpace(name: "Archive", emoji: "🗄️", colorHex: "007AFF", profileID: profile.id)
        // After the setup above: adding a space registers an undo of its own,
        // and once grouping is manual that would happen outside any group.
        store.undoManager.removeAllActions()
        store.undoManager.groupsByEvent = false
        return (db, store, space)
    }

    private func inUndoGroup(_ store: TabStore, _ body: () -> Void) {
        store.undoManager.beginUndoGrouping()
        body()
        store.undoManager.endUndoGrouping()
    }

    func testManualArchiveRecordsArchivedAtAndRegistersUndo() throws {
        let (db, store, space) = try makeArchiveFixture()
        let tab = makeSleepingTab(spaceID: space.id)
        let other = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: [tab, other])
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_000)

        inUndoGroup(store) { store.closeTab(id: tab.id, in: space, archivedAt: archivedAt) }

        let record = try XCTUnwrap(db.closedTabSummaries().first { $0.tabID == tab.id.uuidString })
        XCTAssertEqual(record.archivedAt, archivedAt.timeIntervalSince1970,
                       "a sidebar Archive Tab stamps the record as archived")
        XCTAssertEqual(store.closedTabRecords(in: space).first?.archivedAt, archivedAt.timeIntervalSince1970)
        XCTAssertTrue(store.undoManager.canUndo, "a manual archive is undoable like a close")
        XCTAssertEqual(store.undoManager.undoActionName, "Archive Tab", "and is undone under its own name")
    }

    func testRedoOfUndoneArchiveKeepsArchivedAt() throws {
        let (db, store, space) = try makeArchiveFixture()
        let tab = makeSleepingTab(spaceID: space.id)
        let other = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: [tab, other])
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_000)

        inUndoGroup(store) { store.closeTab(id: tab.id, in: space, archivedAt: archivedAt) }
        store.undoManager.undo()
        XCTAssertEqual(space.tabs.count, 2, "undo restores the archived tab")
        XCTAssertFalse(db.closedTabSummaries().contains { $0.tabID == tab.id.uuidString })
        XCTAssertTrue(store.undoManager.canRedo)

        store.undoManager.redo()

        XCTAssertEqual(space.tabs.map(\.id), [other.id], "redo closes the restored tab again")
        let record = try XCTUnwrap(db.closedTabSummaries().first)
        XCTAssertEqual(record.archivedAt, archivedAt.timeIntervalSince1970,
                       "a redone archive is still an archive, not a plain close")
    }

    func testTimerArchiveRecordsArchivedAtWithoutUndo() throws {
        let (db, store, space) = try makeArchiveFixture()
        let threshold = try XCTUnwrap(space.profile).archiveThreshold
        XCTAssertNotEqual(threshold, .never, "precondition: the profile archives")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = makeSleepingTab(spaceID: space.id)
        stale.lastDeselectedAt = now.addingTimeInterval(-threshold.rawValue - 3600)
        let fresh = makeSleepingTab(spaceID: space.id)
        fresh.lastDeselectedAt = now.addingTimeInterval(-60)
        space.tabs.append(contentsOf: [stale, fresh])

        // Outside any undo group on purpose: grouping is manual in this fixture,
        // so a registration here would also trip NSUndoManager's "must begin a
        // group" error, and an explicitly opened group would count as undoable
        // even when nothing registers into it.
        store.archiveStaleTabs(now: now)

        XCTAssertEqual(space.tabs.map(\.id), [fresh.id], "only the stale tab is archived")
        let record = try XCTUnwrap(db.closedTabSummaries().first { $0.tabID == stale.id.uuidString })
        XCTAssertEqual(record.archivedAt, now.timeIntervalSince1970)
        XCTAssertFalse(store.undoManager.canUndo, "the archive sweep must not register an undo")
    }

    func testPlainCloseRecordsNoArchivedAtAndRegistersUndo() throws {
        let (db, store, space) = try makeArchiveFixture()
        let tab = makeSleepingTab(spaceID: space.id)
        let other = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: [tab, other])

        inUndoGroup(store) { store.closeTab(id: tab.id, in: space) }

        let record = try XCTUnwrap(db.closedTabSummaries().first { $0.tabID == tab.id.uuidString })
        XCTAssertNil(record.archivedAt, "Cmd+W / Close Tab is not an archive")
        XCTAssertTrue(store.undoManager.canUndo)
        XCTAssertEqual(store.undoManager.undoActionName, "Close Tab")
    }

    func testIncognitoArchiveWritesNoClosedTabRecord() throws {
        let (db, store, _) = try makeArchiveFixture()
        let space = store.addIncognitoSpace()
        let tab = makeSleepingTab(spaceID: space.id)
        let other = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: [tab, other])

        inUndoGroup(store) { store.closeTab(id: tab.id, in: space, archivedAt: Date()) }

        XCTAssertFalse(db.closedTabSummaries().contains { $0.tabID == tab.id.uuidString })
        XCTAssertFalse(store.closedTabRecords(in: space).contains { $0.tabID == tab.id.uuidString })
    }

    // MARK: - Closed-tab records live in the database only (TASK-117)

    private func makeTab(_ url: String, spaceID: UUID) -> BrowserTab {
        BrowserTab(id: UUID(), title: url, url: URL(string: url), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: spaceID)
    }

    func testDeleteSpaceUndoKeepsReopenOrder() throws {
        let (db, store, space) = try makeArchiveFixture()
        let profileID = try XCTUnwrap(space.profile).id
        var otherSpace: Space?
        inUndoGroup(store) {
            otherSpace = store.addSpace(name: "Other", emoji: "🧪", colorHex: "007AFF", profileID: profileID)
        }
        let other = try XCTUnwrap(otherSpace)
        store.undoManager.removeAllActions()
        let a = makeTab("https://a.example/", spaceID: space.id)
        let b = makeTab("https://b.example/", spaceID: space.id)
        let keep = makeTab("https://keep.example/", spaceID: space.id)
        space.tabs.append(contentsOf: [a, b, keep])
        let elsewhere = makeTab("https://elsewhere.example/", spaceID: other.id)
        let otherKeep = makeTab("https://other-keep.example/", spaceID: other.id)
        other.tabs.append(contentsOf: [elsewhere, otherKeep])

        inUndoGroup(store) { store.closeTab(id: a.id, in: space) }
        inUndoGroup(store) { store.closeTab(id: b.id, in: space) }
        inUndoGroup(store) { store.deleteSpace(id: space.id) }
        XCTAssertTrue(db.closedTabSummaries(spaceID: space.id.uuidString).isEmpty,
                      "precondition: Delete Space purges the space's closed-tab records")
        // Closed while the space is deleted: its row gets a higher id than A's and B's.
        inUndoGroup(store) { store.closeTab(id: elsewhere.id, in: other) }

        store.undoManager.undo()  // the Close Tab in the other space
        store.undoManager.undo()  // Delete Space
        let restored = try XCTUnwrap(store.space(withID: space.id))

        XCTAssertEqual(store.closedTabRecords(in: restored).map(\.url), ["https://b.example/", "https://a.example/"])
        XCTAssertEqual(store.reopenClosedTab(in: restored)?.url?.absoluteString, "https://b.example/",
                       "the newest close reopens first, as before the delete")
        XCTAssertEqual(store.reopenClosedTab(in: restored)?.url?.absoluteString, "https://a.example/")
        XCTAssertNil(store.reopenClosedTab(in: restored))
    }

    func testReopenReadsOnlyTheChosenRecordsFullRow() throws {
        let (_, store, space) = try makeArchiveFixture()
        let tabs = ["https://a.example/", "https://b.example/", "https://c.example/", "https://keep.example/"]
            .map { makeTab($0, spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        for tab in tabs.dropLast() { inUndoGroup(store) { store.closeTab(id: tab.id, in: space) } }

        AppDatabase.resetReadCounts()
        XCTAssertTrue(store.canReopenClosedTab(in: space))
        let reopened = store.reopenClosedTab(in: space)

        XCTAssertEqual(reopened?.url?.absoluteString, "https://c.example/")
        XCTAssertEqual(AppDatabase.readCount(AppDatabase.closedTabReadLabel), 1,
                       "only the reopened record's full row (and blob) is read")
        XCTAssertEqual(AppDatabase.readCount(AppDatabase.closedTabsForSpaceReadLabel), 0)
        XCTAssertEqual(AppDatabase.readCount(AppDatabase.closedTabSummariesReadLabel), 2,
                       "validation and the reopen scan each read blob-free summaries once")
    }

    func testLaunchLoadsNoClosedTabRecordsAndReadsThemFromTheDatabase() throws {
        let (db, store, space) = try makeArchiveFixture()
        let tabs = ["https://a.example/", "https://b.example/", "https://keep.example/"]
            .map { makeTab($0, spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        for tab in tabs.dropLast() { inUndoGroup(store) { store.closeTab(id: tab.id, in: space) } }
        store.saveNow()

        AppDatabase.resetReadCounts()
        let relaunched = TabStore(appDB: db)
        XCTAssertNotNil(relaunched.restoreSession())
        XCTAssertEqual(AppDatabase.readCount(AppDatabase.closedTabSummariesReadLabel), 0,
                       "launch reads no closed-tab records")
        XCTAssertEqual(AppDatabase.readCount(AppDatabase.closedTabReadLabel), 0)
        XCTAssertEqual(AppDatabase.readCount(AppDatabase.closedTabsForSpaceReadLabel), 0)

        let restoredSpace = try XCTUnwrap(relaunched.space(withID: space.id))
        XCTAssertEqual(relaunched.closedTabRecords(in: restoredSpace).map(\.url),
                       ["https://b.example/", "https://a.example/"])
        XCTAssertTrue(relaunched.canReopenClosedTab(in: restoredSpace))
        XCTAssertEqual(relaunched.reopenClosedTab(in: restoredSpace)?.url?.absoluteString, "https://b.example/")
    }

    // MARK: - Session-less launch (TASK-32/TASK-33)

    /// `loadSession` returns nil whenever the space table is empty — deleting the
    /// last persistent space while a Private window is open gets there — and on
    /// any read error. Such a launch must still hold every stored profile, or the
    /// next save sweeps them out of the database and (before this fix) armed the
    /// removal of their on-disk cookies, logins and extension storage.
    func testSessionLessLaunchKeepsStoredProfilesAndRemovesNoData() throws {
        let db = try makeDatabase()
        let profileIDs = [UUID().uuidString, UUID().uuidString]
        for (index, id) in profileIDs.enumerated() {
            db.saveProfile(ProfileRecord(id: id, name: "Profile \(index)", userAgentMode: 0, customUserAgent: nil,
                                         archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0,
                                         searchSuggestionsEnabled: true, isPerTabIsolation: false,
                                         isAdBlockingEnabled: true, isEasyListEnabled: true,
                                         isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true,
                                         isMalwareFilterEnabled: true))
        }
        XCTAssertNil(db.loadSession(), "precondition: no spaces were saved")

        let store = TabStore(appDB: db)
        XCTAssertNil(store.restoreSession(), "no session to restore")
        XCTAssertEqual(Set(store.profiles.map(\.id.uuidString)).intersection(profileIDs), Set(profileIDs),
                       "both stored profiles are held in memory")

        store.ensureDefaultSpace()
        store.saveNow()

        XCTAssertEqual(Set(db.loadProfiles().map(\.id)).intersection(profileIDs), Set(profileIDs),
                       "both profile rows survive the save")
        XCTAssertEqual(db.pendingProfileDataRemovals(), [],
                       "a launch that restored nothing must never schedule a profile's data removal")
    }
}

// MARK: - Mock Observer

private class MockTabStoreObserver: TabStoreObserver {
    var pinCalls: [(fromIndex: Int, toIndex: Int)] = []
    var unpinCalls: [(fromIndex: Int, toIndex: Int)] = []
    var reorderCalls: Int = 0

    func tabStoreDidPinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space) {
        pinCalls.append((fromIndex: fromIndex, toIndex: toIndex))
    }

    func tabStoreDidUnpinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space) {
        unpinCalls.append((fromIndex: fromIndex, toIndex: toIndex))
    }

    func tabStoreDidReorderTabs(in space: Space) {
        reorderCalls += 1
    }
}
