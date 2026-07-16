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

    // MARK: - splitPaneRects

    func testSplitPaneRectsTileTheInsetBounds() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let rects = splitPaneRects(in: bounds, inset: 10, gap: 8, fraction: 0.5)
        // Panes span the inset content rect with exactly the gap between them.
        XCTAssertEqual(rects.left.minX, 10)
        XCTAssertEqual(rects.right.maxX, 990)
        XCTAssertEqual(rects.left.minY, 10)
        XCTAssertEqual(rects.left.height, 580)
        XCTAssertEqual(rects.right.height, 580)
        XCTAssertEqual(rects.right.minX - rects.left.maxX, 8)
        // 50/50: both panes equal width.
        XCTAssertEqual(rects.left.width, rects.right.width)
    }

    func testSplitPaneRectsHonorFraction() {
        let bounds = NSRect(x: 0, y: 0, width: 1008, height: 100)
        let rects = splitPaneRects(in: bounds, inset: 0, gap: 8, fraction: 0.25)
        // available = 1000; left = 250, right = 750, gap between.
        XCTAssertEqual(rects.left.width, 250)
        XCTAssertEqual(rects.right.width, 750)
        XCTAssertEqual(rects.right.minX, 258)
    }

    func testSplitPaneRectsInsetZeroMatchesSplitViewTiling() {
        // applySplitFraction uses inset 0 within the split view's own bounds:
        // left.width is the divider position, right fills the remainder.
        let bounds = NSRect(x: 0, y: 0, width: 500, height: 300)
        let rects = splitPaneRects(in: bounds, inset: 0, gap: 8, fraction: 0.5)
        XCTAssertEqual(rects.left, NSRect(x: 0, y: 0, width: 246, height: 300))
        XCTAssertEqual(rects.right, NSRect(x: 254, y: 0, width: 246, height: 300))
    }

    func testSplitPaneRectsRoundOddWidths() {
        let bounds = NSRect(x: 0, y: 0, width: 109, height: 100)
        let rects = splitPaneRects(in: bounds, inset: 0, gap: 8, fraction: 0.5)
        // available = 101 → left rounds to 51, right gets 50; still tiles.
        XCTAssertEqual(rects.left.width + rects.right.width + 8, 109)
        XCTAssertEqual(rects.left.width, (101.0 / 2).rounded())
    }

    func testSplitPaneRectsDegenerateBoundsDoNotGoNegative() {
        let rects = splitPaneRects(in: .zero, inset: 8, gap: 8, fraction: 0.5)
        XCTAssertEqual(rects.left.width, 0)
        XCTAssertEqual(rects.right.width, 0)
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
