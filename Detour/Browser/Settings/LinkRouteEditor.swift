import Foundation

// The Links pane's rules (TASK-191.3), kept out of the view controller so
// they can be tested: which targets a pop-up offers, where a dragged route
// lands, what a row's warning says, and the rows themselves (the store's
// routes, with edits the store refused and new routes not yet complete).

/// A normal space as a target pop-up shows it.
struct LinkRouteSpaceOption: Equatable {
    var id: UUID
    var name: String
    var emoji: String

    var title: String { emoji.isEmpty ? name : "\(emoji) \(name)" }
}

/// One item of a target pop-up (a route's "Open in", or the Default).
enum LinkRouteTargetMenuItem: Equatable {
    case space(LinkRouteSpaceOption)
    /// The current target names a space that is not offered: deleted (or a
    /// Private window's). Shown so the row says what it holds; never offered
    /// otherwise.
    case unavailableSpace(UUID)
    case mostRecentSpace
    case privateWindow
    case quarantine
    case quickDetour
    case separator

    /// The target the item stands for; nil for a separator.
    var target: LinkRouteTarget? {
        switch self {
        case .space(let option): return .space(option.id)
        case .unavailableSpace(let id): return .space(id)
        case .mostRecentSpace: return .mostRecentSpace
        case .privateWindow: return .privateWindow
        case .quarantine: return .quarantine
        case .quickDetour: return .quickDetour
        case .separator: return nil
        }
    }
}

/// The items of a target pop-up whose current target is `current`.
///
/// The normal spaces in order, then Most Recent Space, Private Window, Quick
/// Detour (TASK-193.5; it takes links from other apps only, as the resolver
/// rules) and Quarantine (TASK-194; links from other apps, and the clicks a
/// route to it matches, never in a Private window). A space that is not offered (deleted) is listed
/// first when it is the current target, rather than changing silently.
func linkRouteTargetMenu(spaces: [LinkRouteSpaceOption], current: LinkRouteTarget?) -> [LinkRouteTargetMenuItem] {
    var items: [LinkRouteTargetMenuItem] = []
    if case .space(let id) = current, !spaces.contains(where: { $0.id == id }) {
        items += [.unavailableSpace(id), .separator]
    }
    items += spaces.map(LinkRouteTargetMenuItem.space)
    if !spaces.isEmpty { items.append(.separator) }
    items += [.mostRecentSpace, .privateWindow, .quickDetour, .quarantine]
    return items
}

/// Where a route dragged from row `from` and dropped above row `dropRow` goes
/// in the store's order, or nil for no move. Only saved routes (the first
/// `savedCount` rows) move, and only among themselves.
func linkRouteMoveIndex(from: Int, dropRow: Int, savedCount: Int) -> Int? {
    guard from >= 0, from < savedCount else { return nil }
    let row = min(max(dropRow, 0), savedCount)
    // Above a row below it: one less once the route has left its place.
    let to = row > from ? row - 1 : row
    return to == from ? nil : to
}

/// The line a row shows for its problems, or nil when it has none.
/// `isSaved` false: a new route not yet complete; `hasUnsavedChanges`: an
/// edit the store refused, the saved version still routes links.
func linkRouteProblemMessage(_ problems: [LinkRouteProblem], kind: LinkRouteMatchKind?,
                             isSaved: Bool, hasUnsavedChanges: Bool) -> String? {
    guard let problem = problems.first else { return nil }
    let what: String
    switch problem {
    case .noCondition:
        what = "Choose a URL condition or an app."
    case .emptyPattern, .invalidPattern:
        switch kind {
        case .domainIs, nil: what = "Enter a domain, such as example.com."
        case .contains: what = "Enter the text to look for."
        case .isEqualTo: what = "Enter a full address starting with https://."
        }
    case .missingSpace:
        what = "Its space was deleted. Choose where these links open."
    case .privateSpace:
        what = "A Private space can’t be a target. Choose Private Window."
    }
    if !isSaved { return what + " Not saved yet." }
    if hasUnsavedChanges { return what + " Not saved: links follow the saved route." }
    return what
}

