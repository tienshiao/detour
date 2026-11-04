import XCTest
@testable import Detour

nonisolated final class PinnedTreeFlattenerTests: XCTestCase {

    @MainActor private func makeEntry(id: UUID = UUID(), title: String = "Entry", folderID: UUID? = nil, sortOrder: Int = 0) -> PinnedEntry {
        PinnedEntry(
            id: id,
            pinnedURL: URL(string: "https://example.com")!,
            pinnedTitle: title,
            folderID: folderID,
            sortOrder: sortOrder
        )
    }

    @MainActor private func makeFolder(id: UUID = UUID(), name: String = "Folder", parentID: UUID? = nil, isCollapsed: Bool = false, sortOrder: Int = 0) -> PinnedFolder {
        PinnedFolder(id: id, name: name, parentFolderID: parentID, isCollapsed: isCollapsed, sortOrder: sortOrder)
    }

    // MARK: - Basic Cases

    @MainActor func testFlatListNoFolders() {
        let e1 = makeEntry(title: "A", sortOrder: 0)
        let e2 = makeEntry(title: "B", sortOrder: 1)

        let result = flattenPinnedTree(entries: [e1, e2], folders: [], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 2)
        if case .entry(let entry, let depth) = result[0] {
            XCTAssertEqual(entry.id, e1.id)
            XCTAssertEqual(depth, 0)
        } else { XCTFail("Expected entry") }

        if case .entry(let entry, let depth) = result[1] {
            XCTAssertEqual(entry.id, e2.id)
            XCTAssertEqual(depth, 0)
        } else { XCTFail("Expected entry") }
    }

    @MainActor func testFolderWithChildrenExpanded() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let e1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let e2 = makeEntry(title: "B", folderID: folderID, sortOrder: 2)
        let e3 = makeEntry(title: "Outside", sortOrder: 3)

        let result = flattenPinnedTree(entries: [e1, e2, e3], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 4)
        if case .folder(let f, let depth) = result[0] {
            XCTAssertEqual(f.id, folderID)
            XCTAssertEqual(depth, 0)
        } else { XCTFail("Expected folder") }

        if case .entry(let entry, let depth) = result[1] {
            XCTAssertEqual(entry.id, e1.id)
            XCTAssertEqual(depth, 1)
        } else { XCTFail("Expected entry") }

        if case .entry(let entry, let depth) = result[2] {
            XCTAssertEqual(entry.id, e2.id)
            XCTAssertEqual(depth, 1)
        } else { XCTFail("Expected entry") }

        if case .entry(let entry, let depth) = result[3] {
            XCTAssertEqual(entry.id, e3.id)
            XCTAssertEqual(depth, 0)
        } else { XCTFail("Expected entry") }
    }

    @MainActor func testCollapsedFolderHidesChildren() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", isCollapsed: true, sortOrder: 0)
        let e1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let e2 = makeEntry(title: "Outside", sortOrder: 2)

        let result = flattenPinnedTree(entries: [e1, e2], folders: [folder], collapsedFolderIDs: [folderID], selectedTabID: nil)

        XCTAssertEqual(result.count, 2) // folder row + outside entry
        if case .folder(let f, _) = result[0] {
            XCTAssertEqual(f.id, folderID)
        } else { XCTFail("Expected folder") }

        if case .entry(let entry, _) = result[1] {
            XCTAssertEqual(entry.id, e2.id)
        } else { XCTFail("Expected entry") }
    }

    @MainActor func testCollapsedFolderExposesSelectedTab() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", isCollapsed: true, sortOrder: 0)
        let e1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let e2 = makeEntry(title: "B", folderID: folderID, sortOrder: 2)
        // Give e2 a live tab so its tab.id can be the selectedTabID
        let tab = BrowserTab(id: UUID(), title: "B", url: URL(string: "https://example.com"), faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
        e2.tab = tab

        let result = flattenPinnedTree(entries: [e1, e2], folders: [folder], collapsedFolderIDs: [folderID], selectedTabID: tab.id)

        XCTAssertEqual(result.count, 2) // folder row + exposed selected entry
        if case .folder(let f, _) = result[0] {
            XCTAssertEqual(f.id, folderID)
        } else { XCTFail("Expected folder") }

        if case .entry(let entry, let depth) = result[1] {
            XCTAssertEqual(entry.id, e2.id)
            XCTAssertEqual(depth, 1)
        } else { XCTFail("Expected exposed entry") }
    }

    @MainActor func testNestedFolders() {
        let outerID = UUID()
        let innerID = UUID()
        let outer = makeFolder(id: outerID, name: "Outer", sortOrder: 0)
        let inner = makeFolder(id: innerID, name: "Inner", parentID: outerID, sortOrder: 1)
        let e1 = makeEntry(title: "Deep", folderID: innerID, sortOrder: 2)

        let result = flattenPinnedTree(entries: [e1], folders: [outer, inner], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 3) // outer, inner, entry
        if case .folder(_, let depth) = result[0] { XCTAssertEqual(depth, 0) } else { XCTFail() }
        if case .folder(_, let depth) = result[1] { XCTAssertEqual(depth, 1) } else { XCTFail() }
        if case .entry(_, let depth) = result[2] { XCTAssertEqual(depth, 2) } else { XCTFail() }
    }

    @MainActor func testEmptyFolder() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Empty", sortOrder: 0)

        let result = flattenPinnedTree(entries: [], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 1)
        if case .folder(let f, _) = result[0] {
            XCTAssertEqual(f.id, folderID)
        } else { XCTFail("Expected folder") }
    }

    @MainActor func testSortOrderRespected() {
        let f1 = makeFolder(name: "Second", sortOrder: 1)
        let f2 = makeFolder(name: "First", sortOrder: 0)
        let e1 = makeEntry(title: "Third", sortOrder: 2)

        let result = flattenPinnedTree(entries: [e1], folders: [f1, f2], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 3)
        if case .folder(let f, _) = result[0] { XCTAssertEqual(f.name, "First") } else { XCTFail() }
        if case .folder(let f, _) = result[1] { XCTAssertEqual(f.name, "Second") } else { XCTFail() }
        if case .entry(let e, _) = result[2] { XCTAssertEqual(e.pinnedTitle, "Third") } else { XCTFail() }
    }

    @MainActor func testCollapsedNestedFolderExposesSelectedTab() {
        let outerID = UUID()
        let innerID = UUID()
        let outer = makeFolder(id: outerID, name: "Outer", isCollapsed: true, sortOrder: 0)
        let inner = makeFolder(id: innerID, name: "Inner", parentID: outerID, sortOrder: 1)
        let e1 = makeEntry(title: "Deep", folderID: innerID, sortOrder: 2)
        let tab = BrowserTab(id: UUID(), title: "Deep", url: URL(string: "https://example.com"), faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
        e1.tab = tab

        let result = flattenPinnedTree(entries: [e1], folders: [outer, inner], collapsedFolderIDs: [outerID], selectedTabID: tab.id)

        XCTAssertEqual(result.count, 2) // outer + exposed entry
        if case .folder(let f, _) = result[0] { XCTAssertEqual(f.id, outerID) } else { XCTFail() }
        if case .entry(let e, _) = result[1] { XCTAssertEqual(e.id, e1.id) } else { XCTFail() }
    }

    // MARK: - folderIDForDropIndex

    @MainActor func testDropAboveTabInsideFolderReturnsFolderID() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let e1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)

        let items = flattenPinnedTree(entries: [e1], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [folder(depth:0), entry(depth:1)]

        // Dropping above the entry inside the folder → should return folder's ID
        XCTAssertEqual(folderIDForDropIndex(1, in: items), folderID)
    }

    @MainActor func testDropAboveTopLevelTabReturnsNil() {
        let e1 = makeEntry(title: "A", sortOrder: 0)

        let items = flattenPinnedTree(entries: [e1], folders: [], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertNil(folderIDForDropIndex(0, in: items))
    }

    @MainActor func testDropAboveTopLevelFolderReturnsNil() {
        let folder = makeFolder(name: "Work", sortOrder: 0)

        let items = flattenPinnedTree(entries: [], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertNil(folderIDForDropIndex(0, in: items))
    }

    @MainActor func testDropAboveNestedFolderReturnsParentFolderID() {
        let outerID = UUID()
        let innerID = UUID()
        let outer = makeFolder(id: outerID, name: "Outer", sortOrder: 0)
        let inner = makeFolder(id: innerID, name: "Inner", parentID: outerID, sortOrder: 1)

        let items = flattenPinnedTree(entries: [], folders: [outer, inner], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [outer(depth:0), inner(depth:1)]

        // Dropping above the nested folder → should return outer's ID
        XCTAssertEqual(folderIDForDropIndex(1, in: items), outerID)
    }

    @MainActor func testDropPastEndReturnsNil() {
        let folder = makeFolder(name: "Work", sortOrder: 0)
        let e1 = makeEntry(title: "A", folderID: folder.id, sortOrder: 1)

        let items = flattenPinnedTree(entries: [e1], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertNil(folderIDForDropIndex(items.count, in: items))
    }

    // MARK: - itemIDAtDropIndex

    @MainActor func testItemIDAtDropIndexInsideFolder() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let e1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let e2 = makeEntry(title: "B", folderID: folderID, sortOrder: 2)

        let items = flattenPinnedTree(entries: [e1, e2], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [folder(0), e1(1), e2(1)]

        // Drop above e1 → returns e1's ID
        XCTAssertEqual(itemIDAtDropIndex(1, in: items), e1.id)
        // Drop above e2 → returns e2's ID
        XCTAssertEqual(itemIDAtDropIndex(2, in: items), e2.id)
    }

    @MainActor func testItemIDAtDropIndexAboveFolderReturnsFolderID() {
        let folder = makeFolder(name: "Work", sortOrder: 0)
        let e1 = makeEntry(title: "A", folderID: folder.id, sortOrder: 1)

        let items = flattenPinnedTree(entries: [e1], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [folder(0), e1(1)]

        // Drop above folder row → returns folder's ID
        XCTAssertEqual(itemIDAtDropIndex(0, in: items), folder.id)
    }

    @MainActor func testItemIDAtDropIndexPastEndReturnsNil() {
        let e1 = makeEntry(title: "A", sortOrder: 0)

        let items = flattenPinnedTree(entries: [e1], folders: [], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertNil(itemIDAtDropIndex(items.count, in: items))
    }

    @MainActor func testDropBetweenFolderChildrenReturnsFolderID() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let e1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let e2 = makeEntry(title: "B", folderID: folderID, sortOrder: 2)
        let e3 = makeEntry(title: "Outside", sortOrder: 3)

        let items = flattenPinnedTree(entries: [e1, e2, e3], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [folder(0), e1(1), e2(1), e3(0)]

        // Dropping above e2 (between e1 and e2, both in folder) → folder
        XCTAssertEqual(folderIDForDropIndex(2, in: items), folderID)
        // Dropping above e3 (after folder children, top-level) → nil
        XCTAssertNil(folderIDForDropIndex(3, in: items))
    }
}
