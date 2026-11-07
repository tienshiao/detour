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

    /// What a log line calls a record of this type.
    var logName: String {
        switch self {
        case .apiPermission: "API permission"
        case .matchPattern: "match pattern"
        case .url: "URL"
        }
    }

    /// The part of a saved `key` of this type that a log line may print with
    /// public privacy; the whole key goes in a `.private` interpolation beside
    /// it. An API permission name ("history") is not browsing data, and neither
    /// is `<all_urls>`. A URL key is the full address the site-access prompt
    /// asked about (path and query included) and a match pattern names the
    /// sites the user granted, so of those only the scheme is public, the rule
    /// `ExtensionPolyfillHandler.logRejectedOrigin` follows (TASK-268).
    func publicLogPart(ofKey key: String) -> String {
        switch self {
        case .apiPermission:
            return key
        case .matchPattern where key == "<all_urls>":
            return key
        case .matchPattern, .url:
            // The scheme is what precedes the first ":" (`data:text/html,…`
            // has no "://" of its own, but its body can hold one). Only a
            // plain scheme token, or a match pattern's `*`, is printed:
            // anything else before the colon is not a scheme and stays private.
            guard let colon = key.firstIndex(of: ":") else { return "(no scheme)" }
            let scheme = key[..<colon]
            guard scheme == "*" || Self.isPlainScheme(scheme) else { return "(no scheme)" }
            return String(scheme)
        }
    }

    /// ASCII letter first, then letters, digits, `+` or `-`. RFC 3986 also
    /// allows `.`, left out so that a scheme-less `host:port/…` key cannot
    /// pass for one.
    private static func isPlainScheme(_ scheme: Substring) -> Bool {
        guard let first = scheme.unicodeScalars.first,
              first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return scheme.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "-")
        }
    }
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

    /// The API permission key whose saved decision gates real native messaging
    /// hosts (TASK-25). Never applied to a context: the context always holds
    /// `nativeMessaging` so Detour's own bridge hosts keep working, and
    /// `ExtensionManager` enforces the saved decision at host dispatch instead.
    static let nativeMessagingKey = WKWebExtension.Permission.nativeMessaging.rawValue

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
