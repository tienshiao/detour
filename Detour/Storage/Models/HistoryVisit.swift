import Foundation
import GRDB

struct HistoryVisit: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "historyVisit"

    var id: Int64?
    var urlID: Int64
    var spaceID: String
    var visitTime: Double
}
