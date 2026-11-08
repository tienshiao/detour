import Foundation

// What makes a route (or the Default) invalid (TASK-191.3). `LinkRouteStore`
// refuses to save a route with any problem and reports the problems, and the
// Links pane marks the rows the store refused.

/// Why a route cannot be saved, or no longer works.
enum LinkRouteProblem: Equatable {
    /// Neither a URL condition nor a source app: the route would match every link.
    case noCondition
    /// A URL condition with an empty pattern and no source app: the route has
    /// no condition yet. With an app chosen, an empty pattern is no URL
    /// condition (any URL from that app, TASK-302), as "Any URL" (`match == nil`) is.
    case emptyPattern
    /// The pattern means nothing for its kind: a "Domain is" that names no
    /// host, an "Is equal to" that is not an http(s) address.
    case invalidPattern
    /// The target space does not exist (deleted, or removed some other way).
    case missingSpace
    /// The target is a Private window's space. Private is its own target
    /// (`.privateWindow`); its spaces never are.
    case privateSpace
}

/// Whether `match`'s pattern can match anything for its kind.
func linkRoutePatternIsValid(_ match: LinkRouteMatch) -> Bool {
    let pattern = match.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return false }
    switch match.kind {
    case .contains:
        return true
    case .domainIs:
        // Whitespace inside a host is a typo, not a host: URL(string:) would
        // percent-encode it into a host no page has.
        guard !pattern.contains(where: \.isWhitespace) else { return false }
        return linkRouteDomain(fromPattern: pattern) != nil
    case .isEqualTo:
        // A full web address, as the resolver compares it: http(s) with a host.
        guard !pattern.contains(where: \.isWhitespace), let url = URL(string: pattern), isRoutableURL(url) else { return false }
        return url.authorityHost != nil
    }
}

/// What is wrong with `target`, or nil. With no context (a store no
/// `TabStore` owns) a space target is not checked.
func linkRouteTargetProblem(_ target: LinkRouteTarget, context: LinkRouteContext?) -> LinkRouteProblem? {
    guard case .space(let id) = target, let context, !context.spaceIDs.contains(id) else { return nil }
    return context.privateSpaceIDs.contains(id) ? .privateSpace : .missingSpace
}

/// Everything wrong with `route`, conditions first, then the target. Empty
/// when the route can be saved.
func linkRouteProblems(_ route: LinkRoute, context: LinkRouteContext?) -> [LinkRouteProblem] {
    var problems: [LinkRouteProblem] = []
    let hasApp = route.normalizedSourceApp != nil
    if let match = route.match, !match.isEmpty {
        if !linkRoutePatternIsValid(match) { problems.append(.invalidPattern) }
    } else if !hasApp {
        // An empty field is reported as the field to fill (or an app to
        // choose); "Any URL" with no app as a missing condition.
        problems.append(route.match == nil ? .noCondition : .emptyPattern)
    }
    // An app with an empty (or "Any URL") pattern is app-only: any web URL
    // from that app (user, Nov 8 2026; the resolver reads it the same way).
    if let problem = linkRouteTargetProblem(route.target, context: context) { problems.append(problem) }
    return problems
}
