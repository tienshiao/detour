import Foundation
import GRDB
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "storage")

/// Returns the app's data directory inside Application Support.
/// When the `DETOUR_DATA_DIR` environment variable is set (e.g. in the test scheme),
/// that subdirectory name is used instead of "Detour", keeping test data isolated.
func detourDataDirectory() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let subdir = detourDataDirectoryName()
    let dir = appSupport.appendingPathComponent(subdir, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The production data directory's name inside Application Support.
let defaultDetourDataDirectoryName = "Detour"

/// The data directory name in use: `DETOUR_DATA_DIR`, or "Detour" when unset.
func detourDataDirectoryName(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    environment["DETOUR_DATA_DIR"] ?? defaultDetourDataDirectoryName
}

struct AppDatabase {
    static let shared = AppDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        let dir = detourDataDirectory()
        let dbPath = dir.appendingPathComponent("browser.db").path

        dbQueue = try! DatabaseQueue(path: dbPath)
        try! Self.migrator.migrate(dbQueue)
    }

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Helpers

    private func performWrite(_ label: String, _ work: (GRDB.Database) throws -> Void) {
        do {
            try dbQueue.write(work)
        } catch {
            log.error("Failed to \(label): \(error.localizedDescription)")
        }
    }

    private func performWrite<T>(_ label: String, default defaultValue: T, _ work: (GRDB.Database) throws -> T) -> T {
        do {
            return try dbQueue.write(work)
        } catch {
            log.error("Failed to \(label): \(error.localizedDescription)")
            return defaultValue
        }
    }

    private func performRead<T>(_ label: String, default defaultValue: T, _ work: (GRDB.Database) throws -> T) -> T {
        do {
            return try dbQueue.read(work)
        } catch {
            log.error("Failed to \(label): \(error.localizedDescription)")
            return defaultValue
        }
    }

    // MARK: - Profiles

    func saveProfile(_ record: ProfileRecord) {
        performWrite("save profile") { db in
            try record.save(db)
        }
    }

    func loadProfiles() -> [ProfileRecord] {
        performRead("load profiles", default: []) { db in
            try ProfileRecord.fetchAll(db)
        }
    }

    /// Deletes the profile (see `deleteProfileRows`) unless a space still
    /// references it.
    ///
    /// Returns whether the profile row was deleted: false when a space still
    /// references it, when there was no such row, or when the write failed.
    @discardableResult
    func deleteProfile(id: String) -> Bool {
        performWrite("delete profile", default: false) { db in
            try Self.deleteProfileRows(ids: [id], in: db).contains(id)
        }
    }

    /// The one way a profile row is deleted (`deleteProfile`, and `saveProfiles`
    /// for profiles missing from the saved set), run inside the caller's write
    /// transaction. For each id that no space references it deletes every row
    /// keyed by the id (TASK-31) — per-profile extension state, the
    /// `runtime.onInstalled` ledger, favourites and the content blocker
    /// whitelist — then the profile row, and records a pending removal of the
    /// profile's on-disk WebKit data (TASK-32, `ProfileDataRemoval`) if there was
    /// a row, so the data is removed even if the app quits first.
    ///
    /// `favorite`, `profileExtension` and `contentBlockerWhitelist` also cascade
    /// from the profile row, but only while foreign keys are enforced, and
    /// `extensionInstalledEvent` has no foreign key at all, so each is deleted
    /// explicitly. Rows keyed by extension alone (`extension`, `extensionStorage`,
    /// `extensionPermission`) are shared by every profile and are left alone.
    /// An id a space still references is skipped entirely.
    ///
    /// Returns the ids whose profile row was deleted.
    private static func deleteProfileRows(ids: [String], in db: GRDB.Database) throws -> [String] {
        var deletedIDs: [String] = []
        for id in ids {
            let spaceCount = try SpaceRecord.filter(Column("profileID") == id).fetchCount(db)
            guard spaceCount == 0 else {
                log.error("Cannot delete profile \(id): \(spaceCount) space(s) still reference it")
                continue
            }
            try ProfileExtensionRecord.filter(Column("profileID") == id).deleteAll(db)
            try ExtensionInstalledEventRecord.filter(Column("profileID") == id).deleteAll(db)
            try FavoriteRecord.filter(Column("profileID") == id).deleteAll(db)
            try ContentBlockerWhitelistRecord.filter(Column("profileID") == id).deleteAll(db)
            if try ProfileRecord.filter(Column("id") == id).deleteAll(db) > 0 {
                try recordPendingProfileDataRemoval(profileID: id, in: db)
                deletedIDs.append(id)
            }
        }
        return deletedIDs
    }

    // MARK: - Pending profile data removals (TASK-32)

    /// Records that a deleted profile's on-disk WebKit data (its
    /// `WKWebsiteDataStore` and its extension controller storage, both keyed by
    /// the profile id) still has to be removed. Never recorded for the built-in
    /// Private profile, whose store and controller are non-persistent.
    static func recordPendingProfileDataRemoval(profileID: String, in db: GRDB.Database) throws {
        guard UUID(uuidString: profileID) != TabStore.incognitoProfileID else { return }
        try db.execute(
            sql: "INSERT OR IGNORE INTO pendingProfileDataRemoval (profileID, requestedAt) VALUES (?, ?)",
            arguments: [profileID, Date().timeIntervalSince1970]
        )
    }

    func recordPendingProfileDataRemoval(profileID: String) {
        performWrite("record pending profile data removal") { db in
            try Self.recordPendingProfileDataRemoval(profileID: profileID, in: db)
        }
    }

    /// Profile ids whose data removal has not succeeded yet, oldest first.
    func pendingProfileDataRemovals() -> [String] {
        performRead("load pending profile data removals", default: []) { db in
            try String.fetchAll(db, sql: "SELECT profileID FROM pendingProfileDataRemoval ORDER BY requestedAt, profileID")
        }
    }

    func clearPendingProfileDataRemoval(profileID: String) {
        performWrite("clear pending profile data removal") { db in
            try db.execute(sql: "DELETE FROM pendingProfileDataRemoval WHERE profileID = ?", arguments: [profileID])
        }
    }

    // MARK: - Session

    /// Saves `records` as the complete set of profiles, in one transaction. A
    /// stored profile missing from the set is deleted with its per-profile rows
    /// and gets a pending data removal (`deleteProfileRows`), unless a space still
    /// references it, in which case it is kept.
    ///
    /// The pending removal is only recorded here; it runs at the next launch,
    /// which re-checks the profile table. TabStore saves every profile it holds
    /// (every non-Private profile plus the built-in Private one), so a row missing
    /// from the set is one no live profile of that store owns: a profile
    /// `deleteProfile` could not delete, or the saved profiles of a launch whose
    /// session had no spaces and so never loaded them.
    func saveProfiles(_ records: [ProfileRecord]) {
        performWrite("save profiles") { db in
            let savedIDs = Set(records.map(\.id))
            let removedIDs = try String.fetchAll(db, sql: "SELECT id FROM profile").filter { !savedIDs.contains($0) }
            _ = try Self.deleteProfileRows(ids: removedIDs, in: db)
            for record in records {
                try record.save(db)
            }
        }
    }

    func saveSession(spaces: [(SpaceRecord, [TabRecord])], lastActiveSpaceID: String?) {
        performWrite("save session") { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try SpaceRecord.deleteAll(db)

            for (spaceRecord, tabRecords) in spaces {
                try spaceRecord.insert(db)
                for tabRecord in tabRecords {
                    try tabRecord.insert(db)
                }
            }

            if let activeID = lastActiveSpaceID {
                try db.execute(
                    sql: "INSERT INTO appState (key, value) VALUES ('lastActiveSpaceID', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [activeID]
                )
            }
        }
    }

    // MARK: - Closed Tab Stack

    private static let closedTabCap = 100

    func pushClosedTab(_ record: ClosedTabRecord) {
        performWrite("push closed tab") { db in
            try record.insert(db)
            let count = try ClosedTabRecord.fetchCount(db)
            if count > Self.closedTabCap {
                let excess = count - Self.closedTabCap
                try db.execute(
                    sql: "DELETE FROM closedTab WHERE id IN (SELECT id FROM closedTab ORDER BY id ASC LIMIT ?)",
                    arguments: [excess]
                )
            }
        }
    }

    func popClosedTab(spaceID: String) -> ClosedTabRecord? {
        performWrite("pop closed tab", default: nil) { db in
            guard let record = try ClosedTabRecord
                .filter(Column("spaceID") == spaceID)
                .order(Column("id").desc)
                .fetchOne(db) else { return nil }
            try record.delete(db)
            return record
        }
    }

    func loadClosedTabs() -> [ClosedTabRecord] {
        performRead("load closed tabs", default: []) { db in
            try ClosedTabRecord.order(Column("id").desc).fetchAll(db)
        }
    }

    func deleteClosedTabs(spaceID: String) {
        performWrite("delete closed tabs for space") { db in
            try ClosedTabRecord
                .filter(Column("spaceID") == spaceID)
                .deleteAll(db)
        }
    }

    /// Deletes the closed-tab row(s) for a specific tab. Used when undoing a tab
    /// close so the in-memory stack and the DB stay in sync (otherwise the row is
    /// reloaded on next launch and Cmd+Shift+T reopens a duplicate). A given tabID
    /// appears at most once because reopen/undo always mint a fresh tab UUID.
    func deleteClosedTab(tabID: String) {
        performWrite("delete closed tab") { db in
            try ClosedTabRecord
                .filter(Column("tabID") == tabID)
                .deleteAll(db)
        }
    }

    // MARK: - Downloads

    func saveDownload(_ record: DownloadRecord) {
        performWrite("save download") { db in
            try record.save(db)
        }
    }

    func loadDownloads() -> [DownloadRecord] {
        performRead("load downloads", default: []) { db in
            try DownloadRecord.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func deleteDownload(id: String) {
        performWrite("delete download") { db in
            try DownloadRecord.filter(Column("id") == id).deleteAll(db)
        }
    }

    func deleteCompletedDownloads() {
        performWrite("delete completed downloads") { db in
            try DownloadRecord.filter(Column("state") == "completed").deleteAll(db)
        }
    }

    // MARK: - Content Blocker Whitelist

    func saveContentBlockerWhitelistEntry(_ record: ContentBlockerWhitelistRecord) {
        performWrite("save whitelist entry") { db in
            try record.save(db)
        }
    }

    func deleteContentBlockerWhitelistEntry(profileID: String, host: String) {
        performWrite("delete whitelist entry") { db in
            try ContentBlockerWhitelistRecord
                .filter(Column("profileID") == profileID && Column("host") == host)
                .deleteAll(db)
        }
    }

    func loadContentBlockerWhitelist() -> [ContentBlockerWhitelistRecord] {
        performRead("load whitelist", default: []) { db in
            try ContentBlockerWhitelistRecord.fetchAll(db)
        }
    }

    // MARK: - Pinned Tabs

    func savePinnedTabs(_ records: [PinnedTabRecord], spaceID: String) {
        performWrite("save pinned tabs") { db in
            try PinnedTabRecord
                .filter(Column("spaceID") == spaceID)
                .deleteAll(db)
            for record in records {
                try record.insert(db)
            }
        }
    }

    func loadPinnedTabs(spaceID: String) -> [PinnedTabRecord] {
        performRead("load pinned tabs", default: []) { db in
            try PinnedTabRecord
                .filter(Column("spaceID") == spaceID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    // MARK: - Pinned Folders

    func savePinnedFolders(_ records: [PinnedFolderRecord], spaceID: String) {
        performWrite("save pinned folders") { db in
            try PinnedFolderRecord
                .filter(Column("spaceID") == spaceID)
                .deleteAll(db)
            for record in records {
                try record.insert(db)
            }
        }
    }

    /// Saves both folders and tabs in a single transaction to avoid FK violations.
    func savePinnedFoldersAndTabs(folders: [PinnedFolderRecord], tabs: [PinnedTabRecord], spaceID: String) {
        performWrite("save pinned folders and tabs") { db in
            // Delete tabs first (they reference folders), then folders
            try PinnedTabRecord
                .filter(Column("spaceID") == spaceID)
                .deleteAll(db)
            try PinnedFolderRecord
                .filter(Column("spaceID") == spaceID)
                .deleteAll(db)
            // Insert folders first (tabs reference them)
            for record in folders {
                try record.insert(db)
            }
            for record in tabs {
                try record.insert(db)
            }
        }
    }

    func loadPinnedFolders(spaceID: String) -> [PinnedFolderRecord] {
        performRead("load pinned folders", default: []) { db in
            try PinnedFolderRecord
                .filter(Column("spaceID") == spaceID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    func loadSession() -> (spaces: [(SpaceRecord, [TabRecord])], lastActiveSpaceID: String?)? {
        performRead("load session", default: nil) { db in
            let spaceRecords = try SpaceRecord.order(Column("sortOrder")).fetchAll(db)
            guard !spaceRecords.isEmpty else { return nil }

            var spaces: [(SpaceRecord, [TabRecord])] = []
            for spaceRecord in spaceRecords {
                let tabRecords = try TabRecord
                    .filter(Column("spaceID") == spaceRecord.id)
                    .order(Column("sortOrder"))
                    .fetchAll(db)
                spaces.append((spaceRecord, tabRecords))
            }

            let lastActiveSpaceID = try String.fetchOne(db, sql: "SELECT value FROM appState WHERE key = 'lastActiveSpaceID'")
            return (spaces, lastActiveSpaceID)
        }
    }

    /// Internal (not private) so tests can migrate a database part-way and check
    /// what a later migration does to existing rows.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            // Profile
            try db.create(table: "profile") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("userAgentMode", .integer).notNull().defaults(to: 0)
                t.column("customUserAgent", .text)
                t.column("archiveThreshold", .double).notNull().defaults(to: 43200)
                t.column("searchEngine", .integer).notNull().defaults(to: 0)
                t.column("searchSuggestionsEnabled", .boolean).notNull().defaults(to: true)
                t.column("isPerTabIsolation", .boolean).notNull().defaults(to: false)
                t.column("sleepThreshold", .double).notNull().defaults(to: 3600)
                t.column("isAdBlockingEnabled", .boolean).notNull().defaults(to: true)
                t.column("isEasyListEnabled", .boolean).notNull().defaults(to: true)
                t.column("isEasyPrivacyEnabled", .boolean).notNull().defaults(to: true)
                t.column("isEasyListCookieEnabled", .boolean).notNull().defaults(to: true)
                t.column("isMalwareFilterEnabled", .boolean).notNull().defaults(to: true)
            }

            // Space
            try db.create(table: "space") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("emoji", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("sortOrder", .integer).notNull()
                t.column("selectedTabID", .text)
                t.column("profileID", .text).notNull()
                    .references("profile")
            }

            // Tab
            try db.create(table: "tab") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("url", .text)
                t.column("title", .text).notNull().defaults(to: "New Tab")
                t.column("faviconURL", .text)
                t.column("interactionState", .blob)
                t.column("sortOrder", .integer).notNull()
                t.column("lastDeselectedAt", .double)
                t.column("parentID", .text)
                t.column("peekURL", .text)
                t.column("peekInteractionState", .blob)
                t.column("peekFaviconURL", .text)
            }

            // App state
            try db.create(table: "appState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }

            // Closed tabs
            try db.create(table: "closedTab") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tabID", .text).notNull()
                t.column("spaceID", .text).notNull()
                t.column("url", .text)
                t.column("title", .text).notNull()
                t.column("faviconURL", .text)
                t.column("interactionState", .blob)
                t.column("sortOrder", .integer).notNull()
                t.column("archivedAt", .double)
            }

            // Downloads
            try db.create(table: "download") { t in
                t.primaryKey("id", .text)
                t.column("filename", .text).notNull()
                t.column("sourceURL", .text)
                t.column("destinationURL", .text).notNull()
                t.column("totalBytes", .integer).notNull().defaults(to: -1)
                t.column("bytesWritten", .integer).notNull().defaults(to: 0)
                t.column("state", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }

            // Pinned folders
            try db.create(table: "pinnedFolder") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("parentFolderID", .text)
                    .references("pinnedFolder", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("isCollapsed", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull()
            }

            // Pinned tabs (slim: no duplicated tab fields, FK to tab)
            try db.create(table: "pinnedTab") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("pinnedURL", .text).notNull()
                t.column("pinnedTitle", .text).notNull()
                t.column("faviconURL", .text)
                t.column("sortOrder", .integer).notNull()
                t.column("folderID", .text)
                    .references("pinnedFolder", onDelete: .setNull)
                t.column("tabID", .text)
                    .references("tab", onDelete: .setNull)
            }

            // Content blocker whitelist
            try db.create(table: "contentBlockerWhitelist") { t in
                t.column("profileID", .text).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("host", .text).notNull()
                t.uniqueKey(["profileID", "host"])
            }
        }

        migrator.registerMigration("v2") { db in
            // Move extension tables from extensions.db into browser.db
            try db.create(table: "extension") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("version", .text).notNull()
                t.column("manifestJSON", .blob).notNull()
                t.column("basePath", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("installedAt", .double).notNull()
            }

            try db.create(table: "extensionStorage") { t in
                t.column("extensionID", .text).notNull()
                    .references("extension", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("value", .blob).notNull()
                t.primaryKey(["extensionID", "key"])
            }

            // Per-profile extension state (opt-out: missing row = enabled)
            try db.create(table: "profileExtension") { t in
                t.column("profileID", .text).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("extensionID", .text).notNull()
                    .references("extension", onDelete: .cascade)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.primaryKey(["profileID", "extensionID"])
            }
        }

        migrator.registerMigration("v3") { db in
            try db.create(table: "extensionPermission") { t in
                t.column("extensionID", .text).notNull()
                    .references("extension", onDelete: .cascade)
                t.column("permissionKey", .text).notNull()
                t.column("permissionType", .integer).notNull()
                t.column("status", .integer).notNull()
                t.column("grantedAt", .double).notNull()
                t.primaryKey(["extensionID", "permissionKey", "permissionType"])
            }
        }

        migrator.registerMigration("v4") { db in
            try db.create(table: "favorite") { t in
                t.primaryKey("id", .text)
                t.column("profileID", .text).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("url", .text).notNull()
                t.column("title", .text).notNull()
                t.column("faviconURL", .text)
                t.column("sortOrder", .integer).notNull()
                t.column("tabID", .text)
                    .references("tab", onDelete: .setNull)
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "profileExtension") { t in
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "tab") { t in
                t.add(column: "splitGroupID", .text)
                t.add(column: "splitFraction", .double)
            }
        }

        migrator.registerMigration("v7") { db in
            try db.alter(table: "pinnedTab") { t in
                t.add(column: "splitGroupID", .text)
                t.add(column: "splitFraction", .double)
            }
        }

        // TASK-24: the durable identity of an extension page. WebKit mints a fresh
        // webkit-extension://<uuid>/ origin per context load, so a stored URL on
        // its own is dead after a relaunch; the id (with the path/query/fragment
        // the URL already carries) lets restore rewrite it onto the current
        // context. NULL for every URL that is not an extension page.
        migrator.registerMigration("v8") { db in
            for table in ["tab", "pinnedTab", "favorite", "closedTab"] {
                try db.alter(table: table) { t in
                    t.add(column: "extensionID", .text)
                }
            }
        }

        migrator.registerMigration("v9") { db in
            // runtime.onInstalled ledger (TASK-22, RuntimeInstalledEvent).
            try db.create(table: "extensionInstalledEvent") { t in
                t.column("extensionID", .text).notNull()
                t.column("profileID", .text).notNull()
                t.column("deliveredVersion", .text).notNull()
                t.column("deliveredAt", .double).notNull()
                t.primaryKey(["extensionID", "profileID"])
            }
            // Extensions installed before the ledger existed have had their
            // install (or WebKit's version of it) already: seed every saved
            // profile with the installed version, or upgrading Detour would
            // deliver `install` to all of them at the next launch. Profiles made
            // later have no row and get `install` when the extension first runs
            // there, which is Chrome's per-profile rule.
            try db.execute(sql: """
                INSERT INTO extensionInstalledEvent (extensionID, profileID, deliveredVersion, deliveredAt)
                SELECT e.id, p.id, e.version, ? FROM "extension" e CROSS JOIN profile p
                """, arguments: [Date().timeIntervalSince1970])
        }

        migrator.registerMigration("v10") { db in
            // TASK-29: a reinstall owes an `update` even at the same version, which a
            // version-only ledger cannot tell from a reload.
            try db.alter(table: "extensionInstalledEvent") { t in
                t.add(column: "reinstallPending", .boolean).notNull().defaults(to: false)
            }
            // The Private profile never gets runtime.onInstalled, so the rows v9
            // seeded for it are dead. The literal is TabStore.incognitoProfileID,
            // spelled out so this migration cannot change meaning later.
            try db.execute(sql: "DELETE FROM extensionInstalledEvent WHERE profileID = ?",
                           arguments: ["00000000-0000-0000-0000-000000000001"])
        }

        migrator.registerMigration("v11") { db in
            // TASK-32: deleted profiles whose on-disk WebKit data (the
            // WKWebsiteDataStore and extension controller storage for the profile
            // id) has not been removed yet. No foreign key: the profile row is
            // already gone when a row is added here.
            try db.create(table: "pendingProfileDataRemoval") { t in
                t.primaryKey("profileID", .text)
                t.column("requestedAt", .double).notNull()
            }
        }

        return migrator
    }

    // MARK: - Favorites

    func saveFavorites(_ records: [FavoriteRecord], profileID: String) {
        performWrite("save favorites") { db in
            try FavoriteRecord
                .filter(Column("profileID") == profileID)
                .deleteAll(db)
            for record in records {
                try record.insert(db)
            }
        }
    }

    func loadFavorites(profileID: String) -> [FavoriteRecord] {
        performRead("load favorites", default: []) { db in
            try FavoriteRecord
                .filter(Column("profileID") == profileID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    // MARK: - Extension CRUD

    func saveExtension(_ record: ExtensionRecord) {
        performWrite("save extension") { db in
            try record.save(db)
        }
    }

    func loadExtensions() -> [ExtensionRecord] {
        performRead("load extensions", default: []) { db in
            try ExtensionRecord.fetchAll(db)
        }
    }

    func deleteExtension(id: String) {
        performWrite("delete extension") { db in
            try ExtensionRecord.filter(Column("id") == id).deleteAll(db)
            // A reinstall under the same id (a manifest key) is a new install.
            try ExtensionInstalledEventRecord.filter(Column("extensionID") == id).deleteAll(db)
        }
    }

    // MARK: - runtime.onInstalled ledger

    /// The `runtime.onInstalled` event the extension's context in `profileID`
    /// still owes, without delivering it. See `RuntimeInstalledEvent`.
    /// `isPrivateProfile` is the profile's `isIncognito`: the Private profile is
    /// never owed the event (TASK-29).
    func pendingRuntimeInstalledEvent(extensionID: String, profileID: String, isPrivateProfile: Bool,
                                      currentVersion: String) -> RuntimeInstalledEvent.Details? {
        guard !isPrivateProfile else { return nil }
        return performRead("read runtime.onInstalled ledger", default: nil) { db in
            let entry = try ExtensionInstalledEventRecord
                .filter(Column("extensionID") == extensionID && Column("profileID") == profileID)
                .fetchOne(db)?.ledgerEntry
            return RuntimeInstalledEvent.pending(ledger: entry, currentVersion: currentVersion,
                                                 isPrivateProfile: false)
        }
    }

    /// Take the owed `runtime.onInstalled` event, if any, and record it delivered —
    /// read and write in one transaction, so of any number of claims for the same
    /// version exactly one gets the event. The ledger advances *before* the worker
    /// dispatches: a worker that dies in between loses the event rather than
    /// risking it twice (Chrome drops its pending dispatch at the same point).
    /// Delivering clears a pending reinstall. Returns nil when nothing is owed —
    /// always for the Private profile, which is never written — or the write fails.
    func claimRuntimeInstalledEvent(extensionID: String, profileID: String, isPrivateProfile: Bool,
                                    currentVersion: String) -> RuntimeInstalledEvent.Details? {
        guard !isPrivateProfile else { return nil }
        return performWrite("claim runtime.onInstalled event", default: nil) { db in
            let entry = try ExtensionInstalledEventRecord
                .filter(Column("extensionID") == extensionID && Column("profileID") == profileID)
                .fetchOne(db)?.ledgerEntry
            guard let details = RuntimeInstalledEvent.pending(ledger: entry, currentVersion: currentVersion,
                                                              isPrivateProfile: false) else {
                return nil
            }
            try ExtensionInstalledEventRecord(
                extensionID: extensionID, profileID: profileID,
                deliveredVersion: currentVersion, deliveredAt: Date().timeIntervalSince1970,
                reinstallPending: false
            ).save(db)
            return details
        }
    }

    /// Record that the user reinstalled the extension (TASK-29): each profile the
    /// event was already delivered in is owed one `update` from that version, even
    /// when the version did not change. Profiles without a row still get `install`.
    /// Only `ExtensionManager.install` calls this — never a reload or an enable.
    func markRuntimeInstalledEventReinstalled(extensionID: String) {
        performWrite("mark runtime.onInstalled reinstall") { db in
            try db.execute(sql: "UPDATE extensionInstalledEvent SET reinstallPending = 1 WHERE extensionID = ?",
                           arguments: [extensionID])
        }
    }

    func setEnabled(id: String, enabled: Bool) {
        performWrite("update extension enabled state") { db in
            try db.execute(
                sql: "UPDATE \"extension\" SET isEnabled = ? WHERE id = ?",
                arguments: [enabled, id]
            )
        }
    }

    // MARK: - chrome.storage.local

    func storageGet(extensionID: String, keys: [String]) -> [String: Any] {
        performRead("get extension storage", default: [:]) { db in
            var result: [String: Any] = [:]
            for key in keys {
                if let record = try ExtensionStorageRecord
                    .filter(Column("extensionID") == extensionID && Column("key") == key)
                    .fetchOne(db) {
                    if let value = try? JSONSerialization.jsonObject(with: record.value, options: .fragmentsAllowed) {
                        result[key] = value
                    }
                }
            }
            return result
        }
    }

    func storageGetAll(extensionID: String) -> [String: Any] {
        performRead("get all extension storage", default: [:]) { db in
            var result: [String: Any] = [:]
            let records = try ExtensionStorageRecord
                .filter(Column("extensionID") == extensionID)
                .fetchAll(db)
            for record in records {
                if let value = try? JSONSerialization.jsonObject(with: record.value, options: .fragmentsAllowed) {
                    result[record.key] = value
                }
            }
            return result
        }
    }

    func storageSet(extensionID: String, items: [String: Any]) {
        performWrite("set extension storage") { db in
            for (key, value) in items {
                let jsonData = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
                let record = ExtensionStorageRecord(
                    extensionID: extensionID,
                    key: key,
                    value: jsonData
                )
                try record.save(db)
            }
        }
    }

    func storageRemove(extensionID: String, keys: [String]) {
        performWrite("remove extension storage") { db in
            for key in keys {
                try ExtensionStorageRecord
                    .filter(Column("extensionID") == extensionID && Column("key") == key)
                    .deleteAll(db)
            }
        }
    }

    func storageClear(extensionID: String) {
        performWrite("clear extension storage") { db in
            try ExtensionStorageRecord
                .filter(Column("extensionID") == extensionID)
                .deleteAll(db)
        }
    }

    // MARK: - Extension Permissions

    func savePermission(_ record: ExtensionPermissionRecord) {
        performWrite("save extension permission") { db in
            try record.save(db)
        }
    }

    func savePermissions(_ records: [ExtensionPermissionRecord]) {
        performWrite("save extension permissions") { db in
            for record in records {
                try record.save(db)
            }
        }
    }

    /// Every saved decision for an extension. Callers partition by type with
    /// `statusByKey(type:)` — never merge types, since a `.url` row can share
    /// its key string with a `.matchPattern` row.
    func loadPermissions(extensionID: String) -> [ExtensionPermissionRecord] {
        performRead("load extension permissions", default: []) { db in
            try ExtensionPermissionRecord
                .filter(Column("extensionID") == extensionID)
                .fetchAll(db)
        }
    }

    /// The saved decision for one key, or nil when none is saved.
    func permissionStatus(extensionID: String, key: String, type: ExtensionPermissionType) -> ExtensionPermissionStatus? {
        performRead("check extension permission", default: nil) { db in
            if let record = try ExtensionPermissionRecord
                .filter(Column("extensionID") == extensionID
                    && Column("permissionKey") == key
                    && Column("permissionType") == type.rawValue)
                .fetchOne(db) {
                // An unrecognised raw status fails closed, as `statusByKey` does:
                // a present-but-unreadable row must not read as "no decision".
                return ExtensionPermissionStatus(rawValue: record.status) ?? .denied
            }
            return nil
        }
    }

    func revokePermission(extensionID: String, key: String, type: ExtensionPermissionType) {
        performWrite("revoke extension permission") { db in
            try ExtensionPermissionRecord
                .filter(Column("extensionID") == extensionID
                    && Column("permissionKey") == key
                    && Column("permissionType") == type.rawValue)
                .deleteAll(db)
        }
    }

    // MARK: - Per-Profile Extension State

    /// Check if an extension is enabled for a specific profile.
    /// True if globally enabled AND (no per-profile row OR row.isEnabled).
    func isExtensionEnabled(extensionID: String, profileID: String) -> Bool {
        performRead("check extension enabled for profile", default: false) { db in
            // Check global enabled first
            guard let ext = try ExtensionRecord.filter(Column("id") == extensionID).fetchOne(db),
                  ext.isEnabled else {
                return false
            }
            // Check per-profile override
            if let row = try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("extensionID") == extensionID)
                .fetchOne(db) {
                return row.isEnabled
            }
            return true // missing row = enabled
        }
    }

    /// The profile's own choice, ignoring the global flag: true unless the
    /// profile has a row turning the extension off (missing row = enabled).
    func isExtensionEnabledByProfile(extensionID: String, profileID: String) -> Bool {
        performRead("check profile extension enabled row", default: true) { db in
            try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("extensionID") == extensionID)
                .fetchOne(db)?.isEnabled ?? true
        }
    }

    /// Upsert per-profile extension enabled state.
    func setProfileExtensionEnabled(extensionID: String, profileID: String, enabled: Bool) {
        performWrite("set profile extension enabled") { db in
            if var existing = try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("extensionID") == extensionID)
                .fetchOne(db) {
                existing.isEnabled = enabled
                try existing.update(db)
            } else {
                try ProfileExtensionRecord(profileID: profileID, extensionID: extensionID, isEnabled: enabled, isPinned: false).insert(db)
            }
        }
    }

    /// Returns extension IDs that are pinned for this profile.
    func pinnedExtensionIDs(for profileID: String) -> [String] {
        performRead("load pinned extension IDs", default: []) { db in
            try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("isPinned") == true)
                .fetchAll(db)
                .map(\.extensionID)
        }
    }

    /// Toggle the pinned state for an extension in a single transaction.
    func toggleExtensionPinned(extensionID: String, profileID: String) {
        performWrite("toggle extension pinned") { db in
            if var existing = try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("extensionID") == extensionID)
                .fetchOne(db) {
                existing.isPinned = !existing.isPinned
                try existing.update(db)
            } else {
                try ProfileExtensionRecord(profileID: profileID, extensionID: extensionID, isEnabled: true, isPinned: true).insert(db)
            }
        }
    }

    /// Ids of every installed extension, enabled or not.
    func installedExtensionIDs() -> Set<String> {
        performRead("load installed extension IDs", default: []) { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM \"extension\""))
        }
    }

    /// Returns the set of extension IDs that are globally enabled and not disabled for this profile.
    func enabledExtensionIDs(for profileID: String) -> Set<String> {
        performRead("load enabled extension IDs for profile", default: []) { db in
            let globallyEnabled = try ExtensionRecord
                .filter(Column("isEnabled") == true)
                .fetchAll(db)
            let disabledForProfile = try ProfileExtensionRecord
                .filter(Column("profileID") == profileID && Column("isEnabled") == false)
                .fetchAll(db)
            let disabledIDs = Set(disabledForProfile.map(\.extensionID))
            return Set(globallyEnabled.map(\.id).filter { !disabledIDs.contains($0) })
        }
    }
}
