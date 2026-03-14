import Foundation
import GRDB

struct AppDatabase {
    static let shared = AppDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Detour", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
            var r = record
            try r.insert(db)
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

        migrator.registerMigration("v1") { db in
            try db.create(table: "space") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("emoji", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("sortOrder", .integer).notNull()
                t.column("selectedTabID", .text)
            }

            try db.create(table: "tab") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("url", .text)
                t.column("title", .text).notNull().defaults(to: "New Tab")
                t.column("faviconURL", .text)
                t.column("interactionState", .blob)
                t.column("sortOrder", .integer).notNull()
            }

            try db.create(table: "appState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }

        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "closedTab") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tabID", .text).notNull()
                t.column("spaceID", .text).notNull()
                t.column("url", .text)
                t.column("title", .text).notNull()
                t.column("faviconURL", .text)
                t.column("interactionState", .blob)
                t.column("sortOrder", .integer).notNull()
            }
        }

        migrator.registerMigration("v3") { db in
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
        }

        migrator.registerMigration("v4") { db in
            try db.create(table: "pinnedTab") { t in
                t.primaryKey("id", .text)
                t.column("spaceID", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("pinnedURL", .text).notNull()
                t.column("pinnedTitle", .text).notNull()
                t.column("url", .text)
                t.column("title", .text)
                t.column("faviconURL", .text)
                t.column("interactionState", .blob)
                t.column("sortOrder", .integer).notNull()
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "tab") { t in
                t.add(column: "lastDeselectedAt", .double)
            }
            try db.alter(table: "closedTab") { t in
                t.add(column: "archivedAt", .double)
            }
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "tab") { t in
                t.add(column: "parentID", .text)
            }
        }

        migrator.registerMigration("v7") { db in
            // Create profile table
            try db.create(table: "profile") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("userAgentMode", .integer).notNull().defaults(to: 0)
                t.column("customUserAgent", .text)
                t.column("archiveThreshold", .double).notNull().defaults(to: 43200)
            }

            // Insert default profile
            let defaultProfileID = UUID().uuidString
            try db.execute(
                sql: "INSERT INTO profile (id, name, userAgentMode, archiveThreshold) VALUES (?, 'Default', 0, 43200)",
                arguments: [defaultProfileID]
            )

            // Add profileID column to space table referencing the default profile
            try db.alter(table: "space") { t in
                t.add(column: "profileID", .text)
                    .notNull()
                    .defaults(to: defaultProfileID)
                    .references("profile")
            }
        }

        return migrator
    }
}
