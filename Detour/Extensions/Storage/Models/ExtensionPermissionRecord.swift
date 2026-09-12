import Foundation
import GRDB
import WebKit

enum ExtensionPermissionType: Int, Codable {
    case apiPermission = 0
    case matchPattern = 1
    /// A decision for one specific URL, taken at the site-access prompt
    /// (`promptForPermissionToAccess urls:`) rather than for a manifest match
    /// pattern. The key is the URL's `absoluteString`, and the decision is
    /// applied with `WKWebExtensionContext.setPermissionStatus(_:for: URL)`,
    /// which converts the URL to an origin match pattern — so it survives the
    /// context's base URL changing on every (re)load.
    case url = 2
}

enum ExtensionPermissionStatus: Int, Codable {
    case granted = 0
    case denied = 1

    /// The context-level status a saved decision restores as. Anything that is
    /// not a grant is an explicit denial (fail closed), matching `statusByKey`.
    var contextStatus: WKWebExtensionContext.PermissionStatus {
        self == .granted ? .grantedExplicitly : .deniedExplicitly
    }
}

struct ExtensionPermissionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "extensionPermission"

    var extensionID: String
    var permissionKey: String
    var permissionType: Int
    var status: Int
    var grantedAt: Double

    init(extensionID: String, permissionKey: String, permissionType: Int, status: Int, grantedAt: Double) {
        self.extensionID = extensionID
        self.permissionKey = permissionKey
        self.permissionType = permissionType
        self.status = status
        self.grantedAt = grantedAt
    }

    init(extensionID: String, key: String, type: ExtensionPermissionType, status: ExtensionPermissionStatus) {
        self.extensionID = extensionID
        self.permissionKey = key
        self.permissionType = type.rawValue
        self.status = status.rawValue
        self.grantedAt = Date().timeIntervalSince1970
    }
}

extension Array where Element == ExtensionPermissionRecord {
    /// The saved status per key for rows of one type. Keys are only unique
    /// per (key, type): a site-access URL row may share its string with a
    /// manifest match pattern, so callers must never merge types.
    ///
    /// An unrecognised status raw value reads as `.denied` (fail closed).
    func statusByKey(type: ExtensionPermissionType) -> [String: ExtensionPermissionStatus] {
        Dictionary(
            lazy.filter { $0.permissionType == type.rawValue }
                .map { ($0.permissionKey, ExtensionPermissionStatus(rawValue: $0.status) ?? .denied) },
            uniquingKeysWith: { _, latest in latest }
        )
    }
}
