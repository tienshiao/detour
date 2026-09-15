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

    /// - Parameters:
    ///   - hasHandler: an application is registered for the URL.
    ///   - isAllowed: the requesting origin was "Always allowed" for this scheme
    ///     in the navigating tab's profile.
    ///   - isHostedInWindow: the web view that fired is on screen in the window
    ///     that would show the prompt (the selected tab, a pane of its split, or
    ///     its peek) — a background tab never raises a sheet.
    ///   - isMainFrameRequest: the navigation targets the main frame or a new
    ///     window, not a subframe. A subframe navigating to a scheme nothing
    ///     handles (a `data:` iframe, a hidden-iframe probe for an app the user
    ///     does not have) is dropped silently rather than toasting on page load.
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
