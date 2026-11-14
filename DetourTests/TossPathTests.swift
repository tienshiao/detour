import XCTest
@testable import Detour

/// TASK-289 / TASK-324: the toss that carries a space's emoji into its
/// switcher button and a download's icon into the Downloads button. Geometry from a real run: a
/// 228 × 1092 pt sidebar (unflipped), the tile near the top left, the button
/// in the bottom bar.
nonisolated final class TossPathTests: XCTestCase {

    private let sidebar = CGRect(x: 0, y: 0, width: 228, height: 1092)
    private let tile = CGPoint(x: 41, y: 976)
    private let button = CGPoint(x: 134, y: 17)

    private func speeds(_ points: [CGPoint]) -> [Double] {
        zip(points, points.dropFirst()).map { Double(hypot($1.x - $0.x, $1.y - $0.y)) }
    }

    @MainActor func testItStartsAtTheTileAndLandsOnTheButton() {
        let toss = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: SpaceCelebration.hop)
        XCTAssertEqual(toss.points.first, tile)
        XCTAssertEqual(toss.points.last, button)
    }

    @MainActor func testItHopsUpBeforeFalling() {
        let toss = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: SpaceCelebration.hop)
        let top = toss.points.map(\.y).max()!
        XCTAssertEqual(Double(top - tile.y), SpaceCelebration.hop, accuracy: 2)
        XCTAssertGreaterThan(toss.apexTime, 0)
        XCTAssertLessThan(toss.apexTime, toss.duration / 3)
    }

    @MainActor func testItSpeedsUpAsItFalls() {
        let toss = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: SpaceCelebration.hop)
        let apexStep = Int((toss.apexTime / toss.duration * Double(toss.points.count - 1)).rounded())
        let falling = Array(speeds(Array(toss.points[apexStep...])).dropLast())
        // Each step after the hop covers more ground than the one before:
        // gravity, not an ease-out into the button.
        for (earlier, later) in zip(falling, falling.dropFirst()) {
            XCTAssertGreaterThan(later, earlier)
        }
    }

    @MainActor func testItsSidewaysSpeedIsConstant() {
        let toss = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: SpaceCelebration.hop)
        let steps = zip(toss.points, toss.points.dropFirst()).map { Double($1.x - $0.x) }.dropLast()
        for step in steps {
            XCTAssertEqual(step, steps.first!, accuracy: 0.01)
        }
    }

    @MainActor func testASidebarTallFallTakesUnderASecond() {
        let toss = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: SpaceCelebration.hop)
        XCTAssertGreaterThan(toss.duration, 0.45)
        XCTAssertLessThan(toss.duration, 0.8)
        XCTAssertGreaterThanOrEqual(toss.points.count, Int(toss.duration * 60))
    }

    @MainActor func testTheHopStaysBelowTheTopOfTheSidebar() {
        let nearTop = CGPoint(x: 41, y: 1070)
        let toss = TossPath.toss(from: nearTop, to: button, in: sidebar, flipped: false, hop: SpaceCelebration.hop)
        let top = toss.points.map(\.y).max()!
        XCTAssertLessThanOrEqual(Double(top), Double(sidebar.maxY) - TossPath.margin + 0.5)
    }

    @MainActor func testAFlippedSpaceFallsTowardsLargerY() {
        let flippedTile = CGPoint(x: 41, y: 116)
        let flippedButton = CGPoint(x: 134, y: 1075)
        let toss = TossPath.toss(from: flippedTile, to: flippedButton, in: sidebar, flipped: true, hop: SpaceCelebration.hop)
        XCTAssertEqual(toss.points.first, flippedTile)
        XCTAssertEqual(toss.points.last, flippedButton)
        let highest = toss.points.map(\.y).min()!
        XCTAssertEqual(Double(flippedTile.y - highest), SpaceCelebration.hop, accuracy: 2, "up is -y")
        let unflipped = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: SpaceCelebration.hop)
        XCTAssertEqual(toss.duration, unflipped.duration, accuracy: 0.02, "the same fall either way up")
    }

    @MainActor func testWithoutAHopItSimplyFalls() {
        let toss = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: 0)
        XCTAssertEqual(toss.apexTime, 0)
        XCTAssertEqual(toss.points.map(\.y).max(), tile.y, "never above the tile")
        let withHop = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: 50)
        XCTAssertLessThan(toss.duration, withHop.duration, "a fall from rest is quicker than a hop and a fall")
    }

    @MainActor func testStrongerGravityIsQuicker() {
        let normal = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: SpaceCelebration.hop)
        let strong = TossPath.toss(from: tile, to: button, in: sidebar, flipped: false, hop: SpaceCelebration.hop, gravity: 9000)
        XCTAssertLessThan(strong.duration, normal.duration)
    }

    @MainActor func testALevelThrowArcsForItsMinimumDuration() {
        // A download clicked level with the Downloads button: no drop at all.
        let start = CGPoint(x: 900, y: 40), end = CGPoint(x: 20, y: 40)
        let wide = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let toss = TossPath.toss(from: start, to: end, in: wide, flipped: false, hop: 0, minimumDuration: 0.5)
        XCTAssertEqual(toss.duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(toss.points.last, end)
        let top = toss.points.map(\.y).max()!
        XCTAssertGreaterThan(top, start.y + 100, "it arcs up instead of darting sideways")
        XCTAssertEqual(toss.apexTime, 0.25, accuracy: 0.01, "a level throw peaks halfway")
        // The step before landing is close to the end: no jump onto it.
        let last = toss.points[toss.points.count - 2]
        XCTAssertLessThan(Double(hypot(end.x - last.x, end.y - last.y)), 60)
    }

    @MainActor func testATargetAboveTheTileStillArrives() {
        let toss = TossPath.toss(from: button, to: tile, in: sidebar, flipped: false, hop: SpaceCelebration.hop)
        XCTAssertEqual(toss.points.last, tile)
        XCTAssertGreaterThanOrEqual(toss.duration, 0.25)
    }
}
