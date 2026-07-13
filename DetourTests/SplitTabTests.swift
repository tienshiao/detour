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

    func testSanitizeClearsOversizedGroup() throws {
        let (_, space) = try makeStore()
        let tabs = (0..<4).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        let groupID = UUID()
        for tab in tabs.prefix(3) {  // 3 adjacent members: corrupted/legacy DB
            tab.splitGroupID = groupID
            tab.splitFraction = 0.5
        }

        sanitizeSplitGroups(space.tabs)

        for tab in tabs.prefix(3) {
            XCTAssertNil(tab.splitGroupID,
                         "a split is EXACTLY two members — a 3-member group must dissolve on load")
            XCTAssertNil(tab.splitFraction)
        }
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

    func testDeleteSpaceUndoPreservesPinnedSplit() throws {
        let (store, space) = try makeStore()
        let profileID = space.profileID
        let space2 = store.addSpace(name: "Two", emoji: "2️⃣", colorHex: "FF0000", profileID: profileID)
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space2.id) }
        space2.tabs.append(contentsOf: tabs)
        let groupID = UUID()
        for tab in [tabs[0], tabs[1]] { tab.splitGroupID = groupID; tab.splitFraction = 0.5 }

        // Pin the split so the group lives ONLY on the entries (design §12) — the
        // path that regressed: EntrySnapshot dropped the entry-level group.
        store.pinSplitGroup(groupID: groupID, in: space2)
        store.setSplitFraction(groupID: groupID, fraction: 0.65, in: space2)

        // All registrations in one runloop turn share an undo group; drop the
        // pin/add-space undos so undo() runs only deleteSpace's restore.
        store.undoManager.removeAllActions()
        store.deleteSpace(id: space2.id)
        store.undoManager.undo()

        let restored = try XCTUnwrap(store.space(withID: space2.id))
        let members = store.pinnedSplitEntries(groupID: groupID, in: restored)
        XCTAssertEqual(members.count, 2, "both pinned entries must keep the group after undo")
        XCTAssertEqual(members[0].splitGroupID, groupID)
        XCTAssertEqual(members[1].splitGroupID, groupID)
        XCTAssertEqual(members.first?.splitFraction, 0.65, "stored split fraction must survive undo")
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

    /// The Option-click fallback (background tab instead of split) relies on
    /// addTabInSplit returning nil for anchors that can't join a group.
    func testAddTabInSplitRejectsGroupedAnchor() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)

        let pane = store.addTabInSplit(with: tabs[1].id, url: URL(string: "https://example.com")!, in: space)

        XCTAssertNil(pane)
        XCTAssertEqual(space.tabs.count, 4)
    }

    func testAddTabInSplitRejectsPinnedAnchor() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)

        let pane = store.addTabInSplit(with: tab.id, url: URL(string: "https://example.com")!, in: space)

        XCTAssertNil(pane)
        XCTAssertTrue(space.tabs.isEmpty)
    }

    func testAddTabInSplitFocusTargetIsRightPane() throws {
        let (store, space) = try makeStore()
        let anchor = makeSleepingTab(spaceID: space.id)
        space.tabs.append(anchor)

        let pane = try XCTUnwrap(store.addTabInSplit(with: anchor.id, url: URL(string: "https://example.com")!, in: space))

        XCTAssertEqual(space.tabs.map(\.id), [anchor.id, pane.id],
                       "new pane opens on the right of its anchor")
        XCTAssertEqual(pane.parentID, anchor.id)
        XCTAssertEqual(pane.splitFraction, 0.5)
    }

    // MARK: - splitGroup drag kind

    func testSplitGroupDragReordersAndPins() {
        let folder = PinnedFolder(id: UUID(), name: "F", parentFolderID: nil, isCollapsed: false, sortOrder: 0)
        let items: [PinnedItem] = [.folder(folder, depth: 0)]

        // Pin-section targets accept: a split row pins as two entries.
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .pinnedItem(index: 0), operation: .above, items: items), .accept)
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .pinnedItem(index: 0), operation: .on, items: items), .accept)
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .topSpacer, operation: .above, items: items),
                       .retargetToPinnedGap(index: 0))
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .separator, operation: .above, items: items),
                       .retargetToPinnedGap(index: items.count))
        // Normal-section reorder accepted.
        XCTAssertEqual(validateSidebarDrop(kind: .splitGroup, sourceItemID: nil,
                                           row: .normalTab(index: 1), operation: .above, items: items), .accept)

        let groupID = UUID()
        let memberIDs = [UUID(), UUID()]
        XCTAssertEqual(
            resolveSidebarDrop(source: .splitGroup(index: 0, groupID: groupID, memberTabIDs: memberIDs),
                               destination: .beforeNormalTab(gapIndex: 2), items: items),
            .reorderNormalTab(tabID: memberIDs[0], fromIndex: 0, toGapIndex: 2)
        )
        XCTAssertNil(resolveSidebarDrop(source: .splitGroup(index: 0, groupID: groupID, memberTabIDs: memberIDs),
                                        destination: .beforeNormalTab(gapIndex: 0), items: items),
                     "adjacent own gap is a no-op")
        // Pinning keeps the group (§12), anchored at the drop position (folder at flat 0).
        XCTAssertEqual(
            resolveSidebarDrop(source: .splitGroup(index: 0, groupID: groupID, memberTabIDs: memberIDs),
                               destination: .beforePinnedItem(flatIndex: 0), items: items),
            .pinSplitGroup(groupID: groupID, firstMemberTabID: memberIDs[0], folderID: nil, beforeItemID: folder.id)
        )
        XCTAssertEqual(
            resolveSidebarDrop(source: .splitGroup(index: 0, groupID: groupID, memberTabIDs: memberIDs),
                               destination: .intoFolder(folderID: folder.id), items: items),
            .pinSplitGroup(groupID: groupID, firstMemberTabID: memberIDs[0], folderID: folder.id, beforeItemID: nil)
        )
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

    func testCreateSplitUndoRestoresOriginalOrderBothDirections() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)

        // Forward drag: A onto C's right edge, then undo.
        store.createSplit(draggedTabID: tabs[0].id, targetTabID: tabs[2].id, edge: .right, in: space)
        store.undoManager.undo()
        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
        XCTAssertNil(tabs[0].splitGroupID)
        XCTAssertNil(tabs[2].splitGroupID)

        // Backward drag: C onto A's left edge, then undo — the dragged tab now
        // sits BEFORE its original position, the case the pre-removal gap
        // conversion must shift by one.
        store.createSplit(draggedTabID: tabs[2].id, targetTabID: tabs[0].id, edge: .left, in: space)
        store.undoManager.undo()
        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
        XCTAssertNil(tabs[0].splitGroupID)
        XCTAssertNil(tabs[2].splitGroupID)
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

    func testRemoveTabFromSplitPreRemovalGapAfterSource() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)

        // Pre-removal gap 4 = end of [A, B, C, D] → C lands after D.
        store.removeTabFromSplit(tabID: tabs[2].id, toGapIndex: 4, in: space)

        XCTAssertEqual(space.tabs.map(\.id), [tabs[0].id, tabs[1].id, tabs[3].id, tabs[2].id])
        XCTAssertNil(tabs[1].splitGroupID)
        XCTAssertNil(tabs[2].splitGroupID)
    }

    func testRemoveTabFromSplitGapJustAfterGroupKeepsOrder() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makeSplitFixture(store, space)

        // Gap 3 = immediately after the group: order unchanged, group dissolved.
        store.removeTabFromSplit(tabID: tabs[2].id, toGapIndex: 3, in: space)

        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
        XCTAssertNil(tabs[1].splitGroupID)
        XCTAssertNil(tabs[2].splitGroupID)
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

    // MARK: - Pinned splits (§12)

    /// Pins the fixture's split and returns its (still valid) group ID.
    private func makePinnedSplitFixture(_ store: TabStore, _ space: Space) -> (tabs: [BrowserTab], groupID: UUID) {
        let (tabs, groupID) = makeSplitFixture(store, space)
        store.pinSplitGroup(groupID: groupID, in: space)
        return (tabs, groupID)
    }

    private func pinnedEntry(for tab: BrowserTab, in space: Space) -> PinnedEntry? {
        space.pinnedEntries.first { $0.tab?.id == tab.id }
    }

    func testPinSplitGroupPreservesGroupOnEntries() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makeSplitFixture(store, space)
        store.setSplitFraction(groupID: groupID, fraction: 0.3, in: space)

        store.pinSplitGroup(groupID: groupID, in: space)

        // Both members left the tab list, in one piece.
        XCTAssertEqual(space.tabs.map(\.id), [tabs[0].id, tabs[3].id])
        XCTAssertEqual(space.pinnedEntries.count, 2)

        // The group now lives on the entries — left pane first — and the
        // backing tabs' groupIDs are cleared (space.tabs invariants never see
        // pinned groups).
        let members = store.pinnedSplitEntries(groupID: groupID, in: space)
        XCTAssertEqual(members.map { $0.tab?.id }, [tabs[1].id, tabs[2].id])
        XCTAssertEqual(members.map(\.splitFraction), [0.3, 0.3])
        XCTAssertNil(tabs[1].splitGroupID)
        XCTAssertNil(tabs[2].splitGroupID)

        // splitGroup(containing:) resolves the pinned group for hosting.
        let group = store.splitGroup(containing: tabs[2].id, in: space)
        XCTAssertEqual(group?.groupID, groupID)
        XCTAssertEqual(group?.members.map(\.id), [tabs[1].id, tabs[2].id])
        XCTAssertEqual(store.splitFraction(containing: tabs[2].id, in: space), 0.3)
    }

    func testPinSplitGroupUndoRestoresNormalSplit() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makeSplitFixture(store, space)
        store.undoManager.removeAllActions()

        store.pinSplitGroup(groupID: groupID, in: space)
        store.undoManager.undo()

        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
        XCTAssertTrue(space.pinnedEntries.isEmpty)
        XCTAssertEqual(tabs[1].splitGroupID, groupID)
        XCTAssertEqual(tabs[2].splitGroupID, groupID)
    }

    func testUnpinSplitGroupRestoresSplitAtGap() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)  // tabs now [A, D]

        store.unpinSplitGroup(groupID: groupID, toGapIndex: 1, in: space)

        XCTAssertTrue(space.pinnedEntries.isEmpty)
        XCTAssertEqual(space.tabs.map(\.id), [tabs[0].id, tabs[1].id, tabs[2].id, tabs[3].id])
        XCTAssertEqual(tabs[1].splitGroupID, groupID)
        XCTAssertEqual(tabs[2].splitGroupID, groupID)
        XCTAssertEqual(tabs[1].splitFraction, 0.5)
    }

    func testUnpinSplitGroupMaterializesDormantMember() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)
        let leftEntry = try XCTUnwrap(pinnedEntry(for: tabs[1], in: space))
        store.closePinnedTab(id: leftEntry.id, in: space)  // left pane dormant
        XCTAssertNil(leftEntry.tab)
        XCTAssertEqual(leftEntry.splitGroupID, groupID, "dormancy must not dissolve the pinned split")

        store.unpinSplitGroup(groupID: groupID, toGapIndex: 0, in: space)

        XCTAssertEqual(space.tabs.count, 4)
        let restored = space.tabs[0]
        XCTAssertNotEqual(restored.id, tabs[1].id, "dormant member materializes a fresh tab")
        XCTAssertEqual(restored.splitGroupID, groupID)
        XCTAssertEqual(space.tabs[1].id, tabs[2].id)
        XCTAssertEqual(space.tabs[1].splitGroupID, groupID)
    }

    func testUnpinSplitGroupUndoRepins() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)
        store.undoManager.removeAllActions()

        store.unpinSplitGroup(groupID: groupID, toGapIndex: 0, in: space)
        store.undoManager.undo()

        XCTAssertEqual(space.tabs.map(\.id), [tabs[0].id, tabs[3].id])
        let members = store.pinnedSplitEntries(groupID: groupID, in: space)
        XCTAssertEqual(members.compactMap { $0.tab?.id }, [tabs[1].id, tabs[2].id])
    }

    func testUnpinSplitGroupUndoSurvivesSortOrderCollision() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)  // entry orders (0, 1)
        store.undoManager.removeAllActions()

        store.unpinSplitGroup(groupID: groupID, toGapIndex: 0, in: space)
        // A later, non-undoable mutation whose sortOrder collides with the
        // pair's saved right-member order — per-level renumbering makes such
        // collisions routine (e.g. pinURL assigns from a global max).
        let interloper = PinnedEntry(pinnedURL: URL(string: "https://x.example")!,
                                     pinnedTitle: "X", sortOrder: 1)
        space.pinnedEntries.append(interloper)

        store.undoManager.undo()

        // The pair must come back grouped AND adjacent — a raw sortOrder
        // restore would tie with the interloper, interleave it between the
        // members, and the sanitizer would dissolve the restored group.
        let members = store.pinnedSplitEntries(groupID: groupID, in: space)
        XCTAssertEqual(members.compactMap { $0.tab?.id }, [tabs[1].id, tabs[2].id])
        let items = flattenPinnedTree(entries: space.pinnedEntries, folders: space.pinnedFolders,
                                      collapsedFolderIDs: [], selectedTabID: nil)
        XCTAssertTrue(items.contains { if case .split(groupID, _, _) = $0 { return true } else { return false } },
                      "restored pair must render as one split row")
    }

    func testDeletePinnedFolderKeepsSplitPairAdjacent() throws {
        let (store, space) = try makeStore()
        let (_, groupID) = makePinnedSplitFixture(store, space)  // pair at orders (0, 1)
        // Folder with one child whose per-level sortOrder (0) collides with the
        // pair's top-level numbering once reparented.
        let folder = store.addPinnedFolder(name: "F", in: space)
        store.pinURL(URL(string: "https://child.example")!, title: "Child", faviconURL: nil, in: space)
        let child = try XCTUnwrap(space.pinnedEntries.first { $0.pinnedTitle == "Child" })
        store.movePinnedTabToFolder(tabID: child.id, folderID: folder.id, in: space)
        XCTAssertEqual(child.sortOrder, 0, "folder levels renumber from 0 — the collision is real")

        store.deletePinnedFolder(id: folder.id, in: space)

        // The reparented child must not interleave into the pair.
        XCTAssertEqual(store.pinnedSplitEntries(groupID: groupID, in: space).count, 2)
        let items = flattenPinnedTree(entries: space.pinnedEntries, folders: space.pinnedFolders,
                                      collapsedFolderIDs: [], selectedTabID: nil)
        XCTAssertTrue(items.contains { if case .split(groupID, _, _) = $0 { return true } else { return false } },
                      "pair must still render as one split row after the folder delete")
        XCTAssertNil(child.folderID, "child reparents to the deleted folder's level")
    }

    func testUnpinSingleMemberDissolvesPinnedSplitAndUndoRejoins() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)
        let rightEntry = try XCTUnwrap(pinnedEntry(for: tabs[2], in: space))
        let leftEntry = try XCTUnwrap(pinnedEntry(for: tabs[1], in: space))
        store.undoManager.removeAllActions()

        store.unpinTab(id: rightEntry.id, in: space, at: 0)

        XCTAssertEqual(space.tabs.first?.id, tabs[2].id)
        XCTAssertNil(tabs[2].splitGroupID, "unpinned member returns as a lone tab")
        XCTAssertNil(leftEntry.splitGroupID, "partner's pinned split dissolves")

        store.undoManager.undo()

        XCTAssertEqual(store.pinnedSplitEntries(groupID: groupID, in: space).count, 2,
                       "undo re-pins the member and rejoins the pinned split")
    }

    func testDeletePinnedSplitMemberDissolvesAndUndoRejoins() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)
        let leftEntry = try XCTUnwrap(pinnedEntry(for: tabs[1], in: space))
        let rightEntry = try XCTUnwrap(pinnedEntry(for: tabs[2], in: space))
        store.undoManager.removeAllActions()

        store.deletePinnedEntry(id: leftEntry.id, in: space)

        XCTAssertEqual(space.pinnedEntries.count, 1)
        XCTAssertNil(rightEntry.splitGroupID)

        store.undoManager.undo()

        XCTAssertEqual(store.pinnedSplitEntries(groupID: groupID, in: space).count, 2)
    }

    func testDetachPinnedSplitMemberDissolves() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makePinnedSplitFixture(store, space)
        let leftEntry = try XCTUnwrap(pinnedEntry(for: tabs[1], in: space))
        let rightEntry = try XCTUnwrap(pinnedEntry(for: tabs[2], in: space))

        let detached = store.detachPinnedEntry(id: leftEntry.id, from: space)

        XCTAssertEqual(detached?.id, tabs[1].id)
        XCTAssertNil(rightEntry.splitGroupID)
        XCTAssertNil(rightEntry.splitFraction)
    }

    func testMovePinnedSplitMovesPairAsBlock() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)
        let folder = store.addPinnedFolder(name: "F", in: space)
        let leftEntry = try XCTUnwrap(pinnedEntry(for: tabs[1], in: space))

        store.movePinnedTabToFolder(tabID: leftEntry.id, folderID: folder.id, in: space)

        let members = store.pinnedSplitEntries(groupID: groupID, in: space)
        XCTAssertEqual(members.map(\.folderID), [folder.id, folder.id])
        XCTAssertEqual(members.compactMap { $0.tab?.id }, [tabs[1].id, tabs[2].id],
                       "visual order survives the block move")
        XCTAssertEqual(members[1].sortOrder, members[0].sortOrder + 1)
    }

    func testMovePinnedAnchorSnapsOutOfGroupInterior() throws {
        let (store, space) = try makeStore()
        let (tabs, _) = makePinnedSplitFixture(store, space)
        let rightEntry = try XCTUnwrap(pinnedEntry(for: tabs[2], in: space))
        // A third, ungrouped pinned entry to move around.
        let lone = makeSleepingTab(spaceID: space.id)
        space.tabs.append(lone)
        store.pinTab(id: lone.id, in: space)
        let loneEntry = try XCTUnwrap(pinnedEntry(for: lone, in: space))

        // Anchoring before the RIGHT member would land inside the group — the
        // store must retarget to the left member (before the whole group).
        store.movePinnedTabToFolder(tabID: loneEntry.id, folderID: nil, beforeItemID: rightEntry.id, in: space)

        let ordered = space.pinnedEntries.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(ordered.map { $0.tab?.id }, [lone.id, tabs[1].id, tabs[2].id])
    }

    func testSeparatePinnedSplitAndUndo() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)
        let leftEntry = try XCTUnwrap(pinnedEntry(for: tabs[1], in: space))
        let rightEntry = try XCTUnwrap(pinnedEntry(for: tabs[2], in: space))
        store.undoManager.removeAllActions()

        store.separatePinnedSplit(groupID: groupID, in: space)

        XCTAssertNil(leftEntry.splitGroupID)
        XCTAssertNil(rightEntry.splitGroupID)
        XCTAssertEqual(space.pinnedEntries.count, 2, "entries stay as two pinned rows")

        store.undoManager.undo()

        XCTAssertNotNil(leftEntry.splitGroupID)
        XCTAssertEqual(leftEntry.splitGroupID, rightEntry.splitGroupID)
    }

    func testRemovePinnedEntryFromSplitBreaksOutAndUndoRestores() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)
        let leftEntry = try XCTUnwrap(pinnedEntry(for: tabs[1], in: space))
        let rightEntry = try XCTUnwrap(pinnedEntry(for: tabs[2], in: space))
        store.undoManager.removeAllActions()

        // Break the RIGHT member out to the front of the pinned section.
        store.removePinnedEntryFromSplit(entryID: rightEntry.id, folderID: nil,
                                         beforeItemID: leftEntry.id, in: space)

        XCTAssertNil(leftEntry.splitGroupID)
        XCTAssertNil(rightEntry.splitGroupID)
        let ordered = space.pinnedEntries.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(ordered.map { $0.tab?.id }, [tabs[2].id, tabs[1].id])

        store.undoManager.undo()

        let members = store.pinnedSplitEntries(groupID: groupID, in: space)
        XCTAssertEqual(members.compactMap { $0.tab?.id }, [tabs[1].id, tabs[2].id])
    }

    func testSetSplitFractionRoutesToPinnedEntries() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)

        store.setSplitFraction(groupID: groupID, fraction: 0.7, in: space)

        let members = store.pinnedSplitEntries(groupID: groupID, in: space)
        XCTAssertEqual(members.map(\.splitFraction), [0.7, 0.7])
        XCTAssertEqual(store.splitFraction(containing: tabs[1].id, in: space), 0.7)
    }

    func testSplitGroupContainingOmitsDormantPinnedMember() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)
        let leftEntry = try XCTUnwrap(pinnedEntry(for: tabs[1], in: space))

        store.closePinnedTab(id: leftEntry.id, in: space)

        let group = try XCTUnwrap(store.splitGroup(containing: tabs[2].id, in: space))
        XCTAssertEqual(group.groupID, groupID)
        XCTAssertEqual(group.members.map(\.id), [tabs[2].id],
                       "a dormant partner is absent until selection wakes it")
    }

    func testFlattenPinnedTreeGroupsAdjacentSplitEntries() throws {
        let (store, space) = try makeStore()
        let (_, groupID) = makePinnedSplitFixture(store, space)
        // A trailing lone entry after the split pair.
        let lone = makeSleepingTab(spaceID: space.id)
        space.tabs.append(lone)
        store.pinTab(id: lone.id, in: space)

        let items = flattenPinnedTree(entries: space.pinnedEntries, folders: [],
                                      collapsedFolderIDs: [], selectedTabID: nil)

        XCTAssertEqual(items.count, 2)
        guard case .split(let gid, let entries, let depth) = items[0] else {
            return XCTFail("expected split item, got \(items[0])")
        }
        XCTAssertEqual(gid, groupID)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(depth, 0)
        XCTAssertEqual(pinnedItemID(items[0]), groupID, "diff identity is the groupID")
        // Drop anchors resolve to the FIRST member so nothing lands inside.
        XCTAssertEqual(itemIDAtDropIndex(0, in: items), entries[0].id)
    }

    func testFlattenPinnedTreeRendersSingletonGroupAsEntry() throws {
        let (store, space) = try makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)
        space.pinnedEntries[0].splitGroupID = UUID()

        let items = flattenPinnedTree(entries: space.pinnedEntries, folders: [],
                                      collapsedFolderIDs: [], selectedTabID: nil)

        guard case .entry = items[0] else {
            return XCTFail("singleton group must degrade to a plain entry row")
        }
    }

    func testCollapsedFolderExposesSelectedSplitMemberAsSplitItem() throws {
        let (store, space) = try makeStore()
        let (tabs, groupID) = makePinnedSplitFixture(store, space)
        let folder = store.addPinnedFolder(name: "F", in: space)
        let leftEntry = try XCTUnwrap(pinnedEntry(for: tabs[1], in: space))
        store.movePinnedTabToFolder(tabID: leftEntry.id, folderID: folder.id, in: space)  // pair moves as a block

        let items = flattenPinnedTree(entries: space.pinnedEntries, folders: space.pinnedFolders,
                                      collapsedFolderIDs: [folder.id], selectedTabID: tabs[1].id)

        // Folder row + the exposed split row, and nothing else (no duplicate
        // member rows).
        XCTAssertEqual(items.count, 2)
        guard case .folder(let f, _) = items[0], f.id == folder.id else {
            return XCTFail("expected the collapsed folder row first, got \(items[0])")
        }
        guard case .split(let gid, let exposed, let depth) = items[1] else {
            return XCTFail("a selected split member in a collapsed folder must expose the whole group, got \(items[1])")
        }
        XCTAssertEqual(gid, groupID)
        XCTAssertEqual(exposed.compactMap { $0.tab?.id }, [tabs[1].id, tabs[2].id],
                       "both members, left pane first — same item the expanded path produces")
        XCTAssertEqual(depth, 1)
    }

    func testCollapsedFolderExposureFallsBackToEntryWithoutValidPartner() throws {
        let (store, space) = try makeStore()
        let folder = store.addPinnedFolder(name: "F", in: space)
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)
        let entry = try XCTUnwrap(pinnedEntry(for: tab, in: space))
        store.movePinnedTabToFolder(tabID: entry.id, folderID: folder.id, in: space)
        entry.splitGroupID = UUID()  // corrupt: no partner at this sibling level

        let items = flattenPinnedTree(entries: space.pinnedEntries, folders: space.pinnedFolders,
                                      collapsedFolderIDs: [folder.id], selectedTabID: tab.id)

        XCTAssertEqual(items.count, 2)
        guard case .entry(let exposed, let depth) = items[1] else {
            return XCTFail("a partnerless group must fall back to the single-entry exposure, got \(items[1])")
        }
        XCTAssertEqual(exposed.id, entry.id)
        XCTAssertEqual(depth, 1)
    }

    func testSanitizePinnedSplitGroups() throws {
        let (store, space) = try makeStore()

        func makeEntry(sortOrder: Int, folderID: UUID? = nil) -> PinnedEntry {
            let entry = PinnedEntry(id: UUID(), pinnedURL: URL(string: "https://example.com")!,
                                    pinnedTitle: "E", folderID: folderID, sortOrder: sortOrder)
            space.pinnedEntries.append(entry)
            return entry
        }

        // Valid adjacent pair.
        let valid = UUID()
        let v1 = makeEntry(sortOrder: 0); v1.splitGroupID = valid
        let v2 = makeEntry(sortOrder: 1); v2.splitGroupID = valid
        // Pair torn apart by a folder sorting between the members.
        let torn = UUID()
        let t1 = makeEntry(sortOrder: 2); t1.splitGroupID = torn
        let folder = PinnedFolder(id: UUID(), name: "F", parentFolderID: nil, isCollapsed: false, sortOrder: 3)
        space.pinnedFolders.append(folder)
        let t2 = makeEntry(sortOrder: 4); t2.splitGroupID = torn
        // Pair split across folders.
        let cross = UUID()
        let c1 = makeEntry(sortOrder: 5); c1.splitGroupID = cross
        let c2 = makeEntry(sortOrder: 0, folderID: folder.id); c2.splitGroupID = cross
        // Singleton.
        let lone = makeEntry(sortOrder: 6); lone.splitGroupID = UUID(); lone.splitFraction = 0.4
        // Three adjacent members (corrupted/legacy DB) — a split is EXACTLY two.
        let oversized = UUID()
        let o1 = makeEntry(sortOrder: 7); o1.splitGroupID = oversized
        let o2 = makeEntry(sortOrder: 8); o2.splitGroupID = oversized
        let o3 = makeEntry(sortOrder: 9); o3.splitGroupID = oversized

        sanitizePinnedSplitGroups(entries: space.pinnedEntries, folders: space.pinnedFolders)

        XCTAssertEqual(v1.splitGroupID, valid)
        XCTAssertEqual(v2.splitGroupID, valid)
        XCTAssertNil(t1.splitGroupID)
        XCTAssertNil(t2.splitGroupID)
        XCTAssertNil(c1.splitGroupID)
        XCTAssertNil(c2.splitGroupID)
        XCTAssertNil(lone.splitGroupID)
        XCTAssertNil(lone.splitFraction)
        XCTAssertNil(o1.splitGroupID)
        XCTAssertNil(o2.splitGroupID)
        XCTAssertNil(o3.splitGroupID)
    }

    func testPinnedSplitPersistsAcrossSaveLoad() throws {
        let dbQueue = try DatabaseQueue()
        let db = try AppDatabase(dbQueue: dbQueue)
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Test")
        let space = store.addSpace(name: "Test", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        let (tabs, groupID) = makeSplitFixture(store, space)
        store.pinSplitGroup(groupID: groupID, in: space)
        store.setSplitFraction(groupID: groupID, fraction: 0.65, in: space)
        let expectedTabIDs = [tabs[1].id, tabs[2].id]

        store.saveNow()
        let reloaded = TabStore(appDB: db)
        _ = reloaded.restoreSession()

        let loadedSpace = try XCTUnwrap(reloaded.space(withID: space.id))
        let members = reloaded.pinnedSplitEntries(groupID: groupID, in: loadedSpace)
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members.compactMap { $0.tab?.id }, expectedTabIDs)
        XCTAssertEqual(members.first?.splitFraction, 0.65)
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
