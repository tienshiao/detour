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
}
