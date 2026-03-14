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

    func saveSession(spaces: [(SpaceRecord, [TabRecord])], lastActiveSpaceID: String?) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                // Clear existing session data (tabs cascade-deleted via FK)
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
        } catch {
            print("Failed to save session: \(error)")
        }
    }

    // MARK: - Closed Tab Stack

    private static let closedTabCap = 100

    func pushClosedTab(_ record: ClosedTabRecord) {
        do {
            try dbQueue.write { db in
                var r = record
                try r.insert(db)
                // Trim oldest entries beyond cap
                let count = try ClosedTabRecord.fetchCount(db)
                if count > Self.closedTabCap {
                    let excess = count - Self.closedTabCap
                    try db.execute(
                        sql: "DELETE FROM closedTab WHERE id IN (SELECT id FROM closedTab ORDER BY id ASC LIMIT ?)",
                        arguments: [excess]
                    )
                }
            }
        } catch {
            print("Failed to push closed tab: \(error)")
        }
    }

    func popClosedTab(spaceID: String) -> ClosedTabRecord? {
        do {
            return try dbQueue.write { db in
                guard let record = try ClosedTabRecord
                    .filter(Column("spaceID") == spaceID)
                    .order(Column("id").desc)
                    .fetchOne(db) else { return nil }
                try record.delete(db)
                return record
            }
        } catch {
            print("Failed to pop closed tab: \(error)")
            return nil
        }
    }

    func loadClosedTabs() -> [ClosedTabRecord] {
        do {
            return try dbQueue.read { db in
                try ClosedTabRecord.order(Column("id").desc).fetchAll(db)
            }
        } catch {
            print("Failed to load closed tabs: \(error)")
            return []
        }
    }

    func deleteClosedTabs(spaceID: String) {
        do {
            try dbQueue.write { db in
                try ClosedTabRecord
                    .filter(Column("spaceID") == spaceID)
                    .deleteAll(db)
            }
        } catch {
            print("Failed to delete closed tabs for space: \(error)")
        }
    }

    // MARK: - Downloads

    func saveDownload(_ record: DownloadRecord) {
        do {
            try dbQueue.write { db in
                try record.save(db)
            }
        } catch {
            print("Failed to save download: \(error)")
        }
    }

    func loadDownloads() -> [DownloadRecord] {
        do {
            return try dbQueue.read { db in
                try DownloadRecord.order(Column("createdAt").desc).fetchAll(db)
            }
        } catch {
            print("Failed to load downloads: \(error)")
            return []
        }
    }

    func deleteDownload(id: String) {
        do {
            try dbQueue.write { db in
                try DownloadRecord.filter(Column("id") == id).deleteAll(db)
            }
        } catch {
            print("Failed to delete download: \(error)")
        }
    }

    func deleteCompletedDownloads() {
        do {
            try dbQueue.write { db in
                try DownloadRecord.filter(Column("state") == "completed").deleteAll(db)
            }
        } catch {
            print("Failed to delete completed downloads: \(error)")
        }
    }

    // MARK: - Pinned Tabs

    func savePinnedTabs(_ records: [PinnedTabRecord], spaceID: String) {
        do {
            try dbQueue.write { db in
                try PinnedTabRecord
                    .filter(Column("spaceID") == spaceID)
                    .deleteAll(db)
                for record in records {
                    try record.insert(db)
                }
            }
        } catch {
            print("Failed to save pinned tabs: \(error)")
        }
    }

    func loadPinnedTabs(spaceID: String) -> [PinnedTabRecord] {
        do {
            return try dbQueue.read { db in
                try PinnedTabRecord
                    .filter(Column("spaceID") == spaceID)
                    .order(Column("sortOrder"))
                    .fetchAll(db)
            }
        } catch {
            print("Failed to load pinned tabs: \(error)")
            return []
        }
    }

    func loadSession() -> (spaces: [(SpaceRecord, [TabRecord])], lastActiveSpaceID: String?)? {
        do {
            return try dbQueue.read { db in
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
        } catch {
            print("Failed to load session: \(error)")
            return nil
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

        return migrator
    }
}
