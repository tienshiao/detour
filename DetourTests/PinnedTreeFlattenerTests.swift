import XCTest
@testable import Detour

final class PinnedTreeFlattenerTests: XCTestCase {

    private func makeTab(id: UUID = UUID(), title: String = "Tab", folderID: UUID? = nil, sortOrder: Int = 0) -> BrowserTab {
        let tab = BrowserTab(id: id, title: title, url: URL(string: "https://example.com"), faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
        tab.isPinned = true
        tab.pinnedTitle = title
        tab.pinnedURL = URL(string: "https://example.com")
        tab.folderID = folderID
        tab.pinnedSortOrder = sortOrder
        return tab
    }

    private func makeFolder(id: UUID = UUID(), name: String = "Folder", parentID: UUID? = nil, isCollapsed: Bool = false, sortOrder: Int = 0) -> PinnedFolder {
        PinnedFolder(id: id, name: name, parentFolderID: parentID, isCollapsed: isCollapsed, sortOrder: sortOrder)
    }

    // MARK: - Basic Cases

    func testFlatListNoFolders() {
        let t1 = makeTab(title: "A", sortOrder: 0)
        let t2 = makeTab(title: "B", sortOrder: 1)

        let result = flattenPinnedTree(tabs: [t1, t2], folders: [], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 2)
        if case .tab(let tab, let depth) = result[0] {
            XCTAssertEqual(tab.id, t1.id)
            XCTAssertEqual(depth, 0)
        } else { XCTFail("Expected tab") }

        if case .tab(let tab, let depth) = result[1] {
            XCTAssertEqual(tab.id, t2.id)
            XCTAssertEqual(depth, 0)
        } else { XCTFail("Expected tab") }
    }

    func testFolderWithChildrenExpanded() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let t1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let t2 = makeTab(title: "B", folderID: folderID, sortOrder: 2)
        let t3 = makeTab(title: "Outside", sortOrder: 3)

        let result = flattenPinnedTree(tabs: [t1, t2, t3], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 4)
        if case .folder(let f, let depth) = result[0] {
            XCTAssertEqual(f.id, folderID)
            XCTAssertEqual(depth, 0)
        } else { XCTFail("Expected folder") }

        if case .tab(let tab, let depth) = result[1] {
            XCTAssertEqual(tab.id, t1.id)
            XCTAssertEqual(depth, 1)
        } else { XCTFail("Expected tab") }

        if case .tab(let tab, let depth) = result[2] {
            XCTAssertEqual(tab.id, t2.id)
            XCTAssertEqual(depth, 1)
        } else { XCTFail("Expected tab") }

        if case .tab(let tab, let depth) = result[3] {
            XCTAssertEqual(tab.id, t3.id)
            XCTAssertEqual(depth, 0)
        } else { XCTFail("Expected tab") }
    }

    func testCollapsedFolderHidesChildren() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", isCollapsed: true, sortOrder: 0)
        let t1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let t2 = makeTab(title: "Outside", sortOrder: 2)

        let result = flattenPinnedTree(tabs: [t1, t2], folders: [folder], collapsedFolderIDs: [folderID], selectedTabID: nil)

        XCTAssertEqual(result.count, 2) // folder row + outside tab
        if case .folder(let f, _) = result[0] {
            XCTAssertEqual(f.id, folderID)
        } else { XCTFail("Expected folder") }

