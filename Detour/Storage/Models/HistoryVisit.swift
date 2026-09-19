import Foundation
import GRDB

struct HistoryVisit: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "historyVisit"

    var id: Int64?
    var urlID: Int64
    var spaceID: String
    var visitTime: Double
    var isTyped: Bool = false
    /// What the page was called at the time of *this* visit (TASK-91). Nil for
    /// visits recorded before the per-visit title existed — they fall back to
    /// `historyURL.title`, the latest known title of the URL, which is all that
    /// was ever stored for them.
    var title: String?
}
