import Foundation
import GRDB

struct HistoryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "historyVisit"

    var id: Int64?
    var url: String
    var title: String
    var faviconURL: String?
    var spaceID: String
    var visitedAt: Double
}
