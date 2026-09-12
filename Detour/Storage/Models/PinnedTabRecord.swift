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
    /// Extension id of the extension page the record's URL names (TASK-24); nil otherwise.
    var extensionID: String? = nil
}
