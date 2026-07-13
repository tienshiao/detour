import XCTest
@testable import Detour

final class SidebarDragDropTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEntry(id: UUID = UUID(), title: String = "Entry", folderID: UUID? = nil, sortOrder: Int = 0) -> PinnedEntry {
        PinnedEntry(id: id, pinnedURL: URL(string: "https://example.com")!, pinnedTitle: title, folderID: folderID, sortOrder: sortOrder)
    }

    private func makeFolder(id: UUID = UUID(), name: String = "Folder", parentID: UUID? = nil, isCollapsed: Bool = false, sortOrder: Int = 0) -> PinnedFolder {
        PinnedFolder(id: id, name: name, parentFolderID: parentID, isCollapsed: isCollapsed, sortOrder: sortOrder)
    }

    private func flatItems(_ entries: [PinnedEntry] = [], folders: [PinnedFolder] = [],
                           collapsed: Set<UUID> = []) -> [PinnedItem] {
        flattenPinnedTree(entries: entries, folders: folders, collapsedFolderIDs: collapsed, selectedTabID: nil)
    }

    /// folderA(0) > entryInA(1), entryTop(2) — a folder with one child, then a top-level entry.
    private func standardTree() -> (items: [PinnedItem], folderA: PinnedFolder, entryInA: PinnedEntry, entryTop: PinnedEntry) {
        let folderA = makeFolder(name: "A", sortOrder: 0)
        let entryInA = makeEntry(title: "inA", folderID: folderA.id, sortOrder: 0)
        let entryTop = makeEntry(title: "top", sortOrder: 1)
        let items = flatItems([entryInA, entryTop], folders: [folderA])
        return (items, folderA, entryInA, entryTop)
    }

    // MARK: - Payload round-trip

    func testDragPayloadRoundTrip() {
        let payload = SidebarDragPayload(kind: .pinnedEntry, itemID: UUID(), spaceID: UUID(), sidebarID: UUID())
        let string = payload.pasteboardString
        XCTAssertNotNil(string)
        XCTAssertEqual(SidebarDragPayload(pasteboardString: string!), payload)
    }

    func testFavoritePayloadRoundTrip() {
        let payload = FavoriteDragPayload(favoriteID: UUID(), sidebarID: UUID())
        let string = payload.pasteboardString
        XCTAssertNotNil(string)
        XCTAssertEqual(FavoriteDragPayload(pasteboardString: string!), payload)
    }

    func testDragPayloadRejectsGarbage() {
        XCTAssertNil(SidebarDragPayload(pasteboardString: "3"))
        XCTAssertNil(SidebarDragPayload(pasteboardString: ""))
        XCTAssertNil(FavoriteDragPayload(pasteboardString: "{\"nope\":true}"))
    }

    func testSplitMemberPayloadRoundTrip() {
        let payload = SidebarDragPayload(kind: .splitMember, itemID: UUID(), spaceID: UUID(), sidebarID: UUID())
        let string = payload.pasteboardString
        XCTAssertNotNil(string)
        XCTAssertEqual(SidebarDragPayload(pasteboardString: string!), payload)
    }

    // MARK: - validateSidebarDrop

    func testValidateOnDropOntoFolderAccepted() {
        let (items, folderA, _, _) = standardTree()
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: UUID(),
                                           row: .pinnedItem(index: 0), operation: .on, items: items),
                       .accept)
        XCTAssertEqual(validateSidebarDrop(kind: .favorite, sourceItemID: UUID(),
                                           row: .pinnedItem(index: 0), operation: .on, items: items),
                       .accept)
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedFolder, sourceItemID: folderA.id,
                                           row: .pinnedItem(index: 0), operation: .on, items: items),
                       .reject, "folder onto itself")
    }

    func testValidateOnDropOntoNonFolderRejected() {
        let (items, _, _, _) = standardTree()
        // index 1 = entryInA, index 2 = entryTop
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: UUID(),
                                           row: .pinnedItem(index: 1), operation: .on, items: items),
                       .reject)
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: UUID(),
                                           row: .normalTab(index: 0), operation: .on, items: items),
                       .reject)
    }

    func testValidateAboveRetargetsChromeRows() {
        let (items, _, _, _) = standardTree()
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: UUID(),
                                           row: .topSpacer, operation: .above, items: items),
                       .retargetToPinnedGap(index: 0))
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: UUID(),
                                           row: .separator, operation: .above, items: items),
                       .retargetToPinnedGap(index: items.count))
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: UUID(),
                                           row: .newTab, operation: .above, items: items),
                       .retargetToNormalTabGap(index: 0))
    }

    func testValidateFolderCannotEnterNormalSection() {
        let (items, folderA, _, _) = standardTree()
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedFolder, sourceItemID: folderA.id,
                                           row: .newTab, operation: .above, items: items),
                       .reject)
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedFolder, sourceItemID: folderA.id,
                                           row: .normalTab(index: 0), operation: .above, items: items),
                       .reject)
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedFolder, sourceItemID: folderA.id,
                                           row: .separator, operation: .above, items: items),
                       .retargetToPinnedGap(index: items.count))
    }

    // MARK: - sidebarDropDestination

    func testDestinationNormalization() {
        let (items, folderA, _, _) = standardTree()
        XCTAssertEqual(sidebarDropDestination(row: .topSpacer, operation: .above, items: items),
                       .beforePinnedItem(flatIndex: 0))
        XCTAssertEqual(sidebarDropDestination(row: .separator, operation: .above, items: items),
                       .beforePinnedItem(flatIndex: items.count))
        XCTAssertEqual(sidebarDropDestination(row: .newTab, operation: .above, items: items),
                       .beforeNormalTab(gapIndex: 0))
        XCTAssertEqual(sidebarDropDestination(row: .normalTab(index: 3), operation: .above, items: items),
                       .beforeNormalTab(gapIndex: 3))
        XCTAssertEqual(sidebarDropDestination(row: .pinnedItem(index: 1), operation: .above, items: items),
                       .beforePinnedItem(flatIndex: 1))
        XCTAssertEqual(sidebarDropDestination(row: .pinnedItem(index: 0), operation: .on, items: items),
                       .intoFolder(folderID: folderA.id))
        XCTAssertNil(sidebarDropDestination(row: .pinnedItem(index: 1), operation: .on, items: items),
                     ".on a non-folder row is not a destination")
    }

    // MARK: - resolveSidebarDrop: normal tab reorder

    func testReorderNoOpGaps() {
        let tabID = UUID()
        let items: [PinnedItem] = []
        // Gap at own position and gap just after are both no-ops
        XCTAssertNil(resolveSidebarDrop(source: .normalTab(index: 2, tabID: tabID),
                                        destination: .beforeNormalTab(gapIndex: 2), items: items))
        XCTAssertNil(resolveSidebarDrop(source: .normalTab(index: 2, tabID: tabID),
                                        destination: .beforeNormalTab(gapIndex: 3), items: items))
    }

    func testReorderForwardAndBackward() {
        let tabID = UUID()
        let items: [PinnedItem] = []
        XCTAssertEqual(resolveSidebarDrop(source: .normalTab(index: 0, tabID: tabID),
                                          destination: .beforeNormalTab(gapIndex: 4), items: items),
                       .reorderNormalTab(tabID: tabID, fromIndex: 0, toGapIndex: 4))
        XCTAssertEqual(resolveSidebarDrop(source: .normalTab(index: 4, tabID: tabID),
                                          destination: .beforeNormalTab(gapIndex: 0), items: items),
                       .reorderNormalTab(tabID: tabID, fromIndex: 4, toGapIndex: 0))
    }

    // MARK: - resolveSidebarDrop: pinning

    func testPinTabInheritsFolderFromDropPosition() {
        let (items, folderA, entryInA, _) = standardTree()
        let tabID = UUID()
        // Dropping above the entry inside folderA joins folderA, anchored before that entry
        XCTAssertEqual(resolveSidebarDrop(source: .normalTab(index: 0, tabID: tabID),
                                          destination: .beforePinnedItem(flatIndex: 1), items: items),
                       .pinTab(tabID: tabID, folderID: folderA.id, beforeItemID: entryInA.id))
    }

    func testPinTabAtTopLevelAndEnd() {
        let (items, folderA, _, _) = standardTree()
        let tabID = UUID()
        // Above the folder itself → top level, before the folder
        XCTAssertEqual(resolveSidebarDrop(source: .normalTab(index: 0, tabID: tabID),
                                          destination: .beforePinnedItem(flatIndex: 0), items: items),
                       .pinTab(tabID: tabID, folderID: nil, beforeItemID: folderA.id))
        // Past the end → top level, appended
        XCTAssertEqual(resolveSidebarDrop(source: .normalTab(index: 0, tabID: tabID),
                                          destination: .beforePinnedItem(flatIndex: items.count), items: items),
                       .pinTab(tabID: tabID, folderID: nil, beforeItemID: nil))
    }

    func testPinTabIntoFolder() {
        let (items, folderA, _, _) = standardTree()
        let tabID = UUID()
        XCTAssertEqual(resolveSidebarDrop(source: .normalTab(index: 0, tabID: tabID),
                                          destination: .intoFolder(folderID: folderA.id), items: items),
                       .pinTab(tabID: tabID, folderID: folderA.id, beforeItemID: nil))
    }

    // MARK: - resolveSidebarDrop: pinned entry moves

    func testMovePinnedEntryOntoOwnPositionIsNoOp() {
        // Regression: the store excludes the moved item from its sibling scan, so
        // anchoring an item to itself would send it to the end of its level.
        let (items, _, entryInA, _) = standardTree()
        XCTAssertNil(resolveSidebarDrop(source: .pinnedEntry(entryID: entryInA.id),
                                        destination: .beforePinnedItem(flatIndex: 1), items: items))
    }

    func testMovePinnedEntryBetweenLevels() {
        let (items, folderA, entryInA, entryTop) = standardTree()
        // Move top-level entry above the entry inside folderA → joins the folder
        XCTAssertEqual(resolveSidebarDrop(source: .pinnedEntry(entryID: entryTop.id),
                                          destination: .beforePinnedItem(flatIndex: 1), items: items),
                       .movePinnedEntry(entryID: entryTop.id, folderID: folderA.id, beforeItemID: entryInA.id))
        // Move nested entry to end of pinned section → leaves the folder
        XCTAssertEqual(resolveSidebarDrop(source: .pinnedEntry(entryID: entryInA.id),
                                          destination: .beforePinnedItem(flatIndex: items.count), items: items),
                       .movePinnedEntry(entryID: entryInA.id, folderID: nil, beforeItemID: nil))
    }

    func testUnpinEntryToNormalSection() {
        let (items, _, _, entryTop) = standardTree()
        XCTAssertEqual(resolveSidebarDrop(source: .pinnedEntry(entryID: entryTop.id),
                                          destination: .beforeNormalTab(gapIndex: 2), items: items),
                       .unpinEntry(entryID: entryTop.id, toGapIndex: 2))
    }

    // MARK: - resolveSidebarDrop: folder moves

    func testMoveFolderRejectsCycles() {
        // outer(0) > inner(1) > entryInInner(2)
        let outer = makeFolder(name: "outer", sortOrder: 0)
        let inner = makeFolder(name: "inner", parentID: outer.id, sortOrder: 0)
        let entryInInner = makeEntry(folderID: inner.id, sortOrder: 0)
        let items = flatItems([entryInInner], folders: [outer, inner])

        // outer into itself
        XCTAssertNil(resolveSidebarDrop(source: .pinnedFolder(folderID: outer.id),
                                        destination: .intoFolder(folderID: outer.id), items: items))
        // outer into its descendant
        XCTAssertNil(resolveSidebarDrop(source: .pinnedFolder(folderID: outer.id),
                                        destination: .intoFolder(folderID: inner.id), items: items))
        // outer above the entry inside its own descendant (parent would be inner)
        XCTAssertNil(resolveSidebarDrop(source: .pinnedFolder(folderID: outer.id),
                                        destination: .beforePinnedItem(flatIndex: 2), items: items))
        // inner out to top level is fine
        XCTAssertEqual(resolveSidebarDrop(source: .pinnedFolder(folderID: inner.id),
                                          destination: .beforePinnedItem(flatIndex: items.count), items: items),
                       .movePinnedFolder(folderID: inner.id, parentFolderID: nil, beforeItemID: nil))
    }

    func testMoveFolderOntoOwnPositionIsNoOp() {
        let (items, folderA, _, _) = standardTree()
        XCTAssertNil(resolveSidebarDrop(source: .pinnedFolder(folderID: folderA.id),
                                        destination: .beforePinnedItem(flatIndex: 0), items: items))
    }

    func testMoveFolderCannotDropInNormalSection() {
        let (items, folderA, _, _) = standardTree()
        XCTAssertNil(resolveSidebarDrop(source: .pinnedFolder(folderID: folderA.id),
                                        destination: .beforeNormalTab(gapIndex: 0), items: items))
    }

    func testMoveFolderIntoSiblingFolder() {
        let folderA = makeFolder(name: "A", sortOrder: 0)
        let folderB = makeFolder(name: "B", sortOrder: 1)
        let items = flatItems([], folders: [folderA, folderB])
        XCTAssertEqual(resolveSidebarDrop(source: .pinnedFolder(folderID: folderB.id),
                                          destination: .intoFolder(folderID: folderA.id), items: items),
                       .movePinnedFolder(folderID: folderB.id, parentFolderID: folderA.id, beforeItemID: nil))
    }

    // MARK: - Split fixtures

    private func makeTab() -> BrowserTab {
        BrowserTab(id: UUID(), title: "Tab", url: URL(string: "https://example.com"),
                   faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
    }

    /// Tabs 0–3 where 1+2 form a split → items [single(0), split(1,2), single(3)].
    private func splitTabItems() -> (items: [TabListItem], tabs: [BrowserTab], groupID: UUID) {
        let tabs = (0..<4).map { _ in makeTab() }
        let groupID = UUID()
        tabs[1].splitGroupID = groupID
        tabs[2].splitGroupID = groupID
        return (tabListItems(from: tabs), tabs, groupID)
    }

    // MARK: - Drop geometry

    func testRowDropZoneEdgesAndMiddleBand() {
        let size = CGSize(width: 100, height: 36)
        XCTAssertEqual(rowDropZone(forX: 10, y: 18, rowSize: size), .splitEdge(.left))
        XCTAssertEqual(rowDropZone(forX: 39, y: 18, rowSize: size), .splitEdge(.left))
        XCTAssertEqual(rowDropZone(forX: 61, y: 18, rowSize: size), .splitEdge(.right))
        XCTAssertEqual(rowDropZone(forX: 90, y: 18, rowSize: size), .splitEdge(.right))
        // Middle band → nearest reorder gap by vertical half (flipped coords: y from row top)
        XCTAssertEqual(rowDropZone(forX: 50, y: 10, rowSize: size), .reorderGap(offset: 0))
        XCTAssertEqual(rowDropZone(forX: 50, y: 30, rowSize: size), .reorderGap(offset: 1))
        // Degenerate row falls back to reorder rather than a phantom edge
        XCTAssertEqual(rowDropZone(forX: 0, y: 0, rowSize: .zero), .reorderGap(offset: 0))
    }

    func testSplitRowDragKindGrabZones() {
        // Each half's leading 34pt (the favicon segment) grabs that member.
        XCTAssertEqual(splitRowDragKind(forX: 0, rowWidth: 200), .member(.left))
        XCTAssertEqual(splitRowDragKind(forX: 33, rowWidth: 200), .member(.left))
        XCTAssertEqual(splitRowDragKind(forX: 34, rowWidth: 200), .group)
        XCTAssertEqual(splitRowDragKind(forX: 99, rowWidth: 200), .group)
        XCTAssertEqual(splitRowDragKind(forX: 100, rowWidth: 200), .member(.right))
        XCTAssertEqual(splitRowDragKind(forX: 133, rowWidth: 200), .member(.right))
        XCTAssertEqual(splitRowDragKind(forX: 134, rowWidth: 200), .group)
        XCTAssertEqual(splitRowDragKind(forX: 199, rowWidth: 200), .group)
        // Out-of-row points (drag begun outside the row rect) fall back to group
        XCTAssertEqual(splitRowDragKind(forX: -5, rowWidth: 200), .group)
        XCTAssertEqual(splitRowDragKind(forX: 205, rowWidth: 200), .group)
    }

    func testSplitRowDragKindIndentedRow() {
        // A pinned split row at folder depth 1 is indented 16pt: the left
        // grab band follows the favicon; the indent gutter drags the group.
        XCTAssertEqual(splitRowDragKind(forX: 8, rowWidth: 200, indent: 16), .group)
        XCTAssertEqual(splitRowDragKind(forX: 15, rowWidth: 200, indent: 16), .group)
        XCTAssertEqual(splitRowDragKind(forX: 16, rowWidth: 200, indent: 16), .member(.left))
        XCTAssertEqual(splitRowDragKind(forX: 49, rowWidth: 200, indent: 16), .member(.left))
        XCTAssertEqual(splitRowDragKind(forX: 50, rowWidth: 200, indent: 16), .group)
        // The right band is centered in the row and ignores indentation.
        XCTAssertEqual(splitRowDragKind(forX: 100, rowWidth: 200, indent: 16), .member(.right))
        XCTAssertEqual(splitRowDragKind(forX: 134, rowWidth: 200, indent: 16), .group)
        // Depth 2 in a narrow sidebar: the band still stops at the midline.
        XCTAssertEqual(splitRowDragKind(forX: 45, rowWidth: 100, indent: 32), .member(.left))
        XCTAssertEqual(splitRowDragKind(forX: 50, rowWidth: 100, indent: 32), .member(.right))
    }

    // MARK: - validateSidebarDrop: split edges

    func testValidateEdgeDropOntoSingleTab() {
        let (tabItems, tabs, _) = splitTabItems()
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: tabs[3].id,
                                           row: .normalTab(index: 0), operation: .on, items: [],
                                           tabItems: tabItems, dropZone: .splitEdge(.left)),
                       .acceptIntoSplit(edge: .left))
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: tabs[3].id,
                                           row: .normalTab(index: 0), operation: .on, items: [],
                                           tabItems: tabItems, dropZone: .splitEdge(.right)),
                       .acceptIntoSplit(edge: .right))
        // Middle band → plain reorder retarget at the pointer's nearest gap
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: tabs[3].id,
                                           row: .normalTab(index: 0), operation: .on, items: [],
                                           tabItems: tabItems, dropZone: .reorderGap(offset: 1)),
                       .retargetToNormalTabGap(index: 1))
        // Tab onto its own row's edge
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: tabs[0].id,
                                           row: .normalTab(index: 0), operation: .on, items: [],
                                           tabItems: tabItems, dropZone: .splitEdge(.left)),
                       .reject)
        // Split rows are not split targets (2 panes max)
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: tabs[3].id,
                                           row: .normalTab(index: 1), operation: .on, items: [],
                                           tabItems: tabItems, dropZone: .splitEdge(.left)),
                       .reject)
        // No pointer geometry → nothing to accept
        XCTAssertEqual(validateSidebarDrop(kind: .normalTab, sourceItemID: tabs[3].id,
                                           row: .normalTab(index: 0), operation: .on, items: [],
                                           tabItems: tabItems, dropZone: nil),
                       .reject)
    }

    func testValidateEdgeDropRejectsNonNormalTabSources() {
        let (tabItems, tabs, _) = splitTabItems()
        for kind: SidebarDragKind in [.pinnedEntry, .pinnedFolder, .favorite, .splitGroup, .splitMember] {
            XCTAssertEqual(validateSidebarDrop(kind: kind, sourceItemID: UUID(),
                                               row: .normalTab(index: 0), operation: .on, items: [],
                                               tabItems: tabItems, dropZone: .splitEdge(.left)),
                           .reject, "\(kind) must not become a split pane by edge drop")
        }
        _ = tabs
    }

    func testValidateSplitMemberSectionRules() {
        let (items, folderA, _, _) = standardTree()
        // Members can only land in the normal section (v1: no pin/favorite by drag)
        XCTAssertEqual(validateSidebarDrop(kind: .splitMember, sourceItemID: UUID(),
                                           row: .topSpacer, operation: .above, items: items), .reject)
        XCTAssertEqual(validateSidebarDrop(kind: .splitMember, sourceItemID: UUID(),
                                           row: .separator, operation: .above, items: items), .reject)
        XCTAssertEqual(validateSidebarDrop(kind: .splitMember, sourceItemID: UUID(),
                                           row: .pinnedItem(index: 0), operation: .above, items: items), .reject)
        XCTAssertEqual(validateSidebarDrop(kind: .splitMember, sourceItemID: UUID(),
                                           row: .pinnedItem(index: 0), operation: .on, items: items),
                       .reject, "a lone pane can't be dropped into folder \(folderA.name)")
        XCTAssertEqual(validateSidebarDrop(kind: .splitMember, sourceItemID: UUID(),
                                           row: .normalTab(index: 1), operation: .above, items: items), .accept)
        XCTAssertEqual(validateSidebarDrop(kind: .splitMember, sourceItemID: UUID(),
                                           row: .newTab, operation: .above, items: items),
                       .retargetToNormalTabGap(index: 0))
    }

    // MARK: - sidebarDropDestination: split edges

    func testDestinationIntoSplit() {
        let (tabItems, tabs, _) = splitTabItems()
        XCTAssertEqual(sidebarDropDestination(row: .normalTab(index: 0), operation: .on, items: [],
                                              tabItems: tabItems, dropZone: .splitEdge(.right)),
                       .intoSplit(targetTabID: tabs[0].id, edge: .right))
        // A split row is not a target
        XCTAssertNil(sidebarDropDestination(row: .normalTab(index: 1), operation: .on, items: [],
                                            tabItems: tabItems, dropZone: .splitEdge(.left)))
        // Middle band resolves to the reorder gap even if the drop lands before
        // the retargeted proposal arrives
        XCTAssertEqual(sidebarDropDestination(row: .normalTab(index: 2), operation: .on, items: [],
                                              tabItems: tabItems, dropZone: .reorderGap(offset: 1)),
                       .beforeNormalTab(gapIndex: 3))
        // No geometry → no destination
        XCTAssertNil(sidebarDropDestination(row: .normalTab(index: 0), operation: .on, items: [],
                                            tabItems: tabItems, dropZone: nil))
    }

    // MARK: - resolveSidebarDrop: split commands

    func testResolveCreateSplit() {
        let dragged = UUID()
        let target = UUID()
        XCTAssertEqual(resolveSidebarDrop(source: .normalTab(index: 3, tabID: dragged),
                                          destination: .intoSplit(targetTabID: target, edge: .left), items: []),
                       .createSplit(draggedTabID: dragged, targetTabID: target, edge: .left))
        XCTAssertNil(resolveSidebarDrop(source: .normalTab(index: 0, tabID: dragged),
                                        destination: .intoSplit(targetTabID: dragged, edge: .left), items: []),
                     "tab onto its own edge is a no-op")
        XCTAssertNil(resolveSidebarDrop(source: .splitGroup(index: 0, groupID: UUID(), memberTabIDs: [dragged, UUID()]),
                                        destination: .intoSplit(targetTabID: target, edge: .right), items: []))
        XCTAssertNil(resolveSidebarDrop(source: .splitMember(tabID: dragged, groupID: UUID()),
                                        destination: .intoSplit(targetTabID: target, edge: .right), items: []),
                     "leave-and-rejoin is v2")
        XCTAssertNil(resolveSidebarDrop(source: .pinnedEntry(entryID: dragged),
                                        destination: .intoSplit(targetTabID: target, edge: .left), items: []))
        XCTAssertNil(resolveSidebarDrop(source: .pinnedFolder(folderID: dragged),
                                        destination: .intoSplit(targetTabID: target, edge: .left), items: []))
    }

    func testResolveRemoveFromSplit() {
        let (items, _, _, _) = standardTree()
        let tabID = UUID()
        let groupID = UUID()
        XCTAssertEqual(resolveSidebarDrop(source: .splitMember(tabID: tabID, groupID: groupID),
                                          destination: .beforeNormalTab(gapIndex: 0), items: items),
                       .removeFromSplit(tabID: tabID, toGapIndex: 0))
        // Gaps adjacent to the member's own group are real changes (the group
        // dissolves), unlike plain reorders — no no-op suppression.
        XCTAssertEqual(resolveSidebarDrop(source: .splitMember(tabID: tabID, groupID: groupID),
                                          destination: .beforeNormalTab(gapIndex: 2), items: items),
                       .removeFromSplit(tabID: tabID, toGapIndex: 2))
        XCTAssertNil(resolveSidebarDrop(source: .splitMember(tabID: tabID, groupID: groupID),
                                        destination: .beforePinnedItem(flatIndex: 0), items: items))
        XCTAssertNil(resolveSidebarDrop(source: .splitMember(tabID: tabID, groupID: groupID),
                                        destination: .intoFolder(folderID: UUID()), items: items))
    }

    // MARK: - Pinned splits (§12)

    /// A pinned split pair (left, right) followed by a lone entry, all top-level.
    private func pinnedSplitTree() -> (items: [PinnedItem], groupID: UUID,
                                       left: PinnedEntry, right: PinnedEntry, lone: PinnedEntry) {
        let groupID = UUID()
        let left = makeEntry(title: "left", sortOrder: 0)
        let right = makeEntry(title: "right", sortOrder: 1)
        left.splitGroupID = groupID
        right.splitGroupID = groupID
        let lone = makeEntry(title: "lone", sortOrder: 2)
        let items = flatItems([left, right, lone])
        return (items, groupID, left, right, lone)
    }

    func testFlattenerHelpersOnPinnedSplitItems() {
        let (items, groupID, left, _, lone) = pinnedSplitTree()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(pinnedItemID(items[0]), groupID)
        XCTAssertEqual(itemIDAtDropIndex(0, in: items), left.id,
                       "anchors name the FIRST member so drops land before the group")
        XCTAssertEqual(itemIDAtDropIndex(1, in: items), lone.id)
        XCTAssertNil(folderIDForDropIndex(0, in: items), "top-level split inherits no folder")
    }

    func testValidatePinnedSplitGroupTargets() {
        let (items, _, left, _, _) = pinnedSplitTree()
        let folder = makeFolder(name: "F", sortOrder: 3)
        let withFolder = flatItems([left], folders: [folder])

        // Whole pinned split rows reorder in the pinned section, enter folders,
        // and unpin to the tab section.
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedSplitGroup, sourceItemID: left.id,
                                           row: .pinnedItem(index: 1), operation: .above, items: items), .accept)
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedSplitGroup, sourceItemID: left.id,
                                           row: .pinnedItem(index: 1), operation: .on, items: withFolder), .accept)
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedSplitGroup, sourceItemID: left.id,
                                           row: .normalTab(index: 0), operation: .above, items: items), .accept)
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedSplitGroup, sourceItemID: left.id,
                                           row: .topSpacer, operation: .above, items: items),
                       .retargetToPinnedGap(index: 0))
        // No split creation from pinned rows: edge drops don't validate for them.
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedSplitGroup, sourceItemID: left.id,
                                           row: .normalTab(index: 0), operation: .on, items: items,
                                           tabItems: [], dropZone: .splitEdge(.left)), .reject)
    }

    func testValidatePinnedSplitMemberTargets() {
        let (items, _, left, _, _) = pinnedSplitTree()
        let folder = makeFolder(name: "F", sortOrder: 3)
        let withFolder = flatItems([left], folders: [folder])

        // A lone pane may break out to pinned gaps and unpin to tab gaps…
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedSplitMember, sourceItemID: left.id,
                                           row: .pinnedItem(index: 1), operation: .above, items: items), .accept)
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedSplitMember, sourceItemID: left.id,
                                           row: .topSpacer, operation: .above, items: items),
                       .retargetToPinnedGap(index: 0))
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedSplitMember, sourceItemID: left.id,
                                           row: .normalTab(index: 0), operation: .above, items: items), .accept)
        // …but can't enter folders in v1.
        XCTAssertEqual(validateSidebarDrop(kind: .pinnedSplitMember, sourceItemID: left.id,
                                           row: .pinnedItem(index: 1), operation: .on, items: withFolder), .reject)
    }

    func testResolvePinnedSplitGroupMoves() {
        let (items, groupID, left, right, lone) = pinnedSplitTree()
        let memberIDs = [left.id, right.id]

        // Reorder after the lone entry (end of section).
        XCTAssertEqual(
            resolveSidebarDrop(source: .pinnedSplitGroup(groupID: groupID, memberEntryIDs: memberIDs),
                               destination: .beforePinnedItem(flatIndex: 2), items: items),
            .movePinnedSplitGroup(groupID: groupID, firstMemberEntryID: left.id, folderID: nil, beforeItemID: nil)
        )
        XCTAssertEqual(
            resolveSidebarDrop(source: .pinnedSplitGroup(groupID: groupID, memberEntryIDs: memberIDs),
                               destination: .beforePinnedItem(flatIndex: 1), items: items),
            .movePinnedSplitGroup(groupID: groupID, firstMemberEntryID: left.id, folderID: nil, beforeItemID: lone.id)
        )
        // Dropping back before itself is a no-op (anchor = own first member).
        XCTAssertNil(resolveSidebarDrop(source: .pinnedSplitGroup(groupID: groupID, memberEntryIDs: memberIDs),
                                        destination: .beforePinnedItem(flatIndex: 0), items: items))
        // Into a folder.
        let folderID = UUID()
        XCTAssertEqual(
            resolveSidebarDrop(source: .pinnedSplitGroup(groupID: groupID, memberEntryIDs: memberIDs),
                               destination: .intoFolder(folderID: folderID), items: items),
            .movePinnedSplitGroup(groupID: groupID, firstMemberEntryID: left.id, folderID: folderID, beforeItemID: nil)
        )
        // Unpin restores the split in the tab section.
        XCTAssertEqual(
            resolveSidebarDrop(source: .pinnedSplitGroup(groupID: groupID, memberEntryIDs: memberIDs),
                               destination: .beforeNormalTab(gapIndex: 3), items: items),
            .unpinSplitGroup(groupID: groupID, toGapIndex: 3)
        )
        // Never a split-edge target source.
        XCTAssertNil(resolveSidebarDrop(source: .pinnedSplitGroup(groupID: groupID, memberEntryIDs: memberIDs),
                                        destination: .intoSplit(targetTabID: UUID(), edge: .left), items: items))
    }

    func testResolvePinnedSplitMemberBreakouts() {
        let (items, groupID, left, right, lone) = pinnedSplitTree()

        // Member → tab gap: unpin alone (the pinned split dissolves).
        XCTAssertEqual(
            resolveSidebarDrop(source: .pinnedSplitMember(entryID: right.id, groupID: groupID),
                               destination: .beforeNormalTab(gapIndex: 0), items: items),
            .unpinSplitMember(entryID: right.id, toGapIndex: 0)
        )
        // Member → pinned gap: break out into its own pinned row.
        XCTAssertEqual(
            resolveSidebarDrop(source: .pinnedSplitMember(entryID: right.id, groupID: groupID),
                               destination: .beforePinnedItem(flatIndex: 1), items: items),
            .removeFromPinnedSplit(entryID: right.id, folderID: nil, beforeItemID: lone.id)
        )
        // Left pane dropped above its own row: anchor retargets to the partner.
        XCTAssertEqual(
            resolveSidebarDrop(source: .pinnedSplitMember(entryID: left.id, groupID: groupID),
                               destination: .beforePinnedItem(flatIndex: 0), items: items),
            .removeFromPinnedSplit(entryID: left.id, folderID: nil, beforeItemID: right.id)
        )
        // Folders rejected in v1.
        XCTAssertNil(resolveSidebarDrop(source: .pinnedSplitMember(entryID: left.id, groupID: groupID),
                                        destination: .intoFolder(folderID: UUID()), items: items))
    }

    func testPinnedSplitPayloadRoundTrip() {
        for kind: SidebarDragPayload.Kind in [.pinnedSplitGroup, .pinnedSplitMember] {
            let payload = SidebarDragPayload(kind: kind, itemID: UUID(), spaceID: UUID(), sidebarID: UUID())
            let string = payload.pasteboardString
            XCTAssertNotNil(string)
            XCTAssertEqual(SidebarDragPayload(pasteboardString: string!), payload)
        }
    }
}
