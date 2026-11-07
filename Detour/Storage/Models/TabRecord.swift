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
    var lastDeselectedAt: Double?
    var parentID: String?
    var peekURL: String?
    var peekInteractionState: Data?
    var peekFaviconURL: String?
    var splitGroupID: String?
    var splitFraction: Double?
    /// Extension id of the extension page the record's URL names (TASK-24); nil otherwise.
    var extensionID: String? = nil
    /// The normal tab's tab group (TASK-132.10); nil for an ungrouped tab and
    /// for every pinned or favourite backing tab.
    var tabGroupID: String? = nil
}
