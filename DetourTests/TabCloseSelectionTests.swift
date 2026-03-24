import XCTest
@testable import Detour

final class TabCloseSelectionTests: XCTestCase {

    // MARK: - Next sibling

    func testClosingMiddleChildSelectsNextSibling() {
        let parent = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let child3 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: child2, parentID: parent),
            (id: child3, parentID: parent),
        ]
        let result = tabCloseSelectionID(closingIndex: 2, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, child3, "Should select next sibling")
    }

    func testClosingFirstChildSelectsNextSibling() {
        let parent = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: child2, parentID: parent),
        ]
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, child2, "Should select next sibling")
    }

    // MARK: - Previous sibling

    func testClosingLastChildSelectsPreviousSibling() {
        let parent = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: child2, parentID: parent),
        ]
        let result = tabCloseSelectionID(closingIndex: 2, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, child1, "Should select previous sibling when no next sibling")
    }

    // MARK: - Non-contiguous siblings

    func testNonContiguousSiblingStillFound() {
        let parent = UUID()
        let child1 = UUID()
        let unrelated = UUID()
        let child2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: unrelated, parentID: nil),
            (id: child2, parentID: parent),
        ]
        // Close child1 → should find child2 even though unrelated is between them
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, child2, "Should find non-contiguous next sibling")
    }

    func testNonContiguousPreviousSibling() {
        let parent = UUID()
        let child1 = UUID()
        let unrelated = UUID()
        let child2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: unrelated, parentID: nil),
            (id: child2, parentID: parent),
        ]
        // Close child2 (last sibling) → should find child1 backwards
        let result = tabCloseSelectionID(closingIndex: 3, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, child1, "Should find non-contiguous previous sibling")
    }

    // MARK: - Parent selection

    func testOnlyChildSelectsParent() {
        let parent = UUID()
        let child = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child, parentID: parent),
        ]
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, parent, "Only child should select parent")
    }

    func testOnlyChildOfPinnedParentReturnsAdjacent() {
        let pinnedParent = UUID()
        let child = UUID()
        let other = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: child, parentID: pinnedParent),
            (id: other, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 0, tabs: tabs, pinnedTabIDs: [pinnedParent])
        XCTAssertEqual(result, other, "Pinned parent not selectable — should fall back to adjacent")
    }

    func testOrphanTabFallsBackToAdjacent() {
        let missingParent = UUID()
        let orphan = UUID()
        let other = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: orphan, parentID: missingParent),
            (id: other, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 0, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, other, "Parent not found — should fall back to adjacent")
    }

    // MARK: - Adjacent fallback

    func testNoParentSelectsRightNeighbor() {
        let tab1 = UUID()
        let tab2 = UUID()
        let tab3 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab1, parentID: nil),
            (id: tab2, parentID: nil),
            (id: tab3, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, tab3, "No parent — should select right neighbor")
    }

    func testRightmostTabSelectsLeftNeighbor() {
        let tab1 = UUID()
        let tab2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab1, parentID: nil),
            (id: tab2, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, tab1, "Rightmost tab — should select left neighbor")
    }

    // MARK: - Edge cases

    func testSingleTabReturnsNil() {
        let tab = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 0, tabs: tabs, pinnedTabIDs: [])
        XCTAssertNil(result, "Single tab — no next tab to select")
    }

    func testEmptyTabsReturnsNil() {
        let result = tabCloseSelectionID(closingIndex: 0, tabs: [], pinnedTabIDs: [])
        XCTAssertNil(result, "Empty tabs — no next tab to select")
    }

    func testInvalidIndexReturnsNil() {
        let tab = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 5, tabs: tabs, pinnedTabIDs: [])
        XCTAssertNil(result, "Invalid index — should return nil")
    }

    func testNegativeIndexReturnsNil() {
        let tab = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: -1, tabs: tabs, pinnedTabIDs: [])
        XCTAssertNil(result, "Negative index — should return nil")
    }

    // MARK: - Priority ordering

    func testNextSiblingPreferredOverPreviousSibling() {
        let parent = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let child3 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: child2, parentID: parent),
            (id: child3, parentID: parent),
        ]
        // Close child2 — both child1 (prev) and child3 (next) are siblings
        let result = tabCloseSelectionID(closingIndex: 2, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, child3, "Next sibling should be preferred over previous sibling")
    }

    func testSiblingPreferredOverParent() {
        let parent = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: child2, parentID: parent),
        ]
        // Close child2 — child1 (sibling) and parent both available
        let result = tabCloseSelectionID(closingIndex: 2, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, child1, "Sibling should be preferred over parent")
    }

    func testParentPreferredOverAdjacentNonSibling() {
        let parent = UUID()
        let child = UUID()
        let unrelated = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child, parentID: parent),
            (id: unrelated, parentID: nil),
        ]
        // Close child — parent and unrelated (adjacent right) both available
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, pinnedTabIDs: [])
        XCTAssertEqual(result, parent, "Parent should be preferred over adjacent unrelated tab")
    }
}
