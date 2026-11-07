import Foundation
import GRDB

/// A space's tab group (TASK-132.10). Members are the `tab` rows whose
/// `tabGroupID` names it; that column has no foreign key, so a dangling id is
/// cleared at load (`TabStore.sanitizeTabGroups`).
struct TabGroupRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tabGroup"

    var id: String
    var spaceID: String
    var title: String
    /// A `TabGroupColor` raw value; an unknown one loads as grey.
    var color: String
    var isCollapsed: Bool
    /// Position in `Space.tabGroups` (creation order).
    var sortOrder: Int
}
