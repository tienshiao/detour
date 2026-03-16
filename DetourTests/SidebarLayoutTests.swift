import XCTest
@testable import Detour

final class SidebarLayoutTests: XCTestCase {

    // MARK: - sidebarRow

    func testRow0IsTopSpacer() {
        XCTAssertEqual(sidebarRow(for: 0, pinnedItemCount: 3), .topSpacer)
        XCTAssertEqual(sidebarRow(for: 0, pinnedItemCount: 0), .topSpacer)
    }

    func testPinnedItemRows() {
        // With 3 pinned items: rows 1, 2, 3
        XCTAssertEqual(sidebarRow(for: 1, pinnedItemCount: 3), .pinnedItem(index: 0))
        XCTAssertEqual(sidebarRow(for: 2, pinnedItemCount: 3), .pinnedItem(index: 1))
        XCTAssertEqual(sidebarRow(for: 3, pinnedItemCount: 3), .pinnedItem(index: 2))
    }

    func testSeparatorRow() {
        // Separator comes right after pinned items
        XCTAssertEqual(sidebarRow(for: 4, pinnedItemCount: 3), .separator)
        XCTAssertEqual(sidebarRow(for: 1, pinnedItemCount: 0), .separator)
    }

    func testNewTabRow() {
        // New tab comes right after separator
        XCTAssertEqual(sidebarRow(for: 5, pinnedItemCount: 3), .newTab)
        XCTAssertEqual(sidebarRow(for: 2, pinnedItemCount: 0), .newTab)
    }

    func testNormalTabRows() {
        // Normal tabs start after new tab row
        XCTAssertEqual(sidebarRow(for: 6, pinnedItemCount: 3), .normalTab(index: 0))
        XCTAssertEqual(sidebarRow(for: 7, pinnedItemCount: 3), .normalTab(index: 1))
        XCTAssertEqual(sidebarRow(for: 3, pinnedItemCount: 0), .normalTab(index: 0))
    }

    func testZeroPinnedLayout() {
        // row 0: topSpacer, 1: separator, 2: newTab, 3+: normalTab
        XCTAssertEqual(sidebarRow(for: 0, pinnedItemCount: 0), .topSpacer)
        XCTAssertEqual(sidebarRow(for: 1, pinnedItemCount: 0), .separator)
        XCTAssertEqual(sidebarRow(for: 2, pinnedItemCount: 0), .newTab)
        XCTAssertEqual(sidebarRow(for: 3, pinnedItemCount: 0), .normalTab(index: 0))
        XCTAssertEqual(sidebarRow(for: 4, pinnedItemCount: 0), .normalTab(index: 1))
    }

    // MARK: - rowForNormalTab / rowForPinnedItem

    func testRowForNormalTab() {
        // 1 (topSpacer) + pinnedItemCount + 1 (separator) + 1 (newTab) + tabIndex
        XCTAssertEqual(rowForNormalTab(at: 0, pinnedItemCount: 3), 6)
        XCTAssertEqual(rowForNormalTab(at: 2, pinnedItemCount: 3), 8)
        XCTAssertEqual(rowForNormalTab(at: 0, pinnedItemCount: 0), 3)
    }

    func testRowForPinnedItem() {
        XCTAssertEqual(rowForPinnedItem(at: 0), 1)
        XCTAssertEqual(rowForPinnedItem(at: 2), 3)
    }

    // MARK: - totalSidebarRowCount

    func testTotalSidebarRowCount() {
        // 1 (topSpacer) + pinnedItemCount + 1 (separator) + 1 (newTab) + tabCount
        XCTAssertEqual(totalSidebarRowCount(pinnedItemCount: 3, tabCount: 5), 11)
        XCTAssertEqual(totalSidebarRowCount(pinnedItemCount: 0, tabCount: 2), 5)
        XCTAssertEqual(totalSidebarRowCount(pinnedItemCount: 0, tabCount: 0), 3)
    }

    // MARK: - Round-trip

    func testRoundTripNormalTab() {
        for pinnedItemCount in 0...3 {
            for tabIndex in 0..<5 {
                let row = rowForNormalTab(at: tabIndex, pinnedItemCount: pinnedItemCount)
                let result = sidebarRow(for: row, pinnedItemCount: pinnedItemCount)
                XCTAssertEqual(result, .normalTab(index: tabIndex),
                               "Round-trip failed for pinnedItemCount=\(pinnedItemCount), tabIndex=\(tabIndex)")
            }
        }
    }

