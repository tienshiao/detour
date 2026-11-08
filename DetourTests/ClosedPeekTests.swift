import XCTest
import GRDB
@testable import Detour

/// TASK-307: a Peek the user closed is a closed-tab record naming its host.
/// Reopen Closed Tab, the Archived Tabs page and Undo bring it back as the
/// host's Peek while the host is open, else as a tab.
nonisolated final class ClosedPeekTests: XCTestCase {

    private var observers: [NSObjectProtocol] = []

    @MainActor override func tearDown() async throws {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        try await super.tearDown()
    }

    @MainActor private func makeFixture() throws -> (AppDatabase, TabStore, Space) {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Peek")
        let space = store.addSpace(name: "Peek", emoji: "👀", colorHex: "007AFF", profileID: profile.id)
        store.undoManager.removeAllActions()
        store.undoManager.groupsByEvent = false
        return (db, store, space)
    }

    @MainActor private func inUndoGroup(_ store: TabStore, _ body: () -> Void) {
        store.undoManager.beginUndoGrouping()
        body()
        store.undoManager.endUndoGrouping()
    }

    @MainActor private func makeTab(_ url: String, in space: Space, state: Data? = nil) -> BrowserTab {
        BrowserTab(id: UUID(), title: url, url: URL(string: url), faviconURL: nil,
                   cachedInteractionState: state, spaceID: space.id)
    }

    /// A Peek on `host` as the window builds one: in no list, held by the host.
    @MainActor private func makePeek(on host: BrowserTab, url: String, state: Data?) -> BrowserTab {
        let peek = BrowserTab(id: UUID(), title: "Peeked", url: URL(string: url),
                              faviconURL: URL(string: "https://peeked.example/favicon.ico"),
                              cachedInteractionState: state, spaceID: UUID())
        peek.spaceID = nil
        host.peekTab = peek
        return peek
    }

    /// What `closePeekOverlay` does to the host after the record is written.
    @MainActor private func closePeek(_ peek: BrowserTab, on host: BrowserTab, in space: Space, _ store: TabStore) {
        inUndoGroup(store) { store.recordClosedPeek(peek, host: host, in: space) }
        host.clearPeekState()
        peek.teardown()
    }

    // MARK: - The record

    @MainActor func testClosingAPeekRecordsItWithItsHost() throws {
        let (db, store, space) = try makeFixture()
        let other = makeTab("https://other.example/", in: space)
        let host = makeTab("https://host.example/", in: space)
        space.tabs.append(contentsOf: [other, host])
        let state = Data("scroll state".utf8)
        let peek = makePeek(on: host, url: "https://peeked.example/article", state: state)

        closePeek(peek, on: host, in: space, store)

        let summary = try XCTUnwrap(db.closedTabSummaries(spaceID: space.id.uuidString).first)
        XCTAssertEqual(summary.peekHostTabID, host.id.uuidString)
        XCTAssertEqual(summary.url, "https://peeked.example/article")
        XCTAssertEqual(summary.title, "Peeked")
        XCTAssertEqual(summary.sortOrder, 2, "after its host")
        XCTAssertNil(summary.archivedAt, "a plain close, which Reopen Closed Tab brings back")
        XCTAssertEqual(db.closedTab(id: summary.id)?.interactionState, state)
        XCTAssertTrue(store.canReopenClosedTab(in: space))
        XCTAssertEqual(store.undoManager.undoActionName, "Close Peek")
    }

    @MainActor func testAPrivatePeekWritesNoRecordButStillUndoes() throws {
        let (db, store, _) = try makeFixture()
        let space = store.addIncognitoSpace()
        store.undoManager.removeAllActions()
        let host = makeTab("https://host.example/", in: space)
        space.tabs.append(host)
        let peek = makePeek(on: host, url: "https://peeked.example/", state: nil)

        closePeek(peek, on: host, in: space, store)

        XCTAssertTrue(db.closedTabSummaries(spaceID: space.id.uuidString).isEmpty)
        XCTAssertTrue(store.undoManager.canUndo)
        store.undoManager.undo()
        XCTAssertEqual(host.peekURL?.absoluteString, "https://peeked.example/")
    }

    // MARK: - Reopen Closed Tab

    @MainActor func testReopenWithTheHostOpenPutsThePeekBackOnIt() throws {
        let (db, store, space) = try makeFixture()
        let host = makeTab("https://host.example/", in: space)
        space.tabs.append(host)
        let state = Data("scroll state".utf8)
        let peek = makePeek(on: host, url: "https://peeked.example/article", state: state)
        closePeek(peek, on: host, in: space, store)
        XCTAssertNil(host.peekURL, "precondition: closing cleared the host")

        let reopened = store.reopenClosedTab(in: space)

        XCTAssertTrue(reopened === host, "the host is what the window selects, which presents the Peek")
        XCTAssertEqual(host.peekURL?.absoluteString, "https://peeked.example/article")
        XCTAssertEqual(host.peekInteractionState, state, "its page and scroll position")
        XCTAssertEqual(host.peekFaviconURL?.absoluteString, "https://peeked.example/favicon.ico")
        XCTAssertEqual(space.tabs.map(\.id), [host.id], "no tab was added")
        XCTAssertTrue(db.closedTabSummaries(spaceID: space.id.uuidString).isEmpty, "the record is consumed")
    }

    @MainActor func testReopenWithTheHostGoneOpensATab() throws {
        let (_, store, space) = try makeFixture()
        let first = makeTab("https://first.example/", in: space)
        let host = makeTab("https://host.example/", in: space)
        let last = makeTab("https://last.example/", in: space)
        space.tabs.append(contentsOf: [first, host, last])
        let peek = makePeek(on: host, url: "https://peeked.example/article", state: nil)
        closePeek(peek, on: host, in: space, store)
        // The host goes without a record of its own: Reopen reaches the Peek.
        inUndoGroup(store) { store.closeTab(id: host.id, in: space, undoable: false) }

        let reopened = try XCTUnwrap(store.reopenClosedTab(in: space))

        XCTAssertEqual(reopened.url?.absoluteString, "https://peeked.example/article")
        XCTAssertEqual(space.tabs.map(\.id), [first.id, last.id, reopened.id],
                       "after where its host was, clamped to the list")
        reopened.teardown()
    }

    @MainActor func testReopenWhileTheHostHasAnotherPeekOpensATab() throws {
        let (_, store, space) = try makeFixture()
        let host = makeTab("https://host.example/", in: space)
        space.tabs.append(host)
        let peek = makePeek(on: host, url: "https://first-peek.example/", state: nil)
        closePeek(peek, on: host, in: space, store)
        host.peekURL = URL(string: "https://second-peek.example/")

        let reopened = try XCTUnwrap(store.reopenClosedTab(in: space))

        XCTAssertFalse(reopened === host)
        XCTAssertEqual(reopened.url?.absoluteString, "https://first-peek.example/")
        XCTAssertEqual(host.peekURL?.absoluteString, "https://second-peek.example/", "the other Peek stays")
        reopened.teardown()
    }

    @MainActor func testAPinnedHostGetsItsPeekBack() throws {
        let (_, store, space) = try makeFixture()
        let tab = makeTab("https://pinned.example/", in: space)
        let other = makeTab("https://other.example/", in: space)
        space.tabs.append(contentsOf: [tab, other])
        inUndoGroup(store) { store.pinTab(id: tab.id, in: space) }
        let host = try XCTUnwrap(space.pinnedEntries.first?.tab)
        let peek = makePeek(on: host, url: "https://peeked.example/", state: nil)
        closePeek(peek, on: host, in: space, store)

        XCTAssertTrue(store.reopenClosedTab(in: space) === host)
        XCTAssertEqual(host.peekURL?.absoluteString, "https://peeked.example/")
    }

    @MainActor func testTheArchivedTabsPageRestoresItTheSameWay() throws {
        let (db, store, space) = try makeFixture()
        let host = makeTab("https://host.example/", in: space)
        space.tabs.append(host)
        let peek = makePeek(on: host, url: "https://peeked.example/", state: nil)
        closePeek(peek, on: host, in: space, store)
        let recordID = try XCTUnwrap(db.closedTabSummaries().first?.id)

        XCTAssertTrue(store.restoreClosedTab(recordID: recordID) === host)
        XCTAssertEqual(host.peekURL?.absoluteString, "https://peeked.example/")
    }

    // MARK: - Undo

    @MainActor func testUndoPutsThePeekBackAndAsksTheWindowToSelectTheHost() throws {
        let (db, store, space) = try makeFixture()
        let host = makeTab("https://host.example/", in: space)
        space.tabs.append(host)
        let state = Data("scroll state".utf8)
        let peek = makePeek(on: host, url: "https://peeked.example/", state: state)
        closePeek(peek, on: host, in: space, store)
        var selected: UUID?
        observers.append(NotificationCenter.default.addObserver(forName: .tabRestoredByUndo, object: nil, queue: nil) { note in
            // Posted on the main thread, delivered there (no queue).
            let id = note.userInfo?["tabID"] as? UUID
            MainActor.assumeIsolated { selected = id }
        })

        store.undoManager.undo()

        XCTAssertEqual(selected, host.id)
        XCTAssertEqual(host.peekURL?.absoluteString, "https://peeked.example/")
        XCTAssertEqual(host.peekInteractionState, state)
        XCTAssertTrue(db.closedTabSummaries(spaceID: space.id.uuidString).isEmpty,
                      "the record is consumed, so Reopen Closed Tab does not bring a second copy")
    }

    @MainActor func testUndoAfterReopenDoesNothing() throws {
        let (_, store, space) = try makeFixture()
        let host = makeTab("https://host.example/", in: space)
        space.tabs.append(host)
        let peek = makePeek(on: host, url: "https://peeked.example/", state: nil)
        closePeek(peek, on: host, in: space, store)
        XCTAssertTrue(store.reopenClosedTab(in: space) === host)
        host.clearPeekState()   // the user closed it again without recording

        store.undoManager.undo()

        XCTAssertNil(host.peekURL, "the record was consumed by the reopen")
    }

    @MainActor func testUndoWithTheHostGoneOpensATab() throws {
        let (_, store, space) = try makeFixture()
        let keep = makeTab("https://keep.example/", in: space)
        let host = makeTab("https://host.example/", in: space)
        space.tabs.append(contentsOf: [keep, host])
        let peek = makePeek(on: host, url: "https://peeked.example/", state: nil)
        closePeek(peek, on: host, in: space, store)
        space.tabs.removeAll { $0.id == host.id }
        host.teardown()

        store.undoManager.undo()

        XCTAssertEqual(space.tabs.map(\.url?.absoluteString), ["https://keep.example/", "https://peeked.example/"])
        space.tabs.last?.teardown()
    }

    // MARK: - Migration

    /// v23 adds `closedTab.peekHostTabID`; rows closed before it are closed
    /// tabs (nil) and reopen as before.
    @MainActor func testMigrationV23KeepsAV22DatabasesClosedTabs() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v22")
        let spaceID = UUID().uuidString
        try queue.write { d in
            try d.execute(sql: """
                INSERT INTO closedTab (tabID, spaceID, url, title, sortOrder, closedAt)
                VALUES ('\(UUID().uuidString)', '\(spaceID)', 'https://old.example/', 'Old', 0, 1)
                """)
        }

        let db = try AppDatabase(dbQueue: queue)

        let summary = try XCTUnwrap(db.closedTabSummaries(spaceID: spaceID).first)
        XCTAssertEqual(summary.url, "https://old.example/")
        XCTAssertNil(summary.peekHostTabID)
        XCTAssertNil(db.closedTab(id: summary.id)?.peekHostTabID)
    }
}
