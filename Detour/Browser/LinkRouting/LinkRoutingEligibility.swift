import Foundation

// WHETHER a link inside Detour is routed at all (TASK-191.4): layer 1 of the
// two described at the top of `LinkRouteResolver.swift`. `resolveLinkRoute`
// (layer 2) then says where a routable link goes, and `linkPlacement` which
// window it opens in. Pure: the window's WebKit delegates and the command
// palette describe what happened, and act on the answer.

/// Where WebKit reported a link leaving a page.
enum InPageLinkEntry: Equatable {
    /// `decidePolicyFor navigationAction`. `opensNewWindow` is a nil
    /// `targetFrame` (a `target=_blank` link, before WebKit would call
    /// `createWebViewWith`); `targetsMainFrame` is a main-frame target.
    case navigationAction(isLinkActivation: Bool, targetsMainFrame: Bool, opensNewWindow: Bool, isRedirect: Bool)
    /// `createWebViewWith` for the page's own new window. A script's
    /// `window.open` reaches only this (`isLinkActivation` false); a `_blank`
    /// link reaches it after the navigation policy allowed it (true).
    case pageWindowRequest(isLinkActivation: Bool, wantsPopup: Bool)
    /// One of the link menu's own actions (Open Link in New Tab, in New
    /// Window, in Split View): the user picked where it opens.
    case linkMenuAction
}

/// The modifier keys held for a link activation, of those that pick a branch.
struct LinkClickModifiers: OptionSet, Equatable {
    let rawValue: Int
    static let command = LinkClickModifiers(rawValue: 1 << 0)
    static let shift = LinkClickModifiers(rawValue: 1 << 1)
    static let option = LinkClickModifiers(rawValue: 1 << 2)
}

/// A link leaving a page, as the routing rule sees it.
struct InPageLinkRequest: Equatable {
    var entry: InPageLinkEntry
    var modifiers: LinkClickModifiers = []
    /// WebKit's user-gesture signal for the action (`_isUserInitiated`).
    var isUserGesture: Bool
    /// The link was fired by a Peek's page, or while a Peek is presented.
    var isInPeek: Bool = false
    /// The page the link is on (the main frame's document).
    var pageURL: URL?
    var targetURL: URL
    /// Settings > Links: Opt-Cmd-click opens a Quick Detour (TASK-193.5).
    /// Off, Opt-Cmd is a Cmd+click as before.
    var quickDetourClickEnabled: Bool = true
}

/// How a routable link would open if no route moved it.
enum RoutableLinkKind: Equatable {
    /// Cmd+click: a background tab.
    case commandClick
    /// A `target=_blank` (or named-target) link.
    case blankTarget
    /// A tab-style `window.open`.
    case scriptedWindow
    /// A plain click that would navigate the tab in place, to another host.
    case crossHostClick
}

/// Why a link is not routed.
enum LinkRoutingExclusion: String, Equatable {
    case notWebURL
    case inPeek
    case linkMenuAction
    /// A `_blank` link in `createWebViewWith`: the navigation policy already decided it.
    case decidedByNavigationPolicy
    case redirect
    /// A navigation that is not a link activation: a script setting
    /// `location`, a client redirect, a form, back/forward, reload, an app load.
    case notLinkActivation
    /// A link activation with no user gesture: a script's `a.click()`.
    case noUserGesture
    /// Opt-Cmd-click: a Quick Detour, which the user chose (TASK-193.5).
    case quickDetourClick
    case shiftClickPeek
    case optionClickSplit
    case popupWindow
    case subframe
    case sameHost
}

enum LinkRoutingEligibility: Equatable {
    case routable(RoutableLinkKind)
    case notRouted(LinkRoutingExclusion)

    var isRoutable: Bool {
        if case .routable = self { return true }
        return false
    }
}

/// Whether a link leaving a page is routed by Air Traffic Control (user
/// decisions 2026-10-25, recorded in wiki/features/link-routing.md):
///
/// - New-tab opens route: Cmd+click, a `target=_blank` link, a tab-style
///   `window.open`.
/// - A plain click that would navigate in place routes only to another host
///   (a leading `www.` is the same host): the tab stays where it is.
/// - Never: redirects, script navigations and clicks without a user gesture,
///   same-host clicks, a popup `window.open` (it keeps its opener), Opt-Cmd
///   (Quick Detour, TASK-193.5), Shift (Peek) and Option (split) clicks,
///   anything in a Peek, subframe navigations, non-web URLs, the link menu's
///   own actions.
///
/// The modifier order is the navigation policy's (`inPageLinkClickBranch`):
/// Opt-Cmd, then Cmd, then Shift, then Option. Downloads and non-web schemes
/// are decided by the policy before it asks, and a non-web target is refused
/// here as well.
func linkRoutingEligibility(_ request: InPageLinkRequest) -> LinkRoutingEligibility {
    guard isWebURL(request.targetURL) else { return .notRouted(.notWebURL) }
    guard !request.isInPeek else { return .notRouted(.inPeek) }
    switch request.entry {
    case .linkMenuAction:
        return .notRouted(.linkMenuAction)
    case .pageWindowRequest(let isLinkActivation, let wantsPopup):
        // A `_blank` link was routed (or not) when the policy saw it.
        if isLinkActivation { return .notRouted(.decidedByNavigationPolicy) }
        if wantsPopup { return .notRouted(.popupWindow) }
        guard request.isUserGesture else { return .notRouted(.noUserGesture) }
        return .routable(.scriptedWindow)
    case .navigationAction(let isLinkActivation, let targetsMainFrame, let opensNewWindow, let isRedirect):
        // A server redirect keeps the link activation and the gesture of the
        // click it interrupts, so it is told apart first.
        if isRedirect { return .notRouted(.redirect) }
        guard isLinkActivation else { return .notRouted(.notLinkActivation) }
        guard request.isUserGesture else { return .notRouted(.noUserGesture) }
        switch inPageLinkClickBranch(request.modifiers, target: request.targetURL,
                                     quickDetourClickEnabled: request.quickDetourClickEnabled) {
        case .quickDetour: return .notRouted(.quickDetourClick)
        case .backgroundTab: return .routable(.commandClick)
        case .peek: return .notRouted(.shiftClickPeek)
        case .split: return .notRouted(.optionClickSplit)
        case .none: break
        }
        if opensNewWindow { return .routable(.blankTarget) }
        guard targetsMainFrame else { return .notRouted(.subframe) }
        if isSameLinkRoutingHost(request.pageURL?.host, request.targetURL.host) { return .notRouted(.sameHost) }
        return .routable(.crossHostClick)
    }
}

