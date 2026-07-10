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

    private func makeEntry(sortOrder: Int = 0, folderID: UUID? = nil) -> PinnedEntry {
        PinnedEntry(
            pinnedURL: URL(string: "https://example.com")!,
            pinnedTitle: "Entry",
            folderID: folderID,
            sortOrder: sortOrder
        )
    }

    /// Helper: returns entry/folder IDs in flattened sort order.
    private func flattenedIDs(_ space: Space) -> [UUID] {
        let items = flattenPinnedTree(
            entries: space.pinnedEntries,
            folders: space.pinnedFolders,
            collapsedFolderIDs: [],
            selectedTabID: nil
        )
        return items.map {
            switch $0 {
            case .entry(let e, _): return e.id
            case .folder(let f, _): return f.id
            }
        }
    }

    // MARK: - movePinnedTabToFolder

    func testMoveTabIntoFolder() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "Work", in: space)
        let entry = makeEntry(sortOrder: 1)
        space.pinnedEntries.append(entry)

        store.movePinnedTabToFolder(tabID: entry.id, folderID: folder.id, in: space)

        XCTAssertEqual(entry.folderID, folder.id)
        XCTAssertEqual(flattenedIDs(space), [folder.id, entry.id])
    }

    func testMoveTabOutOfFolder() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "Work", in: space)
        let entry = makeEntry(sortOrder: 0, folderID: folder.id)
        space.pinnedEntries.append(entry)

        store.movePinnedTabToFolder(tabID: entry.id, folderID: nil, in: space)

        XCTAssertNil(entry.folderID)
        // Entry should be at root level alongside the folder
        XCTAssertEqual(flattenedIDs(space).count, 2)
        XCTAssertTrue(flattenedIDs(space).contains(entry.id))
    }

    func testMoveTabBeforeAnotherTab() throws {
        let (store, space) = try makeStore()
        let e1 = makeEntry(sortOrder: 0)
        let e2 = makeEntry(sortOrder: 1)
        let e3 = makeEntry(sortOrder: 2)
        space.pinnedEntries.append(contentsOf: [e1, e2, e3])

        // Move e3 before e1
        store.movePinnedTabToFolder(tabID: e3.id, folderID: nil, beforeItemID: e1.id, in: space)

        XCTAssertEqual(flattenedIDs(space), [e3.id, e1.id, e2.id])
    }

    func testMoveTabBeforeFolder() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "Work", in: space)
        let entry = makeEntry(sortOrder: 1)
        space.pinnedEntries.append(entry)

        // Move entry before the folder
        store.movePinnedTabToFolder(tabID: entry.id, folderID: nil, beforeItemID: folder.id, in: space)

        XCTAssertEqual(flattenedIDs(space), [entry.id, folder.id])
    }

    func testMoveTabRenumbersSiblings() throws {
        let (store, space) = try makeStore()
        let e1 = makeEntry(sortOrder: 0)
        let e2 = makeEntry(sortOrder: 1)
        let e3 = makeEntry(sortOrder: 2)
        space.pinnedEntries.append(contentsOf: [e1, e2, e3])

        store.movePinnedTabToFolder(tabID: e3.id, folderID: nil, beforeItemID: e1.id, in: space)

        // All sort orders should be contiguous 0, 1, 2
        XCTAssertEqual(e3.sortOrder, 0)
        XCTAssertEqual(e1.sortOrder, 1)
        XCTAssertEqual(e2.sortOrder, 2)
    }

    func testMoveTabBetweenFolders() throws {
        let (store, space) = try makeStore()
        let f1 = store.addPinnedFolder(name: "A", in: space)
        let f2 = store.addPinnedFolder(name: "B", in: space)
        let entry = makeEntry(sortOrder: 0, folderID: f1.id)
        space.pinnedEntries.append(entry)

        store.movePinnedTabToFolder(tabID: entry.id, folderID: f2.id, in: space)

        XCTAssertEqual(entry.folderID, f2.id)
        XCTAssertEqual(flattenedIDs(space), [f1.id, f2.id, entry.id])
    }

    // MARK: - movePinnedFolder

    func testMoveFolderToEnd() throws {
        let (store, space) = try makeStore()
        let f1 = store.addPinnedFolder(name: "A", in: space)
        let f2 = store.addPinnedFolder(name: "B", in: space)
        let entry = makeEntry(sortOrder: 2)
        space.pinnedEntries.append(entry)

        // Move f1 to end (no beforeItemID)
        store.movePinnedFolder(folderID: f1.id, parentFolderID: nil, in: space)

        XCTAssertEqual(flattenedIDs(space), [f2.id, entry.id, f1.id])
    }

    func testMoveFolderBeforeTab() throws {
        let (store, space) = try makeStore()
        let entry = makeEntry(sortOrder: 0)
        space.pinnedEntries.append(entry)
        let folder = store.addPinnedFolder(name: "Work", in: space)

        // Move folder before the entry
        store.movePinnedFolder(folderID: folder.id, parentFolderID: nil, beforeItemID: entry.id, in: space)

        XCTAssertEqual(flattenedIDs(space), [folder.id, entry.id])
    }

    func testMoveFolderIntoAnotherFolder() throws {
        let (store, space) = try makeStore()
        let outer = store.addPinnedFolder(name: "Outer", in: space)
        let inner = store.addPinnedFolder(name: "Inner", in: space)

        store.movePinnedFolder(folderID: inner.id, parentFolderID: outer.id, in: space)

        XCTAssertEqual(inner.parentFolderID, outer.id)
        XCTAssertEqual(flattenedIDs(space), [outer.id, inner.id])
    }

    func testMoveFolderIntoItselfIsRejected() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "A", in: space)

        store.movePinnedFolder(folderID: folder.id, parentFolderID: folder.id, in: space)

        XCTAssertNil(folder.parentFolderID)
        XCTAssertEqual(flattenedIDs(space), [folder.id])
    }

    func testMoveFolderIntoDescendantIsRejected() throws {
        let (store, space) = try makeStore()
        let outer = store.addPinnedFolder(name: "Outer", in: space)
        let inner = PinnedFolder(name: "Inner", parentFolderID: outer.id, sortOrder: 0)
        space.pinnedFolders.append(inner)

        // Would create outer → inner → outer, hanging flattenPinnedTree
        store.movePinnedFolder(folderID: outer.id, parentFolderID: inner.id, in: space)

        XCTAssertNil(outer.parentFolderID)
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
        let entry = makeEntry(sortOrder: 2)
        space.pinnedEntries.append(entry)

        // Move f2 before f1
        store.movePinnedFolder(folderID: f2.id, parentFolderID: nil, beforeItemID: f1.id, in: space)

        XCTAssertEqual(f2.sortOrder, 0)
        XCTAssertEqual(f1.sortOrder, 1)
        XCTAssertEqual(entry.sortOrder, 2)
    }

    func testMoveFolderPreservesChildren() throws {
        let (store, space) = try makeStore()
        let f1 = store.addPinnedFolder(name: "A", in: space)
        let child = makeEntry(sortOrder: 0, folderID: f1.id)
        space.pinnedEntries.append(child)
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
        let e1 = makeEntry(sortOrder: 1)
        let e2 = makeEntry(sortOrder: 2)
        space.pinnedEntries.append(contentsOf: [e1, e2])

        // Move e1 into folder
        store.movePinnedTabToFolder(tabID: e1.id, folderID: folder.id, in: space)
        let order1 = flattenedIDs(space)

        // Rebuild flattened tree again — order should be identical
        let order2 = flattenedIDs(space)
        XCTAssertEqual(order1, order2)

        // Move e2 before e1 inside the folder
        store.movePinnedTabToFolder(tabID: e2.id, folderID: folder.id, beforeItemID: e1.id, in: space)
        let order3 = flattenedIDs(space)
        XCTAssertEqual(order3, [folder.id, e2.id, e1.id])

        // Rebuild again
        let order4 = flattenedIDs(space)
        XCTAssertEqual(order3, order4)
    }

    // MARK: - Observer notifications

    func testMoveTabToFolderNotifiesObserver() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "Work", in: space)
        let entry = makeEntry(sortOrder: 1)
        space.pinnedEntries.append(entry)
        let observer = FolderObserver()
        store.addObserver(observer)

        store.movePinnedTabToFolder(tabID: entry.id, folderID: folder.id, in: space)

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
