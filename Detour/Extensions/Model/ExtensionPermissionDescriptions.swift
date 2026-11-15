import Foundation

/// Human-readable descriptions for Chrome extension permission strings.
enum ExtensionPermissionDescriptions {

    private static let descriptions: [String: String] = [
        "activeTab": "Access the current tab when you click the extension",
        "alarms": "Schedule alarms and timers",
        "background": "Run in the background",
        "bookmarks": "Read and modify bookmarks",
        "clipboardWrite": "Write to the clipboard",
        "contextMenus": "Add items to the right-click menu",
        "cookies": "Read and modify cookies",
        "declarativeNetRequest": "Block and modify network requests",
        "declarativeNetRequestFeedback": "View info about matched network rules",
        "declarativeNetRequestWithHostAccess": "Block and redirect network requests",
        "favicon": "Read the icons of websites",
        "fontSettings": "Read and modify browser font settings",
        "history": "Read and modify browsing history",
        "idle": "Detect when the system is idle",
        "management": "Manage other extensions",
        "menus": "Add items to the browser menus",
        "nativeMessaging": "Communicate with native applications",
        "notifications": "Show desktop notifications",
        "offscreen": "Create offscreen documents",
        "privacy": "Read and change privacy settings",
        "scripting": "Inject scripts into web pages",
        "search": "Use the default search engine",
        "sessions": "Access recently closed tabs and windows",
        "storage": "Store data locally",
        "tabs": "Read your browsing activity",
        "unlimitedStorage": "Store unlimited data locally",
        "webNavigation": "Monitor browser navigation events",
        "webRequest": "Observe and analyze network traffic",
    ]

    /// Whether the permission has a description of its own (TASK-339).
    static func hasDescription(_ permission: String) -> Bool {
        descriptions[permission] != nil
    }

    /// A human-readable description of a permission string. One without a
    /// description of its own reads as its name made legible ("tabGroups" is
    /// "Tab groups", "system.display" "System display"), never as the raw
    /// manifest string (TASK-339).
    static func describe(_ permission: String) -> String {
        descriptions[permission] ?? legibleName(permission)
    }

    /// A permission's name in words: camelCase and dot or underscore
    /// boundaries split, in sentence case; a run of capitals stays one word
    /// as it is ("readURLs" is "Read URLs"). Empty stays empty.
    static func legibleName(_ permission: String) -> String {
        let characters = Array(permission)
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if character == "." || character == "_" || character == "-" || character == " " {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let afterNext = index + 2 < characters.count ? characters[index + 2] : nil
            // A plural "s" ends a run of capitals ("URLs"), it starts no word.
            let pluralS = next == "s" && afterNext?.isLowercase != true
            // A capital starts a word after a lower-case letter or a digit,
            // or ends a run of capitals before a lower-case letter ("URLPattern").
            let startsWord = character.isUppercase && previous.map {
                $0.isLowercase || $0.isNumber || ($0.isUppercase && next?.isLowercase == true && !pluralS)
            } == true
            if startsWord, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return permission }
        func cased(_ word: String) -> String {
            // An acronym (two or more capitals, a plural "s" allowed) keeps its case.
            let letters = word.hasSuffix("s") ? String(word.dropLast()) : word
            return letters.count > 1 && letters.allSatisfy(\.isUppercase) ? word : word.lowercased()
        }
        // The first word capitalised, unless it is an acronym.
        let isAcronym = cased(first) == first && first != first.lowercased()
        let head = isAcronym ? first : first.prefix(1).uppercased() + first.dropFirst().lowercased()
        return ([head] + words.dropFirst().map(cased)).joined(separator: " ")
    }

    /// How a host pattern reads in the install prompt.
    static func describeHost(_ pattern: String) -> String {
        pattern == "<all_urls>" ? "All websites" : pattern
    }

    /// The install prompt's lines for required permissions and site access,
    /// flattened: what `management.getPermissionWarningsByManifest` returns
    /// (TASK-257).
    /// A permission without a description of its own stays its manifest
    /// name here, as the API has returned it (not the legible form the
    /// window shows).
    static func warnings(permissions: [String], hostPermissions: [String]) -> [String] {
        permissions.map { descriptions[$0] ?? $0 } + hostPermissions.map(describeHost)
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
                lines.append("  \u{2022} \(describeHost(host))")
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
