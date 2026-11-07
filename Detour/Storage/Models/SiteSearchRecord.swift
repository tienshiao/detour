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
    /// Added from the site's OpenSearch description (TASK-288, migration v22).
    var isDiscovered: Bool = false
}

/// The host of a site search the user removed (TASK-288,
/// `siteSearchRemovedHost`): discovery never adds that site again.
struct SiteSearchRemovedHostRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "siteSearchRemovedHost"

    var host: String
}
