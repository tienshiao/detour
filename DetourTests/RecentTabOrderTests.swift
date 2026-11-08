import XCTest
@testable import Detour

/// Control+Tab switcher ordering and highlight movement (TASK-108).
nonisolated final class RecentTabOrderTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    @MainActor private func candidate(_ ids: UUID..., leftAt offset: TimeInterval?) -> RecentTabCandidate {
        RecentTabCandidate(tabIDs: ids, lastLeftAt: offset.map { t0.addingTimeInterval($0) })
    }

    // MARK: - Order

    @MainActor func testCurrentFirstThenMostRecentlyLeft() {
        let a = UUID(), b = UUID(), c = UUID()
        let old = candidate(a, leftAt: 10)
        let current = candidate(b, leftAt: nil)
        let recent = candidate(c, leftAt: 20)

        XCTAssertEqual(recentTabOrder([old, current, recent], selectedTabID: b), [current, recent, old])
    }

    @MainActor func testTabsNotVisitedThisSessionAreLeftOut() {
        let a = UUID(), b = UUID(), c = UUID()
        let current = candidate(a, leftAt: nil)
        let visited = candidate(b, leftAt: 5)
        let neverVisited = candidate(c, leftAt: nil)

        XCTAssertEqual(recentTabOrder([neverVisited, visited, current], selectedTabID: a), [current, visited])
    }

    @MainActor func testCurrentIsFirstEvenWithAnOlderLeaveStamp() {
        // Re-selecting a tab stamps it as left; it is still the current item.
        let a = UUID(), b = UUID()
        let current = candidate(a, leftAt: 1)
        let other = candidate(b, leftAt: 50)

        XCTAssertEqual(recentTabOrder([other, current], selectedTabID: a), [current, other])
    }

    @MainActor func testEitherSplitPaneMakesTheSplitCurrent() {
        let left = UUID(), right = UUID(), other = UUID()
        let split = candidate(left, right, leftAt: nil)
        let lone = candidate(other, leftAt: 3)

        XCTAssertEqual(recentTabOrder([lone, split], selectedTabID: right), [split, lone])
    }

    @MainActor func testNoSelectionListsOnlyVisitedItems() {
        let a = UUID(), b = UUID()
        let visited = candidate(a, leftAt: 3)
        let neverVisited = candidate(b, leftAt: nil)

        XCTAssertEqual(recentTabOrder([neverVisited, visited], selectedTabID: nil), [visited])
    }

    // MARK: - Highlight

    @MainActor func testNothingToSwitchToWithFewerThanTwoItems() {
        XCTAssertNil(RecentTabSwitcherState(count: 0, backward: false))
        XCTAssertNil(RecentTabSwitcherState(count: 1, backward: true))
    }

    @MainActor func testForwardStartsOnThePreviousTabAndBackwardOnTheOldest() {
        XCTAssertEqual(RecentTabSwitcherState(count: 4, backward: false)?.index, 1)
        XCTAssertEqual(RecentTabSwitcherState(count: 4, backward: true)?.index, 3)
    }

    @MainActor func testAdvanceWrapsBothWays() {
        var state = RecentTabSwitcherState(count: 3, backward: false)!
        state.advance(backward: false)
        XCTAssertEqual(state.index, 2)
        state.advance(backward: false)
        XCTAssertEqual(state.index, 0)
        state.advance(backward: true)
        XCTAssertEqual(state.index, 2)
    }

    @MainActor func testHighlightIgnoresOutOfRangeIndices() {
        var state = RecentTabSwitcherState(count: 3, backward: false)!
        state.highlight(2)
        XCTAssertEqual(state.index, 2)
        state.highlight(5)
        state.highlight(-1)
        XCTAssertEqual(state.index, 2)
    }

    @MainActor func testWithoutACurrentItemForwardStartsOnTheMostRecentTab() {
        XCTAssertEqual(RecentTabSwitcherState(count: 1, backward: false, hasCurrent: false)?.index, 0)
        XCTAssertEqual(RecentTabSwitcherState(count: 3, backward: false, hasCurrent: false)?.index, 0)
        XCTAssertEqual(RecentTabSwitcherState(count: 3, backward: true, hasCurrent: false)?.index, 2)
        XCTAssertNil(RecentTabSwitcherState(count: 0, backward: false, hasCurrent: false))
    }

    // MARK: - Control+W (TASK-308)

    @MainActor func testClosingTheHighlightMovesToTheNextCard() {
        var state = RecentTabSwitcherState(count: 4, backward: false)!   // index 1
        XCTAssertTrue(state.removeHighlighted(hasCurrent: true))
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(state.index, 1, "the card after the closed one slides into its place")
    }

    @MainActor func testClosingTheLastCardWrapsToTheFirst() {
        var state = RecentTabSwitcherState(count: 3, backward: true)!    // index 2
        XCTAssertTrue(state.removeHighlighted(hasCurrent: false))
        XCTAssertEqual(state.index, 0)
    }

    @MainActor func testTheSwitcherEndsWhenNothingIsLeftToSwitchTo() {
        var withCurrent = RecentTabSwitcherState(count: 2, backward: false)!
        XCTAssertFalse(withCurrent.removeHighlighted(hasCurrent: true),
                       "only the current card is left")
        var current = RecentTabSwitcherState(count: 2, backward: false)!
        current.highlight(0)
        XCTAssertTrue(current.removeHighlighted(hasCurrent: false),
                      "the current card closed: the other one can still be chosen")
        var last = RecentTabSwitcherState(count: 1, backward: false, hasCurrent: false)!
        XCTAssertFalse(last.removeHighlighted(hasCurrent: false), "the last card closed")
    }

    @MainActor func testALoneNormalTabCloses() {
        let id = UUID()
        XCTAssertEqual(recentTabCloseAction(card: [id], members: [id: .normal(splitGroupID: nil)]), .closeTab(id))
    }

    @MainActor func testASplitCardClosesItsWholeGroup() {
        let (left, right, group) = (UUID(), UUID(), UUID())
        XCTAssertEqual(recentTabCloseAction(card: [left, right],
                                            members: [left: .normal(splitGroupID: group),
                                                      right: .normal(splitGroupID: group)]),
                       .closeSplitGroup(group))
    }

    @MainActor func testAPinnedCardGoesDormant() {
        let (tab, entry) = (UUID(), UUID())
        XCTAssertEqual(recentTabCloseAction(card: [tab], members: [tab: .pinned(entryID: entry)]),
                       .makePinnedDormant(entryIDs: [entry]))
    }

    @MainActor func testAPinnedSplitCardPutsBothEntriesToSleep() {
        let (left, right, leftEntry, rightEntry) = (UUID(), UUID(), UUID(), UUID())
        XCTAssertEqual(recentTabCloseAction(card: [left, right],
                                            members: [left: .pinned(entryID: leftEntry),
                                                      right: .pinned(entryID: rightEntry)]),
                       .makePinnedDormant(entryIDs: [leftEntry, rightEntry]))
    }

    @MainActor func testAFavoriteIsDeactivated() {
        let (tab, favorite) = (UUID(), UUID())
        XCTAssertEqual(recentTabCloseAction(card: [tab], members: [tab: .favorite(favoriteID: favorite)]),
                       .deactivateFavorite(favorite))
    }

    @MainActor func testACardWithAGoneOrMismatchedTabClosesNothing() {
        let (a, b, group) = (UUID(), UUID(), UUID())
        XCTAssertNil(recentTabCloseAction(card: [a], members: [:]), "closed since it was listed")
        XCTAssertNil(recentTabCloseAction(card: [a, b], members: [a: .normal(splitGroupID: group)]))
        XCTAssertNil(recentTabCloseAction(card: [a, b], members: [a: .normal(splitGroupID: group),
                                                                b: .normal(splitGroupID: UUID())]))
        XCTAssertNil(recentTabCloseAction(card: [a, b], members: [a: .normal(splitGroupID: nil),
                                                                b: .normal(splitGroupID: nil)]))
        XCTAssertNil(recentTabCloseAction(card: [a, b], members: [a: .pinned(entryID: UUID()),
                                                                b: .normal(splitGroupID: group)]))
    }
}
