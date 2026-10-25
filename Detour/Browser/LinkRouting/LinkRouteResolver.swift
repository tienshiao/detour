import Foundation

// The Air Traffic Control rules (TASK-191.1), as pure functions. The entry
// points (TASK-191.2 links from other apps, TASK-191.4 typed URLs and clicks)
// call `resolveLinkRoute` and act on its decision; nothing here touches a
// window or the store.
//
// Two layers decide a link inside Detour:
// 1. WHETHER it is routed at all: TASK-191.4's pure click rule (and its
//    typed-URL rule: a URL, not a search, from a palette mode that routes).
//    Same-host plain clicks, redirects, script navigations, popups that keep
//    their opener, Option- and Shift-clicks and links in a Peek never reach
//    layer 2: the caller builds no `.typed` or `.clicked` origin for them.
// 2. WHERE it goes: `resolveLinkRoute`, which has no exclusions of its own.
//    Every `.typed` and `.clicked` origin it is handed is routable, so the
//    routes and then the Default apply to it.

/// Where a link came from.
enum LinkOrigin: Equatable {
    /// Opened from another app. `sourceApp` is the sender's bundle ID when the
    /// Get URL Apple Event names one; nil when it does not (`open` from a shell).
    case external(sourceApp: String?)
    /// Typed in the command palette of a window showing `fromSpace`, in a
    /// submission TASK-191.4 routes (a URL, not a search).
    case typed(fromSpace: UUID, isPrivateWindow: Bool)
    /// Clicked in a page of a tab in `inSpace`: only a click TASK-191.4's click
    /// rule has already found routable. The resolver applies the routes and the
    /// Default to every click it is given, so the excluded clicks (same host,
    /// redirects, scripts, popups, Option/Shift-click, Peek) must not get here.
    case clicked(inSpace: UUID, isPrivateWindow: Bool)

    var isExternal: Bool {
        if case .external = self { return true }
        return false
    }

    /// The space the link is already in, for a link from inside Detour.
    var currentSpaceID: UUID? {
        switch self {
        case .external: return nil
        case .typed(let id, _), .clicked(let id, _): return id
        }
    }

    var isFromPrivateWindow: Bool {
        switch self {
        case .external: return false
        case .typed(_, let isPrivate), .clicked(_, let isPrivate): return isPrivate
        }
    }
}

/// What the resolver needs to know about the app's state.
struct LinkRouteContext: Equatable {
    /// The normal (non-Private) spaces that exist. A route to any other id (a
    /// deleted space, or a Private window's space) is skipped.
    var spaceIDs: Set<UUID>
}

/// Where a link should open.
enum LinkRouteDecision: Equatable {
    case openInSpace(UUID)
    /// The space in front, as a link from another app opened before routes.
    case mostRecentSpace
    case privateWindow
    case quarantine
    case quickDetour
    /// Leave the link where it is: a typed URL or click that no route moves.
    case stay
}

/// Where `url`, arriving from `origin`, should open.
///
/// - Routes are tried in `sortOrder`; the first that matches and can be used
///   from this origin wins. One that matches but cannot be used (a space that
///   is gone, a normal space from a Private window, Quarantine for a typed URL)
///   is skipped, and the next route is tried.
/// - No route: the Default applies, from every origin (user decision
///   2026-10-25). When it cannot be used from this origin (a deleted space, a
///   normal space from a Private window, Quarantine or Quick Detour for a typed
///   URL or click), a link from another app goes to the most recent space and
///   a typed URL or click stays where it is.
/// - Only http and https URLs match a route.
///
/// The caller has already decided the link is routed (see the top of this
/// file): a `.typed` or `.clicked` origin is never excluded here.
func resolveLinkRoute(url: URL, origin: LinkOrigin, routes: [LinkRoute],
                      defaultTarget: LinkRouteTarget, context: LinkRouteContext) -> LinkRouteDecision {
    let ordered = routes.enumerated()
        .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
        .map(\.element)
    for route in ordered where linkRoute(route, matches: url, origin: origin) {
        if let decision = decision(for: route.target, origin: origin, context: context) { return decision }
    }
    // The Default, for every origin: a Default of "Work" takes an unmatched
    // typed URL or click from another space into Work. Unusable, a link from
    // another app still needs a window (the most recent space); a typed URL or
    // click is already in one, so it stays.
    return decision(for: defaultTarget, origin: origin, context: context)
        ?? (origin.isExternal ? .mostRecentSpace : .stay)
}

/// What `target` means for a link from `origin`; nil when it cannot be used
/// from there, so the next route (or the Default's fallback) is tried. The
/// same rules hold for a route's target and for the Default.
private func decision(for target: LinkRouteTarget, origin: LinkOrigin,
                      context: LinkRouteContext) -> LinkRouteDecision? {
    switch target {
    case .privateWindow:
        // Into Private from anywhere; already in one, the link stays.
        return origin.isFromPrivateWindow ? .stay : .privateWindow
    case .space(let id):
        // A space that is gone (or a Private window's, which no route may
        // name) never takes a link; nothing leaves a Private window.
        guard context.spaceIDs.contains(id), !origin.isFromPrivateWindow else { return nil }
        return id == origin.currentSpaceID ? .stay : .openInSpace(id)
    case .mostRecentSpace:
        guard !origin.isFromPrivateWindow else { return nil }
        // Typed or clicked, the link is in the key window's space, which is
        // the most recent one: nothing to move.
        return origin.isExternal ? .mostRecentSpace : .stay
    case .quarantine:
        return origin.isExternal ? .quarantine : nil
    case .quickDetour:
        return origin.isExternal ? .quickDetour : nil
    }
}

