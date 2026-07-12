import XCTest
import GRDB
@testable import Detour

final class SplitTabTests: XCTestCase {

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

    /// Tabs A, B, C, D where B+C form a split group. Returns the group ID.
    @discardableResult
    private func makeSplitFixture(_ store: TabStore, _ space: Space) -> (tabs: [BrowserTab], groupID: UUID) {
        let tabs = (0..<4).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        let groupID = UUID()
        for tab in [tabs[1], tabs[2]] {
            tab.splitGroupID = groupID
            tab.splitFraction = 0.5
        }
        return (tabs, groupID)
    }

    // MARK: - tabListItems

    func testTabListItemsGroupsAdjacentPair() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makeSplitFixture(store, space)

        let items = tabListItems(from: space.tabs)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0], .single(tabs[0]))
        XCTAssertEqual(items[1], .split(groupID: groupID, members: [tabs[1], tabs[2]]))
        XCTAssertEqual(items[2], .single(tabs[3]))
    }

    func testTabListItemsTreatsSingletonGroupAsSingle() throws {
        let (_, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        tab.splitGroupID = UUID()
        space.tabs.append(tab)

        XCTAssertEqual(tabListItems(from: space.tabs), [.single(tab)])
    }

    func testTabListItemsTreatsNonAdjacentGroupMembersAsSingles() throws {
        let (_, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        let groupID = UUID()
        tabs[0].splitGroupID = groupID
        tabs[2].splitGroupID = groupID

        let items = tabListItems(from: space.tabs)
        XCTAssertEqual(items, [.single(tabs[0]), .single(tabs[1]), .single(tabs[2])])
    }

    func testItemIndexConversions() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)
        let items = tabListItems(from: space.tabs)

        XCTAssertEqual(itemIndex(forTabIndex: 0, in: items), 0)
        XCTAssertEqual(itemIndex(forTabIndex: 1, in: items), 1)
        XCTAssertEqual(itemIndex(forTabIndex: 2, in: items), 1)
        XCTAssertEqual(itemIndex(forTabIndex: 3, in: items), 2)
        XCTAssertNil(itemIndex(forTabIndex: 4, in: items))

        XCTAssertEqual(itemIndex(containingTabID: tabs[2].id, in: items), 1)

        XCTAssertEqual(firstTabIndex(forItemIndex: 0, in: items), 0)
        XCTAssertEqual(firstTabIndex(forItemIndex: 1, in: items), 1)
        XCTAssertEqual(firstTabIndex(forItemIndex: 2, in: items), 3)
        XCTAssertNil(firstTabIndex(forItemIndex: 3, in: items))

        XCTAssertEqual(tabGapIndex(forItemGap: 0, in: items), 0)
        XCTAssertEqual(tabGapIndex(forItemGap: 1, in: items), 1)
        XCTAssertEqual(tabGapIndex(forItemGap: 2, in: items), 3)
        XCTAssertEqual(tabGapIndex(forItemGap: 3, in: items), 4)
    }

    // MARK: - sanitizeSplitGroups

    func testSanitizeClearsSingletonAndNonAdjacentGroups() throws {
        let (_, space) = try makeStore()
        let tabs = (0..<5).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        tabs[0].splitGroupID = UUID()               // singleton group
        tabs[0].splitFraction = 0.4
        let tornGroup = UUID()
        tabs[1].splitGroupID = tornGroup            // non-adjacent pair
        tabs[3].splitGroupID = tornGroup

        sanitizeSplitGroups(space.tabs)

        XCTAssertNil(tabs[0].splitGroupID)
        XCTAssertNil(tabs[0].splitFraction)
        XCTAssertNil(tabs[1].splitGroupID)
        XCTAssertNil(tabs[3].splitGroupID)
    }

    func testSanitizeKeepsValidPair() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makeSplitFixture(store, space)

        sanitizeSplitGroups(space.tabs)

        XCTAssertEqual(tabs[1].splitGroupID, groupID)
        XCTAssertEqual(tabs[2].splitGroupID, groupID)
    }

    // MARK: - Insertion snapping

    func testSnappedToSplitGroupBoundary() {
        let g = UUID()
        let groups: [UUID?] = [nil, g, g, nil]
        XCTAssertEqual(snappedToSplitGroupBoundary(0, groupIDs: groups), 0)
        XCTAssertEqual(snappedToSplitGroupBoundary(1, groupIDs: groups), 1)
        XCTAssertEqual(snappedToSplitGroupBoundary(2, groupIDs: groups), 3)  // inside pair → past it
        XCTAssertEqual(snappedToSplitGroupBoundary(3, groupIDs: groups), 3)
        XCTAssertEqual(snappedToSplitGroupBoundary(4, groupIDs: groups), 4)
        XCTAssertEqual(snappedToSplitGroupBoundary(9, groupIDs: groups), 4)  // clamped
    }

    func testChildTabInsertionNeverLandsInsideGroup() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)

        // Child of the left member would insert at parentIndex+1 — between the
        // members. It must snap past the group instead.
        let child = store.addTab(in: space, parentID: tabs[1].id)

        XCTAssertEqual(space.tabs.firstIndex { $0.id == child.id }, 3)
        XCTAssertEqual(tabListItems(from: space.tabs).count, 4)
    }

    // MARK: - resolveTabMove

    func testResolveTabMoveSingleTab() {
        let groups: [UUID?] = [nil, nil, nil]
        let move = resolveTabMove(sourceIndex: 0, destinationIndex: 2, groupIDs: groups)
        XCTAssertEqual(move?.blockRange, 0..<1)
        XCTAssertEqual(move?.insertAt, 2)
    }

    func testResolveTabMoveMemberMovesWholeBlock() {
        let g = UUID()
        let groups: [UUID?] = [nil, g, g, nil]
        let move = resolveTabMove(sourceIndex: 2, destinationIndex: 0, groupIDs: groups)
        XCTAssertEqual(move?.blockRange, 1..<3)
        XCTAssertEqual(move?.insertAt, 0)
    }

    func testResolveTabMoveDestinationSnapsPastOtherGroup() {
        let g = UUID()
        let groups: [UUID?] = [nil, g, g, nil]
        // Moving tab 0 to land "between" the pair (post-removal index 1) snaps to 2.
        let move = resolveTabMove(sourceIndex: 0, destinationIndex: 1, groupIDs: groups)
        XCTAssertEqual(move?.insertAt, 2)
    }

    func testResolveTabMoveNoOpReturnsNil() {
        let g = UUID()
        let groups: [UUID?] = [g, g, nil]
        XCTAssertNil(resolveTabMove(sourceIndex: 1, destinationIndex: 0, groupIDs: groups))
        XCTAssertNil(resolveTabMove(sourceIndex: 5, destinationIndex: 0, groupIDs: groups))
    }

    func testMoveTabMovesSplitBlockAsUnit() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makeSplitFixture(store, space)

        // Move the right member (index 2) to the front — whole block moves.
        store.moveTab(from: 2, to: 0, in: space)

        XCTAssertEqual(space.tabs.map(\.id), [tabs[1].id, tabs[2].id, tabs[0].id, tabs[3].id])
        XCTAssertEqual(tabs[1].splitGroupID, groupID)
        XCTAssertEqual(tabs[2].splitGroupID, groupID)

        store.undoManager.undo()
        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
    }

    // MARK: - Gap-based moves (drop handling)

    func testGapMoveSplitRowToEndGap() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)  // [A, S1, S2, D] with S1+S2 split

        store.moveTab(id: tabs[1].id, toGapIndex: 4, in: space)  // gap after D

        XCTAssertEqual(space.tabs.map(\.id), [tabs[0].id, tabs[3].id, tabs[1].id, tabs[2].id])
    }

    func testGapMoveSplitRowInteriorGapDoesNotOvershoot() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<5).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        let groupID = UUID()
        for tab in [tabs[1], tabs[2]] { tab.splitGroupID = groupID; tab.splitFraction = 0.5 }
        // [A, B, C, D, E] with B+C split. Drop indicator between D and E = tab gap 4.
        store.moveTab(id: tabs[1].id, toGapIndex: 4, in: space)

        XCTAssertEqual(space.tabs.map(\.id),
                       [tabs[0].id, tabs[3].id, tabs[1].id, tabs[2].id, tabs[4].id],
                       "block must land exactly at the drop gap, not one slot past it")
    }

    func testGapMoveIntoOwnGapsIsNoOp() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)

        store.moveTab(id: tabs[1].id, toGapIndex: 1, in: space)  // own leading gap
        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
        store.moveTab(id: tabs[2].id, toGapIndex: 3, in: space)  // own trailing gap
        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
        store.moveTab(id: tabs[1].id, toGapIndex: 2, in: space)  // gap inside the block
        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
    }

    func testGapMoveSingleTabMatchesOldSemantics() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)

        store.moveTab(id: tabs[0].id, toGapIndex: 2, in: space)  // between B and C
        XCTAssertEqual(space.tabs.map(\.id), [tabs[1].id, tabs[0].id, tabs[2].id])
    }

    func testMoveTabNonFirstMemberEqualIndicesStillMoves() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)  // [A, S1, S2, D]

        // Pre-removal source 2 (S2), post-removal destination 2: a real move —
        // the old source==destination guard silently rejected it.
        store.moveTab(from: 2, to: 2, in: space)

        XCTAssertEqual(space.tabs.map(\.id), [tabs[0].id, tabs[3].id, tabs[1].id, tabs[2].id])
    }

    // MARK: - closeSplitGroup

    func testCloseSplitGroupClosesBothWithSingleUndo() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makeSplitFixture(store, space)
        store.setSplitFraction(groupID: groupID, fraction: 0.3, in: space)

        store.closeSplitGroup(groupID: groupID, in: space)

        XCTAssertEqual(space.tabs.map(\.id), [tabs[0].id, tabs[3].id])
        XCTAssertEqual(store.closedTabStack.filter { $0.spaceID == space.id.uuidString }.count, 2)

        store.undoManager.undo()

        XCTAssertEqual(space.tabs.count, 4)
        let restoredLeft = space.tabs[1]
        let restoredRight = space.tabs[2]
        XCTAssertNotNil(restoredLeft.splitGroupID)
        XCTAssertEqual(restoredLeft.splitGroupID, restoredRight.splitGroupID)
        XCTAssertEqual(restoredLeft.splitFraction, 0.3)
        XCTAssertEqual(store.closedTabStack.filter { $0.spaceID == space.id.uuidString }.count, 0,
                       "undo must remove both closed-tab records so Cmd+Shift+T can't duplicate")
    }

    // MARK: - Delete Space undo

    func testDeleteSpaceUndoPreservesSplit() throws {
        let (store, space) = try makeStore()
        let profileID = space.profileID
        let space2 = store.addSpace(name: "Two", emoji: "2️⃣", colorHex: "FF0000", profileID: profileID)
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space2.id) }
        space2.tabs.append(contentsOf: tabs)
        let groupID = UUID()
        for tab in [tabs[0], tabs[1]] { tab.splitGroupID = groupID; tab.splitFraction = 0.7 }

        // All registrations in one runloop turn share an undo group; drop the
        // addSpace undo so undo() runs only deleteSpace's restore.
        store.undoManager.removeAllActions()
        store.deleteSpace(id: space2.id)
        store.undoManager.undo()

        let restored = store.space(withID: space2.id)
        XCTAssertNotNil(restored)
        let members = restored!.tabs.filter { $0.splitGroupID != nil }
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0].splitGroupID, members[1].splitGroupID)
        XCTAssertEqual(members[0].splitFraction, 0.7)
    }

    // MARK: - addTabInSplit undo

    func testAddTabInSplitUndoDoesNotArchive() throws {
        let (store, space) = try makeStore()
        let anchor = makeSleepingTab(spaceID: space.id)
        space.tabs.append(anchor)

        let pane = store.addTabInSplit(with: anchor.id, url: URL(string: "https://example.com/b")!, in: space)
        XCTAssertNotNil(pane)
        XCTAssertEqual(anchor.splitGroupID, pane?.splitGroupID)

        store.undoManager.undo()

        XCTAssertEqual(space.tabs.map(\.id), [anchor.id])
        XCTAssertNil(anchor.splitGroupID)
        XCTAssertTrue(store.closedTabStack.isEmpty,
                      "undoing Open in Split must not leave a phantom closed-tab record")
    }

    // MARK: - splitGroup drag kind

    func testSplitGroupDragOnlyReordersInNormalSection() {
        let folder = PinnedFolder(id: UUID(), name: "F", parentFolderID: nil, isCollapsed: false, sortOrder: 0)
        let items: [PinnedItem] = [.folder(folder, depth: 0)]

        // Pin-section and folder targets reject outright.
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .pinnedItem(index: 0), operation: .above, items: items), .reject)
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .pinnedItem(index: 0), operation: .on, items: items), .reject)
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .topSpacer, operation: .above, items: items), .reject)
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .separator, operation: .above, items: items), .reject)
        // Normal-section reorder accepted.
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .normalTab(index: 1), operation: .above, items: items), .accept)

        // Resolver: reorder command in the normal section, nil elsewhere.
        let firstTabID = UUID()
        XCTAssertEqual(
            resolveSidebarDrop(source: .splitGroup(index: 0, firstTabID: firstTabID),
                               destination: .beforeNormalTab(gapIndex: 2), items: items),
            .reorderNormalTab(tabID: firstTabID, fromIndex: 0, toGapIndex: 2)
        )
        XCTAssertNil(resolveSidebarDrop(source: .splitGroup(index: 0, firstTabID: firstTabID),
                                        destination: .beforeNormalTab(gapIndex: 0), items: items),
                     "adjacent own gap is a no-op")
        XCTAssertNil(resolveSidebarDrop(source: .splitGroup(index: 0, firstTabID: firstTabID),
                                        destination: .beforePinnedItem(flatIndex: 0), items: items))
        XCTAssertNil(resolveSidebarDrop(source: .splitGroup(index: 0, firstTabID: firstTabID),
                                        destination: .intoFolder(folderID: folder.id), items: items))
    }

    // MARK: - createSplit

    func testCreateSplitRightEdgePlacesDraggedAfterTarget() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)

        store.createSplit(draggedTabID: tabs[0].id, targetTabID: tabs[2].id, edge: .right, in: space)

        XCTAssertEqual(space.tabs.map(\.id), [tabs[1].id, tabs[2].id, tabs[0].id])
        XCTAssertNotNil(tabs[0].splitGroupID)
        XCTAssertEqual(tabs[0].splitGroupID, tabs[2].splitGroupID)
        XCTAssertEqual(tabs[0].splitFraction, 0.5)
        XCTAssertEqual(tabListItems(from: space.tabs).count, 2)
    }

    func testCreateSplitLeftEdgePlacesDraggedBeforeTarget() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)

        store.createSplit(draggedTabID: tabs[2].id, targetTabID: tabs[0].id, edge: .left, in: space)

        XCTAssertEqual(space.tabs.map(\.id), [tabs[2].id, tabs[0].id, tabs[1].id])
        XCTAssertEqual(tabs[2].splitGroupID, tabs[0].splitGroupID)
    }

    func testCreateSplitRejectsGroupedParticipants() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makeSplitFixture(store, space)

        // Target already in a group
        store.createSplit(draggedTabID: tabs[0].id, targetTabID: tabs[1].id, edge: .left, in: space)
        XCTAssertNil(tabs[0].splitGroupID)

        // Dragged already in a group
        store.createSplit(draggedTabID: tabs[2].id, targetTabID: tabs[3].id, edge: .right, in: space)
        XCTAssertEqual(tabs[2].splitGroupID, groupID)
        XCTAssertNil(tabs[3].splitGroupID)

        // Self-split
        store.createSplit(draggedTabID: tabs[0].id, targetTabID: tabs[0].id, edge: .left, in: space)
        XCTAssertNil(tabs[0].splitGroupID)
    }

    // MARK: - separateSplit

    func testSeparateSplitClearsGroupAndUndoRejoins() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makeSplitFixture(store, space)

        store.separateSplit(groupID: groupID, in: space)

        XCTAssertNil(tabs[1].splitGroupID)
        XCTAssertNil(tabs[2].splitGroupID)
        XCTAssertEqual(tabListItems(from: space.tabs).count, 4)
        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))  // order unchanged

        store.undoManager.undo()

        XCTAssertNotNil(tabs[1].splitGroupID)
        XCTAssertEqual(tabs[1].splitGroupID, tabs[2].splitGroupID)
        XCTAssertEqual(tabs[1].splitFraction, 0.5)
        XCTAssertEqual(tabListItems(from: space.tabs).count, 3)
    }

    // MARK: - removeTabFromSplit

    func testRemoveTabFromSplitMovesOutAndDissolves() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)

        store.removeTabFromSplit(tabID: tabs[2].id, toGapIndex: 0, in: space)

        XCTAssertEqual(space.tabs.map(\.id), [tabs[2].id, tabs[0].id, tabs[1].id, tabs[3].id])
        XCTAssertNil(tabs[1].splitGroupID)
        XCTAssertNil(tabs[2].splitGroupID)
        XCTAssertNil(tabs[1].splitFraction)
    }

    func testRemoveTabFromSplitUndoRestoresSplit() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)

        store.removeTabFromSplit(tabID: tabs[2].id, toGapIndex: 0, in: space)
        store.undoManager.undo()

        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
        XCTAssertNotNil(tabs[2].splitGroupID)
        XCTAssertEqual(tabs[1].splitGroupID, tabs[2].splitGroupID)
    }

    // MARK: - closeTab

    func testCloseMemberDissolvesGroup() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)

        store.closeTab(id: tabs[1].id, in: space)

        XCTAssertNil(tabs[2].splitGroupID)
        XCTAssertNil(tabs[2].splitFraction)
        XCTAssertEqual(space.tabs.count, 3)
    }

    func testCloseMemberUndoRejoinsSplit() throws {
        let (store, space) = try makeStore()
        makeSplitFixture(store, space)
        let leftID = space.tabs[1].id
        let rightTab = space.tabs[2]

        store.closeTab(id: leftID, in: space)
        store.undoManager.undo()

        XCTAssertEqual(space.tabs.count, 4)
        let restored = space.tabs[1]
        XCTAssertNotEqual(restored.id, leftID)  // undo mints a fresh UUID
        XCTAssertNotNil(restored.splitGroupID)
        XCTAssertEqual(restored.splitGroupID, rightTab.splitGroupID)
        XCTAssertEqual(space.tabs[2].id, rightTab.id)  // restored to the left pane
    }

    // MARK: - pinTab

    func testPinningMemberDissolvesGroup() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)

        store.pinTab(id: tabs[1].id, in: space)

        XCTAssertNil(tabs[1].splitGroupID)
        XCTAssertNil(tabs[2].splitGroupID)
        XCTAssertEqual(space.pinnedEntries.count, 1)
    }

    // MARK: - setSplitFraction

    func testSetSplitFractionClampsAndAppliesToBothMembers() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makeSplitFixture(store, space)

        store.setSplitFraction(groupID: groupID, fraction: 0.05, in: space)
        XCTAssertEqual(tabs[1].splitFraction, 0.2)
        XCTAssertEqual(tabs[2].splitFraction, 0.2)

        store.setSplitFraction(groupID: groupID, fraction: 0.63, in: space)
        XCTAssertEqual(tabs[1].splitFraction, 0.63)
    }

    // MARK: - Sidebar diff with split items

    func testDiffTreatsSplitMergeAsRemoveAndInsert() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        let oldItems = tabListItems(from: space.tabs)

        store.createSplit(draggedTabID: tabs[0].id, targetTabID: tabs[2].id, edge: .right, in: space)
        let newItems = tabListItems(from: space.tabs)

        let diff = diffSidebarState(
            oldPinnedItems: [], newPinnedItems: [],
            oldTabs: oldItems, newTabs: newItems
        )
        XCTAssertTrue(diff.hasChanges)
        // tabs[0] and tabs[2] rows disappear; the new group row appears.
        XCTAssertEqual(diff.removedRows.count, 2)
        XCTAssertEqual(diff.insertedRows.count, 1)
    }
}
