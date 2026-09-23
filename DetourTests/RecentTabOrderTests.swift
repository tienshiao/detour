import XCTest
@testable import Detour

/// Control+Tab switcher ordering and highlight movement (TASK-108).
final class RecentTabOrderTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func candidate(_ ids: UUID..., leftAt offset: TimeInterval?) -> RecentTabCandidate {
        RecentTabCandidate(tabIDs: ids, lastLeftAt: offset.map { t0.addingTimeInterval($0) })
    }

    // MARK: - Order

    func testCurrentFirstThenMostRecentlyLeft() {
        let a = UUID(), b = UUID(), c = UUID()
        let old = candidate(a, leftAt: 10)
        let current = candidate(b, leftAt: nil)
        let recent = candidate(c, leftAt: 20)

        XCTAssertEqual(recentTabOrder([old, current, recent], selectedTabID: b), [current, recent, old])
    }

    func testTabsNotVisitedThisSessionAreLeftOut() {
        let a = UUID(), b = UUID(), c = UUID()
        let current = candidate(a, leftAt: nil)
        let visited = candidate(b, leftAt: 5)
        let neverVisited = candidate(c, leftAt: nil)

        XCTAssertEqual(recentTabOrder([neverVisited, visited, current], selectedTabID: a), [current, visited])
    }

    func testCurrentIsFirstEvenWithAnOlderLeaveStamp() {
        // Re-selecting a tab stamps it as left; it is still the current item.
        let a = UUID(), b = UUID()
        let current = candidate(a, leftAt: 1)
        let other = candidate(b, leftAt: 50)

        XCTAssertEqual(recentTabOrder([other, current], selectedTabID: a), [current, other])
    }

    func testEitherSplitPaneMakesTheSplitCurrent() {
        let left = UUID(), right = UUID(), other = UUID()
        let split = candidate(left, right, leftAt: nil)
        let lone = candidate(other, leftAt: 3)

        XCTAssertEqual(recentTabOrder([lone, split], selectedTabID: right), [split, lone])
    }

    func testNoSelectionListsOnlyVisitedItems() {
        let a = UUID(), b = UUID()
        let visited = candidate(a, leftAt: 3)
        let neverVisited = candidate(b, leftAt: nil)

        XCTAssertEqual(recentTabOrder([neverVisited, visited], selectedTabID: nil), [visited])
    }

    // MARK: - Highlight

    func testNothingToSwitchToWithFewerThanTwoItems() {
        XCTAssertNil(RecentTabSwitcherState(count: 0, backward: false))
        XCTAssertNil(RecentTabSwitcherState(count: 1, backward: true))
    }

    func testForwardStartsOnThePreviousTabAndBackwardOnTheOldest() {
        XCTAssertEqual(RecentTabSwitcherState(count: 4, backward: false)?.index, 1)
        XCTAssertEqual(RecentTabSwitcherState(count: 4, backward: true)?.index, 3)
    }

    func testAdvanceWrapsBothWays() {
        var state = RecentTabSwitcherState(count: 3, backward: false)!
        state.advance(backward: false)
        XCTAssertEqual(state.index, 2)
        state.advance(backward: false)
        XCTAssertEqual(state.index, 0)
        state.advance(backward: true)
        XCTAssertEqual(state.index, 2)
    }

    func testHighlightIgnoresOutOfRangeIndices() {
        var state = RecentTabSwitcherState(count: 3, backward: false)!
        state.highlight(2)
        XCTAssertEqual(state.index, 2)
        state.highlight(5)
        state.highlight(-1)
        XCTAssertEqual(state.index, 2)
    }

    func testWithoutACurrentItemForwardStartsOnTheMostRecentTab() {
        XCTAssertEqual(RecentTabSwitcherState(count: 1, backward: false, hasCurrent: false)?.index, 0)
        XCTAssertEqual(RecentTabSwitcherState(count: 3, backward: false, hasCurrent: false)?.index, 0)
        XCTAssertEqual(RecentTabSwitcherState(count: 3, backward: true, hasCurrent: false)?.index, 2)
        XCTAssertNil(RecentTabSwitcherState(count: 0, backward: false, hasCurrent: false))
    }
}
