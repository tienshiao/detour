import Foundation
import GRDB

struct HistoryURL: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "historyURL"

    var id: Int64?
    var url: String
    var title: String
    var faviconURL: String?
    var visitCount: Int
    var lastVisitTime: Double

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
