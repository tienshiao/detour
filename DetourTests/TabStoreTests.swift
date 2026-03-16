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

    func testPinTabMovesToPinnedTabs() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)

        store.pinTab(id: tab.id, in: space)

        XCTAssertTrue(space.tabs.isEmpty)
        XCTAssertEqual(space.pinnedTabs.count, 1)
        XCTAssertTrue(space.pinnedTabs[0].isPinned)
        XCTAssertEqual(space.pinnedTabs[0].pinnedURL, tab.url)
        XCTAssertEqual(space.pinnedTabs[0].pinnedTitle, tab.title)
    }

    func testUnpinTabMovesBackToTabs() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)

        store.unpinTab(id: tab.id, in: space)

        XCTAssertTrue(space.pinnedTabs.isEmpty)
        XCTAssertEqual(space.tabs.count, 1)
        XCTAssertFalse(space.tabs[0].isPinned)
        XCTAssertNil(space.tabs[0].pinnedURL)
        XCTAssertNil(space.tabs[0].pinnedTitle)
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

        XCTAssertEqual(space.pinnedTabs.map(\.id), [tab3.id, tab1.id, tab2.id])
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

        // Move tabs[0] to the end (after tabs[2])
        store.movePinnedTabToFolder(tabID: tabs[0].id, folderID: nil, beforeItemID: nil, in: space)

        // tabs[0] should now be last, sorted by pinnedSortOrder
        let sorted = space.pinnedTabs.sorted { ($0.pinnedSortOrder ?? 0) < ($1.pinnedSortOrder ?? 0) }
        XCTAssertEqual(sorted.map(\.id), [tabs[1].id, tabs[2].id, tabs[0].id])
    }

    // MARK: - Move Pinned Folder

    func testMovePinnedFolderToFirstPosition() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)

        let folder = store.addPinnedFolder(name: "Folder", in: space)

        // Move folder before the tab (to first position)
        store.movePinnedFolder(folderID: folder.id, parentFolderID: nil, beforeItemID: tab.id, in: space)

        XCTAssertLessThan(folder.sortOrder, tab.pinnedSortOrder ?? 0,
                          "Folder should have lower sort order than tab after move to first position")

        let items = flattenPinnedTree(tabs: space.pinnedTabs, folders: space.pinnedFolders,
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

        // Move folder before the tab
        store.movePinnedFolder(folderID: folder.id, parentFolderID: nil, beforeItemID: tab.id, in: space)

        // Force save
        store.saveNow()

        // Verify the saved sort orders are correct by checking the flattened tree
        // after simulating what a reload would produce
        let items = flattenPinnedTree(tabs: space.pinnedTabs, folders: space.pinnedFolders,
                                       collapsedFolderIDs: [], selectedTabID: nil)
        guard items.count == 2 else { XCTFail("Expected 2 items"); return }
        if case .folder(let f, _) = items[0] {
            XCTAssertEqual(f.id, folder.id, "Folder should be first after save")
        } else {
            XCTFail("Expected folder first after save, got tab")
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

        // Move tab before the folder
        store.movePinnedTabToFolder(tabID: tab.id, folderID: nil, beforeItemID: folder.id, in: space)

        // Tab should have lower sort order than folder
        XCTAssertEqual(tab.pinnedSortOrder, 0)
        XCTAssertEqual(folder.sortOrder, 1)

        // Verify the flattened tree reflects the correct order
        let items = flattenPinnedTree(tabs: space.pinnedTabs, folders: space.pinnedFolders,
                                       collapsedFolderIDs: [], selectedTabID: nil)
        XCTAssertEqual(items.count, 2)
        if case .tab(let t, _) = items[0] {
            XCTAssertEqual(t.id, tab.id, "Tab should appear before folder")
        } else {
            XCTFail("Expected tab first")
        }
        if case .folder(let f, _) = items[1] {
            XCTAssertEqual(f.id, folder.id, "Folder should appear after tab")
        } else {
            XCTFail("Expected folder second")
        }
    }

    func testAddFolderSortOrderAccountsForTabs() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)

        let folder = store.addPinnedFolder(name: "Folder", in: space)

        // New folder must have sort order higher than existing tabs
        XCTAssertGreaterThan(folder.sortOrder, tab.pinnedSortOrder ?? 0,
                             "Newly created folder must have sort order after existing pinned tabs")
    }

    func testPinTabSortOrderAccountsForFolders() throws {
        let (store, space) = try makeStore()
        let folder = PinnedFolder(name: "Folder", sortOrder: 5)
        space.pinnedFolders.append(folder)

        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)

        // New tab's sort order must be higher than the folder's
        XCTAssertGreaterThan(tab.pinnedSortOrder ?? 0, folder.sortOrder,
                             "Newly pinned tab must have sort order after existing folders")
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
        let observer = MockTabStoreObserver()
        store.addObserver(observer)

        store.unpinTab(id: tab.id, in: space)

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

    func tabStoreDidPinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {
        pinCalls.append((fromIndex: fromIndex, toIndex: toIndex))
    }

    func tabStoreDidUnpinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {
        unpinCalls.append((fromIndex: fromIndex, toIndex: toIndex))
    }

    func tabStoreDidReorderTabs(in space: Space) {
        reorderCalls += 1
    }
}
