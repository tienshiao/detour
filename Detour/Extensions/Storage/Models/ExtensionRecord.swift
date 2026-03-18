import Foundation
import GRDB

struct ExtensionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "extension"

    var id: String
    var name: String
    var version: String
    var manifestJSON: Data
    var basePath: String
    var isEnabled: Bool
    var installedAt: Double
}
