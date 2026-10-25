import Foundation
import GRDB

/// One Air Traffic Control route (TASK-191.1), `linkRoute` table. The target
/// is `targetKind` (`LinkRouteTarget.storageKind`) plus `targetSpaceID` for a
/// space target. `targetSpaceID` has no foreign key: the session save deletes
/// and re-inserts every space row, so a cascade would wipe the routes on each
/// save and a restriction would refuse it.
struct LinkRouteRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "linkRoute"

    var id: String
    /// `LinkRouteMatchKind.rawValue`; nil for an app-only route.
    var matchKind: String?
    var matchPattern: String?
    /// The sending app's bundle ID; nil when the route ignores the sender.
    var sourceApp: String?
    var targetKind: String
    var targetSpaceID: String?
    var sortOrder: Int
}

/// The Default target for links no route matches: one row (`id` 1) in
/// `linkRouteDefault`. No row means Most Recent Space.
struct LinkRouteDefaultRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "linkRouteDefault"

    var id: Int = 1
    var targetKind: String
    var targetSpaceID: String?
}
