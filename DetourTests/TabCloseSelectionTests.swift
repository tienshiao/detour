import XCTest
@testable import Detour

nonisolated final class TabCloseSelectionTests: XCTestCase {

    /// The opener rule for a list with no pinned tabs or favourites: a parent
    /// counts while it is a tab of the list.
    private static func listed(in tabs: [(id: UUID, parentID: UUID?)]) -> (UUID) -> Bool {
        { id in tabs.contains { $0.id == id } }
    }

    // MARK: - Next sibling

    @MainActor func testClosingMiddleChildSelectsNextSibling() {
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
        let result = tabCloseSelectionID(closingIndex: 2, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, child3, "Should select next sibling")
    }

    @MainActor func testClosingFirstChildSelectsNextSibling() {
        let parent = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: child2, parentID: parent),
        ]
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, child2, "Should select next sibling")
    }

    // MARK: - Previous sibling

    @MainActor func testClosingLastChildSelectsPreviousSibling() {
        let parent = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: child2, parentID: parent),
        ]
        let result = tabCloseSelectionID(closingIndex: 2, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, child1, "Should select previous sibling when no next sibling")
    }

    // MARK: - Non-contiguous siblings

    @MainActor func testNonContiguousSiblingStillFound() {
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
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, child2, "Should find non-contiguous next sibling")
    }

    @MainActor func testNonContiguousPreviousSibling() {
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
        let result = tabCloseSelectionID(closingIndex: 3, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, child1, "Should find non-contiguous previous sibling")
    }

    // MARK: - Parent selection

    @MainActor func testOnlyChildSelectsParent() {
        let parent = UUID()
        let child = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child, parentID: parent),
        ]
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, parent, "Only child should select parent")
    }

    @MainActor func testOnlyChildOfPinnedParentReturnsAdjacent() {
        let pinnedParent = UUID()
        let child = UUID()
        let other = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: child, parentID: pinnedParent),
            (id: other, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 0, tabs: tabs,
                                         isOpener: { $0 == pinnedParent })
        XCTAssertEqual(result, pinnedParent, "a live pinned (or favourite) opener is returned to, as Back does (TASK-358)")
    }

    @MainActor func testTheLastTabReturnsToAnOpenerOutsideTheList() {
        let pinnedParent = UUID()
        let child = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [(id: child, parentID: pinnedParent)]
        XCTAssertEqual(tabCloseSelectionID(closingIndex: 0, tabs: tabs, isOpener: { $0 == pinnedParent }),
                       pinnedParent, "the last normal tab still returns to its pinned opener")
        XCTAssertNil(tabCloseSelectionID(closingIndex: 0, tabs: tabs, isOpener: { _ in false }),
                     "and with none, nothing in the list is left")
    }

    @MainActor func testSiblingsComeBeforeAnOpenerOutsideTheList() {
        let pinnedParent = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: child1, parentID: pinnedParent),
            (id: child2, parentID: pinnedParent),
        ]
        XCTAssertEqual(tabCloseSelectionID(closingIndex: 1, tabs: tabs, isOpener: { $0 == pinnedParent }), child1)
    }

    @MainActor func testOrphanTabFallsBackToAdjacent() {
        let missingParent = UUID()
        let orphan = UUID()
        let other = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: orphan, parentID: missingParent),
            (id: other, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 0, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, other, "Parent not found — should fall back to adjacent")
    }

    // MARK: - Adjacent fallback

    @MainActor func testNoParentSelectsRightNeighbor() {
        let tab1 = UUID()
        let tab2 = UUID()
        let tab3 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab1, parentID: nil),
            (id: tab2, parentID: nil),
            (id: tab3, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, tab3, "No parent — should select right neighbor")
    }

    @MainActor func testRightmostTabSelectsLeftNeighbor() {
        let tab1 = UUID()
        let tab2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab1, parentID: nil),
            (id: tab2, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, tab1, "Rightmost tab — should select left neighbor")
    }

    // MARK: - Edge cases

    @MainActor func testSingleTabReturnsNil() {
        let tab = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 0, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertNil(result, "Single tab — no next tab to select")
    }

    @MainActor func testEmptyTabsReturnsNil() {
        let result = tabCloseSelectionID(closingIndex: 0, tabs: [], isOpener: { _ in false })
        XCTAssertNil(result, "Empty tabs — no next tab to select")
    }

    @MainActor func testInvalidIndexReturnsNil() {
        let tab = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: 5, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertNil(result, "Invalid index — should return nil")
    }

    @MainActor func testNegativeIndexReturnsNil() {
        let tab = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: tab, parentID: nil),
        ]
        let result = tabCloseSelectionID(closingIndex: -1, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertNil(result, "Negative index — should return nil")
    }

    // MARK: - Priority ordering

    @MainActor func testNextSiblingPreferredOverPreviousSibling() {
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
        let result = tabCloseSelectionID(closingIndex: 2, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, child3, "Next sibling should be preferred over previous sibling")
    }

    @MainActor func testSiblingPreferredOverParent() {
        let parent = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child1, parentID: parent),
            (id: child2, parentID: parent),
        ]
        // Close child2 — child1 (sibling) and parent both available
        let result = tabCloseSelectionID(closingIndex: 2, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, child1, "Sibling should be preferred over parent")
    }

    @MainActor func testParentPreferredOverAdjacentNonSibling() {
        let parent = UUID()
        let child = UUID()
        let unrelated = UUID()
        let tabs: [(id: UUID, parentID: UUID?)] = [
            (id: parent, parentID: nil),
            (id: child, parentID: parent),
            (id: unrelated, parentID: nil),
        ]
        // Close child — parent and unrelated (adjacent right) both available
        let result = tabCloseSelectionID(closingIndex: 1, tabs: tabs, isOpener: Self.listed(in: tabs))
        XCTAssertEqual(result, parent, "Parent should be preferred over adjacent unrelated tab")
    }
}
