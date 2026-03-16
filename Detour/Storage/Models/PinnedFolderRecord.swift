import Foundation
import GRDB

struct PinnedFolderRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pinnedFolder"

    var id: String
    var spaceID: String
    var parentFolderID: String?
    var name: String
    var isCollapsed: Bool
    var sortOrder: Int
}
