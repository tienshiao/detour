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
        // 1 (topSpacer) + pinnedItemCount + 1 (separator) + 1 (newTab) + itemCount
        XCTAssertEqual(totalSidebarRowCount(pinnedItemCount: 3, itemCount: 5), 11)
        XCTAssertEqual(totalSidebarRowCount(pinnedItemCount: 0, itemCount: 2), 5)
        XCTAssertEqual(totalSidebarRowCount(pinnedItemCount: 0, itemCount: 0), 3)
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

    private func makeEntry(id: UUID = UUID(), title: String = "Entry", folderID: UUID? = nil, sortOrder: Int = 0) -> PinnedEntry {
        PinnedEntry(id: id, pinnedURL: URL(string: "https://example.com")!, pinnedTitle: title, folderID: folderID, sortOrder: sortOrder)
    }

    private func makeTab(id: UUID = UUID()) -> BrowserTab {
        BrowserTab(id: id, title: "Tab", url: URL(string: "https://example.com"), faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
    }


    private func singles(_ tabs: BrowserTab...) -> [TabListItem] {
        tabs.map { .single($0) }
    }

    private func makeFolder(id: UUID = UUID(), name: String = "Folder", parentID: UUID? = nil, isCollapsed: Bool = false, sortOrder: Int = 0) -> PinnedFolder {
        PinnedFolder(id: id, name: name, parentFolderID: parentID, isCollapsed: isCollapsed, sortOrder: sortOrder)
    }

    private func flatItems(_ entries: [PinnedEntry] = [], folders: [PinnedFolder] = [],
                           collapsed: Set<UUID> = [], selectedTabID: UUID? = nil) -> [PinnedItem] {
        flattenPinnedTree(entries: entries, folders: folders, collapsedFolderIDs: collapsed, selectedTabID: selectedTabID)
    }

    func testDiffNoChanges() {
        let e1 = makeEntry(title: "A", sortOrder: 0)
        let e2 = makeEntry(title: "B", sortOrder: 1)
        let t1 = makeTab()
        let items = flatItems([e1, e2])
        let diff = diffSidebarState(oldPinnedItems: items, newPinnedItems: items,
                                     oldTabs: singles(t1), newTabs: singles(t1))
        XCTAssertFalse(diff.hasChanges)
    }

    func testDiffNormalTabInserted() {
        let t1 = makeTab()
        let t2 = makeTab()
        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: singles(t1), newTabs: singles(t1, t2))
        XCTAssertTrue(diff.removedRows.isEmpty)
        // t2 inserted at normal tab index 1 with 0 pinned items → row 4
        XCTAssertEqual(diff.insertedRows, IndexSet(integer: rowForNormalTab(at: 1, pinnedItemCount: 0)))
    }

    func testDiffNormalTabRemoved() {
        let t1 = makeTab()
        let t2 = makeTab()
        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: singles(t1, t2), newTabs: singles(t1))
        XCTAssertTrue(diff.insertedRows.isEmpty)
        // t2 was at normal tab index 1 with 0 pinned items
        XCTAssertEqual(diff.removedRows, IndexSet(integer: rowForNormalTab(at: 1, pinnedItemCount: 0)))
    }

    func testDiffExpandFolder() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let child1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let child2 = makeEntry(title: "B", folderID: folderID, sortOrder: 2)

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
        let child1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let child2 = makeEntry(title: "B", folderID: folderID, sortOrder: 2)

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
        let child1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let child2 = makeEntry(title: "B", folderID: folderID, sortOrder: 2)
        let tab = BrowserTab(id: UUID(), title: "B", url: URL(string: "https://example.com"), faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
        child2.tab = tab

        let expanded = flatItems([child1, child2], folders: [folder])
        // Collapse with child2's tab selected → child2 exposed
        let collapsed = flatItems([child1, child2], folders: [folder], collapsed: [folderID], selectedTabID: tab.id)

        let diff = diffSidebarState(oldPinnedItems: expanded, newPinnedItems: collapsed,
                                     oldTabs: [], newTabs: [])
        // child1 removed, child2 stays (exposed) → only 1 removal
        XCTAssertEqual(diff.removedRows.count, 1)
        XCTAssertTrue(diff.insertedRows.isEmpty)
    }

    func testDiffTabPinned() {
        let entry = makeEntry()
        let tab = makeTab()
        let pinnedItem: [PinnedItem] = [.entry(entry, depth: 0)]

        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: pinnedItem,
                                     oldTabs: singles(tab), newTabs: [])
        // entry inserted, tab removed (different IDs, so not a move)
        XCTAssertEqual(diff.removedRows.count, 1)
        XCTAssertEqual(diff.insertedRows.count, 1)
    }

    func testDiffTabUnpinned() {
        let entry = makeEntry()
        let tab = makeTab()
        let pinnedItem: [PinnedItem] = [.entry(entry, depth: 0)]

        let diff = diffSidebarState(oldPinnedItems: pinnedItem, newPinnedItems: [],
                                     oldTabs: [], newTabs: singles(tab))
        // entry removed, tab inserted (different IDs)
        XCTAssertEqual(diff.removedRows.count, 1)
        XCTAssertEqual(diff.insertedRows.count, 1)
    }

    func testDiffPureReorderProducesMoves() {
        let t1 = makeTab()
        let t2 = makeTab()
        // Same IDs, different order → move (not insert/remove)
        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: singles(t1, t2), newTabs: singles(t2, t1))
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
        XCTAssertEqual(diff.movedRows.count, 1, "Swapping 2 items requires 1 move (LIS keeps 1 item stable)")
        XCTAssertTrue(diff.hasChanges)
    }

    func testDiffPinnedReorderProducesMoves() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 1)
        let entry = makeEntry(title: "A", sortOrder: 0)

        let oldItems = flatItems([entry], folders: [folder])  // [entry, folder]
        // Reorder: folder first, then entry
        let reorderedFolder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let reorderedEntry = makeEntry(id: entry.id, title: "A", sortOrder: 1)
        let newItems = flatItems([reorderedEntry], folders: [reorderedFolder])  // [folder, entry]

        let diff = diffSidebarState(oldPinnedItems: oldItems, newPinnedItems: newItems,
                                     oldTabs: [], newTabs: [])
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
        XCTAssertEqual(diff.movedRows.count, 1, "Swapping 2 pinned items requires 1 move")
    }

    func testDiffSwapPrefersMoveUpward() {
        let t1 = makeTab()
        let t2 = makeTab()

        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: singles(t1, t2), newTabs: singles(t2, t1))
        XCTAssertEqual(diff.movedRows.count, 1)
        // t2 (old index 1) moves to new index 0 — upward move
        let move = diff.movedRows[0]
        XCTAssertEqual(move.from, rowForNormalTab(at: 1, pinnedItemCount: 0))
        XCTAssertEqual(move.to, rowForNormalTab(at: 0, pinnedItemCount: 0))
    }

    func testDiffBlockMoveMinimal() {
        let folderID = UUID()
        let entryA = makeEntry(title: "A", sortOrder: 0)
        let folderB = makeFolder(id: folderID, name: "Folder", sortOrder: 1)
        let child1 = makeEntry(title: "Child", folderID: folderID, sortOrder: 2)

        let oldItems = flatItems([entryA, child1], folders: [folderB])
        let newEntryA = makeEntry(id: entryA.id, title: "A", sortOrder: 2)
        let newFolderB = makeFolder(id: folderID, name: "Folder", sortOrder: 0)
        let newChild1 = makeEntry(id: child1.id, title: "Child", folderID: folderID, sortOrder: 1)
        let newItems = flatItems([newEntryA, newChild1], folders: [newFolderB])

        let diff = diffSidebarState(oldPinnedItems: oldItems, newPinnedItems: newItems,
                                     oldTabs: [], newTabs: [])
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
        XCTAssertEqual(diff.movedRows.count, 1, "Only EntryA moves; FolderB+Child1 stay (LIS)")
        // EntryA moves from old row 1 to new row 3
        XCTAssertEqual(diff.movedRows[0].from, rowForPinnedItem(at: 0))
        XCTAssertEqual(diff.movedRows[0].to, rowForPinnedItem(at: 2))
    }

    func testDiffEqualBlockSwapMovesUpward() {
        let e1 = makeEntry(title: "A", sortOrder: 0)
        let e2 = makeEntry(title: "B", sortOrder: 1)
        let e3 = makeEntry(title: "C", sortOrder: 2)
        let e4 = makeEntry(title: "D", sortOrder: 3)

        let oldItems: [PinnedItem] = [.entry(e1, depth: 0), .entry(e2, depth: 0),
                                       .entry(e3, depth: 0), .entry(e4, depth: 0)]
        let newItems: [PinnedItem] = [.entry(e3, depth: 0), .entry(e4, depth: 0),
                                       .entry(e1, depth: 0), .entry(e2, depth: 0)]

        let diff = diffSidebarState(oldPinnedItems: oldItems, newPinnedItems: newItems,
                                     oldTabs: [], newTabs: [])
        XCTAssertEqual(diff.movedRows.count, 2, "C and D move upward")
        // Moves should be to lower rows (upward)
        for move in diff.movedRows {
            XCTAssertLessThan(move.to, move.from, "Moves should be upward")
        }
        // Sorted by destination ascending
        XCTAssertLessThanOrEqual(diff.movedRows[0].to, diff.movedRows[1].to)
    }

    func testDiffMovesAreSortedByDestination() {
        let t1 = makeTab()
        let t2 = makeTab()
        let t3 = makeTab()
        let t4 = makeTab()

        // Reverse the order: [D, C, B, A]
        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: singles(t1, t2, t3, t4), newTabs: singles(t4, t3, t2, t1))
        // Whatever moves are generated, they must be sorted by destination
        for i in 1..<diff.movedRows.count {
            XCTAssertLessThanOrEqual(diff.movedRows[i - 1].to, diff.movedRows[i].to,
                                      "Moves must be sorted by destination for sequential processing")
        }
    }

    func testDiffSequentialMoveCorrectness() {
        let t1 = makeTab()
        let t2 = makeTab()
        let t3 = makeTab()
        let t4 = makeTab()

        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: singles(t1, t2, t3, t4), newTabs: singles(t3, t4, t1, t2))

        // Simulate sequential move processing
        var rows = [t1.id, t2.id, t3.id, t4.id]
        for move in diff.movedRows {
            // Convert table rows to array indices (subtract normal tab row offset)
            let pinnedCount = 0
            let fromIdx = move.from - rowForNormalTab(at: 0, pinnedItemCount: pinnedCount)
            let toIdx = move.to - rowForNormalTab(at: 0, pinnedItemCount: pinnedCount)
            let item = rows.remove(at: fromIdx)
            rows.insert(item, at: toIdx)
        }

        XCTAssertEqual(rows, [t3.id, t4.id, t1.id, t2.id],
                       "Sequential processing of moves should produce the correct final order")
    }

    func testDiffNoChangesNoMoves() {
        let e1 = makeEntry(title: "A", sortOrder: 0)
        let e2 = makeEntry(title: "B", sortOrder: 1)
        let t1 = makeTab()
        let items = flatItems([e1, e2])
        let diff = diffSidebarState(oldPinnedItems: items, newPinnedItems: items,
                                     oldTabs: singles(t1), newTabs: singles(t1))
        XCTAssertFalse(diff.hasChanges)
        XCTAssertTrue(diff.movedRows.isEmpty)
    }

    func testDiffInsertDoesNotProduceSpuriousMoves() {
        let t1 = makeTab()
        let t2 = makeTab()
        let t3 = makeTab()
        // Insert t3 between t1 and t2 — t2 shifts but should NOT produce a move
        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: [],
                                     oldTabs: singles(t1, t2), newTabs: singles(t1, t3, t2))
        XCTAssertEqual(diff.insertedRows.count, 1)
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.movedRows.isEmpty, "Shift from insert should not produce moves")
    }

    func testDiffEmptyToPopulated() {
        let e1 = makeEntry()
        let t2 = makeTab()
        let pinnedItem: [PinnedItem] = [.entry(e1, depth: 0)]

        let diff = diffSidebarState(oldPinnedItems: [], newPinnedItems: pinnedItem,
                                     oldTabs: [], newTabs: singles(t2))
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertEqual(diff.insertedRows.count, 2) // 1 pinned + 1 normal
    }

    func testDiffPopulatedToEmpty() {
        let e1 = makeEntry()
        let t2 = makeTab()
        let pinnedItem: [PinnedItem] = [.entry(e1, depth: 0)]

        let diff = diffSidebarState(oldPinnedItems: pinnedItem, newPinnedItems: [],
                                     oldTabs: singles(t2), newTabs: [])
        XCTAssertEqual(diff.removedRows.count, 2) // 1 pinned + 1 normal
        XCTAssertTrue(diff.insertedRows.isEmpty)
    }

    func testDiffMultipleSimultaneousChanges() {
        let e1 = makeEntry()
        let t2 = makeTab()
        let e3 = makeEntry()
        let t4 = makeTab()
        let pinned1: [PinnedItem] = [.entry(e1, depth: 0)]
        let pinned2: [PinnedItem] = [.entry(e3, depth: 0)]

        // e1 pinned→removed, t2 normal→removed, e3 inserted as pinned, t4 inserted as normal
        let diff = diffSidebarState(oldPinnedItems: pinned1, newPinnedItems: pinned2,
                                     oldTabs: singles(t2), newTabs: singles(t4))
        XCTAssertEqual(diff.removedRows.count, 2)  // e1 from pinned, t2 from normal
        XCTAssertEqual(diff.insertedRows.count, 2)  // e3 to pinned, t4 to normal
    }

    // MARK: - Folder collapse/expand preserves folder row (chevron update scenario)

    func testDiffCollapseFolderKeepsFolderRow() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let child = makeEntry(title: "A", folderID: folderID, sortOrder: 1)

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
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let child1 = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let child2 = makeEntry(title: "B", folderID: folderID, sortOrder: 2)

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
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let existingChild = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let draggedTab = makeTab()

        let oldPinned = flatItems([existingChild], folders: [folder])  // [folder, existingChild]
        // After pinning, the entry uses the same ID as the tab for cross-section move detection
        let newChild = makeEntry(id: draggedTab.id, title: "B", folderID: folderID, sortOrder: 2)
        let newPinned = flatItems([existingChild, newChild], folders: [folder])  // [folder, existingChild, newChild]

        let diff = diffSidebarState(oldPinnedItems: oldPinned, newPinnedItems: newPinned,
                                     oldTabs: singles(draggedTab), newTabs: [])

        // draggedTab moved from normal to pinned (cross-section move)
        XCTAssertEqual(diff.movedRows.count, 1)
        XCTAssertEqual(diff.movedRows[0].from, rowForNormalTab(at: 0, pinnedItemCount: oldPinned.count))
        XCTAssertEqual(diff.movedRows[0].to, rowForPinnedItem(at: 2))
        // No inserts or removes for the moved tab
        XCTAssertTrue(diff.removedRows.isEmpty)
        XCTAssertTrue(diff.insertedRows.isEmpty)
    }

    func testDiffNormalTabPinnedIntoCollapsedFolder() {
        let folderID = UUID()
        let folder = makeFolder(id: folderID, name: "Work", sortOrder: 0)
        let existingChild = makeEntry(title: "A", folderID: folderID, sortOrder: 1)
        let draggedTab = makeTab()

        let oldPinned = flatItems([existingChild], folders: [folder], collapsed: [folderID])  // [folder]
        let newChild = makeEntry(id: draggedTab.id, title: "B", folderID: folderID, sortOrder: 2)
        let newPinned = flatItems([existingChild, newChild], folders: [folder], collapsed: [folderID])  // [folder]

        let diff = diffSidebarState(oldPinnedItems: oldPinned, newPinnedItems: newPinned,
                                     oldTabs: singles(draggedTab), newTabs: [])

        // Tab removed from normal, but NOT inserted in pinned (collapsed)
        XCTAssertEqual(diff.removedRows.count, 1)
        XCTAssertEqual(diff.insertedRows.count, 0)
    }
}
