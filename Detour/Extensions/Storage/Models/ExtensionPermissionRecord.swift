import Foundation
import GRDB

enum ExtensionPermissionType: Int, Codable {
    case apiPermission = 0
    case matchPattern = 1
}

enum ExtensionPermissionStatus: Int, Codable {
    case granted = 0
    case denied = 1
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