        if case .tab(let tab, _) = result[1] {
            XCTAssertEqual(tab.id, t2.id)
        } else { XCTFail("Expected tab") }
    }

    func testCollapsedFolderExposesSelectedTab() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", isCollapsed: true, sortOrder: 0)
        let t1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let t2 = makeTab(title: "B", folderID: folderID, sortOrder: 2)

        let result = flattenPinnedTree(tabs: [t1, t2], folders: [folder], collapsedFolderIDs: [folderID], selectedTabID: t2.id)

        XCTAssertEqual(result.count, 2) // folder row + exposed selected tab
        if case .folder(let f, _) = result[0] {
            XCTAssertEqual(f.id, folderID)
        } else { XCTFail("Expected folder") }

        if case .tab(let tab, let depth) = result[1] {
            XCTAssertEqual(tab.id, t2.id)
            XCTAssertEqual(depth, 1)
        } else { XCTFail("Expected exposed tab") }
    }

    func testNestedFolders() {
        let outerID = UUID()
        let innerID = UUID()
        let outer = makeFolder(id: outerID, name: "Outer", sortOrder: 0)
        let inner = makeFolder(id: innerID, name: "Inner", parentID: outerID, sortOrder: 1)
        let t1 = makeTab(title: "Deep", folderID: innerID, sortOrder: 2)

        let result = flattenPinnedTree(tabs: [t1], folders: [outer, inner], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 3) // outer, inner, tab
        if case .folder(_, let depth) = result[0] { XCTAssertEqual(depth, 0) } else { XCTFail() }
        if case .folder(_, let depth) = result[1] { XCTAssertEqual(depth, 1) } else { XCTFail() }
        if case .tab(_, let depth) = result[2] { XCTAssertEqual(depth, 2) } else { XCTFail() }
    }

    func testEmptyFolder() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Empty", sortOrder: 0)

        let result = flattenPinnedTree(tabs: [], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 1)
        if case .folder(let f, _) = result[0] {
            XCTAssertEqual(f.id, folderID)
        } else { XCTFail("Expected folder") }
    }

    func testSortOrderRespected() {
        let f1 = makeFolder(name: "Second", sortOrder: 1)
        let f2 = makeFolder(name: "First", sortOrder: 0)
        let t1 = makeTab(title: "Third", sortOrder: 2)

        let result = flattenPinnedTree(tabs: [t1], folders: [f1, f2], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(result.count, 3)
        if case .folder(let f, _) = result[0] { XCTAssertEqual(f.name, "First") } else { XCTFail() }
        if case .folder(let f, _) = result[1] { XCTAssertEqual(f.name, "Second") } else { XCTFail() }
        if case .tab(let t, _) = result[2] { XCTAssertEqual(t.pinnedTitle, "Third") } else { XCTFail() }
    }

    func testCollapsedNestedFolderExposesSelectedTab() {
        let outerID = UUID()
        let innerID = UUID()
        let outer = makeFolder(id: outerID, name: "Outer", isCollapsed: true, sortOrder: 0)
        let inner = makeFolder(id: innerID, name: "Inner", parentID: outerID, sortOrder: 1)
        let t1 = makeTab(title: "Deep", folderID: innerID, sortOrder: 2)

        let result = flattenPinnedTree(tabs: [t1], folders: [outer, inner], collapsedFolderIDs: [outerID], selectedTabID: t1.id)

        XCTAssertEqual(result.count, 2) // outer + exposed tab
        if case .folder(let f, _) = result[0] { XCTAssertEqual(f.id, outerID) } else { XCTFail() }
        if case .tab(let t, _) = result[1] { XCTAssertEqual(t.id, t1.id) } else { XCTFail() }
    }

    // MARK: - folderIDForDropIndex

    func testDropAboveTabInsideFolderReturnsFolderID() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let t1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)

        let items = flattenPinnedTree(tabs: [t1], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [folder(depth:0), tab(depth:1)]

        // Dropping above the tab inside the folder → should return folder's ID
        XCTAssertEqual(folderIDForDropIndex(1, in: items), folderID)
    }

    func testDropAboveTopLevelTabReturnsNil() {
        let t1 = makeTab(title: "A", sortOrder: 0)

        let items = flattenPinnedTree(tabs: [t1], folders: [], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertNil(folderIDForDropIndex(0, in: items))
    }

    func testDropAboveTopLevelFolderReturnsNil() {
        let folder = makeFolder(name: "Work", sortOrder: 0)

        let items = flattenPinnedTree(tabs: [], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertNil(folderIDForDropIndex(0, in: items))
    }

    func testDropAboveNestedFolderReturnsParentFolderID() {
        let outerID = UUID()
        let innerID = UUID()
        let outer = makeFolder(id: outerID, name: "Outer", sortOrder: 0)
        let inner = makeFolder(id: innerID, name: "Inner", parentID: outerID, sortOrder: 1)

        let items = flattenPinnedTree(tabs: [], folders: [outer, inner], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [outer(depth:0), inner(depth:1)]

        // Dropping above the nested folder → should return outer's ID
        XCTAssertEqual(folderIDForDropIndex(1, in: items), outerID)
    }

    func testDropPastEndReturnsNil() {
        let folder = makeFolder(name: "Work", sortOrder: 0)
        let t1 = makeTab(title: "A", folderID: folder.id, sortOrder: 1)

        let items = flattenPinnedTree(tabs: [t1], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertNil(folderIDForDropIndex(items.count, in: items))
    }

    // MARK: - itemIDAtDropIndex

    func testItemIDAtDropIndexInsideFolder() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let t1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let t2 = makeTab(title: "B", folderID: folderID, sortOrder: 2)

        let items = flattenPinnedTree(tabs: [t1, t2], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [folder(0), t1(1), t2(1)]

        // Drop above t1 → returns t1's ID
        XCTAssertEqual(itemIDAtDropIndex(1, in: items), t1.id)
        // Drop above t2 → returns t2's ID
        XCTAssertEqual(itemIDAtDropIndex(2, in: items), t2.id)
    }

    func testItemIDAtDropIndexAboveFolderReturnsFolderID() {
        let folder = makeFolder(name: "Work", sortOrder: 0)
        let t1 = makeTab(title: "A", folderID: folder.id, sortOrder: 1)

        let items = flattenPinnedTree(tabs: [t1], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [folder(0), t1(1)]

        // Drop above folder row → returns folder's ID
        XCTAssertEqual(itemIDAtDropIndex(0, in: items), folder.id)
    }

    func testItemIDAtDropIndexPastEndReturnsNil() {
        let t1 = makeTab(title: "A", sortOrder: 0)

        let items = flattenPinnedTree(tabs: [t1], folders: [], collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertNil(itemIDAtDropIndex(items.count, in: items))
    }

    func testDropBetweenFolderChildrenReturnsFolderID() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let t1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let t2 = makeTab(title: "B", folderID: folderID, sortOrder: 2)
        let t3 = makeTab(title: "Outside", sortOrder: 3)

        let items = flattenPinnedTree(tabs: [t1, t2, t3], folders: [folder], collapsedFolderIDs: [], selectedTabID: nil)
        // items: [folder(0), t1(1), t2(1), t3(0)]

        // Dropping above t2 (between t1 and t2, both in folder) → folder
        XCTAssertEqual(folderIDForDropIndex(2, in: items), folderID)
        // Dropping above t3 (after folder children, top-level) → nil
        XCTAssertNil(folderIDForDropIndex(3, in: items))
    }
}
