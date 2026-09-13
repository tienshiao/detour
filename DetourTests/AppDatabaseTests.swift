import XCTest
import GRDB
@testable import Detour

final class AppDatabaseTests: XCTestCase {

    private let testProfileID = "test-profile-id"

    private func makeDatabase() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        let db = try AppDatabase(dbQueue: dbQueue)
        // Insert a test profile for foreign key references
        db.saveProfile(ProfileRecord(id: testProfileID, name: "Test", userAgentMode: 0, customUserAgent: nil, archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0, searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true, isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true, isMalwareFilterEnabled: true))
        return db
    }

    private func spaceRecord(id: String, name: String, emoji: String, colorHex: String, sortOrder: Int, selectedTabID: String? = nil) -> SpaceRecord {
        SpaceRecord(id: id, name: name, emoji: emoji, colorHex: colorHex, sortOrder: sortOrder, selectedTabID: selectedTabID, profileID: testProfileID)
    }

    // MARK: - saveSession / loadSession round-trip

    func testSaveAndLoadEmptySession() throws {
        let db = try makeDatabase()
        db.saveSession(spaces: [], lastActiveSpaceID: nil)

        let result = db.loadSession()
        XCTAssertNil(result)
    }

    func testSaveAndLoadSingleSpaceWithTabs() throws {
        let db = try makeDatabase()
        let space = spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0, selectedTabID: "t2")
        let tabs = [
            TabRecord(id: "t1", spaceID: "s1", url: "https://a.com", title: "A", faviconURL: nil, interactionState: nil, sortOrder: 0),
            TabRecord(id: "t2", spaceID: "s1", url: "https://b.com", title: "B", faviconURL: "https://b.com/icon.png", interactionState: nil, sortOrder: 1),
        ]

        db.saveSession(spaces: [(space, tabs)], lastActiveSpaceID: "s1")

        let result = db.loadSession()
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.spaces.count, 1)
        XCTAssertEqual(result!.spaces[0].0.id, "s1")
        XCTAssertEqual(result!.spaces[0].0.name, "Home")
        XCTAssertEqual(result!.spaces[0].0.selectedTabID, "t2")
        XCTAssertEqual(result!.spaces[0].1.count, 2)
        XCTAssertEqual(result!.spaces[0].1[0].id, "t1")
        XCTAssertEqual(result!.spaces[0].1[1].id, "t2")
        XCTAssertEqual(result!.lastActiveSpaceID, "s1")
    }

    func testSaveAndLoadMultipleSpacesPreservesOrder() throws {
        let db = try makeDatabase()
        let spaces: [(SpaceRecord, [TabRecord])] = [
            (spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0), []),
            (spaceRecord(id: "s2", name: "Work", emoji: "💼", colorHex: "FF3B30", sortOrder: 1), []),
            (spaceRecord(id: "s3", name: "Fun", emoji: "🎮", colorHex: "34C759", sortOrder: 2), []),
        ]

        db.saveSession(spaces: spaces, lastActiveSpaceID: "s2")

        let result = db.loadSession()!
        XCTAssertEqual(result.spaces.map { $0.0.id }, ["s1", "s2", "s3"])
        XCTAssertEqual(result.lastActiveSpaceID, "s2")
    }

    func testTabsReturnedInSortOrder() throws {
        let db = try makeDatabase()
        let space = spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0)
        let tabs = [
            TabRecord(id: "t3", spaceID: "s1", url: nil, title: "Third", faviconURL: nil, interactionState: nil, sortOrder: 2),
            TabRecord(id: "t1", spaceID: "s1", url: nil, title: "First", faviconURL: nil, interactionState: nil, sortOrder: 0),
            TabRecord(id: "t2", spaceID: "s1", url: nil, title: "Second", faviconURL: nil, interactionState: nil, sortOrder: 1),
        ]

        db.saveSession(spaces: [(space, tabs)], lastActiveSpaceID: nil)

        let result = db.loadSession()!
        XCTAssertEqual(result.spaces[0].1.map(\.id), ["t1", "t2", "t3"])
    }

    func testTabsAreGroupedBySpace() throws {
        let db = try makeDatabase()
        let spaces: [(SpaceRecord, [TabRecord])] = [
            (spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0), [
                TabRecord(id: "t1", spaceID: "s1", url: nil, title: "Tab 1", faviconURL: nil, interactionState: nil, sortOrder: 0),
            ]),
            (spaceRecord(id: "s2", name: "Work", emoji: "💼", colorHex: "FF3B30", sortOrder: 1), [
                TabRecord(id: "t2", spaceID: "s2", url: nil, title: "Tab 2", faviconURL: nil, interactionState: nil, sortOrder: 0),
                TabRecord(id: "t3", spaceID: "s2", url: nil, title: "Tab 3", faviconURL: nil, interactionState: nil, sortOrder: 1),
            ]),
        ]

        db.saveSession(spaces: spaces, lastActiveSpaceID: nil)

        let result = db.loadSession()!
        XCTAssertEqual(result.spaces[0].1.map(\.id), ["t1"])
        XCTAssertEqual(result.spaces[1].1.map(\.id), ["t2", "t3"])
    }

    // MARK: - saveSession replaces previous data

    func testSaveSessionReplacesExistingData() throws {
        let db = try makeDatabase()

        // Save initial session
        db.saveSession(spaces: [
            (spaceRecord(id: "s1", name: "Old", emoji: "👴", colorHex: "000000", sortOrder: 0), [
                TabRecord(id: "t1", spaceID: "s1", url: nil, title: "Old Tab", faviconURL: nil, interactionState: nil, sortOrder: 0),
            ]),
        ], lastActiveSpaceID: "s1")

        // Save new session
        db.saveSession(spaces: [
            (spaceRecord(id: "s2", name: "New", emoji: "✨", colorHex: "FFFFFF", sortOrder: 0), []),
        ], lastActiveSpaceID: "s2")

        let result = db.loadSession()!
        XCTAssertEqual(result.spaces.count, 1)
        XCTAssertEqual(result.spaces[0].0.id, "s2")
        XCTAssertEqual(result.spaces[0].0.name, "New")
        XCTAssertEqual(result.lastActiveSpaceID, "s2")

        // Verify old tabs are gone too
        try db.dbQueue.read { conn in
            let tabCount = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM tab")
            XCTAssertEqual(tabCount, 0)
        }
    }

    // MARK: - lastActiveSpaceID

    func testLoadSessionWithNoActiveSpaceID() throws {
        let db = try makeDatabase()
        db.saveSession(spaces: [
            (spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0), []),
        ], lastActiveSpaceID: nil)

        let result = db.loadSession()!
        XCTAssertNil(result.lastActiveSpaceID)
    }

    // MARK: - Tab data preservation

    func testTabPreservesAllFields() throws {
        let db = try makeDatabase()
        let stateData = "fake-state".data(using: .utf8)
        let space = spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0)
        let tab = TabRecord(id: "t1", spaceID: "s1", url: "https://example.com", title: "Example", faviconURL: "https://example.com/icon.png", interactionState: stateData, sortOrder: 0)

        db.saveSession(spaces: [(space, [tab])], lastActiveSpaceID: nil)

        let result = db.loadSession()!
        let loaded = result.spaces[0].1[0]
        XCTAssertEqual(loaded.url, "https://example.com")
        XCTAssertEqual(loaded.title, "Example")
        XCTAssertEqual(loaded.faviconURL, "https://example.com/icon.png")
        XCTAssertEqual(loaded.interactionState, stateData)
    }

    // MARK: - Closed Tab Stack

    func testPushAndPopClosedTabRoundTrip() throws {
        let db = try makeDatabase()
        let record = ClosedTabRecord(id: nil, tabID: "t1", spaceID: "s1", url: "https://example.com", title: "Example", faviconURL: "https://example.com/icon.png", interactionState: "state".data(using: .utf8), sortOrder: 2)

        db.pushClosedTab(record)

        let popped = db.popClosedTab(spaceID: "s1")
        XCTAssertNotNil(popped)
        XCTAssertEqual(popped!.tabID, "t1")
        XCTAssertEqual(popped!.spaceID, "s1")
        XCTAssertEqual(popped!.url, "https://example.com")
        XCTAssertEqual(popped!.title, "Example")
        XCTAssertEqual(popped!.faviconURL, "https://example.com/icon.png")
        XCTAssertEqual(popped!.interactionState, "state".data(using: .utf8))
        XCTAssertEqual(popped!.sortOrder, 2)
    }

    func testPopReturnsNilWhenEmpty() throws {
        let db = try makeDatabase()
        let result = db.popClosedTab(spaceID: "s1")
        XCTAssertNil(result)
    }

    func testPopFiltersBySpaceID() throws {
        let db = try makeDatabase()
        db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t1", spaceID: "s1", url: nil, title: "Tab 1", faviconURL: nil, interactionState: nil, sortOrder: 0))
        db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t2", spaceID: "s2", url: nil, title: "Tab 2", faviconURL: nil, interactionState: nil, sortOrder: 0))
        db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t3", spaceID: "s1", url: nil, title: "Tab 3", faviconURL: nil, interactionState: nil, sortOrder: 1))

        // Pop from s1 should get t3 (most recent for s1)
        let popped1 = db.popClosedTab(spaceID: "s1")
        XCTAssertEqual(popped1?.tabID, "t3")

        // Pop from s1 again should get t1
        let popped2 = db.popClosedTab(spaceID: "s1")
        XCTAssertEqual(popped2?.tabID, "t1")

        // Pop from s1 again should be nil
        let popped3 = db.popClosedTab(spaceID: "s1")
        XCTAssertNil(popped3)

        // s2's entry should still be there
        let popped4 = db.popClosedTab(spaceID: "s2")
        XCTAssertEqual(popped4?.tabID, "t2")
    }

    func testClosedTabLIFOOrdering() throws {
        let db = try makeDatabase()
        db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t1", spaceID: "s1", url: nil, title: "First", faviconURL: nil, interactionState: nil, sortOrder: 0))
        db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t2", spaceID: "s1", url: nil, title: "Second", faviconURL: nil, interactionState: nil, sortOrder: 1))
        db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t3", spaceID: "s1", url: nil, title: "Third", faviconURL: nil, interactionState: nil, sortOrder: 2))

        XCTAssertEqual(db.popClosedTab(spaceID: "s1")?.tabID, "t3")
        XCTAssertEqual(db.popClosedTab(spaceID: "s1")?.tabID, "t2")
        XCTAssertEqual(db.popClosedTab(spaceID: "s1")?.tabID, "t1")
    }

    func testClosedTabCapEnforcement() throws {
        let db = try makeDatabase()
        for i in 1...105 {
            db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t\(i)", spaceID: "s1", url: nil, title: "Tab \(i)", faviconURL: nil, interactionState: nil, sortOrder: 0))
        }

        let all = db.loadClosedTabs()
        XCTAssertEqual(all.count, 100)

        // The oldest 5 (t1-t5) should have been trimmed; most recent should be t105
        XCTAssertEqual(all.first?.tabID, "t105")
        XCTAssertEqual(all.last?.tabID, "t6")
    }

    func testDeleteClosedTabsBySpaceID() throws {
        let db = try makeDatabase()
        db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t1", spaceID: "s1", url: nil, title: "Tab 1", faviconURL: nil, interactionState: nil, sortOrder: 0))
        db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t2", spaceID: "s2", url: nil, title: "Tab 2", faviconURL: nil, interactionState: nil, sortOrder: 0))
        db.pushClosedTab(ClosedTabRecord(id: nil, tabID: "t3", spaceID: "s1", url: nil, title: "Tab 3", faviconURL: nil, interactionState: nil, sortOrder: 1))

        db.deleteClosedTabs(spaceID: "s1")

        let all = db.loadClosedTabs()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.tabID, "t2")
        XCTAssertEqual(all.first?.spaceID, "s2")
    }

    // MARK: - Profile deletion with FK constraints

    private func makeProfile(id: String, name: String) -> ProfileRecord {
        ProfileRecord(id: id, name: name, userAgentMode: 0, customUserAgent: nil, archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0, searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true, isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true, isMalwareFilterEnabled: true)
    }

    func testSaveProfilesBeforeSessionLeavesOrphanProfiles() throws {
        let db = try makeDatabase()

        // Create a second profile
        let p2 = makeProfile(id: "profile-2", name: "Second")
        db.saveProfile(p2)

        // Create a space referencing the default test profile
        let space = spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0)
        db.saveSession(spaces: [(space, [])], lastActiveSpaceID: nil)

        // Now try to save only p2 (which should delete testProfileID, but FK prevents it)
        db.saveProfiles([p2])

        // The profile should still be in the DB because the FK constraint blocked deletion
        let profiles = db.loadProfiles()
        XCTAssertEqual(profiles.count, 2, "Profile referenced by a space should not be deleted by saveProfiles")
    }

    func testSaveSessionBeforeProfilesDeletesOrphans() throws {
        let db = try makeDatabase()

        // Create a second profile
        let p2 = makeProfile(id: "profile-2", name: "Second")
        db.saveProfile(p2)

        // Create a space referencing the default test profile
        let space = spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0)
        db.saveSession(spaces: [(space, [])], lastActiveSpaceID: nil)

        // Save session first with a space referencing p2 instead (removes FK to testProfileID)
        let newSpace = SpaceRecord(id: "s2", name: "New", emoji: "✨", colorHex: "FFFFFF", sortOrder: 0, selectedTabID: nil, profileID: "profile-2")
        db.saveSession(spaces: [(newSpace, [])], lastActiveSpaceID: nil)

        // Now saveProfiles excluding testProfileID should succeed cleanly
        db.saveProfiles([p2])

        let profiles = db.loadProfiles()
        XCTAssertEqual(profiles.count, 1, "Orphan profile should be deleted after session is saved first")
        XCTAssertEqual(profiles[0].id, "profile-2")
    }

    func testSaveProfilesAfterSessionDoesNotLeaveOrphans() throws {
        let db = try makeDatabase()

        // Create a second profile and save it
        let p2 = makeProfile(id: "profile-2", name: "Second")
        db.saveProfile(p2)

        // Create a space referencing the default test profile
        let space = spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0)
        db.saveSession(spaces: [(space, [])], lastActiveSpaceID: nil)

        // Now simulate what a correct saveNow() does: save session first
        // (replacing the space with one referencing p2), THEN save profiles.
        let newSpace = SpaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0, selectedTabID: nil, profileID: "profile-2")
        db.saveSession(spaces: [(newSpace, [])], lastActiveSpaceID: nil)
        db.saveProfiles([p2])

        // testProfileID should be gone — no FK blocking it
        let profiles = db.loadProfiles()
        XCTAssertEqual(profiles.count, 1, "Stale profile should be cleaned up when session is saved first")
        XCTAssertEqual(profiles[0].id, "profile-2")
    }

    // MARK: - deleteProfile (TASK-31)

    private let perProfileTables = ["profileExtension", "extensionInstalledEvent", "favorite", "contentBlockerWhitelist"]
    private let extensionKeyedTables = ["extension", "extensionStorage", "extensionPermission"]

    /// An in-memory database with two profiles, an installed extension, and one
    /// row per profile in every profileID-keyed table. `foreignKeysEnabled: false`
    /// shows the rows go without relying on the `profile` cascades.
    private func makeDatabaseWithPerProfileRows(foreignKeysEnabled: Bool = true) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = foreignKeysEnabled
        let db = try AppDatabase(dbQueue: DatabaseQueue(configuration: config))
        db.saveProfile(makeProfile(id: testProfileID, name: "Test"))
        db.saveProfile(makeProfile(id: "profile-2", name: "Second"))
        db.saveExtension(ExtensionRecord(
            id: "ext-1", name: "Ext", version: "1.0", manifestJSON: Data("{}".utf8),
            basePath: "/tmp/ext-1", isEnabled: true, installedAt: 0
        ))
        try db.dbQueue.write { d in
            try ExtensionStorageRecord(extensionID: "ext-1", key: "k", value: Data("1".utf8)).insert(d)
            try ExtensionPermissionRecord(extensionID: "ext-1", key: "tabs", type: .apiPermission, status: .granted).insert(d)
        }
        for profileID in [testProfileID, "profile-2"] {
            db.setProfileExtensionEnabled(extensionID: "ext-1", profileID: profileID, enabled: false)
            _ = db.claimRuntimeInstalledEvent(extensionID: "ext-1", profileID: profileID,
                                              isPrivateProfile: false, currentVersion: "1.0")
            db.saveFavorites([FavoriteRecord(id: "fav-\(profileID)", profileID: profileID, url: "https://a.example/",
                                             title: "A", faviconURL: nil, sortOrder: 0)],
                             profileID: profileID)
            db.saveContentBlockerWhitelistEntry(ContentBlockerWhitelistRecord(profileID: profileID, host: "a.example"))
        }
        return db
    }

    private func rowCount(_ table: String, profileID: String? = nil, in db: AppDatabase) throws -> Int {
        try db.dbQueue.read { d in
            if let profileID {
                return try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \"\(table)\" WHERE profileID = ?",
                                        arguments: [profileID]) ?? 0
            }
            return try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
        }
    }

    func testDeleteProfileRemovesItsPerProfileRowsAndNoOthers() throws {
        for foreignKeysEnabled in [true, false] {
            let db = try makeDatabaseWithPerProfileRows(foreignKeysEnabled: foreignKeysEnabled)
            for table in perProfileTables {
                XCTAssertEqual(try rowCount(table, profileID: testProfileID, in: db), 1, "precondition: \(table)")
            }

            db.deleteProfile(id: testProfileID)

            let label = "foreign keys \(foreignKeysEnabled ? "on" : "off")"
            XCTAssertEqual(db.loadProfiles().map(\.id), ["profile-2"], label)
            for table in perProfileTables {
                XCTAssertEqual(try rowCount(table, profileID: testProfileID, in: db), 0,
                               "\(table) rows of the deleted profile are removed (\(label))")
                XCTAssertEqual(try rowCount(table, profileID: "profile-2", in: db), 1,
                               "\(table) rows of another profile survive (\(label))")
            }
            for table in extensionKeyedTables {
                XCTAssertEqual(try rowCount(table, in: db), 1, "\(table) is untouched (\(label))")
            }
        }
    }

    func testDeleteProfileRefusedBecauseASpaceReferencesItDeletesNothing() throws {
        let db = try makeDatabaseWithPerProfileRows()
        let space = spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0)
        db.saveSession(spaces: [(space, [])], lastActiveSpaceID: nil)

        db.deleteProfile(id: testProfileID)

        XCTAssertEqual(Set(db.loadProfiles().map(\.id)), [testProfileID, "profile-2"], "the profile is kept")
        for table in perProfileTables {
            XCTAssertEqual(try rowCount(table, profileID: testProfileID, in: db), 1, "\(table) rows are kept")
            XCTAssertEqual(try rowCount(table, profileID: "profile-2", in: db), 1)
        }
        for table in extensionKeyedTables {
            XCTAssertEqual(try rowCount(table, in: db), 1, "\(table) is untouched")
        }
    }

    // MARK: - Pending profile data removal (TASK-32)

    func testDeleteProfileRecordsAPendingDataRemovalOnlyWhenItDeletes() throws {
        let db = try makeDatabaseWithPerProfileRows()
        let space = spaceRecord(id: "s1", name: "Home", emoji: "🏠", colorHex: "007AFF", sortOrder: 0)
        db.saveSession(spaces: [(space, [])], lastActiveSpaceID: nil)

        XCTAssertFalse(db.deleteProfile(id: testProfileID), "refused: a space references it")
        XCTAssertEqual(db.pendingProfileDataRemovals(), [], "a refused delete records nothing")

        XCTAssertTrue(db.deleteProfile(id: "profile-2"))
        XCTAssertEqual(db.pendingProfileDataRemovals(), ["profile-2"])

        XCTAssertFalse(db.deleteProfile(id: "profile-2"), "no such row any more")
        XCTAssertEqual(db.pendingProfileDataRemovals(), ["profile-2"], "recorded once")

        db.clearPendingProfileDataRemoval(profileID: "profile-2")
        XCTAssertEqual(db.pendingProfileDataRemovals(), [])
    }
}
