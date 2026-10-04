import XCTest
import GRDB
@testable import Detour

/// One `TabStore.saveNow()` is one database transaction (TASK-149): a save that
/// fails part-way leaves the complete previous state, never the new spaces and
/// tabs without their pinned entries, folders or favourites.
///
/// The failure is injected from the test with a SQLite trigger that raises on
/// the write of one table, so the save throws from inside its transaction at a
/// chosen step without any test-only seam in the app. The store is driven
/// through `saveNow()` only, which is why the same file runs against the code
/// before the fix.
final class SessionSaveAtomicityTests: XCTestCase {

    // MARK: - Fixture

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase(dbQueue: DatabaseQueue())
    }

    private func makeSleepingTab(spaceID: UUID, url: String) -> BrowserTab {
        BrowserTab(id: UUID(), title: "Tab", url: URL(string: url), faviconURL: nil,
                   cachedInteractionState: Data([1, 2, 3]), spaceID: spaceID)
    }

    private struct Fixture {
        let db: AppDatabase
        let store: TabStore
        let work: Profile
        let home: Profile
        let workSpace: Space
        let homeSpace: Space
    }

    /// State A: two profiles, a space on each, normal tabs, nested pinned
    /// folders, live and dormant pinned entries, live and dormant favourites.
    private func makeFixture() throws -> Fixture {
        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        let work = store.addProfile(name: "Work")
        let home = store.addProfile(name: "Home")
        let workSpace = store.addSpace(name: "Work", emoji: "W", colorHex: "007AFF", profileID: work.id)
        let homeSpace = store.addSpace(name: "Home", emoji: "H", colorHex: "FF3B30", profileID: home.id)

        for index in 0 ..< 3 {
            workSpace.tabs.append(makeSleepingTab(spaceID: workSpace.id, url: "https://work.example.com/\(index)"))
        }
        homeSpace.tabs.append(makeSleepingTab(spaceID: homeSpace.id, url: "https://home.example.com/0"))

        // Work: a folder holding a nested folder and a live entry, plus a dormant entry at the root.
        let outer = store.addPinnedFolder(name: "Outer", in: workSpace)
        store.addPinnedFolder(name: "Inner", parentFolderID: outer.id, in: workSpace)
        let livePinned = makeSleepingTab(spaceID: workSpace.id, url: "https://pinned.example.com/live")
        workSpace.tabs.append(livePinned)
        store.pinTab(id: livePinned.id, in: workSpace)
        let liveEntry = try XCTUnwrap(workSpace.pinnedEntries.first { $0.tab === livePinned })
        store.movePinnedTabToFolder(tabID: liveEntry.id, folderID: outer.id, in: workSpace)
        store.pinURL(URL(string: "https://pinned.example.com/dormant")!, title: "Dormant", faviconURL: nil, in: workSpace)

        // Home: one live entry.
        let homePinned = makeSleepingTab(spaceID: homeSpace.id, url: "https://pinned.example.org/live")
        homeSpace.tabs.append(homePinned)
        store.pinTab(id: homePinned.id, in: homeSpace)

        // Favourites: a live and a dormant one on Work, a dormant one on Home.
        store.addFavorite(from: makeSleepingTab(spaceID: workSpace.id, url: "https://fav.example.com/live"),
                          profileID: work.id)
        XCTAssertTrue(store.addFavoriteFromEntry(url: URL(string: "https://fav.example.com/dormant")!, title: "Dormant",
                                                 faviconURL: nil, favicon: nil, profileID: work.id, at: 1))
        XCTAssertTrue(store.addFavoriteFromEntry(url: URL(string: "https://fav.example.org/dormant")!, title: "Home fav",
                                                 faviconURL: nil, favicon: nil, profileID: home.id, at: 0))

        store.lastActiveSpaceID = workSpace.id
        return Fixture(db: db, store: store, work: work, home: home, workSpace: workSpace, homeSpace: homeSpace)
    }

    /// State B: a change in every part `saveNow()` writes, so a save that
    /// stopped half-way is visible in whichever table it reached.
    private func mutateToStateB(_ fixture: Fixture) throws {
        let store = fixture.store
        fixture.workSpace.tabs.append(makeSleepingTab(spaceID: fixture.workSpace.id, url: "https://work.example.com/new"))
        fixture.workSpace.name = "Work renamed"

        let outer = try XCTUnwrap(fixture.workSpace.pinnedFolders.first { $0.name == "Outer" })
        store.renamePinnedFolder(id: outer.id, name: "Outer renamed", in: fixture.workSpace)
        store.addPinnedFolder(name: "Added", in: fixture.workSpace)
        store.pinURL(URL(string: "https://pinned.example.com/added")!, title: "Added", faviconURL: nil, in: fixture.workSpace)
        store.pinURL(URL(string: "https://pinned.example.org/added")!, title: "Added", faviconURL: nil, in: fixture.homeSpace)

        let dormantFavorite = try XCTUnwrap(fixture.work.favorites.first { $0.tab == nil })
        store.removeFavorite(id: dormantFavorite.id, profileID: fixture.work.id)
        XCTAssertTrue(store.addFavoriteFromEntry(url: URL(string: "https://fav.example.org/added")!, title: "Added",
                                                 faviconURL: nil, favicon: nil, profileID: fixture.home.id, at: 1))

        // Not `updateProfile`: that writes the profile row at once, outside the save.
        fixture.home.name = "Home renamed"
        store.lastActiveSpaceID = fixture.homeSpace.id
    }

    // MARK: - Reading the database back

    /// The tables a save writes.
    private static let sessionTables = ["profile", "space", "tab", "pinnedFolder", "pinnedTab", "favorite", "appState"]

    /// Every row of every session table, as text, in primary-key order.
    private func dump(_ db: AppDatabase) throws -> [String: [String]] {
        try db.dbQueue.read { conn in
            var tables: [String: [String]] = [:]
            for table in Self.sessionTables {
                let key = table == "appState" ? "key" : "id"
                let rows = try Row.fetchAll(conn, sql: "SELECT * FROM \(table) ORDER BY \(key)")
                tables[table] = rows.map { row in
                    row.map { column, value in "\(column)=\(value)" }.joined(separator: " | ")
                }
            }
            return tables
        }
    }

    /// What a relaunch sees: the restored spaces, pinned folders and entries,
    /// and favourites, as plain values.
    private func restoredShape(_ db: AppDatabase) -> [String] {
        let store = TabStore(appDB: db)
        _ = store.restoreSession()
        var lines: [String] = []
        for space in store.spaces {
            lines.append("space \(space.id) \(space.name) tabs=\(space.tabs.map(\.id.uuidString))")
            for folder in space.pinnedFolders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                lines.append("  folder \(folder.id) \(folder.name) parent=\(folder.parentFolderID?.uuidString ?? "-") "
                    + "order=\(folder.sortOrder)")
            }
            for entry in space.pinnedEntries.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                lines.append("  pinned \(entry.id) \(entry.pinnedURL.absoluteString) folder=\(entry.folderID?.uuidString ?? "-") "
                    + "order=\(entry.sortOrder) tab=\(entry.tab?.id.uuidString ?? "-")")
            }
        }
        for profile in store.profiles.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines.append("profile \(profile.id) \(profile.name)")
            for favorite in profile.favorites {
                lines.append("  favorite \(favorite.id) \(favorite.url.absoluteString) tab=\(favorite.tab?.id.uuidString ?? "-")")
            }
        }
        return lines
    }

    // MARK: - Failure injection

    /// Makes every `event` on `table` fail, the way a full disk or a constraint
    /// violation would: the statement throws inside the save's transaction.
    private func injectFailure(on table: String, event: String, in db: AppDatabase) throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                CREATE TRIGGER injectedFailure BEFORE \(event) ON \(table)
                BEGIN SELECT RAISE(ABORT, 'injected failure'); END
                """)
        }
    }

    private func removeInjectedFailure(in db: AppDatabase) throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: "DROP TRIGGER injectedFailure")
        }
    }

    /// Saves state A, moves the store to state B, makes the save fail when it
    /// writes `table`, and checks the database still holds state A in full.
    /// Then lets the save through and checks it holds state B in full.
    private func assertInterruptedSaveKeepsPreviousState(failingOn table: String, event: String = "INSERT",
                                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try makeFixture()
        fixture.store.saveNow()
        // The shape first: restoring adds the built-in Private profile's row,
        // which belongs in the baseline the failed save is compared with.
        let shapeA = restoredShape(fixture.db)
        let rowsA = try dump(fixture.db)
        XCTAssertFalse(try XCTUnwrap(rowsA["pinnedTab"]).isEmpty, file: file, line: line)
        XCTAssertFalse(try XCTUnwrap(rowsA["pinnedFolder"]).isEmpty, file: file, line: line)
        XCTAssertFalse(try XCTUnwrap(rowsA["favorite"]).isEmpty, file: file, line: line)

        try mutateToStateB(fixture)
        try injectFailure(on: table, event: event, in: fixture.db)
        fixture.store.saveNow()
        try removeInjectedFailure(in: fixture.db)

        let rowsAfterFailure = try dump(fixture.db)
        for name in Self.sessionTables {
            XCTAssertEqual(rowsAfterFailure[name], rowsA[name],
                           "a save that failed writing \(table) changed the \(name) table", file: file, line: line)
        }
        XCTAssertEqual(restoredShape(fixture.db), shapeA,
                       "a relaunch after a save that failed writing \(table) does not see the previous state",
                       file: file, line: line)

        // The same save, uninterrupted, writes state B in full.
        fixture.store.saveNow()
        let rowsB = try dump(fixture.db)
        XCTAssertNotEqual(rowsB["space"], rowsA["space"], file: file, line: line)
        XCTAssertNotEqual(rowsB["tab"], rowsA["tab"], file: file, line: line)
        XCTAssertNotEqual(rowsB["profile"], rowsA["profile"], file: file, line: line)
        XCTAssertNotEqual(rowsB["pinnedFolder"], rowsA["pinnedFolder"], file: file, line: line)
        XCTAssertNotEqual(rowsB["pinnedTab"], rowsA["pinnedTab"], file: file, line: line)
        XCTAssertNotEqual(rowsB["favorite"], rowsA["favorite"], file: file, line: line)
        XCTAssertNotEqual(rowsB["appState"], rowsA["appState"], file: file, line: line)
    }

    // MARK: - An interrupted save

    func testSaveFailingOnTabRowsKeepsPreviousState() throws {
        try assertInterruptedSaveKeepsPreviousState(failingOn: "tab")
    }

    func testSaveFailingOnProfileRowsKeepsPreviousState() throws {
        // `ProfileRecord.save` updates an existing row.
        try assertInterruptedSaveKeepsPreviousState(failingOn: "profile", event: "UPDATE")
    }

    func testSaveFailingOnPinnedFolderRowsKeepsPreviousState() throws {
        try assertInterruptedSaveKeepsPreviousState(failingOn: "pinnedFolder")
    }

    func testSaveFailingOnPinnedEntryRowsKeepsPreviousState() throws {
        try assertInterruptedSaveKeepsPreviousState(failingOn: "pinnedTab")
    }

    func testSaveFailingOnFavoriteRowsKeepsPreviousState() throws {
        try assertInterruptedSaveKeepsPreviousState(failingOn: "favorite")
    }

    // MARK: - Nested folders in any order

    /// `pinnedFolder.parentFolderID` is an immediate foreign key onto the same
    /// table, and the store's folder array is not parent-first: a folder dragged
    /// into one created after it stays ahead of it. Written in array order the
    /// child row is refused, and since TASK-149 that refusal fails the whole
    /// save, every time, for as long as the folders stay nested that way.
    func testAFolderAheadOfItsParentInTheStoreIsSaved() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let space = fixture.workSpace
        let outer = try XCTUnwrap(space.pinnedFolders.first { $0.name == "Outer" })
        let late = store.addPinnedFolder(name: "Late", in: space)
        store.movePinnedFolder(folderID: outer.id, parentFolderID: late.id, in: space)
        let outerIndex = try XCTUnwrap(space.pinnedFolders.firstIndex { $0.id == outer.id })
        let lateIndex = try XCTUnwrap(space.pinnedFolders.firstIndex { $0.id == late.id })
        XCTAssertLessThan(outerIndex, lateIndex, "premise: the child is ahead of its parent in the store")

        XCTAssertTrue(fixture.db.saveSessionSnapshot(store.makeSessionSnapshot()),
                      "a child folder ahead of its parent must not fail the save")

        let relaunched = TabStore(appDB: fixture.db)
        _ = relaunched.restoreSession()
        let restored = try XCTUnwrap(relaunched.space(withID: space.id))
        XCTAssertEqual(restored.pinnedFolders.count, 3)
        XCTAssertEqual(restored.pinnedFolders.first { $0.id == outer.id }?.parentFolderID, late.id)
        XCTAssertEqual(restored.pinnedEntries.count, space.pinnedEntries.count)

        // The rows load by their per-level sort order, which is not parent-first
        // either: the relaunched store's own save has to go through as well.
        XCTAssertTrue(fixture.db.saveSessionSnapshot(relaunched.makeSessionSnapshot()),
                      "the save after a relaunch must not fail on the folders' load order")
        XCTAssertEqual(try XCTUnwrap(try dump(fixture.db)["pinnedFolder"]).count, 3)
    }

    /// Undo Delete Folder appends the restored folder after the children it
    /// takes back, so the children are ahead of their parent.
    func testAFolderRestoredByUndoBehindItsChildrenIsSaved() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let space = fixture.workSpace
        let outer = try XCTUnwrap(space.pinnedFolders.first { $0.name == "Outer" })
        let inner = try XCTUnwrap(space.pinnedFolders.first { $0.name == "Inner" })

        // The fixture's own undo registrations share the open group: without
        // this the undo below would take them back too.
        store.undoManager.removeAllActions()
        store.deletePinnedFolder(id: outer.id, in: space)
        store.undoManager.undo()
        XCTAssertEqual(space.pinnedFolders.map(\.id), [inner.id, outer.id],
                       "premise: the restored parent is behind its child in the store")
        XCTAssertEqual(inner.parentFolderID, outer.id)

        XCTAssertTrue(fixture.db.saveSessionSnapshot(store.makeSessionSnapshot()))
        XCTAssertEqual(try XCTUnwrap(try dump(fixture.db)["pinnedFolder"]).count, 2)
    }

    // MARK: - One transaction

    private final class CommitCounter: TransactionObserver {
        private(set) var commits = 0
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseDidCommit(_ db: GRDB.Database) { commits += 1 }
        func databaseDidRollback(_ db: GRDB.Database) {}
    }

    func testSaveNowCommitsOnce() throws {
        let fixture = try makeFixture()
        fixture.store.saveNow()
        try mutateToStateB(fixture)

        let counter = CommitCounter()
        fixture.db.dbQueue.add(transactionObserver: counter, extent: .databaseLifetime)
        fixture.store.saveNow()
        fixture.db.dbQueue.remove(transactionObserver: counter)

        XCTAssertEqual(counter.commits, 1, "one save must be one write transaction")
    }

    // MARK: - Same rows as the per-piece saves

    /// The one-transaction save is a change of transaction boundaries only: it
    /// leaves exactly the rows that `saveSession`, `saveProfiles`,
    /// `savePinnedFoldersAndTabs` and `saveFavorites`, run in that order, leave.
    func testSnapshotSaveWritesTheSameRowsAsThePerPieceSaves() throws {
        let fixture = try makeFixture()
        let reference = try makeDatabase()

        func savePerPiece(_ snapshot: AppDatabase.SessionSnapshot) {
            reference.saveSession(spaces: snapshot.spaces, lastActiveSpaceID: snapshot.lastActiveSpaceID)
            reference.saveProfiles(snapshot.profiles)
            for pinned in snapshot.pinnedItems {
                reference.savePinnedFoldersAndTabs(folders: pinned.folders, tabs: pinned.tabs, spaceID: pinned.spaceID)
            }
            for favorites in snapshot.favorites {
                reference.saveFavorites(favorites.records, profileID: favorites.profileID)
            }
        }

        let stateA = fixture.store.makeSessionSnapshot()
        // `addProfile` wrote the fixture's profile rows when they were created;
        // space rows reference them.
        for profile in stateA.profiles { reference.saveProfile(profile) }
        savePerPiece(stateA)
        XCTAssertTrue(fixture.db.saveSessionSnapshot(stateA))
        let rowsA = try dump(fixture.db)
        XCTAssertEqual(rowsA, try dump(reference))
        XCTAssertEqual(rowsA["space"]?.count, 2)
        XCTAssertEqual(rowsA["tab"]?.count, 7, "four normal tabs, two pinned backing tabs, one favourite backing tab")
        XCTAssertEqual(rowsA["pinnedFolder"]?.count, 2)
        XCTAssertEqual(rowsA["pinnedTab"]?.count, 3)
        XCTAssertEqual(rowsA["favorite"]?.count, 3)

        // A second save replaces a full database: the deletes have to match too.
        try mutateToStateB(fixture)
        let stateB = fixture.store.makeSessionSnapshot()
        savePerPiece(stateB)
        XCTAssertTrue(fixture.db.saveSessionSnapshot(stateB))
        let rowsB = try dump(fixture.db)
        XCTAssertEqual(rowsB, try dump(reference))
        XCTAssertNotEqual(rowsB, rowsA)
    }

    // MARK: - A successful save

    func testSuccessfulSaveRoundTripsFullState() throws {
        let fixture = try makeFixture()
        fixture.store.saveNow()
        try mutateToStateB(fixture)
        fixture.store.saveNow()

        let relaunched = TabStore(appDB: fixture.db)
        let restored = relaunched.restoreSession()
        XCTAssertEqual(restored?.spaceID, fixture.homeSpace.id, "lastActiveSpaceID is part of the save")

        XCTAssertEqual(relaunched.spaces.map(\.id), [fixture.workSpace.id, fixture.homeSpace.id])
        for original in [fixture.workSpace, fixture.homeSpace] {
            let space = try XCTUnwrap(relaunched.space(withID: original.id))
            XCTAssertEqual(space.name, original.name)
            XCTAssertEqual(space.profileID, original.profileID)
            XCTAssertEqual(space.tabs.map(\.id), original.tabs.map(\.id))
            XCTAssertEqual(space.tabs.map(\.url), original.tabs.map(\.url))

            let folders = space.pinnedFolders.sorted { $0.id.uuidString < $1.id.uuidString }
            let originalFolders = original.pinnedFolders.sorted { $0.id.uuidString < $1.id.uuidString }
            XCTAssertEqual(folders.map(\.id), originalFolders.map(\.id))
            XCTAssertEqual(folders.map(\.name), originalFolders.map(\.name))
            XCTAssertEqual(folders.map(\.parentFolderID), originalFolders.map(\.parentFolderID))
            XCTAssertEqual(folders.map(\.sortOrder), originalFolders.map(\.sortOrder))

            let entries = space.pinnedEntries.sorted { $0.id.uuidString < $1.id.uuidString }
            let originalEntries = original.pinnedEntries.sorted { $0.id.uuidString < $1.id.uuidString }
            XCTAssertEqual(entries.map(\.id), originalEntries.map(\.id))
            XCTAssertEqual(entries.map(\.pinnedURL), originalEntries.map(\.pinnedURL))
            XCTAssertEqual(entries.map(\.folderID), originalEntries.map(\.folderID))
            XCTAssertEqual(entries.map(\.sortOrder), originalEntries.map(\.sortOrder))
            XCTAssertEqual(entries.map { $0.tab?.id }, originalEntries.map { $0.tab?.id },
                           "live entries come back live, dormant ones dormant")
        }
        XCTAssertEqual(try XCTUnwrap(relaunched.space(withID: fixture.workSpace.id)).pinnedFolders.count, 3)
        XCTAssertEqual(try XCTUnwrap(relaunched.space(withID: fixture.workSpace.id)).pinnedEntries.count, 3)
        XCTAssertEqual(try XCTUnwrap(relaunched.space(withID: fixture.homeSpace.id)).pinnedEntries.count, 2)

        for original in [fixture.work, fixture.home] {
            let profile = try XCTUnwrap(relaunched.profile(withID: original.id))
            XCTAssertEqual(profile.name, original.name)
            XCTAssertEqual(profile.favorites.map(\.id), original.favorites.map(\.id))
            XCTAssertEqual(profile.favorites.map(\.url), original.favorites.map(\.url))
            XCTAssertEqual(profile.favorites.map { $0.tab?.id }, original.favorites.map { $0.tab?.id })
        }
        XCTAssertEqual(try XCTUnwrap(relaunched.profile(withID: fixture.work.id)).favorites.count, 1)
        XCTAssertEqual(try XCTUnwrap(relaunched.profile(withID: fixture.home.id)).favorites.count, 2)
    }
}
