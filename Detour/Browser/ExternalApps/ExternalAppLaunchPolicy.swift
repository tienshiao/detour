import Foundation

/// What to do with a navigation to a URL an external application handles
/// (`zoommtg:`, `mailto:`, …) — TASK-84.
enum ExternalAppLaunchDecision: Equatable {
    /// Hand the URL to its application without asking.
    case open
    /// Ask first. `canRemember` offers "Always allow".
    case prompt(canRemember: Bool)
    /// No application handles the scheme: tell the user.
    case reportNoHandler
    /// Drop the request silently.
    case ignore
}

/// The prompt-or-not rule for external application URLs, kept pure so every
/// branch is unit-tested (`ExternalAppLaunchPolicyTests`). User gesture plays
/// no part: a page redirecting to `zoommtg:` on load is prompted like a click,
/// and nothing opens unasked unless the origin was allowed before.
enum ExternalAppLaunchPolicy {

    /// The schemes a web view loads itself. A navigation to any other scheme
    /// is an external application's (`isForExternalApp(scheme:)`).
    ///
    /// `data` is one of them (TASK-159): a `data:` URL is a document, not a
    /// link to an application. What may navigate to one is WebKit's rule, not
    /// ours: it loads a `data:` URL the app itself asks for and a `data:`
    /// frame, and refuses a page's own top-level navigation to one.
    /// `detour:` is not here because the window's policy settles internal
    /// pages before it asks.
    static let schemesLoadedInTheBrowser: Set<String> =
        ["http", "https", "about", "blob", "data", "webkit-extension", ErrorPage.scheme]

    /// Whether a navigation to a URL with `scheme` is handed to an external
    /// application instead of being loaded.
    static func isForExternalApp(scheme: String) -> Bool {
        !schemesLoadedInTheBrowser.contains(scheme.lowercased())
    }

    /// - Parameters:
    ///   - hasHandler: an application is registered for the URL.
    ///   - isAllowed: the requesting origin was "Always allowed" for this scheme
    ///     in the navigating tab's profile.
    ///   - isHostedInWindow: the web view that fired is on screen in the window
    ///     that would show the prompt (the selected tab, a pane of its split, or
    ///     its peek) — a background tab never raises a sheet.
    ///   - isMainFrameRequest: the navigation targets the main frame or a new
    ///     window, not a subframe. A subframe navigating to a scheme nothing
    ///     handles (a hidden-iframe probe for an app the user does not have)
    ///     is dropped silently rather than toasting on page load.
    ///   - isSheetShowing: the window already has a sheet up; a page looping
    ///     `location = "app:…"` must not queue a prompt per attempt.
    ///   - origin: the requesting frame's origin key (`origin(...)`); nil when it
    ///     has none worth remembering.
    ///   - isPrivateProfile: the navigating tab is in the Private profile.
    static func decide(hasHandler: Bool, isAllowed: Bool, isHostedInWindow: Bool, isMainFrameRequest: Bool = true,
                       isSheetShowing: Bool, origin: String?, isPrivateProfile: Bool) -> ExternalAppLaunchDecision {
        guard hasHandler else { return isHostedInWindow && isMainFrameRequest ? .reportNoHandler : .ignore }
        if isAllowed && origin != nil { return .open }
        guard isHostedInWindow, !isSheetShowing else { return .ignore }
        return .prompt(canRemember: origin != nil && !isPrivateProfile)
    }

    /// The origin key a decision is remembered under: `protocol://host[:port]`,
    /// lowercased. Nil for an opaque or hostless origin (`about:blank`, `data:`,
    /// `file:`), which cannot be told apart from any other such page.
    /// `port` 0 means the scheme's default port, as `WKSecurityOrigin` reports it.
    static func origin(protocol scheme: String, host: String, port: Int) -> String? {
        guard !scheme.isEmpty, !host.isEmpty else { return nil }
        let base = "\(scheme)://\(host)".lowercased()
        return port == 0 ? base : "\(base):\(port)"
    }
}
