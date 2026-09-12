import Foundation
import GRDB

struct FavoriteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "favorite"

    var id: String
    var profileID: String
    var url: String
    var title: String
    var faviconURL: String?
    var sortOrder: Int
    var tabID: String?
    /// Extension id of the extension page the record's URL names (TASK-24); nil otherwise.
    var extensionID: String? = nil
}
