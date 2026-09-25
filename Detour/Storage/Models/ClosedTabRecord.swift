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
    /// When the tab was closed (seconds since 1970), set on every record since
    /// v16 — equal to archivedAt for archives. Rows written before v16 without
    /// archivedAt stay nil and sort by id (TASK-116).
    var closedAt: Double?
    /// Extension id of the extension page the record's URL names (TASK-24); nil otherwise.
    var extensionID: String? = nil
}

/// A closedTab row without its interactionState blob — what menu validation,
/// the reopen scan and listings read (TASK-117).
struct ClosedTabSummary: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "closedTab"

    var id: Int64
    var tabID: String
    var spaceID: String
    var url: String?
    var title: String
    var faviconURL: String?
    var sortOrder: Int
    var archivedAt: Double?
    var closedAt: Double?
    var extensionID: String?
}
