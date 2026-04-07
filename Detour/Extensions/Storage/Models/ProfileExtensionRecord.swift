import Foundation
import GRDB

struct ProfileExtensionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "profileExtension"

    var profileID: String
    var extensionID: String
    var isEnabled: Bool
    var isPinned: Bool
}