/// Whether `route`'s conditions all hold for `url` from `origin`. Ignores
/// whether its target can be used.
func linkRoute(_ route: LinkRoute, matches url: URL, origin: LinkOrigin) -> Bool {
    guard route.hasCondition else { return false }
    if let app = route.normalizedSourceApp {
        // Only a link from another app has a sender, and only a known one can match.
        guard case .external(let sender?) = origin,
              sender.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(app) == .orderedSame
        else { return false }
    }
    if let match = route.match, !match.isEmpty {
        return linkRouteMatch(match, matches: url)
    }
    // App-only: any web URL from that app.
    return isRoutableURL(url)
}

/// Whether `url` meets the URL condition `match`.
func linkRouteMatch(_ match: LinkRouteMatch, matches url: URL) -> Bool {
    guard isRoutableURL(url), !match.isEmpty else { return false }
    let pattern = match.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    switch match.kind {
    case .contains:
        // The full URL text, fragment included, as the address bar's URL
        // spells it (punycode host, percent-encoded path).
        return url.absoluteString.lowercased().contains(pattern.lowercased())
    case .isEqualTo:
        guard let patternURL = URL(string: pattern), isRoutableURL(patternURL),
              let lhs = equalityForm(of: patternURL), let rhs = equalityForm(of: url) else { return false }
        return lhs == rhs
    case .domainIs:
        guard let domain = linkRouteDomain(fromPattern: pattern),
              let host = url.authorityHost.map(normalizedHost) else { return false }
        if host == domain { return true }
        // A subdomain, on a dot boundary. An IP address has no subdomains:
        // "0.1" must not cover "10.0.0.1".
        return !isIPLiteral(host) && !isIPLiteral(domain) && host.hasSuffix("." + domain)
    }
}

/// A `domainIs` pattern as the host it is compared with: lowercased, IDNA
/// (punycode) encoded, an IPv6 literal in brackets, without a scheme, path,
/// port, trailing dot, leading `*.` or leading `www.`. Nil when the pattern
/// names no host.
func linkRouteDomain(fromPattern pattern: String) -> String? {
    var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    // A bare IPv6 literal ("::1") is the only host with colons and no brackets.
    if !text.contains("://"), !text.contains("["), text.filter({ $0 == ":" }).count > 1 {
        text = "[\(text)]"
    }
    while text.hasPrefix("*.") { text.removeFirst(2) }
    while text.hasPrefix(".") { text.removeFirst() }
    // Parsed as a URL so a pasted address, a port or a path is reduced to the
    // host, and an IDN comes back IDNA-encoded, as WebKit's URLs carry it.
    let urlText = text.contains("://") ? text : "http://" + text
    guard let host = URL(string: urlText)?.authorityHost else { return nil }
    var domain = normalizedHost(host)
    // "www.example.com" means the site: example.com and its subdomains. Only
    // when a registrable-looking name is left: "www.com" must not become "com",
    // which would cover every .com host.
    if domain.hasPrefix("www."), domain.dropFirst(4).contains(".") { domain.removeFirst(4) }
    return domain.isEmpty ? nil : domain
}

/// Routes match web pages only: an internal `detour://` page, a file or a
/// `data:` URL is never sent to another space.
private func isRoutableURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
}

private func normalizedHost(_ host: String) -> String {
    var host = host.lowercased()
    while host.hasSuffix(".") { host.removeLast() }
    return host
}

private func isIPLiteral(_ host: String) -> Bool {
    if host.hasPrefix("[") { return true }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    return labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// The form two URLs are compared in for `isEqualTo`: lowercased, without the
/// fragment, a default port or user info, and with an empty path as "/".
private func equalityForm(of url: URL) -> String? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          url.authorityHost != nil else { return nil }
    components.fragment = nil
    components.user = nil
    components.password = nil
    components.port = url.nonDefaultPort
    if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
    return components.string?.lowercased()
}

// MARK: - Routes that point at a space

/// The routes, and whether the Default, that target a space. A space with any
/// cannot be deleted (user decision 2026-10-25).
struct LinkRouteReferences: Equatable {
    var routes: [LinkRoute]
    var isDefaultTarget: Bool

    var isEmpty: Bool { routes.isEmpty && !isDefaultTarget }
}

/// What targets `spaceID`: the routes in `sortOrder`, and the Default.
func linkRoutesTargeting(spaceID: UUID, routes: [LinkRoute], defaultTarget: LinkRouteTarget) -> LinkRouteReferences {
    let targeting = routes.enumerated()
        .filter { $0.element.target == .space(spaceID) }
        .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
        .map(\.element)
    return LinkRouteReferences(routes: targeting, isDefaultTarget: defaultTarget == .space(spaceID))
}
