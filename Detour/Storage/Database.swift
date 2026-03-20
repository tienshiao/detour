import Foundation
import GRDB

/// Returns the app's data directory inside Application Support.
/// When the `DETOUR_DATA_DIR` environment variable is set (e.g. in the test scheme),
/// that subdirectory name is used instead of "Detour", keeping test data isolated.
func detourDataDirectory() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let subdir = ProcessInfo.processInfo.environment["DETOUR_DATA_DIR"] ?? "Detour"
    let dir = appSupport.appendingPathComponent(subdir, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct AppDatabase {
    static let shared = AppDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        let dir = detourDataDirectory()
        let dbPath = dir.appendingPathComponent("browser.db").path

        dbQueue = try! DatabaseQueue(path: dbPath)
        try! migrator.migrate(dbQueue)
    }

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    // MARK: - Helpers

    private func performWrite(_ label: String, _ work: (GRDB.Database) throws -> Void) {
        do {
            try dbQueue.write(work)
        } catch {
            print("Failed to \(label): \(error)")
        }
    }

    private func performWrite<T>(_ label: String, default defaultValue: T, _ work: (GRDB.Database) throws -> T) -> T {
        do {
            return try dbQueue.write(work)
        } catch {
            print("Failed to \(label): \(error)")
            return defaultValue
        }
    }

    private func performRead<T>(_ label: String, default defaultValue: T, _ work: (GRDB.Database) throws -> T) -> T {
        do {
            return try dbQueue.read(work)
        } catch {
            print("Failed to \(label): \(error)")
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

    func deleteProfile(id: String) {
        performWrite("delete profile") { db in
            // Guard: don't delete if any spaces reference it
            let count = try SpaceRecord.filter(Column("profileID") == id).fetchCount(db)
            guard count == 0 else {
                print("Cannot delete profile \(id): \(count) space(s) still reference it")
                return
            }
            try ProfileRecord.filter(Column("id") == id).deleteAll(db)
        }
    }

    // MARK: - Session

    func saveProfiles(_ records: [ProfileRecord]) {
        performWrite("save profiles") { db in
            // Delete profiles not in the new set
            let ids = records.map { $0.id }
            try ProfileRecord.filter(!ids.contains(Column("id"))).deleteAll(db)
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

    private var migrator: DatabaseMigrator {
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

        return migrator
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

    /// Upsert per-profile extension enabled state.
    func setProfileExtensionEnabled(extensionID: String, profileID: String, enabled: Bool) {
        performWrite("set profile extension enabled") { db in
            let record = ProfileExtensionRecord(profileID: profileID, extensionID: extensionID, isEnabled: enabled)
            try record.save(db)
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
