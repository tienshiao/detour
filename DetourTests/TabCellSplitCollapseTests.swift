import XCTest
import AppKit
@testable import Detour

/// Headless coverage for `TabCellView.updateSplitPane`'s split→single collapse.
/// With no window (and zero bounds) the animation guards fail, so every path
/// must land its final state instantly: the right-segment views hidden and
/// their favicon/title cleared. See `collapseSplitSegment` for the animated
/// counterpart that only runs on-screen.
final class TabCellSplitCollapseTests: XCTestCase {

    private func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16))
    }

    private func makeSplitCell() -> TabCellView {
        let cell = TabCellView()
        cell.updateSplitPane(favicon: makeImage(), title: "Right Pane")
        // Sanity: the segment is showing before we collapse it.
        XCTAssertFalse(cell.splitFaviconImageView.isHidden)
        XCTAssertFalse(cell.splitTitleLabel.isHidden)
        XCTAssertFalse(cell.splitDivider.isHidden)
        return cell
    }

    func testCollapseWithoutWindowClearsAndHidesInstantly() {
        let cell = makeSplitCell()
        // animatedReveal requested, but window == nil fails the animateCollapse
        // guard, so the clear applies synchronously.
        cell.updateSplitPane(favicon: nil, title: nil, animatedReveal: true)

        XCTAssertTrue(cell.splitFaviconImageView.isHidden)
        XCTAssertTrue(cell.splitTitleLabel.isHidden)
        XCTAssertTrue(cell.splitDivider.isHidden)
        XCTAssertNil(cell.splitFaviconImageView.image)
        XCTAssertEqual(cell.splitTitleLabel.stringValue, "")
    }

    func testUnanimatedCollapseClearsAndHides() {
        let cell = makeSplitCell()
        cell.updateSplitPane(favicon: nil, title: nil, animatedReveal: false)

        XCTAssertTrue(cell.splitFaviconImageView.isHidden)
        XCTAssertTrue(cell.splitTitleLabel.isHidden)
        XCTAssertTrue(cell.splitDivider.isHidden)
        XCTAssertNil(cell.splitFaviconImageView.image)
        XCTAssertEqual(cell.splitTitleLabel.stringValue, "")
    }

    func testAnimatedRevealWithoutWindowShowsSegmentInstantly() {
        let cell = TabCellView()
        // Reveal guard also requires a window; headless it must apply instantly.
        cell.updateSplitPane(favicon: makeImage(), title: "Right Pane", animatedReveal: true)

        XCTAssertFalse(cell.splitFaviconImageView.isHidden)
        XCTAssertFalse(cell.splitTitleLabel.isHidden)
        XCTAssertFalse(cell.splitDivider.isHidden)
        XCTAssertNotNil(cell.splitFaviconImageView.image)
        XCTAssertEqual(cell.splitTitleLabel.stringValue, "Right Pane")
    }
}