/// What a link activation's modifiers make it, in the order the browser
/// window's navigation policy asks them (wiki/tabs/tab-lifecycle.md).
enum InPageLinkClickBranch: Equatable {
    /// Opt-Cmd, to a web page, with the setting on: a Quick Detour on the
    /// page's profile (TASK-193.5).
    case quickDetour
    /// Cmd (Opt-Cmd with the setting off or to a non-web URL, Cmd+Shift): a
    /// background tab, or where a route sends it.
    case backgroundTab
    /// Shift: a Peek.
    case peek
    /// Option: a split.
    case split
    /// No modifier that picks a branch.
    case none
}

/// The modifier precedence of a link activation (TASK-193.5): Opt-Cmd
/// (Quick Detour), then Cmd (background tab), Shift (Peek), Option (split).
/// Opt-Cmd is the one combination that no longer means Cmd; Cmd still wins
/// over Shift, and over Option when Quick Detour is off or the target is not
/// a web page (an `http`/`https` URL).
func inPageLinkClickBranch(_ modifiers: LinkClickModifiers, target: URL,
                           quickDetourClickEnabled: Bool) -> InPageLinkClickBranch {
    if quickDetourClickEnabled, modifiers.isSuperset(of: [.command, .option]), isWebURL(target) { return .quickDetour }
    if modifiers.contains(.command) { return .backgroundTab }
    if modifiers.contains(.shift) { return .peek }
    if modifiers.contains(.option) { return .split }
    return .none
}

/// Whether two hosts are the same for the cross-host click rule: without
/// case, a trailing dot or a leading `www.` (dropped only when a domain is
/// left, so `www.com` is not `com`). Hosts, not sites: there is no
/// public-suffix list in the codebase, so `mail.example.com` is another host
/// than `example.com`. A missing host is never the same as anything.
func isSameLinkRoutingHost(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = lhs.map(comparableHost), let rhs = rhs.map(comparableHost),
          !lhs.isEmpty, !rhs.isEmpty else { return false }
    return lhs == rhs
}

private func comparableHost(_ host: String) -> String {
    var host = host.lowercased()
    while host.hasSuffix(".") { host.removeLast() }
    if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host.removeFirst(4) }
    return host
}

private func isWebURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
}

/// What the window does with a link activation once routing and the
/// pinned/favourite Peek intercept have both been asked.
enum InPageLinkOutcome: Equatable {
    /// Open it where the route says; the page and its tab are left alone.
    case route(LinkRouteDecision)
    /// The anchor intercept: open it in a Peek.
    case peek
    /// What happened before routes.
    case asBefore
}

/// Precedence between a route and the anchor intercept: a route that sends
/// the link elsewhere wins (user decision 2026-10-25); with no route, or one
/// that keeps the link where it is (`.stay`), the intercept behaves as before.
func inPageLinkOutcome(routed: LinkRouteDecision?, anchorPeeks: Bool) -> InPageLinkOutcome {
    if let routed, routed != .stay { return .route(routed) }
    return anchorPeeks ? .peek : .asBefore
}

/// The decision a routable link acts on: nil when it is not routable or the
/// route keeps it where it is.
func routedLinkDecision(_ eligibility: LinkRoutingEligibility,
                        resolve: () -> LinkRouteDecision) -> LinkRouteDecision? {
    guard eligibility.isRoutable else { return nil }
    let decision = resolve()
    return decision == .stay ? nil : decision
}

/// Whether a command palette submission is routed: a web URL (per
/// `AddressInputClassifier`; a search never is) submitted in new-tab mode.
/// Navigating in place (Cmd+L, a click on the address bar) never routes: the
/// user picked the tab (user decision 2026-10-25).
func typedURLIsRoutable(_ url: URL, isSearch: Bool, navigatesInPlace: Bool) -> Bool {
    !isSearch && !navigatesInPlace && isWebURL(url)
}
