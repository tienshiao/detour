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
}
