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
