import Foundation
import GRDB

/// A remembered "Always allow" for a page origin to open links of one URL
/// scheme in the application that handles it, per profile (TASK-84).
struct ExternalAppPermissionRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "externalAppPermission"

    var profileID: String
    /// `scheme://host[:port]` of the requesting frame, lowercased.
    var origin: String
    /// The external URL scheme, lowercased and without the colon (`zoommtg`).
    var scheme: String
}
