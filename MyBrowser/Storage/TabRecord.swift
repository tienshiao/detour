import Foundation
import GRDB

struct TabRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tab"

    var id: String
    var spaceID: String
    var url: String?
    var title: String
    var faviconURL: String?
    var interactionState: Data?
    var sortOrder: Int
}
