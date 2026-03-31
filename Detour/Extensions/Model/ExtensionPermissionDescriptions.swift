import Foundation

/// Human-readable descriptions for Chrome extension permission strings.
enum ExtensionPermissionDescriptions {

    private static let descriptions: [String: String] = [
        "activeTab": "Access the current tab when you click the extension",
        "alarms": "Schedule alarms and timers",
        "bookmarks": "Read and modify bookmarks",
        "clipboardWrite": "Write to the clipboard",
        "contextMenus": "Add items to the right-click menu",
        "cookies": "Read and modify cookies",
        "declarativeNetRequest": "Block and modify network requests",
        "declarativeNetRequestFeedback": "View info about matched network rules",
        "declarativeNetRequestWithHostAccess": "Block and redirect network requests",
        "fontSettings": "Read and modify browser font settings",
        "history": "Read and modify browsing history",
        "idle": "Detect when the system is idle",
        "management": "Manage other extensions",
        "menus": "Add items to the browser menus",
        "nativeMessaging": "Communicate with native applications",
        "notifications": "Show desktop notifications",
        "offscreen": "Create offscreen documents",
        "scripting": "Inject scripts into web pages",
        "search": "Use the default search engine",
        "sessions": "Access recently closed tabs and windows",
        "storage": "Store data locally",
        "tabs": "Read your browsing activity",
        "unlimitedStorage": "Store unlimited data locally",
        "webNavigation": "Monitor browser navigation events",
        "webRequest": "Observe and analyze network traffic",
    ]

    /// Returns a human-readable description for a permission string, or the raw string if unknown.
    static func describe(_ permission: String) -> String {
        descriptions[permission] ?? permission
    }

    /// Formats a list of permissions and host patterns for display in an alert.
    static func formatForAlert(permissions: [String], hostPermissions: [String], optionalPermissions: [String]? = nil) -> String {
        var lines: [String] = []

        if !permissions.isEmpty {
            lines.append("Permissions:")
            for perm in permissions {
                lines.append("  \u{2022} \(describe(perm))")
            }
        }

        if !hostPermissions.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Site access:")
            for host in hostPermissions {
                let display = host == "<all_urls>" ? "All websites" : host
                lines.append("  \u{2022} \(display)")
            }
        }

        if let optional = optionalPermissions, !optional.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("May also request:")
            for perm in optional {
                lines.append("  \u{2022} \(describe(perm))")
            }
        }

        if lines.isEmpty {
            return "No special permissions requested."
        }

        return lines.joined(separator: "\n")
    }
}
