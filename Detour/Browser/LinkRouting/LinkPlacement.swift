import Foundation

// Where a link from another app opens, once `resolveLinkRoute` has named its
// destination (TASK-191.2). Pure: the caller hands in a snapshot of the
// browser windows and carries out the placement; nothing here touches a
// window or the store.

/// One browser window, as the placement rule sees it.
struct LinkPlacementWindow<ID: Hashable>: Equatable {
    var id: ID
    /// The space the window shows (a Private window's own space for one).
    var activeSpaceID: UUID?
    var isPrivate: Bool
}

/// What to do with a link from another app.
enum LinkPlacement<ID: Hashable>: Equatable {
    /// Open it as a tab in this normal window, which shows the destination
    /// space, and bring the window forward.
    case openInWindow(ID)
    /// Switch this normal window to `toSpace`, open the tab there and bring
    /// the window forward.
    case switchWindow(ID, toSpace: UUID)
    /// Open a new normal window on `space`, with the tab.
    case openInNewWindow(space: UUID)
    /// Open it as a tab in this Private window and bring the window forward.
    case openInPrivateWindow(ID)
    /// Open a new Private window with the tab.
    case openInNewPrivateWindow
    /// Open a new Quick Detour window with the link (TASK-193.5), on the
    /// profile `QuickDetour.profileForRoutedLink` picks.
    case openInQuickDetour
    /// Open a new quarantine window with the link (TASK-194): a Quick Detour
    /// on a throwaway store of its own.
    case openInQuarantine
    /// What a link from another app did before routes existed: a tab in the
    /// key window's active space, else a new window.
    case mostRecentSpace
}

/// Where a link from another app whose route decision is `decision` opens.
/// `windows` are the browser windows, the most recently active first.
///
/// - A space a normal window shows: that window (the most recent of several).
/// - A space no window shows: the most recent normal window switches to it, as
///   a space switch does (user decision 2026-10-25); with no normal window, a
///   new window on it. A Private window is never switched: nothing of a normal
///   space opens in one.
/// - Private window: the most recent Private window, else a new one.
/// - Quick Detour: a new Quick Detour window (TASK-193.5).
/// - Quarantine: a new quarantine window (TASK-194).
/// - Most Recent Space: exactly what a link from another app did before routes.
func linkPlacement<ID: Hashable>(for decision: LinkRouteDecision,
                                 windows: [LinkPlacementWindow<ID>]) -> LinkPlacement<ID> {
    let normalWindows = windows.filter { !$0.isPrivate }
    switch decision {
    case .openInSpace(let spaceID):
        if let showing = normalWindows.first(where: { $0.activeSpaceID == spaceID }) {
            return .openInWindow(showing.id)
        }
        if let recent = normalWindows.first {
            return .switchWindow(recent.id, toSpace: spaceID)
        }
        return .openInNewWindow(space: spaceID)
    case .privateWindow:
        if let recent = windows.first(where: \.isPrivate) {
            return .openInPrivateWindow(recent.id)
        }
        return .openInNewPrivateWindow
    case .mostRecentSpace:
        return .mostRecentSpace
    case .quickDetour:
        // A new Quick Detour window, whatever windows are open (TASK-193.5).
        return .openInQuickDetour
    case .quarantine:
        // A new quarantine window, whatever windows are open (TASK-194).
        return .openInQuarantine
    case .stay:
        // The resolver never keeps a link from another app where it is (it is
        // in no window yet); should it, the link still has to open somewhere.
        return .mostRecentSpace
    }
}
