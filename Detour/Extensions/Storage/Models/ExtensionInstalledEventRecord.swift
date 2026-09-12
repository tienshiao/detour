import Foundation
import GRDB

/// The `runtime.onInstalled` ledger (TASK-22): the extension version whose
/// install/update event was last delivered to the extension's worker in a profile.
/// A missing row means the event was never delivered there. See
/// `RuntimeInstalledEvent`.
///
/// No foreign keys: rows are written for whatever profile a worker runs in, which
/// need not have been saved yet, and are removed with the extension in
/// `AppDatabase.deleteExtension`.
struct ExtensionInstalledEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "extensionInstalledEvent"

    var extensionID: String
    var profileID: String
    var deliveredVersion: String
    var deliveredAt: Double
}
