import XCTest
import GRDB
@testable import Detour

final class PinnedTabMoveTests: XCTestCase {

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

    private func makeTab(spaceID: UUID, sortOrder: Int = 0, folderID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(
            id: UUID(), title: "Tab", url: URL(string: "https://example.com"),
            faviconURL: nil, cachedInteractionState: nil, spaceID: spaceID
        )
        tab.isPinned = true
        tab.pinnedURL = tab.url
        tab.pinnedTitle = tab.title
        tab.pinnedSortOrder = sortOrder
        tab.folderID = folderID
        return tab
    }

    /// Helper: returns tab/folder IDs in flattened sort order (by pinnedSortOrder/sortOrder at each level).
    private func flattenedIDs(_ space: Space) -> [UUID] {
        let items = flattenPinnedTree(
            tabs: space.pinnedTabs,
            folders: space.pinnedFolders,
            collapsedFolderIDs: [],
            selectedTabID: nil
        )
        return items.map {
            switch $0 {
            case .tab(let t, _): return t.id
            case .folder(let f, _): return f.id
            }
        }
    }

    // MARK: - movePinnedTabToFolder

    func testMoveTabIntoFolder() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "Work", in: space)
        let tab = makeTab(spaceID: space.id, sortOrder: 1)
        space.pinnedTabs.append(tab)

        store.movePinnedTabToFolder(tabID: tab.id, folderID: folder.id, in: space)

        XCTAssertEqual(tab.folderID, folder.id)
        XCTAssertEqual(flattenedIDs(space), [folder.id, tab.id])
    }

    func testMoveTabOutOfFolder() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "Work", in: space)
        let tab = makeTab(spaceID: space.id, sortOrder: 0, folderID: folder.id)
        space.pinnedTabs.append(tab)

        store.movePinnedTabToFolder(tabID: tab.id, folderID: nil, in: space)

        XCTAssertNil(tab.folderID)
        // Tab should be at root level alongside the folder
        XCTAssertEqual(flattenedIDs(space).count, 2)
        XCTAssertTrue(flattenedIDs(space).contains(tab.id))
    }

    func testMoveTabBeforeAnotherTab() throws {
        let (store, space) = try makeStore()
        let t1 = makeTab(spaceID: space.id, sortOrder: 0)
        let t2 = makeTab(spaceID: space.id, sortOrder: 1)
        let t3 = makeTab(spaceID: space.id, sortOrder: 2)
        space.pinnedTabs.append(contentsOf: [t1, t2, t3])

        // Move t3 before t1
        store.movePinnedTabToFolder(tabID: t3.id, folderID: nil, beforeItemID: t1.id, in: space)

        XCTAssertEqual(flattenedIDs(space), [t3.id, t1.id, t2.id])
    }

    func testMoveTabBeforeFolder() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "Work", in: space)
        let tab = makeTab(spaceID: space.id, sortOrder: 1)
        space.pinnedTabs.append(tab)

        // Move tab before the folder
        store.movePinnedTabToFolder(tabID: tab.id, folderID: nil, beforeItemID: folder.id, in: space)

        XCTAssertEqual(flattenedIDs(space), [tab.id, folder.id])
    }

    func testMoveTabRenumbersSiblings() throws {
        let (store, space) = try makeStore()
        let t1 = makeTab(spaceID: space.id, sortOrder: 0)
        let t2 = makeTab(spaceID: space.id, sortOrder: 1)
        let t3 = makeTab(spaceID: space.id, sortOrder: 2)
        space.pinnedTabs.append(contentsOf: [t1, t2, t3])

        store.movePinnedTabToFolder(tabID: t3.id, folderID: nil, beforeItemID: t1.id, in: space)

        // All sort orders should be contiguous 0, 1, 2
        XCTAssertEqual(t3.pinnedSortOrder, 0)
        XCTAssertEqual(t1.pinnedSortOrder, 1)
        XCTAssertEqual(t2.pinnedSortOrder, 2)
    }

    func testMoveTabBetweenFolders() throws {
        let (store, space) = try makeStore()
        let f1 = store.addPinnedFolder(name: "A", in: space)
        let f2 = store.addPinnedFolder(name: "B", in: space)
        let tab = makeTab(spaceID: space.id, sortOrder: 0, folderID: f1.id)
        space.pinnedTabs.append(tab)

        store.movePinnedTabToFolder(tabID: tab.id, folderID: f2.id, in: space)

        XCTAssertEqual(tab.folderID, f2.id)
        XCTAssertEqual(flattenedIDs(space), [f1.id, f2.id, tab.id])
    }

    // MARK: - movePinnedFolder

    func testMoveFolderToEnd() throws {
        let (store, space) = try makeStore()
        let f1 = store.addPinnedFolder(name: "A", in: space)
        let f2 = store.addPinnedFolder(name: "B", in: space)
        let tab = makeTab(spaceID: space.id, sortOrder: 2)
        space.pinnedTabs.append(tab)

        // Move f1 to end (no beforeItemID)
        store.movePinnedFolder(folderID: f1.id, parentFolderID: nil, in: space)

        XCTAssertEqual(flattenedIDs(space), [f2.id, tab.id, f1.id])
    }

    func testMoveFolderBeforeTab() throws {
        let (store, space) = try makeStore()
        let tab = makeTab(spaceID: space.id, sortOrder: 0)
        space.pinnedTabs.append(tab)
        let folder = store.addPinnedFolder(name: "Work", in: space)

        // Move folder before the tab
        store.movePinnedFolder(folderID: folder.id, parentFolderID: nil, beforeItemID: tab.id, in: space)

        XCTAssertEqual(flattenedIDs(space), [folder.id, tab.id])
    }

    func testMoveFolderIntoAnotherFolder() throws {
        let (store, space) = try makeStore()
        let outer = store.addPinnedFolder(name: "Outer", in: space)
        let inner = store.addPinnedFolder(name: "Inner", in: space)

        store.movePinnedFolder(folderID: inner.id, parentFolderID: outer.id, in: space)

        XCTAssertEqual(inner.parentFolderID, outer.id)
        XCTAssertEqual(flattenedIDs(space), [outer.id, inner.id])
    }

    func testMoveFolderOutOfParent() throws {
        let (store, space) = try makeStore()
        let outer = store.addPinnedFolder(name: "Outer", in: space)
        let inner = PinnedFolder(name: "Inner", parentFolderID: outer.id, sortOrder: 1)
        space.pinnedFolders.append(inner)

        store.movePinnedFolder(folderID: inner.id, parentFolderID: nil, in: space)

        XCTAssertNil(inner.parentFolderID)
        // Both at root level now
        let ids = flattenedIDs(space)
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains(outer.id))
        XCTAssertTrue(ids.contains(inner.id))
    }

    func testMoveFolderRenumbersSiblings() throws {
        let (store, space) = try makeStore()
        let f1 = store.addPinnedFolder(name: "A", in: space)
        let f2 = store.addPinnedFolder(name: "B", in: space)
        let tab = makeTab(spaceID: space.id, sortOrder: 2)
        space.pinnedTabs.append(tab)

        // Move f2 before f1
        store.movePinnedFolder(folderID: f2.id, parentFolderID: nil, beforeItemID: f1.id, in: space)

        XCTAssertEqual(f2.sortOrder, 0)
        XCTAssertEqual(f1.sortOrder, 1)
        XCTAssertEqual(tab.pinnedSortOrder, 2)
    }

    func testMoveFolderPreservesChildren() throws {
        let (store, space) = try makeStore()
        let f1 = store.addPinnedFolder(name: "A", in: space)
        let child = makeTab(spaceID: space.id, sortOrder: 0, folderID: f1.id)
        space.pinnedTabs.append(child)
        let f2 = store.addPinnedFolder(name: "B", in: space)

        // Move f1 after f2 — child should still be inside f1
        store.movePinnedFolder(folderID: f1.id, parentFolderID: nil, in: space)

        XCTAssertEqual(child.folderID, f1.id)
        XCTAssertEqual(flattenedIDs(space), [f2.id, f1.id, child.id])
    }

    // MARK: - Flattened order survives round-trip

    func testFlattenedOrderStableAfterMultipleMoves() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "F", in: space)
        let t1 = makeTab(spaceID: space.id, sortOrder: 1)
        let t2 = makeTab(spaceID: space.id, sortOrder: 2)
        space.pinnedTabs.append(contentsOf: [t1, t2])

        // Move t1 into folder
        store.movePinnedTabToFolder(tabID: t1.id, folderID: folder.id, in: space)
        let order1 = flattenedIDs(space)

        // Rebuild flattened tree again — order should be identical
        let order2 = flattenedIDs(space)
        XCTAssertEqual(order1, order2)

        // Move t2 before t1 inside the folder
        store.movePinnedTabToFolder(tabID: t2.id, folderID: folder.id, beforeItemID: t1.id, in: space)
        let order3 = flattenedIDs(space)
        XCTAssertEqual(order3, [folder.id, t2.id, t1.id])

        // Rebuild again
        let order4 = flattenedIDs(space)
        XCTAssertEqual(order3, order4)
    }

    // MARK: - Observer notifications

    func testMoveTabToFolderNotifiesObserver() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "Work", in: space)
        let tab = makeTab(spaceID: space.id, sortOrder: 1)
        space.pinnedTabs.append(tab)
        let observer = FolderObserver()
        store.addObserver(observer)

        store.movePinnedTabToFolder(tabID: tab.id, folderID: folder.id, in: space)

        XCTAssertEqual(observer.folderUpdateCount, 1)
    }

    func testMoveFolderNotifiesObserver() throws {
        let (store, space) = try makeStore()
        let f1 = store.addPinnedFolder(name: "A", in: space)
        let f2 = store.addPinnedFolder(name: "B", in: space)
        let observer = FolderObserver()
        store.addObserver(observer)

        store.movePinnedFolder(folderID: f1.id, parentFolderID: nil, beforeItemID: f2.id, in: space)

        XCTAssertEqual(observer.folderUpdateCount, 1)
    }
}

private class FolderObserver: TabStoreObserver {
    var folderUpdateCount = 0

    func tabStoreDidUpdatePinnedFolders(in space: Space) {
        folderUpdateCount += 1
    }
}
