import Foundation
import GRDB

struct PinnedTabRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pinnedTab"

    var id: String
    var spaceID: String
    var pinnedURL: String
    var pinnedTitle: String
    var faviconURL: String?
    var sortOrder: Int
    var folderID: String?
    var tabID: String?
    var splitGroupID: String?
    var splitFraction: Double?
}
