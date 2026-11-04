import XCTest
@testable import Detour

nonisolated final class TabInsertionTests: XCTestCase {

    // MARK: - No parent

    @MainActor func testNoParentReturnsIndex0() {
        let result = tabInsertionIndex(parentID: nil, existingTabs: [], pinnedTabIDs: [])
        XCTAssertEqual(result, 0)
    }

    @MainActor func testNoParentWithExistingTabsReturnsIndex0() {
        let id1 = UUID()
        let result = tabInsertionIndex(
            parentID: nil,
            existingTabs: [(id: id1, parentID: nil)],
            pinnedTabIDs: []
        )
        XCTAssertEqual(result, 0)
    }

    // MARK: - Normal parent

    @MainActor func testNormalParentNoChildren() {
        let parentID = UUID()
        let result = tabInsertionIndex(
            parentID: parentID,
            existingTabs: [(id: parentID, parentID: nil)],
            pinnedTabIDs: []
        )
        XCTAssertEqual(result, 1, "Should insert right after the parent")
    }

    @MainActor func testNormalParentWithChildren() {
        let parentID = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let result = tabInsertionIndex(
            parentID: parentID,
            existingTabs: [
                (id: parentID, parentID: nil),
                (id: child1, parentID: parentID),
                (id: child2, parentID: parentID),
            ],
            pinnedTabIDs: []
        )
        XCTAssertEqual(result, 3, "Should insert after the last child")
    }

    @MainActor func testChildrenMustBeContiguous() {
        let parentID = UUID()
        let child1 = UUID()
        let unrelated = UUID()
        let child2 = UUID()
        let result = tabInsertionIndex(
            parentID: parentID,
            existingTabs: [
                (id: parentID, parentID: nil),
                (id: child1, parentID: parentID),
                (id: unrelated, parentID: nil),   // breaks contiguity
                (id: child2, parentID: parentID),  // not reached
            ],
            pinnedTabIDs: []
        )
        XCTAssertEqual(result, 2, "Should stop at first non-child after parent")
    }

    // MARK: - Pinned parent

    @MainActor func testPinnedParentReturnsIndex0() {
        let parentID = UUID()
        let result = tabInsertionIndex(
            parentID: parentID,
            existingTabs: [],
            pinnedTabIDs: [parentID]
        )
        XCTAssertEqual(result, 0, "Pinned parent with no existing children → index 0")
    }

    @MainActor func testPinnedParentWithExistingSiblings() {
        let parentID = UUID()
        let child1 = UUID()
        let child2 = UUID()
        let result = tabInsertionIndex(
            parentID: parentID,
            existingTabs: [
                (id: child1, parentID: parentID),
                (id: child2, parentID: parentID),
            ],
            pinnedTabIDs: [parentID]
        )
        XCTAssertEqual(result, 2, "Should insert after existing siblings from pinned parent")
    }

    @MainActor func testPinnedParentSiblingsContiguous() {
        let parentID = UUID()
        let child1 = UUID()
        let unrelated = UUID()
        let child2 = UUID()
        let result = tabInsertionIndex(
            parentID: parentID,
            existingTabs: [
                (id: child1, parentID: parentID),
                (id: unrelated, parentID: nil),
                (id: child2, parentID: parentID),
            ],
            pinnedTabIDs: [parentID]
        )
        XCTAssertEqual(result, 1, "Should stop at first non-child in pinned parent path")
    }

    // MARK: - Sequential insertions

    @MainActor func testSequentialInsertionsFromSameParent() {
        let parentID = UUID()
        var tabs: [(id: UUID, parentID: UUID?)] = [(id: parentID, parentID: nil)]

        // Simulate 3 sequential insertions from the same parent
        for _ in 0..<3 {
            let newID = UUID()
            let idx = tabInsertionIndex(parentID: parentID, existingTabs: tabs, pinnedTabIDs: [])
            tabs.insert((id: newID, parentID: parentID), at: idx)
        }

        // Should be: parent, child0, child1, child2
        XCTAssertEqual(tabs.count, 4)
        XCTAssertEqual(tabs[0].id, parentID)
        for i in 1..<4 {
            XCTAssertEqual(tabs[i].parentID, parentID)
        }
    }
}
