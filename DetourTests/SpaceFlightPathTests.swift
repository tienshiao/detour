import XCTest
@testable import Detour

/// TASK-289: the toss that carries a created or saved space's emoji from the
/// editor's tile into its switcher button. Geometry from a real run: a
/// 228 × 1092 pt sidebar (unflipped), the tile near the top left, the button
/// in the bottom bar.
nonisolated final class SpaceFlightPathTests: XCTestCase {

    private let sidebar = CGRect(x: 0, y: 0, width: 228, height: 1092)
    private let tile = CGPoint(x: 41, y: 976)
    private let button = CGPoint(x: 134, y: 17)

    private func speeds(_ points: [CGPoint]) -> [Double] {
        zip(points, points.dropFirst()).map { Double(hypot($1.x - $0.x, $1.y - $0.y)) }
    }

    @MainActor func testItStartsAtTheTileAndLandsOnTheButton() {
        let toss = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false)
        XCTAssertEqual(toss.points.first, tile)
        XCTAssertEqual(toss.points.last, button)
    }

    @MainActor func testItHopsUpBeforeFalling() {
        let toss = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false)
        let top = toss.points.map(\.y).max()!
        XCTAssertEqual(Double(top - tile.y), SpaceFlightPath.defaultHop, accuracy: 2)
        XCTAssertGreaterThan(toss.apexTime, 0)
        XCTAssertLessThan(toss.apexTime, toss.duration / 3)
    }

    @MainActor func testItSpeedsUpAsItFalls() {
        let toss = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false)
        let apexStep = Int((toss.apexTime / toss.duration * Double(toss.points.count - 1)).rounded())
        let falling = Array(speeds(Array(toss.points[apexStep...])).dropLast())
        // Each step after the hop covers more ground than the one before:
        // gravity, not an ease-out into the button.
        for (earlier, later) in zip(falling, falling.dropFirst()) {
            XCTAssertGreaterThan(later, earlier)
        }
    }

    @MainActor func testItsSidewaysSpeedIsConstant() {
        let toss = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false)
        let steps = zip(toss.points, toss.points.dropFirst()).map { Double($1.x - $0.x) }.dropLast()
        for step in steps {
            XCTAssertEqual(step, steps.first!, accuracy: 0.01)
        }
    }

    @MainActor func testASidebarTallFallTakesUnderASecond() {
        let toss = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false)
        XCTAssertGreaterThan(toss.duration, 0.45)
        XCTAssertLessThan(toss.duration, 0.8)
        XCTAssertGreaterThanOrEqual(toss.points.count, Int(toss.duration * 60))
    }

    @MainActor func testTheHopStaysBelowTheTopOfTheSidebar() {
        let nearTop = CGPoint(x: 41, y: 1070)
        let toss = SpaceFlightPath.toss(from: nearTop, to: button, in: sidebar, flipped: false)
        let top = toss.points.map(\.y).max()!
        XCTAssertLessThanOrEqual(Double(top), Double(sidebar.maxY) - SpaceFlightPath.margin + 0.5)
    }

    @MainActor func testAFlippedSpaceFallsTowardsLargerY() {
        let flippedTile = CGPoint(x: 41, y: 116)
        let flippedButton = CGPoint(x: 134, y: 1075)
        let toss = SpaceFlightPath.toss(from: flippedTile, to: flippedButton, in: sidebar, flipped: true)
        XCTAssertEqual(toss.points.first, flippedTile)
        XCTAssertEqual(toss.points.last, flippedButton)
        let highest = toss.points.map(\.y).min()!
        XCTAssertEqual(Double(flippedTile.y - highest), SpaceFlightPath.defaultHop, accuracy: 2, "up is -y")
        let unflipped = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false)
        XCTAssertEqual(toss.duration, unflipped.duration, accuracy: 0.02, "the same fall either way up")
    }

    @MainActor func testWithoutAHopItSimplyFalls() {
        let toss = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: 0)
        XCTAssertEqual(toss.apexTime, 0)
        XCTAssertEqual(toss.points.map(\.y).max(), tile.y, "never above the tile")
        let withHop = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: 50)
        XCTAssertLessThan(toss.duration, withHop.duration, "a fall from rest is quicker than a hop and a fall")
    }

    @MainActor func testStrongerGravityIsQuicker() {
        let normal = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false)
        let strong = SpaceFlightPath.toss(from: tile, to: button, in: sidebar, flipped: false, gravity: 9000)
        XCTAssertLessThan(strong.duration, normal.duration)
    }

    @MainActor func testATargetAboveTheTileStillArrives() {
        let toss = SpaceFlightPath.toss(from: button, to: tile, in: sidebar, flipped: false)
        XCTAssertEqual(toss.points.last, tile)
        XCTAssertGreaterThanOrEqual(toss.duration, 0.25)
    }
}