    func testRoundTripPinnedItem() {
        for index in 0..<3 {
            let row = rowForPinnedItem(at: index)
            let result = sidebarRow(for: row, pinnedItemCount: 3)
            XCTAssertEqual(result, .pinnedItem(index: index))
        }
    }

    // MARK: - diffSidebarState

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

    private func flatItems(_ tabs: [BrowserTab] = [], folders: [PinnedFolder] = [],
                           collapsed: Set<UUID> = [], selectedTabID: UUID? = nil) -> [PinnedItem] {
        flattenPinnedTree(tabs: tabs, folders: folders, collapsedFolderIDs: collapsed, selectedTabID: selectedTabID)
    }

    func testDiffNoChanges() {
        let t1 = makeTab(title: "A", sortOrder: 0)
        let t2 = makeTab(title: "B", sortOrder: 1)
        let items = flatItems([t1, t2])
        let diff = diffSidebarState(oldPinnedItems: items, newPinnedItems: items,
                                     oldTabs: [t1], newTabs: [t1])
        XCTAssertFalse(diff.hasChanges)
    }

    func testDiffNormalTabInserted() {
        let t1 = makeTab()
        let t2 = makeTab()
        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: [t1], newTabs: [t1, t2])
        XCTAssertTrue(diff.removedRows.isEmpty)
        // t2 inserted at normal tab index 1 with 0 pinned items → row 4
        XCTAssertEqual(diff.insertedRows, IndexSet(integer: rowForNormalTab(at: 1, pinnedItemCount: 0)))
    }

    func testDiffNormalTabRemoved() {
        let t1 = makeTab()
        let t2 = makeTab()
        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: [t1, t2], newTabs: [t1])
        XCTAssertTrue(diff.insertedRows.isEmpty)
        // t2 was at normal tab index 1 with 0 pinned items
        XCTAssertEqual(diff.removedRows, IndexSet(integer: rowForNormalTab(at: 1, pinnedItemCount: 0)))
    }

    func testDiffExpandFolder() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let child1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let child2 = makeTab(title: "B", folderID: folderID, sortOrder: 2)

        let collapsed = flatItems([child1, child2], folders: [folder], collapsed: [folderID])
        let expanded = flatItems([child1, child2], folders: [folder])

        let diff = diffSidebarState(oldPinnedItems: collapsed, newPinnedItems: expanded,
                                     oldTabs: [], newTabs: [])
        // Expanding reveals child1 and child2
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertEqual(diff.insertedRows.count, 2)
    }

    func testDiffCollapseFolder() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let child1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let child2 = makeTab(title: "B", folderID: folderID, sortOrder: 2)

        let expanded = flatItems([child1, child2], folders: [folder])
        let collapsed = flatItems([child1, child2], folders: [folder], collapsed: [folderID])

        let diff = diffSidebarState(oldPinnedItems: expanded, newPinnedItems: collapsed,
                                     oldTabs: [], newTabs: [])
        // Collapsing hides child1 and child2
        XCTAssertEqual(diff.removedRows.count, 2)
        XCTAssertTrue(diff.insertedRows.isEmpty)
    }

    func testDiffCollapseWithExposedTab() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let child1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let child2 = makeTab(title: "B", folderID: folderID, sortOrder: 2)

        let expanded = flatItems([child1, child2], folders: [folder])
        // Collapse with child2 selected → child2 exposed
        let collapsed = flatItems([child1, child2], folders: [folder], collapsed: [folderID], selectedTabID: child2.id)

        let diff = diffSidebarState(oldPinnedItems: expanded, newPinnedItems: collapsed,
                                     oldTabs: [], newTabs: [])
        // child1 removed, child2 stays (exposed) → only 1 removal
        XCTAssertEqual(diff.removedRows.count, 1)
        XCTAssertTrue(diff.insertedRows.isEmpty)
    }

    func testDiffTabPinned() {
        let tab = makeTab()
        let pinnedItem: [PinnedItem] = [.tab(tab, depth: 0)]

        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: pinnedItem,
                                     oldTabs: [tab], newTabs: [])
        // Cross-section move: normal → pinned
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
        XCTAssertEqual(diff.movedRows.count, 1)
        XCTAssertEqual(diff.movedRows[0].from, rowForNormalTab(at: 0, pinnedItemCount: 0))
        XCTAssertEqual(diff.movedRows[0].to, rowForPinnedItem(at: 0))
    }

    func testDiffTabUnpinned() {
        let tab = makeTab()
        let pinnedItem: [PinnedItem] = [.tab(tab, depth: 0)]

        let diff = diffSidebarState(oldPinnedItems: pinnedItem, newPinnedItems: [],
                                     oldTabs: [], newTabs: [tab])
        // Cross-section move: pinned → normal
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
        XCTAssertEqual(diff.movedRows.count, 1)
        XCTAssertEqual(diff.movedRows[0].from, rowForPinnedItem(at: 0))
        XCTAssertEqual(diff.movedRows[0].to, rowForNormalTab(at: 0, pinnedItemCount: 0))
    }

    func testDiffPureReorderProducesMoves() {
        let t1 = makeTab()
        let t2 = makeTab()
        // Same IDs, different order → move (not insert/remove)
        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: [t1, t2], newTabs: [t2, t1])
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
        XCTAssertEqual(diff.movedRows.count, 1, "Swapping 2 items requires 1 move (LIS keeps 1 item stable)")
        XCTAssertTrue(diff.hasChanges)
    }

    func testDiffPinnedReorderProducesMoves() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 1)
        let tab = makeTab(title: "A", sortOrder: 0)

        let oldItems = flatItems([tab], folders: [folder])  // [tab, folder]
        // Reorder: folder first, then tab
        let reorderedFolder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let reorderedTab = makeTab(id: tab.id, title: "A", sortOrder: 1)
        let newItems = flatItems([reorderedTab], folders: [reorderedFolder])  // [folder, tab]

        let diff = diffSidebarState(oldPinnedItems: oldItems, newPinnedItems: newItems,
                                     oldTabs: [], newTabs: [])
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
        XCTAssertEqual(diff.movedRows.count, 1, "Swapping 2 pinned items requires 1 move")
    }

    func testDiffNoChangesNoMoves() {
        let t1 = makeTab(title: "A", sortOrder: 0)
        let t2 = makeTab(title: "B", sortOrder: 1)
        let items = flatItems([t1, t2])
        let diff = diffSidebarState(oldPinnedItems: items, newPinnedItems: items,
                                     oldTabs: [t1], newTabs: [t1])
        XCTAssertFalse(diff.hasChanges)
        XCTAssertTrue(diff.movedRows.isEmpty)
    }

    func testDiffInsertDoesNotProduceSpuriousMoves() {
        let t1 = makeTab()
        let t2 = makeTab()
        let t3 = makeTab()
        // Insert t3 between t1 and t2 — t2 shifts but should NOT produce a move
        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: [t1, t2], newTabs: [t1, t3, t2])
        XCTAssertEqual(diff.insertedRows.count, 1)
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.movedRows.isEmpty, "Shift from insert should not produce moves")
    }

    func testDiffEmptyToPopulated() {
        let t1 = makeTab()
        let t2 = makeTab()
        let pinnedItem: [PinnedItem] = [.tab(t1, depth: 0)]

        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: pinnedItem,
                                     oldTabs: [], newTabs: [t2])
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertEqual(diff.insertedRows.count, 2) // 1 pinned + 1 normal
    }

    func testDiffPopulatedToEmpty() {
        let t1 = makeTab()
        let t2 = makeTab()
        let pinnedItem: [PinnedItem] = [.tab(t1, depth: 0)]

        let diff = diffSidebarState(oldPinnedItems: pinnedItem, newPinnedItems: [],
                                     oldTabs: [t2], newTabs: [])
        XCTAssertEqual(diff.removedRows.count, 2) // 1 pinned + 1 normal
        XCTAssertTrue(diff.insertedRows.isEmpty)
    }

    func testDiffMultipleSimultaneousChanges() {
        let t1 = makeTab()
        let t2 = makeTab()
        let t3 = makeTab()
        let t4 = makeTab()
        let pinned1: [PinnedItem] = [.tab(t1, depth: 0)]
        let pinned2: [PinnedItem] = [.tab(t3, depth: 0)]

        // t1 pinned→removed, t2 normal→removed, t3 inserted as pinned, t4 inserted as normal
        let diff = diffSidebarState(oldPinnedItems: pinned1, newPinnedItems: pinned2,
                                     oldTabs: [t2], newTabs: [t4])
        XCTAssertEqual(diff.removedRows.count, 2)  // t1 from pinned, t2 from normal
        XCTAssertEqual(diff.insertedRows.count, 2)  // t3 to pinned, t4 to normal
    }

    // MARK: - Folder collapse/expand preserves folder row (chevron update scenario)

    func testDiffCollapseFolderKeepsFolderRow() {
        // When collapsing a folder, the folder row itself must NOT be in removedRows
        // (it survives and needs a cell refresh for the chevron, not a remove/insert)
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let child = makeTab(title: "A", folderID: folderID, sortOrder: 1)

        let expanded = flatItems([child], folders: [folder])   // [folder, child]
        let collapsed = flatItems([child], folders: [folder], collapsed: [folderID])  // [folder]

        let diff = diffSidebarState(oldPinnedItems: expanded, newPinnedItems: collapsed,
                                     oldTabs: [], newTabs: [])

        let folderRow = rowForPinnedItem(at: 0)
        XCTAssertFalse(diff.removedRows.contains(folderRow), "Folder row should survive collapse")
        XCTAssertFalse(diff.insertedRows.contains(folderRow), "Folder row should not be re-inserted")
        // Only the child row should be removed
        XCTAssertEqual(diff.removedRows.count, 1)
    }

    func testDiffExpandFolderKeepsFolderRow() {
        // Same test for expand: folder row survives, children are inserted
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let child1 = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let child2 = makeTab(title: "B", folderID: folderID, sortOrder: 2)

        let collapsed = flatItems([child1, child2], folders: [folder], collapsed: [folderID])
        let expanded = flatItems([child1, child2], folders: [folder])

        let diff = diffSidebarState(oldPinnedItems: collapsed, newPinnedItems: expanded,
                                     oldTabs: [], newTabs: [])

        let folderRow = rowForPinnedItem(at: 0)
        XCTAssertFalse(diff.removedRows.contains(folderRow), "Folder row should survive expand")
        XCTAssertFalse(diff.insertedRows.contains(folderRow), "Folder row should not be re-inserted")
        // Only the child rows should be inserted
        XCTAssertEqual(diff.insertedRows.count, 2)
    }

    // MARK: - Normal tab pinned into folder (drag-to-folder scenario)

    func testDiffNormalTabPinnedIntoFolder() {
        // Simulates the final state after: pin tab + move into folder
        // Old: folder with 1 child (expanded), tab in normal section
        // New: folder with 2 children (expanded), tab removed from normal
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let existingChild = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let draggedTab = makeTab(title: "B", sortOrder: 2)

        let oldPinned = flatItems([existingChild], folders: [folder])  // [folder, existingChild]
        let newChild = makeTab(id: draggedTab.id, title: "B", folderID: folderID, sortOrder: 2)
        let newPinned = flatItems([existingChild, newChild], folders: [folder])  // [folder, existingChild, newChild]

        let diff = diffSidebarState(oldPinnedItems: oldPinned, newPinnedItems: newPinned,
                                     oldTabs: [draggedTab], newTabs: [])

        // draggedTab moved from normal to pinned (cross-section move)
        XCTAssertEqual(diff.movedRows.count, 1)
        XCTAssertEqual(diff.movedRows[0].from, rowForNormalTab(at: 0, pinnedItemCount: oldPinned.count))
        XCTAssertEqual(diff.movedRows[0].to, rowForPinnedItem(at: 2))
        // No inserts or removes for the moved tab
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
    }

    func testDiffNormalTabPinnedIntoCollapsedFolder() {
        // Pin tab into a collapsed folder — tab should NOT appear as inserted
        // because it's hidden. But the exposed tab logic might show it if selected.
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let existingChild = makeTab(title: "A", folderID: folderID, sortOrder: 1)
        let draggedTab = makeTab(title: "B", sortOrder: 2)

        let oldPinned = flatItems([existingChild], folders: [folder], collapsed: [folderID])  // [folder]
        let newChild = makeTab(id: draggedTab.id, title: "B", folderID: folderID, sortOrder: 2)
        let newPinned = flatItems([existingChild, newChild], folders: [folder], collapsed: [folderID])  // [folder]

        let diff = diffSidebarState(oldPinnedItems: oldPinned, newPinnedItems: newPinned,
                                     oldTabs: [draggedTab], newTabs: [])

        // Tab removed from normal, but NOT inserted in pinned (collapsed)
        XCTAssertEqual(diff.removedRows.count, 1)
        XCTAssertEqual(diff.insertedRows.count, 0)
    }
}
