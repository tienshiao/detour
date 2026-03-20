import Foundation

/// Stateless permission checker for extension API and host access.
struct ExtensionPermissionChecker {

    /// Whether the extension declared the given permission in its manifest.
    static func hasPermission(_ permission: String, extension ext: WebExtension) -> Bool {
        ext.manifest.permissions?.contains(permission) == true
    }

    /// Whether the extension's `host_permissions` cover the given URL.
    static func hasHostPermission(for url: URL, extension ext: WebExtension) -> Bool {
        let patterns = ext.manifest.hostPermissions ?? []
        guard !patterns.isEmpty else { return false }
        let matcher = ContentScriptMatcher(patterns: patterns)
        return matcher.matches(url)
    }

    /// Maps a message type (e.g. "tabs.query") to the permission it requires.
    /// Returns `nil` for APIs that are always allowed.
    ///
    /// Note: `tabs.*` APIs don't require the "tabs" permission in Chrome.
    /// The "tabs" permission only controls whether `url`, `title`, and
    /// `favIconUrl` are included in Tab objects. All extensions can call
    /// `tabs.create`, `tabs.query`, `tabs.update`, `tabs.remove`, etc.
    static func requiredPermission(for messageType: String) -> String? {
        let prefix = messageType.split(separator: ".").first.map(String.init) ?? messageType
        switch prefix {
        case "tabs":       return nil
        case "storage":    return "storage"
        case "scripting":  return "scripting"
        case "webNavigation": return "webNavigation"
        case "webRequest":    return "webRequest"
        case "contextMenus": return "contextMenus"
        case "offscreen":    return "offscreen"
        case "runtime":      return nil
        default:             return nil
        }
    }

    /// Chrome-compatible error for a missing API permission.
    static func apiPermissionError(permission: String, api: String) -> String {
        "Cannot call chrome.\(api). Extension does not have the \"\(permission)\" permission."
    }

    /// Chrome-compatible error for a missing host permission.
    static func hostPermissionError(url: URL) -> String {
        "Cannot access contents of URL \"\(url.absoluteString)\". Extension has not been granted access to this host."
    }

    /// Human-readable descriptions for an install-time permission prompt.
    static func permissionSummary(for manifest: ExtensionManifest) -> [String] {
        var descriptions: [String] = []

        for perm in manifest.permissions ?? [] {
            switch perm {
            case "tabs":          descriptions.append("Access your tabs")
            case "storage":       descriptions.append("Store data locally")
            case "scripting":     descriptions.append("Inject scripts into web pages")
            case "webNavigation": descriptions.append("Monitor your browsing navigation")
            case "webRequest":    descriptions.append("Monitor your web requests")
            case "contextMenus":  descriptions.append("Add items to context menus")
            case "offscreen":     descriptions.append("Create offscreen documents")
            case "activeTab":     descriptions.append("Access the active tab on click")
            case "bookmarks":     descriptions.append("Access your bookmarks")
            default:              descriptions.append("Use the \"\(perm)\" API")
            }
        }

        for pattern in manifest.hostPermissions ?? [] {
            if pattern == "<all_urls>" {
                descriptions.append("Access all websites")
            } else if let match = MatchPattern(pattern), let host = match.host {
                if host == "*" {
                    descriptions.append("Access all websites")
                } else if host.hasPrefix("*.") {
                    let domain = String(host.dropFirst(2))
                    descriptions.append("Access sites on \(domain)")
                } else {
                    descriptions.append("Access \(host)")
                }
            } else {
                descriptions.append("Access \(pattern)")
            }
        }

        return descriptions
    }
}
