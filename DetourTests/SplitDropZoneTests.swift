import XCTest
@testable import Detour

final class SplitDropZoneTests: XCTestCase {

    // MARK: - splitContentDropEdge

    func testSplitContentDropEdgeBands() {
        let width: CGFloat = 100
        // Outer 30% bands target an edge, the middle band rejects.
        XCTAssertEqual(splitContentDropEdge(forX: 10, width: width), .left)
        XCTAssertEqual(splitContentDropEdge(forX: 29, width: width), .left)
        XCTAssertNil(splitContentDropEdge(forX: 50, width: width))
        XCTAssertEqual(splitContentDropEdge(forX: 71, width: width), .right)
        XCTAssertEqual(splitContentDropEdge(forX: 90, width: width), .right)
    }

    func testSplitContentDropEdgeBoundariesAreStrict() {
        let width: CGFloat = 100
        // The band edges themselves fall in the middle (strict < and >).
        XCTAssertNil(splitContentDropEdge(forX: width * 0.3, width: width))
        XCTAssertNil(splitContentDropEdge(forX: width * 0.7, width: width))
    }

    func testSplitContentDropEdgeInclusiveExtremes() {
        let width: CGFloat = 100
        XCTAssertEqual(splitContentDropEdge(forX: 0, width: width), .left)
        XCTAssertEqual(splitContentDropEdge(forX: width, width: width), .right)
    }

    func testSplitContentDropEdgeDegenerateAndOutOfBounds() {
        XCTAssertNil(splitContentDropEdge(forX: 10, width: 0))
        XCTAssertNil(splitContentDropEdge(forX: 10, width: -100))
        XCTAssertNil(splitContentDropEdge(forX: -1, width: 100))
        XCTAssertNil(splitContentDropEdge(forX: 101, width: 100))
    }

    // MARK: - validateContentSplitDrop

    private func makePayload(kind: SidebarDragPayload.Kind, itemID: UUID,
                             spaceID: UUID, sidebarID: UUID) -> SidebarDragPayload {
        SidebarDragPayload(kind: kind, itemID: itemID, spaceID: spaceID, sidebarID: sidebarID)
    }

    func testValidateContentSplitDropAccepts() {
        let sidebarID = UUID()
        let spaceID = UUID()
        let dragged = UUID()
        let target = UUID()
        let payload = makePayload(kind: .normalTab, itemID: dragged, spaceID: spaceID, sidebarID: sidebarID)
        XCTAssertTrue(validateContentSplitDrop(payload: payload, sidebarID: sidebarID,
                                               activeSpaceID: spaceID, targetTabID: target))
    }

    func testValidateContentSplitDropRejectsNonNormalTabKinds() {
        let sidebarID = UUID()
        let spaceID = UUID()
        let target = UUID()
        for kind: SidebarDragPayload.Kind in [.pinnedEntry, .pinnedFolder, .splitGroup,
                                              .splitMember, .pinnedSplitGroup, .pinnedSplitMember] {
            let payload = makePayload(kind: kind, itemID: UUID(), spaceID: spaceID, sidebarID: sidebarID)
            XCTAssertFalse(validateContentSplitDrop(payload: payload, sidebarID: sidebarID,
                                                    activeSpaceID: spaceID, targetTabID: target),
                           "\(kind) must not form a content-area split")
        }
    }

    func testValidateContentSplitDropRejectsSidebarMismatch() {
        let spaceID = UUID()
        let payload = makePayload(kind: .normalTab, itemID: UUID(), spaceID: spaceID, sidebarID: UUID())
        XCTAssertFalse(validateContentSplitDrop(payload: payload, sidebarID: UUID(),
                                                activeSpaceID: spaceID, targetTabID: UUID()))
    }

    func testValidateContentSplitDropRejectsSpaceMismatch() {
        let sidebarID = UUID()
        let payload = makePayload(kind: .normalTab, itemID: UUID(), spaceID: UUID(), sidebarID: sidebarID)
        XCTAssertFalse(validateContentSplitDrop(payload: payload, sidebarID: sidebarID,
                                                activeSpaceID: UUID(), targetTabID: UUID()))
    }

    func testValidateContentSplitDropRejectsNilActiveSpace() {
        let sidebarID = UUID()
        let spaceID = UUID()
        let payload = makePayload(kind: .normalTab, itemID: UUID(), spaceID: spaceID, sidebarID: sidebarID)
        XCTAssertFalse(validateContentSplitDrop(payload: payload, sidebarID: sidebarID,
                                                activeSpaceID: nil, targetTabID: UUID()))
    }

    func testValidateContentSplitDropRejectsNilTarget() {
        let sidebarID = UUID()
        let spaceID = UUID()
        let payload = makePayload(kind: .normalTab, itemID: UUID(), spaceID: spaceID, sidebarID: sidebarID)
        XCTAssertFalse(validateContentSplitDrop(payload: payload, sidebarID: sidebarID,
                                                activeSpaceID: spaceID, targetTabID: nil))
    }

    func testValidateContentSplitDropRejectsDropOntoSelf() {
        let sidebarID = UUID()
        let spaceID = UUID()
        let same = UUID()
        let payload = makePayload(kind: .normalTab, itemID: same, spaceID: spaceID, sidebarID: sidebarID)
        XCTAssertFalse(validateContentSplitDrop(payload: payload, sidebarID: sidebarID,
                                                activeSpaceID: spaceID, targetTabID: same))
    }
}
