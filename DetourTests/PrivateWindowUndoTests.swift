import XCTest
import GRDB
import WebKit
@testable import Detour

/// TASK-357: `TabStore`'s one undo stack is app wide, so a Private window's
/// entries used to outlive the window. Before the fix, Undo Close Tab pressed
/// after the Private window closed rebuilt the closed Private tab live, with
/// a web view on the Private profile's store loading its page, into the
/// removed space that no window shows (and posted `.tabRestoredByUndo` for
/// it). Closing a Private window now drops every undo and redo entry acting in
/// its space, and leaves every other window's entries alone.
nonisolated final class PrivateWindowUndoTests: XCTestCase {

    @MainActor private struct Fixture {
        let store: TabStore
        let normal: Space
    }

    @MainActor private func makeFixture() throws -> Fixture {
        let store = TabStore(appDB: try AppDatabase(dbQueue: DatabaseQueue()))
        let profile = store.addProfile(name: "Normal")
        let normal = store.addSpace(name: "N", emoji: "N", colorHex: "007AFF", profileID: profile.id)
        normal.tabs.append(makeTab("https://keep.example/", in: normal))
        store.undoManager.removeAllActions()
        store.undoManager.groupsByEvent = false
        return Fixture(store: store, normal: normal)
    }

    @MainActor private func makeTab(_ url: String, in space: Space) -> BrowserTab {
        BrowserTab(id: UUID(), title: url, url: URL(string: url), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: space.id)
    }

    /// A Private window's space with a page to close and one to keep it from
    /// emptying.
    @MainActor private func addPrivateSpace(_ store: TabStore) -> (space: Space, page: BrowserTab) {
        let space = store.addIncognitoSpace()
        let page = makeTab("https://secret.example/", in: space)
        space.tabs.append(contentsOf: [page, makeTab("https://other-private.example/", in: space)])
        return (space, page)
    }

    @MainActor private func inUndoGroup(_ store: TabStore, _ body: () -> Void) {
        store.undoManager.beginUndoGrouping()
        body()
        store.undoManager.endUndoGrouping()
    }

    /// The ids of the spaces `.tabRestoredByUndo` named while `body` ran.
    @MainActor private func restoredSpaceIDs(during body: () -> Void) -> [UUID] {
        var ids: [UUID] = []
        let token = NotificationCenter.default.addObserver(forName: .tabRestoredByUndo, object: nil, queue: nil) { note in
            if let id = note.userInfo?["spaceID"] as? UUID { ids.append(id) }
        }
        body()
        NotificationCenter.default.removeObserver(token)
        return ids
    }

    @MainActor private func hasPage(_ host: String, in space: Space) -> Bool {
        space.tabs.contains { $0.url?.host == host }
    }

    // MARK: - The entries go with the window

    @MainActor func testClosingThePrivateWindowLeavesNoUndoOfItsClose() throws {
        let f = try makeFixture()
        let (priv, page) = addPrivateSpace(f.store)
        inUndoGroup(f.store) { f.store.closeTab(id: page.id, in: priv) }
        XCTAssertEqual(f.store.undoManager.undoActionName, "Close Tab", "precondition: the close is undoable while the window is open")

        f.store.removeIncognitoSpace(id: priv.id)

        XCTAssertFalse(f.store.undoManager.canUndo, "a closed Private window's close must not be undoable from another window")
        XCTAssertFalse(f.store.undoManager.canRedo)
        let restored = restoredSpaceIDs { f.store.undoManager.undo() }
        XCTAssertFalse(hasPage("secret.example", in: priv), "the Private tab must not come back into the removed space")
        XCTAssertTrue(restored.isEmpty)
    }

    @MainActor func testARedoOfThePrivateWindowsCloseGoesToo() throws {
        let f = try makeFixture()
        let (priv, page) = addPrivateSpace(f.store)
        inUndoGroup(f.store) { f.store.closeTab(id: page.id, in: priv) }
        f.store.undoManager.undo()
        XCTAssertTrue(hasPage("secret.example", in: priv))
        XCTAssertEqual(f.store.undoManager.redoActionName, "Close Tab", "precondition: the close can be redone")

        f.store.removeIncognitoSpace(id: priv.id)

        XCTAssertFalse(f.store.undoManager.canRedo)
        XCTAssertFalse(f.store.undoManager.canUndo)
    }

    /// Normal history below and above the Private window's entry survives:
    /// each Undo goes to the next normal action.
    @MainActor func testNormalWindowsKeepTheirUndoHistory() throws {
        let f = try makeFixture()
        let first = makeTab("https://normal-1.example/", in: f.normal)
        let second = makeTab("https://normal-2.example/", in: f.normal)
        f.normal.tabs.append(contentsOf: [first, second])
        inUndoGroup(f.store) { f.store.closeTab(id: first.id, in: f.normal) }
        let (priv, page) = addPrivateSpace(f.store)
        inUndoGroup(f.store) { f.store.closeTab(id: page.id, in: priv) }
        inUndoGroup(f.store) { f.store.closeTab(id: second.id, in: f.normal) }

        f.store.removeIncognitoSpace(id: priv.id)

        let restored = restoredSpaceIDs {
            f.store.undoManager.undo()
            XCTAssertTrue(hasPage("normal-2.example", in: f.normal))
            f.store.undoManager.undo()
            XCTAssertTrue(hasPage("normal-1.example", in: f.normal), "the Private entry between them must be skipped")
        }
        XCTAssertEqual(restored, [f.normal.id, f.normal.id])
        XCTAssertFalse(f.store.undoManager.canUndo)
        XCTAssertFalse(hasPage("secret.example", in: priv))
    }

    /// One group (one event) with a Private and a normal action: only the
    /// Private one goes.
    @MainActor func testAGroupMixingBothKeepsOnlyTheNormalAction() throws {
        let f = try makeFixture()
        let normalPage = makeTab("https://normal.example/", in: f.normal)
        f.normal.tabs.append(normalPage)
        let (priv, page) = addPrivateSpace(f.store)
        inUndoGroup(f.store) {
            f.store.closeTab(id: page.id, in: priv)
            f.store.closeTab(id: normalPage.id, in: f.normal)
        }

        f.store.removeIncognitoSpace(id: priv.id)
        f.store.undoManager.undo()

        XCTAssertTrue(hasPage("normal.example", in: f.normal))
        XCTAssertFalse(hasPage("secret.example", in: priv))
        XCTAssertFalse(f.store.undoManager.canUndo)
    }

    @MainActor func testAnotherPrivateWindowKeepsItsEntries() throws {
        let f = try makeFixture()
        let (closing, closingPage) = addPrivateSpace(f.store)
        let (staying, stayingPage) = addPrivateSpace(f.store)
        inUndoGroup(f.store) { f.store.closeTab(id: stayingPage.id, in: staying) }
        inUndoGroup(f.store) { f.store.closeTab(id: closingPage.id, in: closing) }

        f.store.removeIncognitoSpace(id: closing.id)

        XCTAssertEqual(f.store.undoManager.undoActionName, "Close Tab")
        f.store.undoManager.undo()
        XCTAssertTrue(hasPage("secret.example", in: staying), "the open Private window's close is still undoable")
        XCTAssertFalse(hasPage("secret.example", in: closing))
        XCTAssertFalse(f.store.undoManager.canUndo)
        f.store.removeIncognitoSpace(id: staying.id)
    }

    /// Every kind of entry acting in the space goes, not just closes.
    @MainActor func testEveryKindOfEntryInTheSpaceGoes() throws {
        let f = try makeFixture()
        let keeper = makeTab("https://normal.example/", in: f.normal)
        f.normal.tabs.append(keeper)
        inUndoGroup(f.store) { f.store.closeTab(id: keeper.id, in: f.normal) }
        let (priv, page) = addPrivateSpace(f.store)
        let third = makeTab("https://third.example/", in: priv)
        priv.tabs.append(third)
        inUndoGroup(f.store) { f.store.moveTab(from: 0, to: 2, in: priv) }
        inUndoGroup(f.store) {
            f.store.createSplit(draggedTabID: third.id, targetTabID: page.id, edge: .right, in: priv)
        }
        inUndoGroup(f.store) { f.store.pinTab(id: page.id, in: priv) }
        inUndoGroup(f.store) { _ = f.store.addPinnedFolder(name: "Folder", in: priv) }
        inUndoGroup(f.store) { f.store.recordClosedPeek(self.makeTab("https://peek.example/", in: priv), host: third, in: priv) }
        XCTAssertEqual(f.store.undoManager.undoActionName, "Close Peek", "precondition: the Private actions are on the stack")

        f.store.removeIncognitoSpace(id: priv.id)

        XCTAssertEqual(f.store.undoManager.undoActionName, "Close Tab", "only the normal window's close is left")
        f.store.undoManager.undo()
        XCTAssertTrue(hasPage("normal.example", in: f.normal))
        XCTAssertFalse(f.store.undoManager.canUndo)
    }

    /// A Move to Space between two Private windows acts in both: either
    /// window closing drops it.
    @MainActor func testAMoveBetweenPrivateWindowsGoesWithEitherWindow() throws {
        let f = try makeFixture()
        let (from, page) = addPrivateSpace(f.store)
        let (to, _) = addPrivateSpace(f.store)
        inUndoGroup(f.store) { XCTAssertTrue(f.store.moveTab(id: page.id, from: from, to: to)) }
        XCTAssertEqual(f.store.undoManager.undoActionName, "Move to Space")

        f.store.removeIncognitoSpace(id: to.id)

        XCTAssertFalse(f.store.undoManager.canUndo)
        f.store.removeIncognitoSpace(id: from.id)
    }

    /// Nothing still holds the closed window's space once its entries are gone.
    @MainActor func testTheRemovedSpaceIsReleased() throws {
        let f = try makeFixture()
        weak var released: Space?
        try autoreleasepool {
            let (priv, page) = addPrivateSpace(f.store)
            released = priv
            inUndoGroup(f.store) { f.store.closeTab(id: page.id, in: priv) }
            XCTAssertTrue(f.store.undoManager.canUndo)
            f.store.removeIncognitoSpace(id: priv.id)
            _ = try XCTUnwrap(released)
        }
        XCTAssertNil(released, "no undo entry may keep the closed Private window's space")
    }

    // MARK: - Guards

    /// A registration for a Private space already gone is refused, and does
    /// not rename the entry below it.
    @MainActor func testNoEntryIsRegisteredForAGonePrivateSpace() throws {
        let f = try makeFixture()
        let (priv, _) = addPrivateSpace(f.store)
        f.store.removeIncognitoSpace(id: priv.id)
        let late = makeTab("https://late.example/", in: priv)
        priv.tabs.append(late)

        inUndoGroup(f.store) { f.store.closeTab(id: late.id, in: priv) }

        // The group itself stays (an empty group counts for UndoManager), but
        // it holds nothing: no name, and undoing it brings nothing back.
        XCTAssertEqual(f.store.undoManager.undoActionName, "")
        let restored = restoredSpaceIDs { f.store.undoManager.undo() }
        XCTAssertFalse(hasPage("late.example", in: priv))
        XCTAssertTrue(restored.isEmpty)
    }

    /// The window closes in the same event that registered a Private action:
    /// the group is still open, so the entry cannot leave the stack yet. It
    /// does nothing in the meantime and goes once the group is closed.
    @MainActor func testAnEntryInTheOpenGroupGoesOnceTheGroupCloses() throws {
        let f = try makeFixture()
        let (priv, page) = addPrivateSpace(f.store)
        f.store.undoManager.beginUndoGrouping()
        f.store.closeTab(id: page.id, in: priv)
        f.store.removeIncognitoSpace(id: priv.id)
        f.store.undoManager.endUndoGrouping()

        let deadline = Date().addingTimeInterval(2)
        while f.store.undoManager.canUndo, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(f.store.undoManager.canUndo, "the entry must leave the stack once its group is closed")
    }

    /// An Undo that comes before the run loop turns: the dropped entry is
    /// taken off as the undo starts, so this first Undo reaches the normal
    /// action below instead of spending itself on nothing.
    @MainActor func testAnUndoRightAfterTheGroupClosesSkipsTheDroppedEntry() throws {
        let f = try makeFixture()
        let normalPage = makeTab("https://normal.example/", in: f.normal)
        f.normal.tabs.append(normalPage)
        inUndoGroup(f.store) { f.store.closeTab(id: normalPage.id, in: f.normal) }
        let (priv, page) = addPrivateSpace(f.store)
        f.store.undoManager.beginUndoGrouping()
        f.store.closeTab(id: page.id, in: priv)
        f.store.removeIncognitoSpace(id: priv.id)
        f.store.undoManager.endUndoGrouping()

        let restored = restoredSpaceIDs { f.store.undoManager.undo() }

        XCTAssertTrue(hasPage("normal.example", in: f.normal), "the first Undo must reach the normal close")
        XCTAssertFalse(hasPage("secret.example", in: priv))
        XCTAssertEqual(restored, [f.normal.id])
        XCTAssertFalse(f.store.undoManager.canUndo)
    }

    /// As the app runs: the event's group is opened by the first registration
    /// and is still open when the window closes (with no event since, as when
    /// the automation endpoint drives the app); Undo closes it and runs it at
    /// once. Measured at runtime before this was handled: the first Cmd+Z did
    /// nothing, the second brought the normal tab back.
    @MainActor func testAnUndoThatClosesTheEventGroupSkipsTheDroppedEntry() throws {
        let f = try makeFixture()
        let normalPage = makeTab("https://normal.example/", in: f.normal)
        f.normal.tabs.append(normalPage)
        inUndoGroup(f.store) { f.store.closeTab(id: normalPage.id, in: f.normal) }
        let (priv, page) = addPrivateSpace(f.store)
        f.store.undoManager.groupsByEvent = true
        defer { f.store.undoManager.groupsByEvent = false }
        f.store.closeTab(id: page.id, in: priv)
        XCTAssertEqual(f.store.undoManager.groupingLevel, 1, "precondition: the registration opened the event's group")
        f.store.removeIncognitoSpace(id: priv.id)

        let restored = restoredSpaceIDs { f.store.undoManager.undo() }

        XCTAssertTrue(hasPage("normal.example", in: f.normal), "the first Undo must reach the normal close")
        XCTAssertFalse(hasPage("secret.example", in: priv))
        XCTAssertEqual(restored, [f.normal.id])
    }

    /// The dropped entry is all there is: the Undo that closes the event's
    /// group finds an empty stack once it is taken off, and does nothing.
    @MainActor func testAnUndoOfOnlyTheDroppedEntryDoesNothing() throws {
        let f = try makeFixture()
        let (priv, page) = addPrivateSpace(f.store)
        f.store.undoManager.groupsByEvent = true
        defer { f.store.undoManager.groupsByEvent = false }
        f.store.closeTab(id: page.id, in: priv)
        XCTAssertEqual(f.store.undoManager.groupingLevel, 1, "precondition: the registration opened the event's group")
        f.store.removeIncognitoSpace(id: priv.id)

        let restored = restoredSpaceIDs { f.store.undoManager.undo() }

        XCTAssertFalse(hasPage("secret.example", in: priv))
        XCTAssertTrue(restored.isEmpty)
        XCTAssertFalse(f.store.undoManager.canUndo)
        XCTAssertFalse(f.store.undoManager.canRedo)
    }

    // MARK: - An entry put back on its stack (TASK-361)

    /// An undo that puts itself back (as a refused space deletion does) keeps
    /// its spaces: in a Private space, the entry it puts back goes with the
    /// window. Before the fix it was put back with no spaces, as a normal
    /// entry, and outlived the window.
    @MainActor func testAnEntryPutBackOnTheStackGoesWithItsPrivateWindow() throws {
        let f = try makeFixture()
        let store = f.store
        let (priv, _) = addPrivateSpace(store)
        let runs = Counter()
        inUndoGroup(store) {
            store.undoManager.registerUndo(withTarget: store) { s in
                runs.count += 1
                s.reRegisterRunningUndoEntry(actionName: "Try Again", in: [priv]) { runs.count += 1 }
            }
            store.undoManager.setActionName("Try Again")
        }

        store.undoManager.undo()
        drainMainQueue()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(store.undoManager.undoActionName, "Try Again", "precondition: the entry is back on the undo stack")
        XCTAssertFalse(store.undoManager.canRedo, "precondition: the bounce has run")

        store.removeIncognitoSpace(id: priv.id)

        XCTAssertFalse(store.undoManager.canUndo, "the entry put back must go with its Private window")
        store.undoManager.undo()
        XCTAssertEqual(runs.count, 1)
    }

    /// The window closes before the main-queue hop: nothing is put back, and
    /// the hop does not run the entry below in its place. A redo, so the
    /// bounce lands on the undo stack right above a normal window's Close
    /// Tab, which the hop's undo would otherwise reach.
    @MainActor func testAnEntryWhosePrivateWindowClosedBeforeTheHopIsNotPutBack() throws {
        let f = try makeFixture()
        let store = f.store
        let normalPage = makeTab("https://normal.example/", in: f.normal)
        f.normal.tabs.append(normalPage)
        inUndoGroup(store) { store.closeTab(id: normalPage.id, in: f.normal) }
        let (priv, _) = addPrivateSpace(store)
        let runs = Counter()
        inUndoGroup(store) {
            store.undoManager.registerUndo(withTarget: store) { s in
                // Registered while undoing: lands on the redo stack.
                s.undoManager.registerUndo(withTarget: s) { s in
                    runs.count += 1
                    s.reRegisterRunningUndoEntry(actionName: "Try Again", in: [priv]) { runs.count += 1 }
                    s.removeIncognitoSpace(id: priv.id)
                }
                s.undoManager.setActionName("Try Again")
            }
            store.undoManager.setActionName("Try Again")
        }
        store.undoManager.undo()
        XCTAssertEqual(runs.count, 0)
        XCTAssertEqual(store.undoManager.redoActionName, "Try Again", "precondition: the entry is on the redo stack")

        store.undoManager.redo()
        drainMainQueue()

        XCTAssertEqual(runs.count, 1)
        XCTAssertFalse(hasPage("normal.example", in: f.normal), "the hop must not run the normal close's undo")
        XCTAssertEqual(store.undoManager.undoActionName, "Close Tab")
        XCTAssertFalse(store.undoManager.canRedo)
    }

    /// Runs what is already queued on the main queue: the store puts an entry
    /// back on its stack from there.
    @MainActor private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    // MARK: - Move Space across Private windows (TASK-360)

    /// Normal spaces N, B, C with a Private window's space between N and B
    /// (it opened before B and C were added): `spaces` is N, P, B, C.
    @MainActor private func makeSpacesAroundAPrivateOne(_ f: Fixture) -> (priv: Space, b: Space, c: Space) {
        let priv = f.store.addIncognitoSpace()
        let profileID = f.normal.profileID
        var added: [Space] = []
        inUndoGroup(f.store) {
            for name in ["B", "C"] {
                added.append(f.store.addSpace(name: name, emoji: name, colorHex: "007AFF", profileID: profileID))
            }
        }
        let (b, c) = (added[0], added[1])
        f.store.undoManager.removeAllActions()
        XCTAssertEqual(f.store.spaces.map(\.id), [f.normal.id, priv.id, b.id, c.id], "precondition")
        return (priv, b, c)
    }

    @MainActor private func normalOrder(_ store: TabStore) -> [String] {
        store.nonIncognitoSpaces.map(\.name)
    }

    /// Before the fix the undo moved by index into `spaces`, which the closed
    /// window's space no longer shifted: N, B, C came back as N, C, B.
    @MainActor func testUndoOfMoveSpacePutsItBackAfterAPrivateWindowClosed() throws {
        let f = try makeFixture()
        let (priv, b, _) = makeSpacesAroundAPrivateOne(f)
        inUndoGroup(f.store) { f.store.moveSpace(from: 2, to: 0) }
        XCTAssertEqual(normalOrder(f.store), ["B", "N", "C"])
        XCTAssertEqual(f.store.undoManager.undoActionName, "Move Space")

        f.store.removeIncognitoSpace(id: priv.id)
        f.store.undoManager.undo()

        XCTAssertEqual(normalOrder(f.store), ["N", "B", "C"])
        f.store.undoManager.redo()
        XCTAssertEqual(normalOrder(f.store), ["B", "N", "C"])
        XCTAssertEqual(f.store.spaces.first?.id, b.id)
    }

    /// The redo, registered by the undo while the Private window was open,
    /// keeps its target once the window closes.
    @MainActor func testRedoOfMoveSpaceAfterAPrivateWindowClosed() throws {
        let f = try makeFixture()
        let (priv, _, _) = makeSpacesAroundAPrivateOne(f)
        inUndoGroup(f.store) { f.store.moveSpace(from: 2, to: 0) }
        f.store.undoManager.undo()
        XCTAssertEqual(normalOrder(f.store), ["N", "B", "C"])

        f.store.removeIncognitoSpace(id: priv.id)
        f.store.undoManager.redo()

        XCTAssertEqual(normalOrder(f.store), ["B", "N", "C"])
        f.store.undoManager.undo()
        XCTAssertEqual(normalOrder(f.store), ["N", "B", "C"])
    }

    /// A Private window opened between the move and its undo, and another one
    /// closed.
    @MainActor func testUndoOfMoveSpacePutsItBackAfterPrivateWindowsOpenedAndClosed() throws {
        let f = try makeFixture()
        let (priv, _, _) = makeSpacesAroundAPrivateOne(f)
        inUndoGroup(f.store) { f.store.moveSpace(from: 0, to: 3) }
        XCTAssertEqual(normalOrder(f.store), ["B", "C", "N"])

        let opened = f.store.addIncognitoSpace()
        f.store.undoManager.undo()
        XCTAssertEqual(normalOrder(f.store), ["N", "B", "C"], "a Private window opened since")
        f.store.undoManager.redo()
        XCTAssertEqual(normalOrder(f.store), ["B", "C", "N"])

        f.store.removeIncognitoSpace(id: priv.id)
        f.store.undoManager.undo()
        XCTAssertEqual(normalOrder(f.store), ["N", "B", "C"], "and one closed")
        XCTAssertNotNil(f.store.space(withID: opened.id))
        f.store.removeIncognitoSpace(id: opened.id)
    }
}

