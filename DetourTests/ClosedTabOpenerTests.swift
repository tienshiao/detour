import XCTest
import GRDB
@testable import Detour

/// TASK-332: a closed child tab's record carries the tab it was opened from,
/// so Reopen Closed Tab (and the Archived Tabs page) bring it back closing to
/// its opener again — while that opener is still one the Back button resolves
/// (`Space.openerTab(id:)`), never as a dangling link.
nonisolated final class ClosedTabOpenerTests: XCTestCase {

    @MainActor private struct Fixture {
        let db: AppDatabase
        let store: TabStore
        let spaceA: Space
        let spaceB: Space
    }

    @MainActor private func makeFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Opener")
        let spaceA = store.addSpace(name: "A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let spaceB = store.addSpace(name: "B", emoji: "🅱️", colorHex: "FF3B30", profileID: profile.id)
        store.undoManager.removeAllActions()
        store.undoManager.groupsByEvent = false
        return Fixture(db: db, store: store, spaceA: spaceA, spaceB: spaceB)
    }

    @MainActor private func inUndoGroup(_ store: TabStore, _ body: () -> Void) {
        store.undoManager.beginUndoGrouping()
        body()
        store.undoManager.endUndoGrouping()
    }

    @MainActor private func makeTab(_ url: String, in space: Space, parent: BrowserTab? = nil) -> BrowserTab {
        let tab = BrowserTab(id: UUID(), title: url, url: URL(string: url), faviconURL: nil,
                             cachedInteractionState: nil, spaceID: space.id)
        tab.parentID = parent?.id
        return tab
    }

    /// An opener and a child opened from it, with a bystander so the space
    /// never empties.
    @MainActor private func addOpenerAndChild(in space: Space) -> (opener: BrowserTab, child: BrowserTab) {
        let opener = makeTab("https://opener.example/", in: space)
        let child = makeTab("https://child.example/", in: space, parent: opener)
        let other = makeTab("https://other.example/", in: space)
        space.tabs.append(contentsOf: [opener, child, other])
        return (opener, child)
    }

    @MainActor private func record(of tab: BrowserTab, _ db: AppDatabase) throws -> ClosedTabRecord {
        let summary = try XCTUnwrap(db.closedTabSummaries().first { $0.tabID == tab.id.uuidString })
        return try XCTUnwrap(db.closedTab(id: summary.id))
    }

    // MARK: - The record

    @MainActor func testClosingAChildRecordsItsOpener() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)

        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }

        XCTAssertEqual(try record(of: child, f.db).parentID, opener.id.uuidString)
    }

    @MainActor func testClosingARootTabRecordsNoOpener() throws {
        let f = try makeFixture()
        let (opener, _) = addOpenerAndChild(in: f.spaceA)

        inUndoGroup(f.store) { f.store.closeTab(id: opener.id, in: f.spaceA) }

        XCTAssertNil(try record(of: opener, f.db).parentID)
    }

    @MainActor func testArchivingAChildRecordsItsOpener() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)

        f.store.closeTab(id: child.id, in: f.spaceA, archivedAt: Date(), registersUndo: false)

        XCTAssertEqual(try record(of: child, f.db).parentID, opener.id.uuidString)
    }

    // MARK: - Reopen keeps a resolvable opener

    @MainActor func testReopenedChildClosesToItsOpenerAgain() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }

        let reopened = try XCTUnwrap(f.store.reopenClosedTab(in: f.spaceA))

        XCTAssertEqual(reopened.url?.absoluteString, "https://child.example/")
        XCTAssertEqual(reopened.parentID, opener.id)
        XCTAssertTrue(f.spaceA.openerTab(id: opener.id) === opener)
    }

    @MainActor func testArchivePageRestoreOfAnArchivedChildKeepsItsOpener() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        f.store.closeTab(id: child.id, in: f.spaceA, archivedAt: Date(), registersUndo: false)
        let recordID = try XCTUnwrap(record(of: child, f.db).id)

        let restored = try XCTUnwrap(f.store.restoreClosedTab(recordID: recordID))

        XCTAssertEqual(restored.parentID, opener.id)
    }

    @MainActor func testReopenedChildOfALivePinnedOpenerKeepsIt() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.pinTab(id: opener.id, in: f.spaceA) }
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }

        let reopened = try XCTUnwrap(f.store.reopenClosedTab(in: f.spaceA))

        XCTAssertEqual(reopened.parentID, opener.id, "a live pinned tab is an opener the Back button selects")
    }

    @MainActor func testSplitMembersReopenWithTheirOpeners() throws {
        let f = try makeFixture()
        let opener = makeTab("https://opener.example/", in: f.spaceA)
        let left = makeTab("https://left.example/", in: f.spaceA, parent: opener)
        let right = makeTab("https://right.example/", in: f.spaceA)
        let groupID = UUID()
        left.splitGroupID = groupID
        right.splitGroupID = groupID
        f.spaceA.tabs.append(contentsOf: [opener, left, right])

        inUndoGroup(f.store) { f.store.closeSplitGroup(groupID: groupID, in: f.spaceA) }

        XCTAssertEqual(try record(of: left, f.db).parentID, opener.id.uuidString)
        XCTAssertNil(try record(of: right, f.db).parentID)
        let reopened = [f.store.reopenClosedTab(in: f.spaceA), f.store.reopenClosedTab(in: f.spaceA)]
        let reopenedLeft = try XCTUnwrap(reopened.first { $0?.url?.absoluteString == "https://left.example/" } ?? nil)
        XCTAssertEqual(reopenedLeft.parentID, opener.id)
    }

    // MARK: - Reopen drops an opener that is gone

    @MainActor func testReopenedChildOfAClosedOpenerHasNone() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }
        inUndoGroup(f.store) { f.store.closeTab(id: opener.id, in: f.spaceA) }
        let childRecordID = try XCTUnwrap(record(of: child, f.db).id)

        let restored = try XCTUnwrap(f.store.restoreClosedTab(recordID: childRecordID))

        XCTAssertNil(restored.parentID)
    }

    /// Reopening the opener first does not bring the link back: a reopened tab
    /// is a new tab (a new id), not the one the child was opened from.
    @MainActor func testReopeningTheOpenerFirstDoesNotRelinkTheChild() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }
        inUndoGroup(f.store) { f.store.closeTab(id: opener.id, in: f.spaceA) }

        let reopenedOpener = try XCTUnwrap(f.store.reopenClosedTab(in: f.spaceA))
        let reopenedChild = try XCTUnwrap(f.store.reopenClosedTab(in: f.spaceA))

        XCTAssertEqual(reopenedOpener.url?.absoluteString, "https://opener.example/")
        XCTAssertNotEqual(reopenedOpener.id, opener.id)
        XCTAssertEqual(reopenedChild.url?.absoluteString, "https://child.example/")
        XCTAssertNil(reopenedChild.parentID)
    }

    @MainActor func testReopenedChildOfAnArchivedOpenerHasNone() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }
        f.store.closeTab(id: opener.id, in: f.spaceA, archivedAt: Date(), registersUndo: false)

        let reopened = try XCTUnwrap(f.store.reopenClosedTab(in: f.spaceA))

        XCTAssertEqual(reopened.url?.absoluteString, "https://child.example/")
        XCTAssertNil(reopened.parentID)
    }

    @MainActor func testReopenedChildOfAnOpenerMovedToAnotherSpaceHasNone() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }
        var moved = false
        inUndoGroup(f.store) { moved = f.store.moveTab(id: opener.id, from: f.spaceA, to: f.spaceB) }
        XCTAssertTrue(moved)

        let reopened = try XCTUnwrap(f.store.reopenClosedTab(in: f.spaceA))

        XCTAssertNil(reopened.parentID)
        XCTAssertTrue(f.spaceB.tabs.contains { $0.id == opener.id }, "precondition: the opener lives on, elsewhere")
    }

    @MainActor func testReopenedChildOfAnAsleepPinnedOpenerHasNone() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.pinTab(id: opener.id, in: f.spaceA) }
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }
        f.store.closePinnedTab(id: opener.id, in: f.spaceA, undoable: false)
        XCTAssertNil(f.spaceA.pinnedEntries.first { $0.id == opener.id }?.tab, "precondition: asleep")

        let reopened = try XCTUnwrap(f.store.reopenClosedTab(in: f.spaceA))

        XCTAssertNil(reopened.parentID, "the Back button would not resolve an asleep pinned entry")
    }

    /// A Private tab is never an opener of another space's tab. A record naming
    /// one (as a link to any other space's tab would) reopens unlinked.
    @MainActor func testReopenedChildWhoseOpenerIsInAPrivateSpaceHasNone() throws {
        let f = try makeFixture()
        let privateSpace = f.store.addIncognitoSpace()
        let privateTab = makeTab("https://private.example/", in: privateSpace)
        privateSpace.tabs.append(privateTab)
        f.spaceA.tabs.append(makeTab("https://keep.example/", in: f.spaceA))
        f.db.pushClosedTab(ClosedTabRecord(
            id: nil, tabID: UUID().uuidString, spaceID: f.spaceA.id.uuidString, url: "https://child.example/",
            title: "Child", faviconURL: nil, interactionState: nil, sortOrder: 0, archivedAt: nil,
            closedAt: 1_800_000_000, parentID: privateTab.id.uuidString))

        let reopened = try XCTUnwrap(f.store.reopenClosedTab(in: f.spaceA))

        XCTAssertNil(reopened.parentID)
        f.store.removeIncognitoSpace(id: privateSpace.id)
    }

    /// A Private space writes no record, so its children never reopen; the
    /// close undo restores the captured link while the opener is still open.
    @MainActor func testPrivateChildWritesNoRecordAndItsUndoKeepsTheOpener() throws {
        let f = try makeFixture()
        let privateSpace = f.store.addIncognitoSpace()
        let (opener, child) = addOpenerAndChild(in: privateSpace)

        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: privateSpace) }
        XCTAssertTrue(f.db.closedTabSummaries().isEmpty)
        f.store.undoManager.undo()

        let restored = try XCTUnwrap(privateSpace.tabs.first { $0.url?.absoluteString == "https://child.example/" })
        XCTAssertEqual(restored.parentID, opener.id)
        f.store.removeIncognitoSpace(id: privateSpace.id)
    }

    // MARK: - Undo Close Tab keeps the link only while the opener is open

    /// The user's decision (2026-11-14): a close undo filters the captured
    /// link through `Space.openerTab(id:)`, as Reopen Closed Tab does.
    @MainActor func testUndoCloseOfAChildWhoseOpenerIsStillOpenKeepsIt() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }

        f.store.undoManager.undo()

        let restored = try XCTUnwrap(f.spaceA.tabs.first { $0.url?.absoluteString == "https://child.example/" })
        XCTAssertEqual(restored.parentID, opener.id)
    }

    /// Close the child, then its opener, then undo both: the opener comes
    /// back as a new tab (a new id), so the child comes back unlinked rather
    /// than naming a tab that is gone.
    @MainActor func testUndoCloseOfAChildWhoseOpenerWasClosedSinceHasNone() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }
        inUndoGroup(f.store) { f.store.closeTab(id: opener.id, in: f.spaceA) }

        f.store.undoManager.undo()
        let restoredOpener = try XCTUnwrap(f.spaceA.tabs.first { $0.url?.absoluteString == "https://opener.example/" })
        XCTAssertNotEqual(restoredOpener.id, opener.id, "precondition: the opener is a new tab")
        f.store.undoManager.undo()

        let restored = try XCTUnwrap(f.spaceA.tabs.first { $0.url?.absoluteString == "https://child.example/" })
        XCTAssertNil(restored.parentID)
    }

    /// The opener closed for good (no undo of its own) before the child's
    /// close is undone.
    @MainActor func testUndoCloseOfAChildWhoseOpenerIsGoneHasNone() throws {
        let f = try makeFixture()
        let (opener, child) = addOpenerAndChild(in: f.spaceA)
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }
        f.store.closeTab(id: opener.id, in: f.spaceA, registersUndo: false)

        f.store.undoManager.undo()

        let restored = try XCTUnwrap(f.spaceA.tabs.first { $0.url?.absoluteString == "https://child.example/" })
        XCTAssertNil(restored.parentID)
    }

    /// Undo Close Both Splits: a member keeps its opener while it is open,
    /// and comes back unlinked once it has closed.
    @MainActor func testUndoCloseOfASplitKeepsOnlyAnOpenerStillOpen() throws {
        for openerCloses in [false, true] {
            let f = try makeFixture()
            let opener = makeTab("https://opener.example/", in: f.spaceA)
            let left = makeTab("https://left.example/", in: f.spaceA, parent: opener)
            // The right pane was opened from the left one.
            let right = makeTab("https://right.example/", in: f.spaceA, parent: left)
            let other = makeTab("https://other.example/", in: f.spaceA)
            let groupID = UUID()
            left.splitGroupID = groupID
            right.splitGroupID = groupID
            f.spaceA.tabs.append(contentsOf: [opener, left, right, other])

            inUndoGroup(f.store) { f.store.closeSplitGroup(groupID: groupID, in: f.spaceA) }
            if openerCloses { f.store.closeTab(id: opener.id, in: f.spaceA, registersUndo: false) }
            f.store.undoManager.undo()

            let restoredLeft = try XCTUnwrap(f.spaceA.tabs.first { $0.url?.absoluteString == "https://left.example/" })
            let restoredRight = try XCTUnwrap(f.spaceA.tabs.first { $0.url?.absoluteString == "https://right.example/" })
            XCTAssertNotNil(restoredLeft.splitGroupID, "precondition: the split came back")
            XCTAssertEqual(restoredLeft.parentID, openerCloses ? nil : opener.id, "opener closed: \(openerCloses)")
            XCTAssertNil(restoredRight.parentID, "its partner comes back as a new tab")
        }
    }

    /// The pinned cases of the same rule on the undo path: a live pinned
    /// opener is kept; an asleep one leaves no link.
    @MainActor func testUndoCloseOfAChildOfAPinnedOpenerKeepsItOnlyWhileLive() throws {
        enum Case: CaseIterable { case livePinned, asleepPinned }
        for c in Case.allCases {
            let f = try makeFixture()
            let (opener, child) = addOpenerAndChild(in: f.spaceA)
            inUndoGroup(f.store) { f.store.pinTab(id: opener.id, in: f.spaceA) }
            inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.spaceA) }
            if c == .asleepPinned { f.store.closePinnedTab(id: opener.id, in: f.spaceA, undoable: false) }

            f.store.undoManager.undo()

            let restored = try XCTUnwrap(f.spaceA.tabs.first { $0.url?.absoluteString == "https://child.example/" }, "\(c)")
            XCTAssertEqual(restored.parentID, c == .livePinned ? opener.id : nil, "\(c)")
        }
    }

    /// A Private close undo follows the same rule: an opener closed since
    /// leaves no link.
    @MainActor func testPrivateUndoCloseOfAChildWhoseOpenerIsGoneHasNone() throws {
        let f = try makeFixture()
        let privateSpace = f.store.addIncognitoSpace()
        let (opener, child) = addOpenerAndChild(in: privateSpace)
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: privateSpace) }
        f.store.closeTab(id: opener.id, in: privateSpace, registersUndo: false)

        f.store.undoManager.undo()

        let restored = try XCTUnwrap(privateSpace.tabs.first { $0.url?.absoluteString == "https://child.example/" })
        XCTAssertNil(restored.parentID)
        f.store.removeIncognitoSpace(id: privateSpace.id)
    }

    // MARK: - Records written before v26

    /// v26 adds `closedTab.parentID`; rows closed before it carry no opener and
    /// reopen as before, unlinked.
    @MainActor func testMigrationV26KeepsAV25DatabasesClosedTabs() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v25")
        let spaceID = UUID()
        try queue.write { d in
            try d.execute(sql: """
                INSERT INTO closedTab (tabID, spaceID, url, title, sortOrder, closedAt)
                VALUES ('\(UUID().uuidString)', '\(spaceID.uuidString)', 'https://old.example/', 'Old', 0, 1)
                """)
        }

        let db = try AppDatabase(dbQueue: queue)

        let summary = try XCTUnwrap(db.closedTabSummaries(spaceID: spaceID.uuidString).first)
        XCTAssertNil(db.closedTab(id: summary.id)?.parentID)
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Old")
        let space = store.addSpace(name: "Old", emoji: "📦", colorHex: "007AFF", profileID: profile.id)
        space.tabs.append(makeTab("https://keep.example/", in: space))
        // File the old row under the live space (the space ids of a v25
        // database are whatever its spaces were).
        try queue.write { d in
            try d.execute(sql: "UPDATE closedTab SET spaceID = ?", arguments: [space.id.uuidString])
        }

        let reopened = try XCTUnwrap(store.reopenClosedTab(in: space))

        XCTAssertEqual(reopened.url?.absoluteString, "https://old.example/")
        XCTAssertNil(reopened.parentID)
    }
}
