import XCTest
import GRDB
@testable import Detour

/// TASK-187: per-site settings live in one table (`siteSetting`), read through
/// `SiteSettingsStore`'s per-profile cache. Content blocking's site list moved
/// into it from `contentBlockerWhitelist`.
final class SiteSettingsStoreTests: XCTestCase {

    private let profileA = UUID()
    private let profileB = UUID()

    private func makeProfile(_ id: UUID) -> ProfileRecord {
        ProfileRecord(id: id.uuidString, name: "P", userAgentMode: 0, customUserAgent: nil,
                      archiveThreshold: 43200, sleepThreshold: 3600, searchEngine: 0,
                      searchSuggestionsEnabled: true, isPerTabIsolation: false, isAdBlockingEnabled: true,
                      isEasyListEnabled: true, isEasyPrivacyEnabled: true, isEasyListCookieEnabled: true,
                      isMalwareFilterEnabled: true)
    }

    private func makeDatabase() throws -> AppDatabase {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        db.saveProfile(makeProfile(profileA))
        db.saveProfile(makeProfile(profileB))
        return db
    }

    // MARK: - Set, clear, query

    func testASiteWithNoRowHasNoOverride() throws {
        let store = SiteSettingsStore(database: try makeDatabase())
        XCTAssertNil(store.override(.contentBlocking, forSite: "example.com", profileID: profileA))
        XCTAssertTrue(store.overrides(.contentBlocking, profileID: profileA).isEmpty)
    }

