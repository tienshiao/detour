import Foundation
import GRDB

struct PinnedTabRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pinnedTab"

    var id: String
    var spaceID: String
    var pinnedURL: String
    var pinnedTitle: String
    var url: String?
    var title: String?
    var faviconURL: String?
    var interactionState: Data?
    var sortOrder: Int
    var folderID: String?
}
