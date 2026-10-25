import XCTest
import AppKit
@testable import Detour

/// A tab list scrolled to its end stays at its end when its visible height
/// changes — the now-playing bar (TASK-192) shrinks the page by its compact
/// height when it appears — instead of keeping its top offset and sliding the
/// last rows out of view. A list scrolled anywhere else keeps its offset.
@MainActor
final class SpacePageScrollAnchorTests: XCTestCase {

    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { 30 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSView() }
    }

    private let rows = Rows()

    private func makePage(height: CGFloat) -> SpacePageView {
        let page = SpacePageView(tableViewDataSource: rows, tableViewDelegate: rows, menuDelegate: rows,
                                 onScrollWheel: { _ in false })
        page.frame = NSRect(x: 0, y: 0, width: 240, height: height)
        page.tableView.reloadData()
        page.layoutSubtreeIfNeeded()
        return page
    }

    private func maxOffset(_ page: SpacePageView) -> CGFloat {
        let clip = page.scrollView.contentView
        var probe = clip.bounds
        probe.origin.y = 1e7
        return clip.constrainBoundsRect(probe).origin.y
    }

    private func offset(_ page: SpacePageView) -> CGFloat { page.scrollView.contentView.bounds.origin.y }

    private func scroll(_ page: SpacePageView, to y: CGFloat) {
        page.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        page.scrollView.reflectScrolledClipView(page.scrollView.contentView)
    }

    private func resize(_ page: SpacePageView, height: CGFloat) {
        page.frame.size.height = height
        page.layoutSubtreeIfNeeded()
    }

    func testAListAtItsEndStaysAtItsEndWhenItShrinks() {
        let page = makePage(height: 600)
        scroll(page, to: maxOffset(page))
        let before = maxOffset(page)
        XCTAssertGreaterThan(before, 0, "30 rows of 36 pt scroll in 600 pt")

        resize(page, height: 558)

        XCTAssertEqual(maxOffset(page), before + 42, accuracy: 0.5)
        XCTAssertEqual(offset(page), maxOffset(page), accuracy: 0.5, "the last row stays in view")
    }

    func testAListAtItsEndStaysAtItsEndWhenItGrows() {
        let page = makePage(height: 558)
        scroll(page, to: maxOffset(page))

        resize(page, height: 600)

        XCTAssertEqual(offset(page), maxOffset(page), accuracy: 0.5)
    }

    func testAListScrolledElsewhereKeepsItsOffset() {
        let page = makePage(height: 600)
        scroll(page, to: 200)

        resize(page, height: 558)

        XCTAssertEqual(offset(page), 200, accuracy: 0.5)
    }

    func testAListAtItsTopStaysAtItsTop() {
        let page = makePage(height: 600)

        resize(page, height: 558)

        XCTAssertEqual(offset(page), 0, accuracy: 0.5)
    }
}
