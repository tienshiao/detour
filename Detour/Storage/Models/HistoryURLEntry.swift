import Foundation
import GRDB

/// One URL of a profile's history, as `chrome.history.search` reports it
/// (TASK-138): a page the scope visited, summarised over the scope's own
/// visits.
///
/// Nothing here is read from the shared `historyURL` row but the URL text and
/// its id. `visitCount`, `typedCount` and `lastVisitTime` are aggregated from
/// the in-scope `historyVisit` rows — the row's own `visitCount` and
/// `lastVisitTime` count every profile's visits — and `title` is the one an
/// in-scope visit recorded, empty when the scope has none it may show.
struct HistoryURLEntry: Codable, FetchableRecord, Equatable {
    var urlID: Int64
    var url: String
    var title: String
    var visitCount: Int
    var typedCount: Int
    var lastVisitTime: Double
}
