import Foundation
import GRDB

struct ExtensionStorageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "extensionStorage"

    var extensionID: String
    var key: String
    var value: Data  // JSON-encoded value
}
