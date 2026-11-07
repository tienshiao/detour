import Foundation
import GRDB

/// One site search (TASK-287), `siteSearch` table. App-wide: there is no
/// profile column.
struct SiteSearchRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "siteSearch"

    var id: String
    var name: String
    var keyword: String
    var urlTemplate: String
    var sortOrder: Int
}
