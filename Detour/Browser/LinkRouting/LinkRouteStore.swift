import Foundation

/// The link routes and the Default target (TASK-191.1), kept in the
/// session database's `linkRoute` and `linkRouteDefault` tables and cached
/// here. App-wide, not per profile: spaces are global. Loaded once at
/// creation; every change writes through.
final class LinkRouteStore {
    /// Posted (object: the store) after any change to the routes or the Default.
    static let didChangeNotification = Notification.Name("LinkRouteStoreDidChange")

    static let shared = LinkRouteStore(database: .shared)

    private let database: AppDatabase

    /// The routes in the order they are tried.
    private(set) var routes: [LinkRoute] = []
    /// Where a link that no route matches opens (from every origin).
    private(set) var defaultTarget: LinkRouteTarget = .defaultTarget

    /// The spaces a route may target, read at each change (TASK-191.3). The
    /// `TabStore` that owns the store sets it; nil (a store on its own, as in
    /// tests) leaves space targets unchecked.
    var spaceContext: (() -> LinkRouteContext?)?

    init(database: AppDatabase) {
        self.database = database
        // A row this build cannot read (a match kind or target a newer build
        // added) is skipped and left in the table.
        routes = database.loadLinkRoutes().compactMap(Self.route(from:))
        if let record = database.loadLinkRouteDefault(),
           let target = LinkRouteTarget(storageKind: record.targetKind, spaceID: record.targetSpaceID) {
            defaultTarget = target
        }
    }

    /// Everything that keeps `route` from being saved, or that breaks a saved
    /// one (a space that has gone): `linkRouteProblems` against the current
    /// spaces. Empty when the route is fine.
    func problems(for route: LinkRoute) -> [LinkRouteProblem] {
        linkRouteProblems(route, context: spaceContext?())
    }

    /// What is wrong with the Default: a space that has gone, or nil.
    var defaultTargetProblem: LinkRouteProblem? {
        linkRouteTargetProblem(defaultTarget, context: spaceContext?())
    }

    /// Appends a route (it is tried last). Returns the stored route, with its
    /// sort order, or nil when it has any problem (`problems(for:)`): no
    /// condition, an empty or invalid pattern, a missing or Private space.
    @discardableResult
    func add(_ route: LinkRoute) -> LinkRoute? {
        guard problems(for: route).isEmpty else { return nil }
        var route = route
        route.sourceApp = route.normalizedSourceApp
        route.sortOrder = (routes.map(\.sortOrder).max() ?? -1) + 1
        routes.append(route)
        database.saveLinkRoute(Self.record(from: route))
        postChange()
        return route
    }

    /// Replaces the route with `route.id`'s condition and target; its place in
    /// the order is kept. False when there is no such route, or the update
    /// leaves a problem with its conditions, or gives it a target that is
    /// missing or Private. A target the update leaves alone is not checked: a
    /// route whose space went some other way stays editable.
    @discardableResult
    func update(_ route: LinkRoute) -> Bool {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return false }
        let context = spaceContext?()
        var problems = linkRouteProblems(route, context: context)
        if route.target == routes[index].target {
            problems.removeAll { $0 == .missingSpace || $0 == .privateSpace }
        }
        guard problems.isEmpty else { return false }
        var route = route
        route.sourceApp = route.normalizedSourceApp
        route.sortOrder = routes[index].sortOrder
        routes[index] = route
        database.saveLinkRoute(Self.record(from: route))
        postChange()
        return true
    }

    /// Moves a route to `index` in the order (clamped), renumbering them all.
    func moveRoute(id: UUID, to index: Int) {
        guard let from = routes.firstIndex(where: { $0.id == id }) else { return }
        let route = routes.remove(at: from)
        routes.insert(route, at: max(0, min(index, routes.count)))
        for i in routes.indices { routes[i].sortOrder = i }
        database.saveLinkRouteOrder(routes.map { (id: $0.id.uuidString, sortOrder: $0.sortOrder) })
        postChange()
    }

    func removeRoute(id: UUID) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes.remove(at: index)
        database.deleteLinkRoute(id: id.uuidString)
        postChange()
    }

    /// Sets the Default. False, and nothing changes, for a space that is
    /// missing or Private.
    @discardableResult
    func setDefaultTarget(_ target: LinkRouteTarget) -> Bool {
        guard linkRouteTargetProblem(target, context: spaceContext?()) == nil else { return false }
        defaultTarget = target
        database.saveLinkRouteDefault(LinkRouteDefaultRecord(targetKind: target.storageKind,
                                                             targetSpaceID: target.spaceID?.uuidString))
        postChange()
        return true
    }

    /// What targets `spaceID`; a space with any cannot be deleted.
    func references(toSpace spaceID: UUID) -> LinkRouteReferences {
        linkRoutesTargeting(spaceID: spaceID, routes: routes, defaultTarget: defaultTarget)
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: Records

    private static func route(from record: LinkRouteRecord) -> LinkRoute? {
        guard let id = UUID(uuidString: record.id),
              let target = LinkRouteTarget(storageKind: record.targetKind, spaceID: record.targetSpaceID)
        else { return nil }
        var match: LinkRouteMatch?
        if let kind = record.matchKind {
            guard let known = LinkRouteMatchKind(rawValue: kind) else { return nil }
            match = LinkRouteMatch(kind: known, pattern: record.matchPattern ?? "")
        }
        return LinkRoute(id: id, match: match, sourceApp: record.sourceApp, target: target,
                         sortOrder: record.sortOrder)
    }

    private static func record(from route: LinkRoute) -> LinkRouteRecord {
        LinkRouteRecord(id: route.id.uuidString, matchKind: route.match?.kind.rawValue,
                        matchPattern: route.match?.pattern, sourceApp: route.normalizedSourceApp,
                        targetKind: route.target.storageKind, targetSpaceID: route.target.spaceID?.uuidString,
                        sortOrder: route.sortOrder)
    }
}
