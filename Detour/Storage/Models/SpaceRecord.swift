import Foundation
import GRDB

struct SpaceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "space"

    var id: String
    var name: String
    var emoji: String
    var colorHex: String
    var sortOrder: Int
    var selectedTabID: String?
}