    func testASetValueIsReadBackAndSurvivesANewStore() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.contentBlocking, site: "example.com", to: false, profileID: profileA)

        XCTAssertEqual(store.override(.contentBlocking, forSite: "example.com", profileID: profileA), false)
        XCTAssertEqual(store.overrides(.contentBlocking, profileID: profileA), ["example.com": false])

        let reloaded = SiteSettingsStore(database: db)
        XCTAssertEqual(reloaded.override(.contentBlocking, forSite: "example.com", profileID: profileA), false)
        XCTAssertEqual(db.loadSiteSettings().map(\.setting), ["contentBlocking"])
    }

    func testSettingAgainReplacesTheValue() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.contentBlocking, site: "example.com", to: false, profileID: profileA)
        store.set(.contentBlocking, site: "example.com", to: true, profileID: profileA)

        XCTAssertEqual(SiteSettingsStore(database: db).override(.contentBlocking, forSite: "example.com",
                                                                profileID: profileA), true)
        XCTAssertEqual(db.loadSiteSettings().count, 1)
    }

    func testSitesAreStoredLowercased() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.contentBlocking, site: "Example.COM", to: false, profileID: profileA)

        XCTAssertEqual(store.overrides(.contentBlocking, profileID: profileA), ["example.com": false])
        XCTAssertEqual(db.loadSiteSettings().map(\.site), ["example.com"])
    }

    func testClearingRemovesTheRowsAndTheOverride() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.contentBlocking, site: "example.com", to: false, profileID: profileA)
        store.set(.contentBlocking, site: "other.test", to: false, profileID: profileA)

        store.clear(.contentBlocking, sites: ["example.com"], profileID: profileA)

        XCTAssertNil(store.override(.contentBlocking, forSite: "example.com", profileID: profileA))
        XCTAssertEqual(store.overrides(.contentBlocking, profileID: profileA), ["other.test": false])
        XCTAssertEqual(SiteSettingsStore(database: db).overrides(.contentBlocking, profileID: profileA),
                       ["other.test": false])
    }

    func testProfilesDoNotSeeEachOthersSettings() throws {
        let db = try makeDatabase()
        let store = SiteSettingsStore(database: db)
        store.set(.contentBlocking, site: "example.com", to: false, profileID: profileA)

        XCTAssertNil(store.override(.contentBlocking, forSite: "example.com", profileID: profileB))
        store.clear(.contentBlocking, sites: ["example.com"], profileID: profileB)
        XCTAssertEqual(store.override(.contentBlocking, forSite: "example.com", profileID: profileA), false,
                       "clearing in another profile leaves this one's row")
    }

    /// A row written by a newer build for a setting this build does not know
    /// is ignored, not deleted.
    func testAnUnknownSettingIsIgnoredAndKept() throws {
        let db = try makeDatabase()
        try db.dbQueue.write { d in
            try d.execute(sql: "INSERT INTO siteSetting (profileID, site, setting, value) VALUES (?, 'example.com', 'futureSetting', 1)",
                          arguments: [profileA.uuidString])
        }
        let store = SiteSettingsStore(database: db)
        XCTAssertNil(store.override(.contentBlocking, forSite: "example.com", profileID: profileA))
        store.set(.contentBlocking, site: "example.com", to: false, profileID: profileA)
        XCTAssertEqual(Set(db.loadSiteSettings().map(\.setting)), ["futureSetting", "contentBlocking"])
    }

    // MARK: - Matching

    func testContentBlockingMatchesTheHostAndItsSubdomains() throws {
        let store = SiteSettingsStore(database: try makeDatabase())
        store.set(.contentBlocking, site: "example.com", to: false, profileID: profileA)

        XCTAssertEqual(store.override(.contentBlocking, forSite: "www.example.com", profileID: profileA), false)
        XCTAssertEqual(store.override(.contentBlocking, forSite: "A.B.Example.com", profileID: profileA), false)
        XCTAssertNil(store.override(.contentBlocking, forSite: "notexample.com", profileID: profileA))
        XCTAssertNil(store.override(.contentBlocking, forSite: "", profileID: profileA))
    }

    func testTheMostSpecificSiteWins() throws {
        let store = SiteSettingsStore(database: try makeDatabase())
        store.set(.contentBlocking, site: "example.com", to: false, profileID: profileA)
        store.set(.contentBlocking, site: "www.example.com", to: true, profileID: profileA)

        XCTAssertEqual(store.override(.contentBlocking, forSite: "www.example.com", profileID: profileA), true)
        XCTAssertEqual(store.override(.contentBlocking, forSite: "a.www.example.com", profileID: profileA), true)
        XCTAssertEqual(store.override(.contentBlocking, forSite: "mail.example.com", profileID: profileA), false)
    }

    // MARK: - Migration v18

    /// v18 moves every content-blocking exception into `siteSetting` as
    /// `contentBlocking = false` and drops the old table. Hosts are lowercased
    /// (the old loader lowercased them too), so two spellings of one host
    /// become one row; a row whose profile no longer exists is dropped.
    func testMigrationV18MovesTheContentBlockerWhitelistIntoSiteSettings() throws {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v17")
        try dbQueue.write { d in
            for profile in [profileA, profileB] {
                try makeProfile(profile).insert(d)
            }
            for (profile, host) in [(profileA.uuidString, "example.com"), (profileA.uuidString, "Example.com"),
                                    (profileA.uuidString, "other.test"), (profileB.uuidString, "example.com")] {
                try d.execute(sql: "INSERT INTO contentBlockerWhitelist (profileID, host) VALUES (?, ?)",
                              arguments: [profile, host])
            }
        }
        // A row left by a profile deleted while foreign keys were off. The
        // pragma is a no-op inside a transaction, hence no `write`.
        try dbQueue.writeWithoutTransaction { d in
            try d.execute(sql: "PRAGMA foreign_keys = OFF")
            try d.execute(sql: "INSERT INTO contentBlockerWhitelist (profileID, host) VALUES ('gone-profile', 'orphan.test')")
            try d.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let db = try AppDatabase(dbQueue: dbQueue)

        let rows = db.loadSiteSettings()
        XCTAssertEqual(Set(rows.map { "\($0.profileID) \($0.site) \($0.setting) \($0.value)" }), [
            "\(profileA.uuidString) example.com contentBlocking false",
            "\(profileA.uuidString) other.test contentBlocking false",
            "\(profileB.uuidString) example.com contentBlocking false",
        ])
        let oldTableExists = try dbQueue.read { try $0.tableExists("contentBlockerWhitelist") }
        XCTAssertFalse(oldTableExists)

        let whitelist = ContentBlockerWhitelist(store: SiteSettingsStore(database: db))
        XCTAssertTrue(whitelist.isWhitelisted(host: "www.example.com", profileID: profileA),
                      "content blocking reads the moved rows with the same subdomain coverage")
        XCTAssertFalse(whitelist.isWhitelisted(host: "other.test", profileID: profileB))
    }
}
