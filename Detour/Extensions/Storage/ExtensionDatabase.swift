import Foundation
import GRDB

struct ExtensionDatabase {
    static let shared = ExtensionDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Detour", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("extensions.db").path

        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try! DatabaseQueue(path: dbPath, configuration: config)
        try! migrator.migrate(dbQueue)
    }

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("ext1") { db in
            // Use quoted identifier since "extension" is a SQL keyword
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
        }

        return migrator
    }

    // MARK: - Extension CRUD

    func saveExtension(_ record: ExtensionRecord) {
        do {
            try dbQueue.write { db in
                try record.save(db)
            }
        } catch {
            print("Failed to save extension: \(error)")
        }
    }

    func loadExtensions() -> [ExtensionRecord] {
        do {
            return try dbQueue.read { db in
                try ExtensionRecord.fetchAll(db)
            }
        } catch {
            print("Failed to load extensions: \(error)")
            return []
        }
    }

    func deleteExtension(id: String) {
        do {
            try dbQueue.write { db in
                try ExtensionRecord.filter(Column("id") == id).deleteAll(db)
            }
        } catch {
            print("Failed to delete extension: \(error)")
        }
    }

    func setEnabled(id: String, enabled: Bool) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE \"extension\" SET isEnabled = ? WHERE id = ?",
                    arguments: [enabled, id]
                )
            }
        } catch {
            print("Failed to update extension enabled state: \(error)")
        }
    }

    // MARK: - chrome.storage.local

    func storageGet(extensionID: String, keys: [String]) -> [String: Any] {
        do {
            return try dbQueue.read { db in
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
        } catch {
            print("Failed to get extension storage: \(error)")
            return [:]
        }
    }

    func storageGetAll(extensionID: String) -> [String: Any] {
        do {
            return try dbQueue.read { db in
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
        } catch {
            print("Failed to get all extension storage: \(error)")
            return [:]
        }
    }

    func storageSet(extensionID: String, items: [String: Any]) {
        do {
            try dbQueue.write { db in
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
        } catch {
            print("Failed to set extension storage: \(error)")
        }
    }

    func storageRemove(extensionID: String, keys: [String]) {
        do {
            try dbQueue.write { db in
                for key in keys {
                    try ExtensionStorageRecord
                        .filter(Column("extensionID") == extensionID && Column("key") == key)
                        .deleteAll(db)
                }
            }
        } catch {
            print("Failed to remove extension storage: \(error)")
        }
    }

    func storageClear(extensionID: String) {
        do {
            try dbQueue.write { db in
                try ExtensionStorageRecord
                    .filter(Column("extensionID") == extensionID)
                    .deleteAll(db)
            }
        } catch {
            print("Failed to clear extension storage: \(error)")
        }
    }
}