/// TASK-357 AC #3 through the real windows: a Private window closes with its
/// close on the stack, then Edit > Undo runs in a normal window.
nonisolated final class PrivateWindowUndoWindowTests: XCTestCase {

    private var controllers: [BrowserWindowController] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        TabStore.shared.undoManager.removeAllActions()
        TabStore.shared.undoManager.groupsByEvent = false
    }

    @MainActor override func tearDown() async throws {
        for controller in controllers { controller.window?.close() }
        controllers.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        TabStore.shared.undoManager.groupsByEvent = true
        try await super.tearDown()
    }

    @MainActor func testUndoInANormalWindowAfterAPrivateWindowClosedRebuildsNothing() throws {
        let store = TabStore.shared
        let privateWindow = BrowserWindowController(incognito: true)
        controllers.append(privateWindow)
        privateWindow.sidebarSplitView.autosaveName = nil
        let priv = try XCTUnwrap(privateWindow.activeSpace)
        XCTAssertTrue(priv.isIncognito)
        let page = BrowserTab(id: UUID(), title: "Secret", url: URL(string: "https://secret.example/"),
                              faviconURL: nil, cachedInteractionState: nil, spaceID: priv.id)
        priv.tabs.append(page)
        store.undoManager.beginUndoGrouping()
        store.closeTab(id: page.id, in: priv)
        store.undoManager.endUndoGrouping()
        XCTAssertTrue(store.undoManager.canUndo, "precondition: the close is undoable while the window is open")

        privateWindow.window?.close()
        XCTAssertFalse(store.spaces.contains { $0 === priv }, "closing the window removes its space")

        let normalWindow = BrowserWindowController(incognito: false)
        controllers.append(normalWindow)
        normalWindow.sidebarSplitView.autosaveName = nil
        XCTAssertFalse(normalWindow.canUndoBrowserAction, "Edit > Undo has nothing of the Private window's to offer")
        var restoredIDs: [UUID] = []
        let token = NotificationCenter.default.addObserver(forName: .tabRestoredByUndo, object: nil, queue: nil) { note in
            if let id = note.userInfo?["spaceID"] as? UUID { restoredIDs.append(id) }
        }
        normalWindow.browserUndo(nil)
        NotificationCenter.default.removeObserver(token)

        XCTAssertFalse(priv.tabs.contains { $0.url?.host == "secret.example" })
        XCTAssertFalse(store.spaces.flatMap(\.tabs).contains { $0.url?.host == "secret.example" })
        XCTAssertTrue(restoredIDs.isEmpty)
    }
}

/// How many times an undo handler ran (TASK-361's tests).
private final class Counter {
    var count = 0
}
