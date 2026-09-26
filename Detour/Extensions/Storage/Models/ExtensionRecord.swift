import Foundation
import GRDB

struct ExtensionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "extension"

    var id: String
    var name: String
    var version: String
    var manifestJSON: Data
    var basePath: String
    var isEnabled: Bool
    var installedAt: Double
    /// `ExtensionSource.rawValue` (TASK-113): where the files came from, which
    /// decides whether the extension is polled for updates or reloaded from a folder.
    var source: String
    /// The update2 endpoint polled for a CRX install; nil for an unpacked one or a
    /// CRX whose manifest declares none (such an install can never update).
    var updateURL: String?
    /// The folder an unpacked extension was loaded from, so it can be reloaded.
    var sourcePath: String?
    /// `ExtensionUpdatePolicy.PendingApproval` as JSON while an update that added
    /// permissions waits for the user to accept them (the extension is disabled
    /// meanwhile); nil otherwise.
    var pendingPermissionApprovalJSON: Data?

    init(id: String, name: String, version: String, manifestJSON: Data, basePath: String,
         isEnabled: Bool, installedAt: Double,
         source: ExtensionSource = .unpacked, updateURL: String? = nil, sourcePath: String? = nil,
         pendingPermissionApprovalJSON: Data? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.manifestJSON = manifestJSON
        self.basePath = basePath
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.source = source.rawValue
        self.updateURL = updateURL
        self.sourcePath = sourcePath
        self.pendingPermissionApprovalJSON = pendingPermissionApprovalJSON
    }
}
