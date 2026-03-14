import Foundation
import GRDB

struct ClosedTabRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "closedTab"

    var id: Int64?
    var tabID: String
    var spaceID: String
    var url: String?
    var title: String
    var faviconURL: String?
    var interactionState: Data?
    var sortOrder: Int
    var archivedAt: Double?
}
