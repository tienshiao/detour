import XCTest
import GRDB
@testable import Detour

/// What a session save does when it cannot be written as it stands (TASK-154).
///
/// - Rows that can never be valid — a pinned folder whose parent is missing, a
///   parent cycle, a pinned entry in a missing folder — are repaired before the
///   save, so they do not fail it.
/// - A constraint failure in one row costs the unit that row belongs to (a
///   space with its tabs and pinned items, the profiles, one profile's
///   favourites): that unit keeps its last saved rows and every other unit is
///   written.
/// - `TabStore.saveNow()` reports which of the three happened.
///
/// A failure is injected from the test with a SQLite trigger on the store's
/// own database, so the statement throws inside the save and the app has no
/// test-only hook. `SessionSaveAtomicityTests` covers the other kind of
/// failure, one that is not about a row, which must leave the previous save
/// whole.
final class SessionSaveFailureTests: XCTestCase {

    // MARK: - Fixture

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
        let outer: PinnedFolder
        let inner: PinnedFolder
        let liveEntry: PinnedEntry
        let dormantEntry: PinnedEntry
    }

    /// Two profiles with a space each. Work: two tabs, a folder holding a
    /// nested folder and a live entry, a dormant entry at the root, a live and
    /// a dormant favourite. Home: one tab, one dormant entry, one dormant
    /// favourite. Saved once, so the database holds this state.
    private func makeSavedFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let store = TabStore(appDB: db)
        let work = store.addProfile(name: "Work")
        let home = store.addProfile(name: "Home")
        let workSpace = store.addSpace(name: "Work", emoji: "W", colorHex: "007AFF", profileID: work.id)
        let homeSpace = store.addSpace(name: "Home", emoji: "H", colorHex: "FF3B30", profileID: home.id)

        for index in 0 ..< 2 {
            workSpace.tabs.append(makeSleepingTab(spaceID: workSpace.id, url: "https://work.example.com/\(index)"))
        }
        homeSpace.tabs.append(makeSleepingTab(spaceID: homeSpace.id, url: "https://home.example.com/0"))

        let outer = store.addPinnedFolder(name: "Outer", in: workSpace)
        let inner = store.addPinnedFolder(name: "Inner", parentFolderID: outer.id, in: workSpace)
        let livePinned = makeSleepingTab(spaceID: workSpace.id, url: "https://pinned.example.com/live")
        workSpace.tabs.append(livePinned)
        store.pinTab(id: livePinned.id, in: workSpace)
        let liveEntry = try XCTUnwrap(workSpace.pinnedEntries.first { $0.tab === livePinned })
        store.movePinnedTabToFolder(tabID: liveEntry.id, folderID: outer.id, in: workSpace)
        store.pinURL(URL(string: "https://pinned.example.com/dormant")!, title: "Dormant", faviconURL: nil, in: workSpace)
        let dormantEntry = try XCTUnwrap(workSpace.pinnedEntries.first { $0.tab == nil })
        store.pinURL(URL(string: "https://pinned.example.org/dormant")!, title: "Dormant", faviconURL: nil, in: homeSpace)

        store.addFavorite(from: makeSleepingTab(spaceID: workSpace.id, url: "https://fav.example.com/live"),
                          profileID: work.id)
        XCTAssertTrue(store.addFavoriteFromEntry(url: URL(string: "https://fav.example.com/dormant")!, title: "Dormant",
                                                 faviconURL: nil, favicon: nil, profileID: work.id, at: 1))
        XCTAssertTrue(store.addFavoriteFromEntry(url: URL(string: "https://fav.example.org/dormant")!, title: "Home fav",
                                                 faviconURL: nil, favicon: nil, profileID: home.id, at: 0))

        store.lastActiveSpaceID = workSpace.id
        store.saveNow()
        return Fixture(db: db, store: store, work: work, home: home, workSpace: workSpace, homeSpace: homeSpace,
                       outer: outer, inner: inner, liveEntry: liveEntry, dormantEntry: dormantEntry)
    }

    // MARK: - Reading the database back

    /// The rows `sql` selects, as text.
    private func rows(_ db: AppDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> [String] {
        try db.dbQueue.read { conn in
            try Row.fetchAll(conn, sql: sql, arguments: arguments).map { row in
                row.map { column, value in "\(column)=\(value)" }.joined(separator: " | ")
            }
        }
    }

    /// Every row that belongs to one space: the space, its tabs, its pinned
    /// folders and entries.
    private func spaceRows(_ db: AppDatabase, _ space: Space) throws -> [String: [String]] {
        let id = space.id.uuidString
        return [
            "space": try rows(db, "SELECT * FROM space WHERE id = ?", [id]),
            "tab": try rows(db, "SELECT * FROM tab WHERE spaceID = ? ORDER BY id", [id]),
            "pinnedFolder": try rows(db, "SELECT * FROM pinnedFolder WHERE spaceID = ? ORDER BY id", [id]),
            "pinnedTab": try rows(db, "SELECT * FROM pinnedTab WHERE spaceID = ? ORDER BY id", [id]),
        ]
    }

    /// Every row of every table a save writes.
    private func sessionRows(_ db: AppDatabase) throws -> [String: [String]] {
        var tables: [String: [String]] = [:]
        for table in ["profile", "space", "tab", "pinnedFolder", "pinnedTab", "favorite"] {
            tables[table] = try rows(db, "SELECT * FROM \(table) ORDER BY id")
        }
        tables["appState"] = try rows(db, "SELECT * FROM appState ORDER BY key")
        return tables
    }

    private func strings(_ db: AppDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> [String] {
        try db.dbQueue.read { conn in try String.fetchAll(conn, sql: sql, arguments: arguments) }
    }

    private func optionalString(_ db: AppDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> String? {
        try db.dbQueue.read { conn in try String.fetchOne(conn, sql: sql, arguments: arguments) }
    }

    private func count(_ db: AppDatabase, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try db.dbQueue.read { conn in try Int.fetchOne(conn, sql: sql, arguments: arguments) ?? 0 }
    }

    /// What the next launch holds.
    private func relaunch(_ db: AppDatabase) -> TabStore {
        let store = TabStore(appDB: db)
        _ = store.restoreSession()
        return store
    }

    // MARK: - Failure injection

    /// Makes the insert of the one row `id` of `table` fail the way a foreign
    /// key or uniqueness violation does: a constraint error from inside the
    /// statement, for that row only, on every save until it is removed.
    private func refuseRow(_ id: UUID, of table: String, in db: AppDatabase) throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                CREATE TRIGGER refusedRow BEFORE INSERT ON \(table) WHEN NEW.id = '\(id.uuidString)'
                BEGIN SELECT RAISE(ABORT, 'injected constraint failure'); END
                """)
        }
    }

    private func acceptRowsAgain(in db: AppDatabase) throws {
        try db.dbQueue.write { conn in try conn.execute(sql: "DROP TRIGGER refusedRow") }
    }

    /// Makes every insert into `table` fail the way a full disk would: an
    /// error that is not a constraint failure.
    private func failEveryInsert(into table: String, in db: AppDatabase) throws {
        try db.dbQueue.write { conn in
            conn.add(function: DatabaseFunction("injected_failure", argumentCount: 0) { _ in
                throw DatabaseError(resultCode: .SQLITE_FULL, message: "injected failure")
            })
            try conn.execute(sql: """
                CREATE TRIGGER failedInsert BEFORE INSERT ON \(table)
                BEGIN SELECT injected_failure(); END
                """)
        }
    }

    /// The units a save reported as not written; nil when it reported
    /// anything else.
    private func unitsNotSaved(_ outcome: TabStore.SessionSaveOutcome) -> [AppDatabase.SessionSaveFailure.Unit]? {
        guard case .savedExcept(let failures) = outcome else { return nil }
        return failures.map(\.unit)
    }

    // MARK: - Rows that cannot be made valid are repaired

    func testAPinnedFolderWhoseParentIsMissingIsSavedAtTheRoot() throws {
        let fixture = try makeSavedFixture()
        let added = makeSleepingTab(spaceID: fixture.homeSpace.id, url: "https://home.example.com/added")
        fixture.homeSpace.tabs.append(added)
        fixture.inner.parentFolderID = UUID()

        XCTAssertEqual(fixture.store.saveNow(), .saved)

        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE id = ?", [added.id.uuidString]), 1,
                       "a folder with a missing parent must not fail the save")
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM pinnedFolder"), 2)
        XCTAssertNil(try optionalString(fixture.db, "SELECT parentFolderID FROM pinnedFolder WHERE id = ?",
                                        [fixture.inner.id.uuidString]),
                     "the folder is saved at the root")

        let restored = try XCTUnwrap(relaunch(fixture.db).space(withID: fixture.workSpace.id))
        let inner = try XCTUnwrap(restored.pinnedFolders.first { $0.id == fixture.inner.id })
        XCTAssertNil(inner.parentFolderID)
        let rootOrders = restored.pinnedFolders.filter { $0.parentFolderID == nil && $0.id != inner.id }.map(\.sortOrder)
            + restored.pinnedEntries.filter { $0.folderID == nil }.map(\.sortOrder)
        XCTAssertGreaterThan(inner.sortOrder, try XCTUnwrap(rootOrders.max()),
                             "a folder moved to the root goes after what is already there")
        XCTAssertEqual(restored.pinnedEntries.count, 2)
    }

    func testAPinnedFolderParentCycleIsBrokenAndSaved() throws {
        let fixture = try makeSavedFixture()
        let added = makeSleepingTab(spaceID: fixture.homeSpace.id, url: "https://home.example.com/added")
        fixture.homeSpace.tabs.append(added)
        // Inner is already inside Outer: Outer inside Inner closes the cycle.
        fixture.outer.parentFolderID = fixture.inner.id

        XCTAssertEqual(fixture.store.saveNow(), .saved)

        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE id = ?", [added.id.uuidString]), 1,
                       "a folder cycle must not fail the save")
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM pinnedFolder"), 2)

        let restored = try XCTUnwrap(relaunch(fixture.db).space(withID: fixture.workSpace.id))
        let outer = try XCTUnwrap(restored.pinnedFolders.first { $0.id == fixture.outer.id })
        let inner = try XCTUnwrap(restored.pinnedFolders.first { $0.id == fixture.inner.id })
        XCTAssertNil(outer.parentFolderID, "the first folder of the cycle is moved to the root")
        XCTAssertEqual(inner.parentFolderID, outer.id, "the rest of the cycle keeps its parent")
        XCTAssertEqual(restored.pinnedEntries.first { $0.id == fixture.liveEntry.id }?.folderID, outer.id)
    }

    func testAPinnedEntryWhoseFolderIsMissingIsSavedAtTheRoot() throws {
        let fixture = try makeSavedFixture()
        let added = makeSleepingTab(spaceID: fixture.homeSpace.id, url: "https://home.example.com/added")
        fixture.homeSpace.tabs.append(added)
        fixture.liveEntry.folderID = UUID()

        XCTAssertEqual(fixture.store.saveNow(), .saved)

        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE id = ?", [added.id.uuidString]), 1,
                       "an entry in a missing folder must not fail the save")
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM pinnedTab WHERE spaceID = ?",
                                 [fixture.workSpace.id.uuidString]), 2)

        let restored = try XCTUnwrap(relaunch(fixture.db).space(withID: fixture.workSpace.id))
        let entry = try XCTUnwrap(restored.pinnedEntries.first { $0.id == fixture.liveEntry.id })
        XCTAssertNil(entry.folderID)
        XCTAssertEqual(entry.tab?.id, fixture.liveEntry.tab?.id, "the entry is still live")
        let otherRootOrders = restored.pinnedFolders.filter { $0.parentFolderID == nil }.map(\.sortOrder)
            + restored.pinnedEntries.filter { $0.folderID == nil && $0.id != entry.id }.map(\.sortOrder)
        XCTAssertGreaterThan(entry.sortOrder, try XCTUnwrap(otherRootOrders.max()))
    }

    // MARK: - A constraint failure in one space

    /// Changes in every part of the save: both spaces, the profiles, the
    /// favourites of both profiles, the active space.
    private func changeEveryPart(_ fixture: Fixture) throws -> (workTab: BrowserTab, homeTab: BrowserTab) {
        let store = fixture.store
        let workTab = makeSleepingTab(spaceID: fixture.workSpace.id, url: "https://work.example.com/new")
        fixture.workSpace.tabs.append(workTab)
        fixture.workSpace.name = "Work renamed"
        store.pinURL(URL(string: "https://pinned.example.com/added")!, title: "Added", faviconURL: nil, in: fixture.workSpace)

        let homeTab = makeSleepingTab(spaceID: fixture.homeSpace.id, url: "https://home.example.com/new")
        fixture.homeSpace.tabs.append(homeTab)
        fixture.homeSpace.name = "Home renamed"
        store.pinURL(URL(string: "https://pinned.example.org/added")!, title: "Added", faviconURL: nil, in: fixture.homeSpace)
        store.addPinnedFolder(name: "Home folder", in: fixture.homeSpace)

        let dormantFavorite = try XCTUnwrap(fixture.work.favorites.first { $0.tab == nil })
        store.removeFavorite(id: dormantFavorite.id, profileID: fixture.work.id)
        XCTAssertTrue(store.addFavoriteFromEntry(url: URL(string: "https://fav.example.org/added")!, title: "Added",
                                                 faviconURL: nil, favicon: nil, profileID: fixture.home.id, at: 1))
        // Not `updateProfile`: that writes the profile row at once, outside the save.
        fixture.home.name = "Home profile renamed"
        store.lastActiveSpaceID = fixture.homeSpace.id
        return (workTab, homeTab)
    }

    func testAConstraintFailureInOneSpaceStillSavesEveryOtherPart() throws {
        let fixture = try makeSavedFixture()
        let workRowsBefore = try spaceRows(fixture.db, fixture.workSpace)
        let tabs = try changeEveryPart(fixture)
        try refuseRow(tabs.workTab.id, of: "tab", in: fixture.db)

        // The store is told which unit was not written, and why.
        let outcome = fixture.store.saveNow()
        guard case .savedExcept(let failures) = outcome else { return XCTFail("the save reported \(outcome)") }
        XCTAssertEqual(failures.map(\.unit), [.space(id: fixture.workSpace.id.uuidString)])
        XCTAssertTrue(failures[0].reason.contains("injected constraint failure"), failures[0].reason)
        XCTAssertEqual(fixture.store.lastSaveOutcome, outcome)

        // The space with the refused row keeps what the last good save wrote.
        XCTAssertEqual(try spaceRows(fixture.db, fixture.workSpace), workRowsBefore)

        // Every other part is the new state.
        let homeID = fixture.homeSpace.id.uuidString
        XCTAssertEqual(try strings(fixture.db, "SELECT name FROM space WHERE id = ?", [homeID]), ["Home renamed"])
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE id = ?", [tabs.homeTab.id.uuidString]), 1)
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM pinnedTab WHERE spaceID = ?", [homeID]), 2)
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM pinnedFolder WHERE spaceID = ?", [homeID]), 1)
        XCTAssertEqual(try strings(fixture.db, "SELECT name FROM profile WHERE id = ?", [fixture.home.id.uuidString]),
                       ["Home profile renamed"])
        XCTAssertEqual(try strings(fixture.db, "SELECT id FROM favorite WHERE profileID = ? ORDER BY sortOrder",
                                   [fixture.home.id.uuidString]),
                       fixture.home.favorites.map(\.id.uuidString))
        XCTAssertEqual(try strings(fixture.db, "SELECT id FROM favorite WHERE profileID = ? ORDER BY sortOrder",
                                   [fixture.work.id.uuidString]),
                       fixture.work.favorites.map(\.id.uuidString))
        XCTAssertEqual(try optionalString(fixture.db, "SELECT value FROM appState WHERE key = 'lastActiveSpaceID'"),
                       homeID)

        // The next launch loads both spaces: Home as it is now, Work as it was.
        let relaunched = relaunch(fixture.db)
        XCTAssertEqual(relaunched.spaces.map(\.id), [fixture.workSpace.id, fixture.homeSpace.id])
        let work = try XCTUnwrap(relaunched.space(withID: fixture.workSpace.id))
        XCTAssertEqual(work.name, "Work")
        XCTAssertEqual(work.tabs.count, 2)
        XCTAssertEqual(work.pinnedFolders.count, 2)
        XCTAssertEqual(work.pinnedEntries.count, 2)
        XCTAssertEqual(work.pinnedEntries.first { $0.id == fixture.liveEntry.id }?.tab?.id, fixture.liveEntry.tab?.id)
        let home = try XCTUnwrap(relaunched.space(withID: fixture.homeSpace.id))
        XCTAssertEqual(home.name, "Home renamed")
        XCTAssertEqual(home.tabs.map(\.id), fixture.homeSpace.tabs.map(\.id))
        XCTAssertEqual(home.pinnedEntries.count, 2)
        let liveFavorite = try XCTUnwrap(fixture.work.favorites.first { $0.tab != nil })
        XCTAssertEqual(relaunched.profile(withID: fixture.work.id)?.favorites.first { $0.id == liveFavorite.id }?.tab?.id,
                       liveFavorite.tab?.id, "the live favourite's backing tab is in the rows Work kept")

        // The failure repeats: later saves still write the other parts.
        let later = makeSleepingTab(spaceID: fixture.homeSpace.id, url: "https://home.example.com/later")
        fixture.homeSpace.tabs.append(later)
        XCTAssertEqual(unitsNotSaved(fixture.store.saveNow()), [.space(id: fixture.workSpace.id.uuidString)])
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE id = ?", [later.id.uuidString]), 1)
        XCTAssertEqual(try spaceRows(fixture.db, fixture.workSpace), workRowsBefore)

        // Once the row is accepted the whole session is saved again.
        try acceptRowsAgain(in: fixture.db)
        XCTAssertEqual(fixture.store.saveNow(), .saved)
        XCTAssertEqual(fixture.store.lastSaveOutcome, .saved)
        XCTAssertEqual(try strings(fixture.db, "SELECT name FROM space WHERE id = ?", [fixture.workSpace.id.uuidString]),
                       ["Work renamed"])
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE id = ?", [tabs.workTab.id.uuidString]), 1)
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM pinnedTab WHERE spaceID = ?",
                                 [fixture.workSpace.id.uuidString]), 3)
    }

    /// A failing pinned row is part of its space's unit: the space keeps its
    /// previous pinned rows instead of losing them to the cascade.
    func testAConstraintFailureInAPinnedRowKeepsThatSpacesPinnedRows() throws {
        let fixture = try makeSavedFixture()
        let workRowsBefore = try spaceRows(fixture.db, fixture.workSpace)
        let tabs = try changeEveryPart(fixture)
        try refuseRow(fixture.dormantEntry.id, of: "pinnedTab", in: fixture.db)

        XCTAssertEqual(unitsNotSaved(fixture.store.saveNow()), [.space(id: fixture.workSpace.id.uuidString)])

        XCTAssertEqual(try spaceRows(fixture.db, fixture.workSpace), workRowsBefore)
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE id = ?", [tabs.homeTab.id.uuidString]), 1)
        let work = try XCTUnwrap(relaunch(fixture.db).space(withID: fixture.workSpace.id))
        XCTAssertEqual(work.pinnedEntries.count, 2)
        XCTAssertEqual(work.pinnedFolders.count, 2)
    }

    /// A space that was never saved and cannot be is missing after the save;
    /// the spaces that were there are written.
    func testANewSpaceThatCannotBeSavedDoesNotStopTheOthers() throws {
        let fixture = try makeSavedFixture()
        let tabs = try changeEveryPart(fixture)
        let extra = fixture.store.addSpace(name: "Extra", emoji: "E", colorHex: "34C759", profileID: fixture.home.id)
        extra.tabs.append(makeSleepingTab(spaceID: extra.id, url: "https://extra.example.com/0"))
        try refuseRow(extra.id, of: "space", in: fixture.db)

        XCTAssertEqual(unitsNotSaved(fixture.store.saveNow()), [.space(id: extra.id.uuidString)])

        XCTAssertEqual(try strings(fixture.db, "SELECT id FROM space ORDER BY sortOrder"),
                       [fixture.workSpace.id.uuidString, fixture.homeSpace.id.uuidString])
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE id = ?", [tabs.workTab.id.uuidString]), 1)
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE id = ?", [tabs.homeTab.id.uuidString]), 1)
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE spaceID = ?", [extra.id.uuidString]), 0)
        XCTAssertEqual(relaunch(fixture.db).spaces.map(\.name), ["Work renamed", "Home renamed"])
    }

    /// A space the user deleted is deleted even when another space fails.
    func testADeletedSpaceIsRemovedWhileAnotherSpaceFails() throws {
        let fixture = try makeSavedFixture()
        let tabs = try changeEveryPart(fixture)
        fixture.store.deleteSpace(id: fixture.homeSpace.id)
        XCTAssertNil(fixture.store.space(withID: fixture.homeSpace.id))
        fixture.store.lastActiveSpaceID = fixture.workSpace.id
        try refuseRow(tabs.workTab.id, of: "tab", in: fixture.db)

        fixture.store.saveNow()

        XCTAssertEqual(try strings(fixture.db, "SELECT id FROM space"), [fixture.workSpace.id.uuidString])
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM tab WHERE spaceID = ?",
                                 [fixture.homeSpace.id.uuidString]), 0)
        XCTAssertEqual(try count(fixture.db, "SELECT COUNT(*) FROM pinnedTab WHERE spaceID = ?",
                                 [fixture.homeSpace.id.uuidString]), 0)
    }

    // MARK: - Rows that moved between units

    /// A tab that left the failing space is in its new space only: the row the
    /// failing space kept for it would otherwise collide with the new one.
    func testATabMovedOutOfTheFailingSpaceIsSavedInItsNewSpace() throws {
        let fixture = try makeSavedFixture()
        let tabs = try changeEveryPart(fixture)
        // Work is written first and fails; Home, written after it, receives the tab.
        let moved = fixture.workSpace.tabs.removeFirst()
        moved.spaceID = fixture.homeSpace.id
        fixture.homeSpace.tabs.append(moved)
        try refuseRow(tabs.workTab.id, of: "tab", in: fixture.db)

        fixture.store.saveNow()

        XCTAssertEqual(try strings(fixture.db, "SELECT spaceID FROM tab WHERE id = ?", [moved.id.uuidString]),
                       [fixture.homeSpace.id.uuidString])
        let relaunched = relaunch(fixture.db)
        XCTAssertEqual(relaunched.space(withID: fixture.homeSpace.id)?.tabs.map(\.id), fixture.homeSpace.tabs.map(\.id))
        XCTAssertEqual(relaunched.space(withID: fixture.workSpace.id)?.tabs.count, 1,
                       "Work keeps its previous tabs, without the one that moved")
    }

    /// The same when the failing space is written after the space that
    /// receives the tab.
    func testATabMovedOutOfASpaceThatFailsLaterIsSavedInItsNewSpace() throws {
        let fixture = try makeSavedFixture()
        let tabs = try changeEveryPart(fixture)
        // Work is written first and receives the tab; Home, written after it, fails.
        let moved = fixture.homeSpace.tabs.removeFirst()
        moved.spaceID = fixture.workSpace.id
        fixture.workSpace.tabs.append(moved)
        try refuseRow(tabs.homeTab.id, of: "tab", in: fixture.db)

        fixture.store.saveNow()

        XCTAssertEqual(try strings(fixture.db, "SELECT spaceID FROM tab WHERE id = ?", [moved.id.uuidString]),
                       [fixture.workSpace.id.uuidString])
        let relaunched = relaunch(fixture.db)
        XCTAssertEqual(relaunched.space(withID: fixture.workSpace.id)?.tabs.map(\.id), fixture.workSpace.tabs.map(\.id))
        XCTAssertEqual(relaunched.space(withID: fixture.homeSpace.id)?.tabs.count, 0,
                       "Home keeps its previous tabs, without the one that moved")
        XCTAssertEqual(relaunched.space(withID: fixture.homeSpace.id)?.name, "Home")
    }

    /// A favourite made live since the last good save has its backing tab's
    /// row in the space that hosts it. When that space fails, the favourites
    /// are still written, with that one dormant.
    func testAFavouriteWhoseBackingTabWasNotSavedIsSavedDormant() throws {
        let fixture = try makeSavedFixture()
        let tabs = try changeEveryPart(fixture)
        let backing = makeSleepingTab(spaceID: fixture.workSpace.id, url: "https://fav.example.com/new-live")
        fixture.store.addFavorite(from: backing, profileID: fixture.work.id)
        let favorite = try XCTUnwrap(fixture.work.favorites.first { $0.tab === backing })
        try refuseRow(tabs.workTab.id, of: "tab", in: fixture.db)

        fixture.store.saveNow()

        XCTAssertEqual(try strings(fixture.db, "SELECT id FROM favorite WHERE profileID = ? ORDER BY sortOrder",
                                   [fixture.work.id.uuidString]),
                       fixture.work.favorites.map(\.id.uuidString), "the favourites are the new list")
        XCTAssertNil(try optionalString(fixture.db, "SELECT tabID FROM favorite WHERE id = ?", [favorite.id.uuidString]))
        let restored = try XCTUnwrap(relaunch(fixture.db).profile(withID: fixture.work.id))
        XCTAssertNil(restored.favorites.first { $0.id == favorite.id }?.tab)
        XCTAssertEqual(restored.favorites.count, fixture.work.favorites.count)
    }

    // MARK: - A failure that is not about a row

    /// The unit-by-unit save is one transaction too: an error that is not a
    /// refused row, met after some units were written, undoes all of them.
    func testAFailureThatIsNotARefusedRowDuringTheUnitByUnitSaveWritesNothing() throws {
        let fixture = try makeSavedFixture()
        let before = try sessionRows(fixture.db)
        let tabs = try changeEveryPart(fixture)
        // The one-step save stops at the refused tab row, before it reaches
        // the favourites; the unit-by-unit save gets past it and reaches them.
        try refuseRow(tabs.workTab.id, of: "tab", in: fixture.db)
        try failEveryInsert(into: "favorite", in: fixture.db)

        let outcome = fixture.store.saveNow()

        guard case .failed(let reason) = outcome else { return XCTFail("the save reported \(outcome)") }
        XCTAssertTrue(reason.contains("injected failure"), reason)
        XCTAssertEqual(fixture.store.lastSaveOutcome, outcome)
        XCTAssertEqual(try sessionRows(fixture.db), before)
    }

    /// A failure that is not a refused row is not retried unit by unit: the
    /// same error would stop every unit.
    func testAFailureThatIsNotARefusedRowKeepsTheLastGoodSave() throws {
        let fixture = try makeSavedFixture()
        let before = try sessionRows(fixture.db)
        _ = try changeEveryPart(fixture)
        try failEveryInsert(into: "pinnedTab", in: fixture.db)

        guard case .failed = fixture.store.saveNow() else { return XCTFail("the save did not report a failure") }

        XCTAssertEqual(try sessionRows(fixture.db), before)
        XCTAssertEqual(relaunch(fixture.db).spaces.map(\.name), ["Work", "Home"])
    }
}
