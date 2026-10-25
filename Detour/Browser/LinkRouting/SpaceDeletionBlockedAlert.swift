import AppKit

/// A line naming a route for the user: its conditions, e.g.
/// `Domain is example.com, from Slack`. `appName` turns a bundle ID into the
/// app's name (nil: the bundle ID is shown).
func linkRouteSummary(_ route: LinkRoute, appName: (String) -> String? = { _ in nil }) -> String {
    var parts: [String] = []
    if let match = route.match, !match.isEmpty {
        let pattern = match.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        switch match.kind {
        case .isEqualTo: parts.append("URL is \(pattern)")
        case .contains: parts.append("URL contains “\(pattern)”")
        case .domainIs: parts.append("Domain is \(pattern)")
        }
    }
    if let app = route.normalizedSourceApp {
        let name = appName(app) ?? app
        parts.append(parts.isEmpty ? "Links from \(name)" : "from \(name)")
    }
    return parts.joined(separator: ", ")
}

/// The text of the alert shown when a space cannot be deleted because routes
/// target it (user decision 2026-10-25).
func spaceDeletionBlockedMessage(spaceName: String, references: LinkRouteReferences,
                                 appName: (String) -> String? = { _ in nil }) -> (title: String, detail: String) {
    var lines = references.routes.map { "• " + linkRouteSummary($0, appName: appName) }
    if references.isDefaultTarget { lines.append("• The Default route, for links no route matches") }
    let detail = "Links are routed to this space by:\n" + lines.joined(separator: "\n")
        + "\n\nChange or remove these routes before deleting the space."
    return ("“\(spaceName)” can’t be deleted", detail)
}

/// Explains a refused space deletion. A minimal alert until the Links pane
/// (TASK-191.3) exists; that task adds a button opening it.
enum SpaceDeletionBlockedAlert {
    static func run(spaceName: String, references: LinkRouteReferences) {
        let message = spaceDeletionBlockedMessage(spaceName: spaceName, references: references,
                                                  appName: installedAppName(bundleID:))
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func installedAppName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
