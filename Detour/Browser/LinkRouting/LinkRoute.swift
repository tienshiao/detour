import Foundation

// Link Routes (TASK-191): routes that send a link to a chosen space.
// This file is the model; `LinkRouteResolver.swift` decides where a link goes,
// `LinkRouteStore` keeps the routes in the session database.

/// What a route's URL condition compares. Every kind is case-insensitive.
enum LinkRouteMatchKind: String, CaseIterable {
    /// The whole URL equals the pattern, ignoring the fragment, a default port
    /// and an empty path (`https://example.com` equals `https://example.com/#top`).
    case isEqualTo
    /// The URL's text contains the pattern.
    case contains
    /// The URL's host is the pattern's host or one of its subdomains.
    case domainIs
}

/// A route's URL condition.
struct LinkRouteMatch: Equatable {
    var kind: LinkRouteMatchKind
    var pattern: String

    /// Whether the pattern says anything: an empty (or all-whitespace) pattern
    /// matches no URL.
    var isEmpty: Bool { pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Where a routed link opens.
enum LinkRouteTarget: Equatable, Hashable {
    /// A specific normal (non-Private) space.
    case space(UUID)
    /// The space in front: what a link from another app does without routes.
    case mostRecentSpace
    /// The most recent open Private window, else a new one. Routing is one-way
    /// at the Private boundary: into Private only.
    case privateWindow
    /// A throwaway Quick Detour window on its own ephemeral store (TASK-194).
    /// Links from other apps only.
    case quarantine
    /// A Quick Detour window (TASK-193.5). Links from other apps only until
    /// TASK-193.5 decides otherwise.
    case quickDetour

    /// The default target when none is stored.
    static let defaultTarget: LinkRouteTarget = .mostRecentSpace

    /// The space this target names, if it names one.
    var spaceID: UUID? {
        if case .space(let id) = self { return id }
        return nil
    }

    // MARK: Storage form

    /// The stored `targetKind`. Text rather than a number, so a target a later
    /// build adds is a new string an older build skips, not a renumbering.
    var storageKind: String {
        switch self {
        case .space: return "space"
        case .mostRecentSpace: return "mostRecentSpace"
        case .privateWindow: return "privateWindow"
        case .quarantine: return "quarantine"
        case .quickDetour: return "quickDetour"
        }
    }

    /// Rebuilds a target from its stored kind and space id. Nil for a kind this
    /// build does not know, or a space target without a readable id.
    init?(storageKind: String, spaceID: String?) {
        switch storageKind {
        case "space":
            guard let id = spaceID.flatMap(UUID.init(uuidString:)) else { return nil }
            self = .space(id)
        case "mostRecentSpace": self = .mostRecentSpace
        case "privateWindow": self = .privateWindow
        case "quarantine": self = .quarantine
        case "quickDetour": self = .quickDetour
        default: return nil
        }
    }
}

/// One link route: if a link matches the URL condition and/or
/// came from the source app, open it in `target`. Routes are tried in
/// `sortOrder`; the first that applies wins.
struct LinkRoute: Equatable, Identifiable {
    var id: UUID
    /// The URL condition; nil for an app-only route.
    var match: LinkRouteMatch?
    /// The sending app's bundle ID; nil for a route that ignores the sender. A
    /// route with one matches only links from other apps.
    var sourceApp: String?
    var target: LinkRouteTarget
    var sortOrder: Int

    init(id: UUID = UUID(), match: LinkRouteMatch?, sourceApp: String? = nil,
         target: LinkRouteTarget, sortOrder: Int = 0) {
        self.id = id
        self.match = match
        self.sourceApp = sourceApp
        self.target = target
        self.sortOrder = sortOrder
    }

    /// The source app with surrounding whitespace removed; nil when empty.
    var normalizedSourceApp: String? {
        guard let app = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { return nil }
        return app
    }

    /// A route needs at least one condition: a non-empty URL pattern or a
    /// source app. One with neither would match every link, so the store
    /// refuses it and the resolver ignores it.
    var hasCondition: Bool {
        (match.map { !$0.isEmpty } ?? false) || normalizedSourceApp != nil
    }
}
