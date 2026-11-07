import XCTest
@testable import Detour

/// The pure tab group rules in TabGroup.swift (TASK-132.10): where a block
/// entering the tab list lands, which group it joins, the snap out of group
/// interiors, the load-time sanitizer and the default colour.
nonisolated final class TabGroupPlacementTests: XCTestCase {

    private let g = UUID()
    private let h = UUID()
    private let split = UUID()

    /// Slots from a compact spec: each element is (tab group, split group).
    @MainActor private func slots(_ spec: [(UUID?, UUID?)]) -> [TabSlot] {
        spec.map { TabSlot(splitGroupID: $0.1, tabGroupID: $0.0) }
    }

    // MARK: - byPosition

    @MainActor func testABlockLandingBetweenTwoMembersJoinsTheirGroup() {
        let list = slots([(nil, nil), (g, nil), (g, nil), (nil, nil)])
        XCTAssertEqual(tabGroupPlacement(gap: 2, slots: list, intent: .byPosition(preferring: nil)),
                       TabGroupPlacement(insertAt: 2, tabGroupID: g))
        XCTAssertEqual(tabGroupPlacement(gap: 2, slots: list, intent: .byPosition(preferring: h)),
                       TabGroupPlacement(insertAt: 2, tabGroupID: g), "the neighbours win over a preference")
    }

    @MainActor func testABlockAtAGroupsEdgeStaysOutUnlessItPrefersThatGroup() {
        let list = slots([(nil, nil), (g, nil), (g, nil), (nil, nil)])
        for gap in [1, 3] {
            XCTAssertEqual(tabGroupPlacement(gap: gap, slots: list, intent: .byPosition(preferring: nil)).tabGroupID,
                           nil, "gap \(gap) without a preference")
            XCTAssertEqual(tabGroupPlacement(gap: gap, slots: list, intent: .byPosition(preferring: g)).tabGroupID,
                           g, "gap \(gap) preferring the group next to it")
        }
    }

    @MainActor func testAPreferenceIsDroppedAwayFromTheGroup() {
        let list = slots([(g, nil), (g, nil), (nil, nil), (nil, nil)])
        XCTAssertEqual(tabGroupPlacement(gap: 3, slots: list, intent: .byPosition(preferring: g)),
                       TabGroupPlacement(insertAt: 3, tabGroupID: nil))
        // Between two groups, a block keeps the one it prefers.
        let two = slots([(g, nil), (h, nil)])
        XCTAssertEqual(tabGroupPlacement(gap: 1, slots: two, intent: .byPosition(preferring: h)).tabGroupID, h)
        XCTAssertEqual(tabGroupPlacement(gap: 1, slots: two, intent: .byPosition(preferring: nil)).tabGroupID, nil)
    }

    @MainActor func testAGapInsideASplitSnapsPastItBeforeTheNeighboursAreRead() {
        // A split at the group's right end: the gap between its panes snaps to
        // the group's edge, outside it.
        let list = slots([(g, nil), (g, split), (g, split), (nil, nil)])
        XCTAssertEqual(tabGroupPlacement(gap: 2, slots: list, intent: .byPosition(preferring: nil)),
                       TabGroupPlacement(insertAt: 3, tabGroupID: nil))
        // In the middle of the group it stays inside.
        let middle = slots([(g, split), (g, split), (g, nil)])
        XCTAssertEqual(tabGroupPlacement(gap: 1, slots: middle, intent: .byPosition(preferring: nil)),
                       TabGroupPlacement(insertAt: 2, tabGroupID: g))
    }

    @MainActor func testTheGapIsClampedToTheList() {
        let list = slots([(g, nil)])
        XCTAssertEqual(tabGroupPlacement(gap: 9, slots: list, intent: .byPosition(preferring: nil)),
                       TabGroupPlacement(insertAt: 1, tabGroupID: nil))
        XCTAssertEqual(tabGroupPlacement(gap: -3, slots: list, intent: .byPosition(preferring: g)),
                       TabGroupPlacement(insertAt: 0, tabGroupID: g))
        XCTAssertEqual(tabGroupPlacement(gap: 0, slots: [], intent: .byPosition(preferring: g)),
                       TabGroupPlacement(insertAt: 0, tabGroupID: nil))
    }

    // MARK: - rejoin

    @MainActor func testRejoinClampsTheGapIntoTheGroup() {
        let list = slots([(nil, nil), (nil, nil), (g, nil), (g, nil), (nil, nil), (nil, nil)])
        XCTAssertEqual(tabGroupPlacement(gap: 0, slots: list, intent: .rejoin(g)),
                       TabGroupPlacement(insertAt: 2, tabGroupID: g), "before the group: its left edge")
        XCTAssertEqual(tabGroupPlacement(gap: 6, slots: list, intent: .rejoin(g)),
                       TabGroupPlacement(insertAt: 4, tabGroupID: g), "after the group: its right edge")
        XCTAssertEqual(tabGroupPlacement(gap: 3, slots: list, intent: .rejoin(g)),
                       TabGroupPlacement(insertAt: 3, tabGroupID: g), "inside: where it was")
    }

    @MainActor func testRejoinNeverLandsInsideASplitOfTheGroup() {
        let list = slots([(g, split), (g, split)])
        XCTAssertEqual(tabGroupPlacement(gap: 1, slots: list, intent: .rejoin(g)),
                       TabGroupPlacement(insertAt: 2, tabGroupID: g))
    }

    @MainActor func testRejoiningAGroupWithNoMembersCarriesIt() {
        let list = slots([(h, nil), (h, nil)])
        XCTAssertEqual(tabGroupPlacement(gap: 1, slots: list, intent: .rejoin(g)),
                       TabGroupPlacement(insertAt: 2, tabGroupID: g), "snapped out of the other group")
    }

    // MARK: - carry

    @MainActor func testAWholeGroupSnapsOutOfAnotherGroupsInterior() {
        let list = slots([(nil, nil), (h, nil), (h, nil), (h, nil), (nil, nil)])
        XCTAssertEqual(tabGroupPlacement(gap: 2, slots: list, intent: .carry(g)),
                       TabGroupPlacement(insertAt: 4, tabGroupID: g))
        XCTAssertEqual(tabGroupPlacement(gap: 1, slots: list, intent: .carry(g)),
                       TabGroupPlacement(insertAt: 1, tabGroupID: g), "an edge is not an interior")
        XCTAssertEqual(snappedOutOfTabGroups(3, slots: list), 4)
    }

    @MainActor func testCarrySnapsOutOfASplitInsideAnotherGroup() {
        let list = slots([(h, split), (h, split), (h, nil)])
        XCTAssertEqual(snappedOutOfTabGroups(1, slots: list), 3)
    }

    @MainActor func testTheRangeOfAGroup() {
        let list = slots([(nil, nil), (g, nil), (g, nil), (nil, nil)])
        XCTAssertEqual(tabGroupRange(of: g, in: list), 1..<3)
        XCTAssertNil(tabGroupRange(of: h, in: list))
    }

    // MARK: - sanitizer

    @MainActor func testTheSanitizerClearsIdsOfUnknownGroups() {
        let list = slots([(g, nil), (h, nil)])
        XCTAssertEqual(sanitizedTabGroupIDs(list, knownGroupIDs: [g]), [g, nil])
    }

    @MainActor func testTheSanitizerGivesASplitPairItsLeftPanesGroup() {
        let list = slots([(g, split), (nil, split), (nil, nil)])
        XCTAssertEqual(sanitizedTabGroupIDs(list, knownGroupIDs: [g]), [g, g, nil])
        let other = slots([(nil, split), (g, split)])
        XCTAssertEqual(sanitizedTabGroupIDs(other, knownGroupIDs: [g]), [nil, nil])
    }

    @MainActor func testTheSanitizerKeepsOnlyTheFirstRunOfAGroup() {
        let list = slots([(g, nil), (g, nil), (nil, nil), (g, nil), (h, nil), (g, nil)])
        XCTAssertEqual(sanitizedTabGroupIDs(list, knownGroupIDs: [g, h]), [g, g, nil, nil, h, nil])
    }

    @MainActor func testAValidListIsLeftAsItIs() {
        let list = slots([(nil, nil), (g, split), (g, split), (g, nil), (h, nil)])
        XCTAssertEqual(sanitizedTabGroupIDs(list, knownGroupIDs: [g, h]), [nil, g, g, g, h])
    }

    // MARK: - colour

    @MainActor func testANewGroupGetsTheLeastUsedColourInChromesOrder() {
        XCTAssertEqual(TabGroupColor.next(after: []), .grey)
        XCTAssertEqual(TabGroupColor.next(after: [.grey]), .blue)
        XCTAssertEqual(TabGroupColor.next(after: [.grey, .red]), .blue)
        XCTAssertEqual(TabGroupColor.next(after: TabGroupColor.allCases), .grey)
        XCTAssertEqual(TabGroupColor.next(after: TabGroupColor.allCases + [.grey]), .blue)
    }

    @MainActor func testTheColourNamesAreChromes() {
        XCTAssertEqual(TabGroupColor.allCases.map(\.rawValue),
                       ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"])
    }
}