/// The rows of the Links pane over a `LinkRouteStore`.
///
/// Saved routes come first, in the store's order; an edit the store refuses
/// (an emptied pattern, say) stays on its row, marked, while the store keeps
/// the saved version. New routes are drafts after them until they are
/// complete, when the store takes them. Nothing incomplete is ever saved.
/// Drafts and refused edits last as long as the editor (the app's session).
final class LinkRouteEditor {
    struct Row: Equatable {
        var route: LinkRoute
        /// In the store. False for a new route the store has not accepted yet.
        var isSaved: Bool
        /// The row shows an edit the store refused; the saved version is still in use.
        var hasUnsavedChanges: Bool
        var problems: [LinkRouteProblem]
    }

    let store: LinkRouteStore

    /// What a row shows instead of the store's route: a refused edit of a
    /// saved route, or a draft (keyed by id either way).
    private var shown: [UUID: LinkRoute] = [:]
    /// The drafts, in the order they were added.
    private var draftIDs: [UUID] = []
    private var storeObserver: NSObjectProtocol?

    init(store: LinkRouteStore) {
        self.store = store
        // A refused edit belongs to its route: when the route goes (removed
        // here or anywhere else) the edit goes with it, and is not laid over
        // a route that comes back.
        storeObserver = NotificationCenter.default.addObserver(
            forName: LinkRouteStore.didChangeNotification, object: store, queue: nil) { [weak self] _ in
            self?.dropEditsOfRemovedRoutes()
        }
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    /// Saved routes in order, then drafts.
    var rows: [Row] {
        let saved = store.routes.map { route -> Row in
            if let edit = shown[route.id] {
                return Row(route: edit, isSaved: true, hasUnsavedChanges: true, problems: store.problems(for: edit))
            }
            return Row(route: route, isSaved: true, hasUnsavedChanges: false, problems: store.problems(for: route))
        }
        let drafts = draftIDs.compactMap { id -> Row? in
            guard let draft = shown[id] else { return nil }
            return Row(route: draft, isSaved: false, hasUnsavedChanges: false, problems: store.problems(for: draft))
        }
        return saved + drafts
    }

    /// Starts a new route as a draft at the end: "Domain is" with an empty
    /// pattern, to the Most Recent Space. Returns its id.
    @discardableResult
    func addDraft() -> UUID {
        let draft = LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: ""), target: .mostRecentSpace)
        shown[draft.id] = draft
        draftIDs.append(draft.id)
        return draft.id
    }

    /// Applies `change` to the row's route as shown and saves it if the store
    /// takes it. True when saved; otherwise the row keeps the change, marked.
    @discardableResult
    func edit(_ id: UUID, _ change: (inout LinkRoute) -> Void) -> Bool {
        guard var route = currentRoute(id) else { return false }
        change(&route)
        // Both branches drop the row's overlay before the store posts its
        // change, so a pane reloading on the notification already sees the
        // outcome (not the saved route and its draft as two rows).
        if let draftIndex = draftIDs.firstIndex(of: id) {
            draftIDs.remove(at: draftIndex)
            shown[id] = nil
            guard store.add(route) != nil else {
                draftIDs.insert(id, at: draftIndex)
                shown[id] = route
                return false
            }
            return true
        }
        shown[id] = nil
        guard store.update(route) else {
            shown[id] = route
            return false
        }
        return true
    }

    /// The problems `change` would leave the row with, without saving.
    func problems(previewing id: UUID, _ change: (inout LinkRoute) -> Void) -> [LinkRouteProblem] {
        guard var route = currentRoute(id) else { return [] }
        change(&route)
        return store.problems(for: route)
    }

    /// Removes a draft, or a saved route from the store.
    func remove(_ id: UUID) {
        if draftIDs.contains(id) {
            draftIDs.removeAll { $0 == id }
            shown[id] = nil
            return
        }
        shown[id] = nil
        store.removeRoute(id: id)
    }

    /// Moves the route on row `from` above row `dropRow`. True when it moved.
    @discardableResult
    func move(from: Int, dropRow: Int) -> Bool {
        let saved = store.routes
        guard let to = linkRouteMoveIndex(from: from, dropRow: dropRow, savedCount: saved.count) else { return false }
        store.moveRoute(id: saved[from].id, to: to)
        return true
    }

    /// The route a row shows: its draft or refused edit, else the saved one.
    private func currentRoute(_ id: UUID) -> LinkRoute? {
        shown[id] ?? store.routes.first { $0.id == id }
    }

    private func dropEditsOfRemovedRoutes() {
        let saved = Set(store.routes.map(\.id))
        let drafts = Set(draftIDs)
        shown = shown.filter { saved.contains($0.key) || drafts.contains($0.key) }
    }
}
