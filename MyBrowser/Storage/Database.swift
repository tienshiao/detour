import Foundation
import GRDB

struct AppDatabase {
    static let shared = AppDatabase()

    let dbQueue: DatabaseQueue

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MyBrowser", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("browser.db").path

        dbQueue = try! DatabaseQueue(path: dbPath)
        try! migrator.migrate(dbQueue)
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

            try db.create(table: "historyVisit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("faviconURL", .text)
                t.column("spaceID", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("visitedAt", .double).notNull()
            }

            try db.create(table: "appState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }

            try db.create(virtualTable: "historySearch", using: FTS5()) { t in
                t.synchronize(withTable: "historyVisit")
                t.tokenizer = .unicode61()
                t.column("url")
                t.column("title")
            }
        }

        return migrator
    }
}
