import Foundation
import GRDB

/// One row of the History page: a single visit, carrying the page metadata from
/// its `historyURL` row.
///
/// `visitTime` is the time of *this* visit — never `historyURL.lastVisitTime`,
/// which aggregates across every profile that has seen the URL. Only `title`
/// and `faviconURL` are read from the shared URL row.
struct HistoryVisitEntry: Codable, FetchableRecord, Equatable {
    var visitID: Int64
    var url: String
    var title: String
    var faviconURL: String?
    var visitTime: Double
}

/// Keyset pagination cursor for the History page: "the entries strictly older
/// than this one" in `(visitTime DESC, visitID DESC)` order.
///
/// Keyset rather than OFFSET so visits recorded while the user is paging can't
/// shift the window and make rows repeat or disappear.
struct HistoryCursor: Equatable {
    let visitTime: Double
    let visitID: Int64

    init(visitTime: Double, visitID: Int64) {
        self.visitTime = visitTime
        self.visitID = visitID
    }

    /// The cursor that resumes paging after `entry`.
    init(after entry: HistoryVisitEntry) {
        self.init(visitTime: entry.visitTime, visitID: entry.visitID)
    }
}
