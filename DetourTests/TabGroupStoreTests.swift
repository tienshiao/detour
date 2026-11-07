import XCTest
import GRDB
@testable import Detour

/// Tab groups in `TabStore` (TASK-132.10): the group API, how every other tab
/// mutation keeps the invariants (contiguous members, a split pair wholly in
/// or out, only normal tabs, no empty group), undo, the observer callbacks,
/// and persistence. The pure placement rules are in `TabGroupPlacementTests`.
nonisolated final class TabGroupStoreTests: XCTestCase {

    @MainActor private final class Recorder: TabStoreObserver {
        var events: [String] = []
        func tabStoreDidCreateTabGroup(_ group: TabGroup, in space: Space) { events.append("create \(group.title)") }
        func tabStoreDidUpdateTabGroup(_ group: TabGroup, in space: Space) { events.append("update \(group.title)") }
        func tabStoreDidRemoveTabGroup(_ group: TabGroup, in space: Space) { events.append("remove \(group.title)") }
        func tabStoreDidMoveTabGroup(_ group: TabGroup, in space: Space) { events.append("move \(group.title)") }
        func tabStoreDidChangeTabGroupMembership(of tabs: [BrowserTab]) {
            events.append("membership " + tabs.map(\.title).joined(separator: ","))
        }
        func tabStoreDidReorderTabs(in space: Space) { events.append("reorder") }
        func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) { events.append("insert \(tab.title)") }
        func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) { events.append("removeTab \(tab.title)") }
    }

    private struct Fixture {
        let db: AppDatabase
        let store: TabStore
        let profile: Profile
        let space: Space
        let other: Space
        let recorder: Recorder
    }

    /// A private store, two spaces of one profile, manual undo grouping: an
    /// undo group is open for the setup steps, and `act` gives the step under
    /// test a group of its own.
    @MainActor private func makeFixture(queue: DatabaseQueue? = nil) throws -> Fixture {
        let db = try AppDatabase(dbQueue: queue ?? DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Groups")
        let space = store.addSpace(name: "A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let other = store.addSpace(name: "B", emoji: "🅱️", colorHex: "FF9500", profileID: profile.id)
        store.undoManager.removeAllActions()
        store.undoManager.groupsByEvent = false
        store.undoManager.beginUndoGrouping()
        let recorder = Recorder()
        store.addObserver(recorder)
        return Fixture(db: db, store: store, profile: profile, space: space, other: other, recorder: recorder)
    }

    /// Runs the step under test in an undo group of its own and leaves no
    /// group open, so `undo` takes back exactly that step. Setup steps after
    /// it must not register undos.
    @MainActor private func act(_ f: Fixture, _ body: () throws -> Void) rethrows {
        let undoManager = f.store.undoManager
        if undoManager.groupingLevel > 0 { undoManager.endUndoGrouping() }
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        try body()
    }

    @MainActor private func undo(_ f: Fixture) {
        if f.store.undoManager.groupingLevel > 0 { f.store.undoManager.endUndoGrouping() }
        f.store.undoManager.undo()
    }

    @MainActor private func redo(_ f: Fixture) {
        if f.store.undoManager.groupingLevel > 0 { f.store.undoManager.endUndoGrouping() }
        f.store.undoManager.redo()
    }

    @MainActor private func makeTab(_ title: String, in space: Space) -> BrowserTab {
        BrowserTab(id: UUID(), title: title, url: URL(string: "https://example.com/\(title)"), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: space.id)
    }

    /// Appends sleeping tabs named by `titles` to the space, as a restored session would.
    @discardableResult
    @MainActor private func addTabs(_ titles: String, to space: Space) -> [BrowserTab] {
        let tabs = titles.map { makeTab(String($0), in: space) }
        space.tabs.append(contentsOf: tabs)
        return tabs
    }

    @MainActor private func tab(_ title: String, in space: Space) -> BrowserTab {
        space.tabs.first { $0.title == title }!
    }

    @MainActor private func ids(_ titles: String, in space: Space) -> [UUID] {
        titles.map { tab(String($0), in: space).id }
    }

    /// The list as "A B [C D] E", a bracket per group, its title after it
    /// when not empty ("[C D]x").
    @MainActor private func layout(_ space: Space) -> String {
        var parts: [String] = []
        var current: UUID?
        for tab in space.tabs {
            if tab.tabGroupID != current {
                if let current, let last = parts.indices.last {
                    parts[last] += "]" + (space.tabGroup(id: current)?.title ?? "?")
                }
                current = tab.tabGroupID
                parts.append((tab.tabGroupID == nil ? "" : "[") + tab.title)
            } else {
                parts.append(tab.title)
            }
        }
        if let current, let last = parts.indices.last {
            parts[last] += "]" + (space.tabGroup(id: current)?.title ?? "?")
        }
        return parts.joined(separator: " ")
    }

    /// Every group has a member, every member's group exists, members are
    /// contiguous, split pairs share a group, and no pinned or favourite tab
    /// carries an id.
    @MainActor private func assertInvariants(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        for space in [f.space, f.other] {
            let known = Set(space.tabGroups.map(\.id))
            XCTAssertEqual(sanitizedTabGroupIDs(f.store.tabSlots(space.tabs), knownGroupIDs: known),
                           space.tabs.map(\.tabGroupID), "invariants hold in \(space.name)", file: file, line: line)
            XCTAssertEqual(Set(space.tabs.compactMap(\.tabGroupID)), known, "no empty group in \(space.name)",
                           file: file, line: line)
            XCTAssertTrue(space.pinnedTabs.allSatisfy { $0.tabGroupID == nil }, file: file, line: line)
        }
        XCTAssertTrue(f.profile.favorites.compactMap(\.tab).allSatisfy { $0.tabGroupID == nil }, file: file, line: line)
    }

    // MARK: - createTabGroup

    @MainActor func testANewGroupGathersItsTabsWhereTheFirstOfThemIs() throws {
        let f = try makeFixture()
        addTabs("ABCDE", to: f.space)

        let group = try f.store.createTabGroup(tabIDs: ids("DB", in: f.space), title: "g", in: f.space)

        XCTAssertEqual(layout(f.space), "A [B D]g C E")
        XCTAssertEqual(group.color, .grey)
        XCTAssertEqual(f.space.tabGroups.map(\.id), [group.id])
        XCTAssertEqual(f.recorder.events, ["create g", "reorder", "membership B,D"])
        assertInvariants(f)
    }

    @MainActor func testANewGroupTakesTheLeastUsedColour() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        _ = try f.store.createTabGroup(tabIDs: ids("A", in: f.space), in: f.space)
        let second = try f.store.createTabGroup(tabIDs: ids("B", in: f.space), in: f.space)
        let chosen = try f.store.createTabGroup(tabIDs: ids("C", in: f.space), color: .orange, in: f.space)
        XCTAssertEqual(second.color, .blue)
        XCTAssertEqual(chosen.color, .orange)
    }

    @MainActor func testGroupingASplitPaneBringsItsPartner() throws {
        let f = try makeFixture()
        addTabs("ABCD", to: f.space)
        f.store.createSplit(draggedTabID: tab("C", in: f.space).id, targetTabID: tab("B", in: f.space).id,
                            edge: .right, in: f.space)

        try f.store.createTabGroup(tabIDs: ids("C", in: f.space), title: "g", in: f.space)

        XCTAssertEqual(layout(f.space), "A [B C]g D")
        assertInvariants(f)
    }

    @MainActor func testGroupingAPinnedTabOrAFavouriteOrAnUnknownIdIsRefusedAndChangesNothing() throws {
        let f = try makeFixture()
        addTabs("ABCD", to: f.space)
        let pinned = tab("C", in: f.space)
        f.store.pinTab(id: pinned.id, in: f.space)
        let favourite = tab("D", in: f.space)
        XCTAssertTrue(f.store.moveTabToFavorites(id: favourite.id, from: f.space, profileID: f.profile.id))
        let elsewhere = addTabs("X", to: f.other)[0]
        let unknown = UUID()
        f.recorder.events = []

        XCTAssertThrowsError(try f.store.createTabGroup(tabIDs: [tab("A", in: f.space).id, pinned.id], in: f.space)) {
            XCTAssertEqual($0 as? TabGroupError, .tabNotGroupable(pinned.id))
        }
        XCTAssertThrowsError(try f.store.createTabGroup(tabIDs: [favourite.id], in: f.space)) {
            XCTAssertEqual($0 as? TabGroupError, .tabNotGroupable(favourite.id))
        }
        XCTAssertThrowsError(try f.store.createTabGroup(tabIDs: [elsewhere.id], in: f.space)) {
            XCTAssertEqual($0 as? TabGroupError, .tabNotFound(elsewhere.id))
        }
        XCTAssertThrowsError(try f.store.createTabGroup(tabIDs: [unknown], in: f.space)) {
            XCTAssertEqual($0 as? TabGroupError, .tabNotFound(unknown))
        }
        XCTAssertThrowsError(try f.store.createTabGroup(tabIDs: [], in: f.space)) {
            XCTAssertEqual($0 as? TabGroupError, .noTabs)
        }

        XCTAssertEqual(layout(f.space), "A B")
        XCTAssertTrue(f.space.tabGroups.isEmpty)
        XCTAssertEqual(f.recorder.events, [])
    }

    @MainActor func testANewGroupStartingInsideAnotherLandsPastIt() throws {
        let f = try makeFixture()
        addTabs("ABCDE", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("BCD", in: f.space), title: "g", in: f.space)

        try f.store.createTabGroup(tabIDs: ids("CE", in: f.space), title: "h", in: f.space)

        XCTAssertEqual(layout(f.space), "A [B D]g [C E]h")
        assertInvariants(f)
    }

    @MainActor func testTakingAGroupsLastTabIntoANewGroupRemovesTheOldOne() throws {
        let f = try makeFixture()
        addTabs("AB", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", in: f.space)
        f.recorder.events = []

        try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "h", in: f.space)

        XCTAssertEqual(layout(f.space), "[A]h B")
        XCTAssertEqual(f.space.tabGroups.map(\.title), ["h"])
        XCTAssertEqual(f.recorder.events, ["create h", "membership A", "remove g"])
    }

    // MARK: - addTabs / ungroupTabs

    @MainActor func testJoiningTabsGoToTheEdgeOnTheirSide() throws {
        let f = try makeFixture()
        addTabs("ABCDEF", to: f.space)
        let group = try f.store.createTabGroup(tabIDs: ids("CD", in: f.space), title: "g", in: f.space)

        try f.store.addTabs(ids("FA", in: f.space), toTabGroup: group.id, in: f.space)

        XCTAssertEqual(layout(f.space), "B [A C D F]g E")
        assertInvariants(f)
    }

    @MainActor func testAddingToAnUnknownGroupIsRefused() throws {
        let f = try makeFixture()
        addTabs("AB", to: f.space)
        let unknown = UUID()
        XCTAssertThrowsError(try f.store.addTabs(ids("A", in: f.space), toTabGroup: unknown, in: f.space)) {
            XCTAssertEqual($0 as? TabGroupError, .groupNotFound(unknown))
        }
        XCTAssertThrowsError(try f.store.updateTabGroup(unknown, title: "x", in: f.space))
        XCTAssertThrowsError(try f.store.moveTabGroup(unknown, to: 0, in: f.space))
        XCTAssertEqual(layout(f.space), "A B")
    }

    @MainActor func testUngroupingMovesAMiddleTabPastTheGroupAndLeavesEdgeTabsInPlace() throws {
        let f = try makeFixture()
        addTabs("ABCDEF", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("BCDE", in: f.space), title: "g", in: f.space)
        f.recorder.events = []

        try f.store.ungroupTabs(ids("C", in: f.space), in: f.space)
        XCTAssertEqual(layout(f.space), "A [B D E]g C F")
        XCTAssertEqual(f.recorder.events, ["reorder", "membership C"])

        try f.store.ungroupTabs(ids("B", in: f.space), in: f.space)
        XCTAssertEqual(layout(f.space), "A B [D E]g C F", "the left edge stays")
        try f.store.ungroupTabs(ids("E", in: f.space), in: f.space)
        XCTAssertEqual(layout(f.space), "A B [D]g E C F", "the right edge stays")
        assertInvariants(f)
    }

    @MainActor func testUngroupingEveryMemberRemovesTheGroupAfterTheMembership() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)
        f.recorder.events = []

        try f.store.ungroupTabs(ids("BAC", in: f.space), in: f.space)

        XCTAssertEqual(layout(f.space), "A B C")
        XCTAssertTrue(f.space.tabGroups.isEmpty)
        XCTAssertEqual(f.recorder.events, ["membership A,B", "remove g"])
    }

    // MARK: - updateTabGroup / moveTabGroup

    @MainActor func testTheGroupsTitleColourAndCollapsedStateChange() throws {
        let f = try makeFixture()
        addTabs("A", to: f.space)
        let group = try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", in: f.space)
        f.recorder.events = []

        try f.store.updateTabGroup(group.id, title: "work", color: .cyan, isCollapsed: true, in: f.space)
        try f.store.updateTabGroup(group.id, title: "work", in: f.space)

        XCTAssertEqual(group.title, "work")
        XCTAssertEqual(group.color, .cyan)
        XCTAssertTrue(group.isCollapsed)
        XCTAssertEqual(f.recorder.events, ["update work"], "an update that changes nothing is not reported")
    }

    @MainActor func testAGroupMovesAsABlockAndSnapsPastAnotherGroup() throws {
        let f = try makeFixture()
        addTabs("ABCDEF", to: f.space)
        let g = try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)
        try f.store.createTabGroup(tabIDs: ids("DE", in: f.space), title: "h", in: f.space)
        f.recorder.events = []

        try f.store.moveTabGroup(g.id, to: 2, in: f.space)  // between D and E

        XCTAssertEqual(layout(f.space), "C [D E]h [A B]g F")
        XCTAssertEqual(f.recorder.events, ["reorder", "move g"])
        try f.store.moveTabGroup(g.id, to: 99, in: f.space)
        XCTAssertEqual(layout(f.space), "C [D E]h F [A B]g")
        assertInvariants(f)
    }

    // MARK: - Every other mutation (AC #3)

    @MainActor func testClosingAMemberLeavesTheGroupAndClosingTheLastRemovesIt() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)
        f.recorder.events = []

        f.store.closeTab(id: tab("A", in: f.space).id, in: f.space)
        XCTAssertEqual(layout(f.space), "[B]g C")
        XCTAssertEqual(f.recorder.events, ["removeTab A"], "a closed tab reports only its removal")

        f.store.closeTab(id: tab("B", in: f.space).id, in: f.space, archivedAt: Date())
        XCTAssertEqual(layout(f.space), "C")
        XCTAssertTrue(f.space.tabGroups.isEmpty)
        XCTAssertEqual(f.recorder.events, ["removeTab A", "removeTab B", "remove g"])
    }

    @MainActor func testPinningAMemberUngroupsIt() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)
        let a = tab("A", in: f.space)
        f.recorder.events = []

        f.store.pinTab(id: a.id, in: f.space)

        XCTAssertNil(a.tabGroupID)
        XCTAssertEqual(layout(f.space), "[B]g C")
        XCTAssertEqual(f.recorder.events.last, "membership A")
        assertInvariants(f)
    }

    @MainActor func testPinningASplitInAGroupUngroupsBothPanes() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        f.store.createSplit(draggedTabID: tab("B", in: f.space).id, targetTabID: tab("A", in: f.space).id,
                            edge: .right, in: f.space)
        try f.store.createTabGroup(tabIDs: ids("AC", in: f.space), title: "g", in: f.space)
        let splitID = try XCTUnwrap(tab("A", in: f.space).splitGroupID)

        f.store.pinSplitGroup(groupID: splitID, in: f.space)

        XCTAssertEqual(layout(f.space), "[C]g")
        assertInvariants(f)
    }

    @MainActor func testMakingAMemberAFavouriteUngroupsIt() throws {
        let f = try makeFixture()
        addTabs("AB", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)
        let b = tab("B", in: f.space)

        XCTAssertTrue(f.store.moveTabToFavorites(id: b.id, from: f.space, profileID: f.profile.id))

        XCTAssertNil(b.tabGroupID)
        XCTAssertEqual(layout(f.space), "[A]g")
        assertInvariants(f)
    }

    @MainActor func testAnUnpinnedTabJoinsAGroupOnlyBetweenTwoMembers() throws {
        let f = try makeFixture()
        addTabs("ABCPQ", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)
        let p = tab("P", in: f.space)
        let q = tab("Q", in: f.space)
        f.store.pinTab(id: p.id, in: f.space)
        f.store.pinTab(id: q.id, in: f.space)
        XCTAssertEqual(layout(f.space), "[A B]g C")
        f.recorder.events = []

        XCTAssertTrue(f.store.unpinTab(id: p.id, in: f.space, at: 1))  // between A and B
        XCTAssertEqual(layout(f.space), "[A P B]g C")
        XCTAssertEqual(f.recorder.events.last, "membership P")

        XCTAssertTrue(f.store.unpinTab(id: q.id, in: f.space, at: 3))  // at the group's edge
        XCTAssertEqual(layout(f.space), "[A P B]g Q C", "an outsider at the edge stays out")
        assertInvariants(f)
    }

    @MainActor func testAFavouriteRestoredBetweenTwoMembersJoinsTheGroup() throws {
        let f = try makeFixture()
        addTabs("ABF", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)
        let fav = tab("F", in: f.space)
        XCTAssertTrue(f.store.moveTabToFavorites(id: fav.id, from: f.space, profileID: f.profile.id))
        let favoriteID = try XCTUnwrap(f.profile.favorites.first { $0.tab === fav }?.id)
        f.recorder.events = []

        XCTAssertTrue(f.store.restoreFavoriteAsTab(id: favoriteID, profileID: f.profile.id, in: f.space, at: 1))

        XCTAssertEqual(layout(f.space), "[A F B]g")
        XCTAssertFalse(f.recorder.events.contains { $0.hasPrefix("membership") },
                       "its insertion carries the group")
        assertInvariants(f)
    }

    @MainActor func testMovingTheLastMemberToAnotherSpaceRemovesTheGroupAndTheUndoBringsItBack() throws {
        let f = try makeFixture()
        addTabs("AB", to: f.space)
        addTabs("XY", to: f.other)
        let group = try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", color: .pink, in: f.space)
        let a = tab("A", in: f.space)

        try act(f) { XCTAssertTrue(f.store.moveTab(id: a.id, from: f.space, to: f.other, at: 1)) }

        XCTAssertEqual(layout(f.space), "B")
        XCTAssertEqual(layout(f.other), "X A Y")
        XCTAssertTrue(f.space.tabGroups.isEmpty)
        assertInvariants(f)

        undo(f)

        XCTAssertEqual(layout(f.space), "[A]g B")
        XCTAssertEqual(f.space.tabGroups.map(\.id), [group.id])
        XCTAssertEqual(f.space.tabGroups.first?.color, .pink)
        assertInvariants(f)
    }

    @MainActor func testAMoveToAnotherSpaceBetweenTwoMembersJoinsThatGroup() throws {
        let f = try makeFixture()
        addTabs("A", to: f.space)
        addTabs("XYZ", to: f.other)
        try f.store.createTabGroup(tabIDs: ids("XY", in: f.other), title: "h", in: f.other)

        XCTAssertTrue(f.store.moveTab(id: tab("A", in: f.space).id, from: f.space, to: f.other, at: 1))

        XCTAssertEqual(layout(f.other), "[X A Y]h Z")
        assertInvariants(f)
    }

    // MARK: - Moves within the space

    @MainActor func testATabDroppedBetweenTwoMembersJoinsAndOneDraggedPastTheEdgeLeaves() throws {
        let f = try makeFixture()
        addTabs("ABCDE", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("BCD", in: f.space), title: "g", in: f.space)

        f.store.moveTab(id: tab("A", in: f.space).id, toGapIndex: 2, in: f.space)  // between B and C
        XCTAssertEqual(layout(f.space), "[B A C D]g E")

        f.store.moveTab(id: tab("B", in: f.space).id, toGapIndex: 5, in: f.space)  // after E
        XCTAssertEqual(layout(f.space), "[A C D]g E B")

        f.store.moveTab(id: tab("E", in: f.space).id, toGapIndex: 3, in: f.space)  // to the group's edge
        XCTAssertEqual(layout(f.space), "[A C D]g E B", "an outsider at the edge stays out")

        f.store.moveTab(id: tab("D", in: f.space).id, toGapIndex: 0, in: f.space)  // to the other edge
        XCTAssertEqual(layout(f.space), "[D A C]g E B", "a member moved to its group's edge stays in")
        assertInvariants(f)
    }

    @MainActor func testMovingAGroupsOnlyMemberCarriesTheGroupPastAnother() throws {
        let f = try makeFixture()
        addTabs("ABCD", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", in: f.space)
        try f.store.createTabGroup(tabIDs: ids("BC", in: f.space), title: "h", in: f.space)

        f.recorder.events = []
        f.store.moveTab(id: tab("A", in: f.space).id, toGapIndex: 2, in: f.space)  // between B and C

        XCTAssertEqual(layout(f.space), "[B C]h [A]g D")
        XCTAssertEqual(f.recorder.events, ["reorder", "move g"], "a carried group reports its move")
        assertInvariants(f)
    }

    @MainActor func testUndoingAMoveOutOfAGroupPutsTheTabBackIn() throws {
        let f = try makeFixture()
        addTabs("ABCD", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("ABC", in: f.space), title: "g", in: f.space)

        try act(f) { f.store.moveTab(id: tab("C", in: f.space).id, toGapIndex: 4, in: f.space) }
        XCTAssertEqual(layout(f.space), "[A B]g D C")

        undo(f)
        XCTAssertEqual(layout(f.space), "[A B C]g D")

        redo(f)
        XCTAssertEqual(layout(f.space), "[A B]g D C")
        assertInvariants(f)
    }

    @MainActor func testAWholeSplitMovesIntoAGroupAndBackOut() throws {
        let f = try makeFixture()
        addTabs("ABCDE", to: f.space)
        f.store.createSplit(draggedTabID: tab("D", in: f.space).id, targetTabID: tab("C", in: f.space).id,
                            edge: .right, in: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)

        f.store.moveTab(id: tab("D", in: f.space).id, toGapIndex: 1, in: f.space)
        XCTAssertEqual(layout(f.space), "[A C D B]g E")

        f.store.moveTab(id: tab("C", in: f.space).id, toGapIndex: 5, in: f.space)  // after E
        XCTAssertEqual(layout(f.space), "[A B]g E C D")
        assertInvariants(f)
    }

    // MARK: - Splits and groups

    @MainActor func testASplitTakesTheTargetsGroupAndItsUndoRestoresTheDraggedTabsGroup() throws {
        let f = try makeFixture()
        addTabs("ABCD", to: f.space)
        let g = try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", in: f.space)
        try f.store.createTabGroup(tabIDs: ids("CD", in: f.space), title: "h", in: f.space)

        try act(f) {
            f.store.createSplit(draggedTabID: tab("A", in: f.space).id, targetTabID: tab("C", in: f.space).id,
                                edge: .left, in: f.space)
        }
        XCTAssertEqual(layout(f.space), "B [A C D]h")
        XCTAssertNil(f.space.tabGroup(id: g.id), "the dragged tab's emptied group is removed")
        assertInvariants(f)

        undo(f)
        XCTAssertEqual(layout(f.space), "[A]g B [C D]h")
        assertInvariants(f)
    }

    @MainActor func testOptionClickingAGroupedTabPutsTheNewPaneInTheGroup() throws {
        let f = try makeFixture()
        addTabs("AB", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", in: f.space)
        let anchor = tab("A", in: f.space)

        let pane = try XCTUnwrap(f.store.addTabInSplit(with: anchor.id, url: URL(string: "about:blank")!,
                                                       in: f.space))

        XCTAssertEqual(pane.tabGroupID, anchor.tabGroupID)
        assertInvariants(f)
    }

    @MainActor func testAPaneDraggedOutOfAGroupedSplitKeepsTheGroupOnlyNextToAMember() throws {
        let f = try makeFixture()
        addTabs("ABCD", to: f.space)
        f.store.createSplit(draggedTabID: tab("B", in: f.space).id, targetTabID: tab("A", in: f.space).id,
                            edge: .right, in: f.space)
        try f.store.createTabGroup(tabIDs: ids("AC", in: f.space), title: "g", in: f.space)
        XCTAssertEqual(layout(f.space), "[A B C]g D")

        f.store.removeTabFromSplit(tabID: tab("B", in: f.space).id, toGapIndex: 3, in: f.space)  // after C
        XCTAssertEqual(layout(f.space), "[A C B]g D", "next to a member it stays in")
        XCTAssertNil(tab("A", in: f.space).splitGroupID)
        assertInvariants(f)

        f.store.createSplit(draggedTabID: tab("B", in: f.space).id, targetTabID: tab("A", in: f.space).id,
                            edge: .right, in: f.space)
        f.store.removeTabFromSplit(tabID: tab("B", in: f.space).id, toGapIndex: 4, in: f.space)  // after D
        XCTAssertEqual(layout(f.space), "[A C]g D B")
        assertInvariants(f)
    }

    @MainActor func testUndoingSeparateTabsDoesNotRejoinPanesInDifferentGroups() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        f.store.createSplit(draggedTabID: tab("B", in: f.space).id, targetTabID: tab("A", in: f.space).id,
                            edge: .right, in: f.space)
        try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", in: f.space)
        let splitID = try XCTUnwrap(tab("A", in: f.space).splitGroupID)

        try act(f) { f.store.separateSplit(groupID: splitID, in: f.space) }
        try f.store.ungroupTabs(ids("B", in: f.space), in: f.space)
        XCTAssertEqual(layout(f.space), "[A]g B C")

        undo(f)

        XCTAssertNil(tab("A", in: f.space).splitGroupID, "a split pair shares one group")
        XCTAssertNil(tab("B", in: f.space).splitGroupID)
        assertInvariants(f)
    }

    // MARK: - Opened tabs (user decision a)

    @MainActor func testATabOpenedFromAGroupedTabJoinsItsGroup() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)
        let child = makeTab("N", in: f.space)

        f.store.insertTab(child, in: f.space, parentID: tab("B", in: f.space).id)

        XCTAssertEqual(layout(f.space), "[A B N]g C")
        assertInvariants(f)
    }

    @MainActor func testATabOpenedFromAnUngroupedTabNextToAGroupStaysOut() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("BC", in: f.space), title: "g", in: f.space)

        f.store.insertTab(makeTab("N", in: f.space), in: f.space, parentID: tab("A", in: f.space).id)

        XCTAssertEqual(layout(f.space), "A N [B C]g")
    }

    // MARK: - Undo of a close (AC #4, user decision b)

    @MainActor func testUndoingACloseRejoinsTheGroupClampedIntoItsCurrentRange() throws {
        let f = try makeFixture()
        addTabs("ABCD", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)

        try act(f) { f.store.closeTab(id: tab("A", in: f.space).id, in: f.space) }
        // The group moves away from where A was.
        try f.store.moveTabGroup(try XCTUnwrap(f.space.tabGroups.first).id, to: 99, in: f.space)
        XCTAssertEqual(layout(f.space), "C D [B]g")

        undo(f)

        XCTAssertEqual(layout(f.space), "C D [A B]g")
        assertInvariants(f)
    }

    @MainActor func testUndoingTheCloseOfAGroupsLastTabBringsTheGroupBack() throws {
        let f = try makeFixture()
        addTabs("AB", to: f.space)
        let group = try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", color: .green, in: f.space)
        try f.store.updateTabGroup(group.id, isCollapsed: true, in: f.space)

        try act(f) { f.store.closeTab(id: tab("A", in: f.space).id, in: f.space) }
        XCTAssertTrue(f.space.tabGroups.isEmpty)
        f.recorder.events = []

        undo(f)

        XCTAssertEqual(layout(f.space), "[A]g B")
        let restored = try XCTUnwrap(f.space.tabGroups.first)
        XCTAssertEqual(restored.id, group.id)
        XCTAssertEqual(restored.color, .green)
        XCTAssertTrue(restored.isCollapsed)
        XCTAssertEqual(f.recorder.events, ["create g", "insert A"],
                       "the group comes back with its tab already in it")
        assertInvariants(f)
    }

    @MainActor func testUndoingCloseBothSplitsBringsThePairBackIntoItsGroup() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        f.store.createSplit(draggedTabID: tab("B", in: f.space).id, targetTabID: tab("A", in: f.space).id,
                            edge: .right, in: f.space)
        try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", in: f.space)
        let splitID = try XCTUnwrap(tab("A", in: f.space).splitGroupID)

        try act(f) { f.store.closeSplitGroup(groupID: splitID, in: f.space) }
        XCTAssertEqual(layout(f.space), "C")
        XCTAssertTrue(f.space.tabGroups.isEmpty)

        undo(f)

        XCTAssertEqual(layout(f.space), "[A B]g C")
        XCTAssertNotNil(tab("A", in: f.space).splitGroupID)
        assertInvariants(f)
    }

    @MainActor func testUndoingAPinPutsTheTabBackIntoItsGroupEvenOneThePinRemoved() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        let group = try f.store.createTabGroup(tabIDs: ids("B", in: f.space), title: "g", color: .red, in: f.space)
        let b = tab("B", in: f.space)

        try act(f) { f.store.pinTab(id: b.id, in: f.space) }
        XCTAssertTrue(f.space.tabGroups.isEmpty)
        f.recorder.events = []

        undo(f)

        XCTAssertEqual(layout(f.space), "A [B]g C")
        XCTAssertEqual(f.space.tabGroups.map(\.id), [group.id])
        XCTAssertEqual(f.space.tabGroups.first?.color, .red)
        XCTAssertEqual(f.recorder.events.filter { $0.hasPrefix("create") || $0.hasPrefix("membership") },
                       ["create g", "membership B"])
        assertInvariants(f)
    }

    @MainActor func testUndoingPinSplitPutsThePairBackIntoItsGroup() throws {
        let f = try makeFixture()
        addTabs("ABCD", to: f.space)
        f.store.createSplit(draggedTabID: tab("C", in: f.space).id, targetTabID: tab("B", in: f.space).id,
                            edge: .right, in: f.space)
        try f.store.createTabGroup(tabIDs: ids("BD", in: f.space), title: "g", in: f.space)
        XCTAssertEqual(layout(f.space), "A [B C D]g")
        let splitID = try XCTUnwrap(tab("B", in: f.space).splitGroupID)

        try act(f) { f.store.pinSplitGroup(groupID: splitID, in: f.space) }
        XCTAssertEqual(layout(f.space), "A [D]g")

        undo(f)

        XCTAssertEqual(layout(f.space), "A [B C D]g")
        assertInvariants(f)
    }

    // MARK: - Undo Delete Space

    @MainActor func testUndoDeleteSpaceBringsTheGroupsBack() throws {
        let f = try makeFixture()
        addTabs("ABC", to: f.space)
        let group = try f.store.createTabGroup(tabIDs: ids("BC", in: f.space), title: "g", in: f.space)

        try act(f) { XCTAssertEqual(f.store.deleteSpace(id: f.space.id), .deleted) }
        XCTAssertTrue(f.space.tabGroups.isEmpty)
        XCTAssertTrue(f.recorder.events.contains("remove g"))

        undo(f)

        XCTAssertEqual(layout(f.space), "A [B C]g")
        XCTAssertEqual(f.space.tabGroups.map(\.id), [group.id])
    }

    // MARK: - Persistence (AC #5)

    @MainActor func testGroupsAndMembershipSurviveARelaunch() throws {
        let queue = try DatabaseQueue()
        let f = try makeFixture(queue: queue)
        addTabs("ABCD", to: f.space)
        let g = try f.store.createTabGroup(tabIDs: ids("BC", in: f.space), title: "work", color: .purple,
                                           isCollapsed: true, in: f.space)
        let h = try f.store.createTabGroup(tabIDs: ids("D", in: f.space), title: "h", in: f.space)
        XCTAssertEqual(f.store.saveNow(), .saved)

        let relaunched = TabStore(appDB: try AppDatabase(dbQueue: queue))
        _ = relaunched.restoreSession()
        let space = try XCTUnwrap(relaunched.space(withID: f.space.id))

        XCTAssertEqual(layout(space), "A [B C]work [D]h")
        XCTAssertEqual(space.tabGroups.map(\.id), [g.id, h.id])
        XCTAssertEqual(space.tabGroups.first?.color, .purple)
        XCTAssertEqual(space.tabGroups.first?.isCollapsed, true)
    }

    @MainActor func testADanglingOrSplitRunAtLoadIsCleared() throws {
        let queue = try DatabaseQueue()
        let f = try makeFixture(queue: queue)
        addTabs("ABCD", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("AB", in: f.space), title: "g", in: f.space)
        XCTAssertEqual(f.store.saveNow(), .saved)
        let groupID = try XCTUnwrap(f.space.tabGroups.first).id.uuidString
        // D names the group too, out of the group's run, and C a group that does not exist.
        try queue.write { db in
            try db.execute(sql: "UPDATE tab SET tabGroupID = ? WHERE title = 'D'", arguments: [groupID])
            try db.execute(sql: "UPDATE tab SET tabGroupID = ? WHERE title = 'C'", arguments: [UUID().uuidString])
        }

        let relaunched = TabStore(appDB: try AppDatabase(dbQueue: queue))
        _ = relaunched.restoreSession()
        let space = try XCTUnwrap(relaunched.space(withID: f.space.id))

        XCTAssertEqual(layout(space), "[A B]g C D")
    }

    @MainActor func testADatabaseFromBeforeTheMigrationLoadsWithNoGroups() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v22")
        let spaceID = UUID().uuidString
        let profileID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Old')", arguments: [profileID])
            try db.execute(sql: """
                INSERT INTO space (id, name, emoji, colorHex, sortOrder, profileID) VALUES (?, 'Old', '🗂', '007AFF', 0, ?)
                """, arguments: [spaceID, profileID])
            for (order, title) in ["A", "B"].enumerated() {
                try db.execute(sql: "INSERT INTO tab (id, spaceID, url, title, sortOrder) VALUES (?, ?, ?, ?, ?)",
                               arguments: [UUID().uuidString, spaceID, "https://example.com/\(title)", title, order])
            }
        }
        XCTAssertFalse(try queue.read { try $0.tableExists("tabGroup") })

        let store = TabStore(appDB: try AppDatabase(dbQueue: queue))
        _ = store.restoreSession()
        let space = try XCTUnwrap(store.space(withID: UUID(uuidString: spaceID)!))

        XCTAssertEqual(layout(space), "A B")
        XCTAssertTrue(space.tabGroups.isEmpty)
        XCTAssertTrue(try queue.read { try $0.tableExists("tabGroup") })
        XCTAssertTrue(try queue.read { try $0.columns(in: "tab").contains { $0.name == "tabGroupID" } })
    }

    @MainActor func testDeletingASpaceRowDeletesItsGroupRows() throws {
        let queue = try DatabaseQueue()
        let f = try makeFixture(queue: queue)
        addTabs("A", to: f.space)
        try f.store.createTabGroup(tabIDs: ids("A", in: f.space), title: "g", in: f.space)
        XCTAssertEqual(f.store.saveNow(), .saved)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tabGroup") }, 1)

        try act(f) { XCTAssertEqual(f.store.deleteSpace(id: f.space.id), .deleted) }
        XCTAssertEqual(f.store.saveNow(), .saved)

        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tabGroup") }, 0)
    }
}
