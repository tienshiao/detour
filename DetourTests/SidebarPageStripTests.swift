import XCTest
@testable import Detour

/// TASK-119: the sidebar page strip's page ↔ strip-index mapping, with the
/// Archived Tabs page at strip index 0 (non-incognito) and without it.
final class SidebarPageStripTests: XCTestCase {

    func testWithArchivePage() {
        let strip = SidebarPageStrip(hasArchivePage: true, spaceCount: 3)
        XCTAssertEqual(strip.pageCount, 4)
        XCTAssertEqual(strip.stripIndex(for: .archive), 0)
        XCTAssertEqual(strip.stripIndex(for: .space(0)), 1)
        XCTAssertEqual(strip.stripIndex(for: .space(2)), 3)
        XCTAssertEqual(strip.page(atStripIndex: 0), .archive)
        XCTAssertEqual(strip.page(atStripIndex: 1), .space(0))
        XCTAssertEqual(strip.page(atStripIndex: 3), .space(2))
    }

    func testWithoutArchivePage() {
        let strip = SidebarPageStrip(hasArchivePage: false, spaceCount: 2)
        XCTAssertEqual(strip.pageCount, 2)
        XCTAssertEqual(strip.stripIndex(for: .space(0)), 0)
        XCTAssertEqual(strip.stripIndex(for: .space(1)), 1)
        XCTAssertEqual(strip.page(atStripIndex: 0), .space(0))
        XCTAssertEqual(strip.page(atStripIndex: 1), .space(1))
    }

    func testRoundTrip() {
        for hasArchive in [true, false] {
            let strip = SidebarPageStrip(hasArchivePage: hasArchive, spaceCount: 5)
            for index in 0..<strip.pageCount {
                let page = try? XCTUnwrap(strip.page(atStripIndex: index))
                XCTAssertEqual(page.map(strip.stripIndex(for:)), index)
            }
        }
    }

    func testOutOfRange() {
        let strip = SidebarPageStrip(hasArchivePage: true, spaceCount: 2)
        XCTAssertNil(strip.page(atStripIndex: -1))
        XCTAssertNil(strip.page(atStripIndex: 3))
        let empty = SidebarPageStrip(hasArchivePage: false, spaceCount: 0)
        XCTAssertEqual(empty.pageCount, 0)
        XCTAssertNil(empty.page(atStripIndex: 0))
        let archiveOnly = SidebarPageStrip(hasArchivePage: true, spaceCount: 0)
        XCTAssertEqual(archiveOnly.page(atStripIndex: 0), .archive)
    }

    func testFractionalSpaceButtonIndex() {
        let strip = SidebarPageStrip(hasArchivePage: true, spaceCount: 3)
        XCTAssertEqual(strip.spaceButtonIndex(forFractionalStripIndex: 1), 0, "first space")
        XCTAssertEqual(strip.spaceButtonIndex(forFractionalStripIndex: 2.5), 1.5, "between spaces 1 and 2")
        XCTAssertEqual(strip.spaceButtonIndex(forFractionalStripIndex: 0.25), -0.75, "most of the way onto the archive")
        XCTAssertEqual(strip.spaceButtonIndex(forFractionalStripIndex: 0), -1, "on the archive page")

        let incognito = SidebarPageStrip(hasArchivePage: false, spaceCount: 1)
        XCTAssertEqual(incognito.spaceButtonIndex(forFractionalStripIndex: 0), 0)
        XCTAssertEqual(incognito.spaceButtonIndex(forFractionalStripIndex: -0.2), -0.2, "rubber band past the edge")
    }

    func testSpaceChromeRidesTheFirstSpacePageOntoTheArchive() {
        let strip = SidebarPageStrip(hasArchivePage: true, spaceCount: 3)
        let w: CGFloat = 200
        XCTAssertEqual(strip.spaceChromeX(forStripX: -w, pageWidth: w), 0, "on the first space")
        XCTAssertEqual(strip.spaceChromeX(forStripX: -2.5 * w, pageWidth: w), 0, "between spaces it stays put")
        XCTAssertEqual(strip.spaceChromeX(forStripX: -3 * w - 40, pageWidth: w), 0, "rubber band past the last space")
        XCTAssertEqual(strip.spaceChromeX(forStripX: -0.75 * w, pageWidth: w), 0.25 * w, "sliding onto the archive")
        XCTAssertEqual(strip.spaceChromeX(forStripX: 0, pageWidth: w), w, "off to the right on the archive page")
        XCTAssertEqual(strip.spaceChromeX(forStripX: 30, pageWidth: w), w + 30, "rubber band past the archive")

        let incognito = SidebarPageStrip(hasArchivePage: false, spaceCount: 1)
        XCTAssertEqual(incognito.spaceChromeX(forStripX: 30, pageWidth: w), 0, "no archive: never moves")
    }
}
