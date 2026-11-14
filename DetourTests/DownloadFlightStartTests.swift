import XCTest
@testable import Detour

/// TASK-324: a download's icon takes off from the click that started it,
/// when that click was in the window's web content moments ago, and from the
/// middle of the page otherwise.
nonisolated final class DownloadFlightStartTests: XCTestCase {

    private let content = CGRect(x: 240, y: 0, width: 1360, height: 1100)
    private var middle: CGPoint { CGPoint(x: content.midX, y: content.midY) }

    @MainActor func testAFreshClickInTheContentIsTheStart() {
        let click = WebContentClick(point: CGPoint(x: 900, y: 700), time: 100)
        XCTAssertEqual(DownloadFlightStart.point(click: click, now: 101.2, contentRect: content), click.point)
    }

    @MainActor func testNoClickStartsInTheMiddle() {
        XCTAssertEqual(DownloadFlightStart.point(click: nil, now: 100, contentRect: content), middle)
    }

    @MainActor func testAStaleClickStartsInTheMiddle() {
        let click = WebContentClick(point: CGPoint(x: 900, y: 700), time: 100)
        XCTAssertEqual(DownloadFlightStart.point(click: click, now: 100 + DownloadFlightStart.maxClickAge, contentRect: content),
                       click.point, "at the limit it still counts")
        XCTAssertEqual(DownloadFlightStart.point(click: click, now: 100.01 + DownloadFlightStart.maxClickAge, contentRect: content),
                       middle)
    }

    @MainActor func testAClickFromTheFutureStartsInTheMiddle() {
        // A clock that went backwards, or a click recorded after `now` was read.
        let click = WebContentClick(point: CGPoint(x: 900, y: 700), time: 105)
        XCTAssertEqual(DownloadFlightStart.point(click: click, now: 100, contentRect: content), middle)
    }

    @MainActor func testAClickOutsideTheContentStartsInTheMiddle() {
        // The page was resized since (the sidebar grew over the point).
        let click = WebContentClick(point: CGPoint(x: 120, y: 700), time: 100)
        XCTAssertEqual(DownloadFlightStart.point(click: click, now: 100.5, contentRect: content), middle)
    }
}
