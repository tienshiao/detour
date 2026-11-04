import Foundation

/// What a command palette may suggest from: which spaces' open tabs ("Switch
/// to Tab" rows, the open-tab top hit and its inline completion) and which
/// history (every history row, the history top hit and inline completion, the
/// empty-field list and the filler rows under a typed query).
///
/// Both are the palette's **profile** (TASK-209): no row comes from another
/// profile, and none crosses the Private boundary in either direction
/// (TASK-137).
enum PaletteTabScope {
    /// The three facts about a space the rule needs.
    struct SpaceRef: Equatable {
        let id: UUID
        let isIncognito: Bool
        let profileID: UUID
    }

    /// The ids of the spaces whose tabs the palette of one window may list.
    ///
    /// - Parameters:
    ///   - spaces: every space in the store, Private windows' spaces included.
    ///   - windowIsPrivate: whether the palette's window is a Private window.
    ///   - activeSpaceID: the space that window is showing.
    ///
    /// A normal window is offered the non-incognito spaces of its active
    /// space's profile, not only the active one. A Private window is offered
    /// its own space only: every Private window shares the one Private profile
    /// but not its session. The window also counts as Private when the space
    /// it shows is incognito, whatever `windowIsPrivate` says: the flag reaches
    /// the palette through an optional profile, and a missing one must not
    /// widen the list. With no active space (or one the store no longer has)
    /// there is no profile to scope to, and nothing is offered.
    static func offeredSpaceIDs(spaces: [SpaceRef], windowIsPrivate: Bool, activeSpaceID: UUID?) -> Set<UUID> {
        guard let activeSpace = spaces.first(where: { $0.id == activeSpaceID }) else { return [] }
        if windowIsPrivate || activeSpace.isIncognito {
            return [activeSpace.id]
        }
        return Set(spaces.filter { !$0.isIncognito && $0.profileID == activeSpace.profileID }.map(\.id))
    }

    /// The history scope (`historyVisit.spaceID`s) a palette on `profile`
    /// suggests from: the profile's, exactly as its History page reads it
    /// (`HistoryPageBridge.scope(forProfile:)`) — every space of the profile
    /// and its Quick Detour scope. Empty for the Private profile (a Private
    /// window, a Private Quick Detour, a quarantine: none records history, and
    /// none may read a profile's), for a deleted profile and for none.
    ///
    /// The user's decision in TASK-209 (2026-10-26): the whole profile,
    /// replacing the TASK-94 scope of the window's active space.
    static func historySpaceIDs(profile: Profile?, in store: TabStore) -> [String] {
        HistoryPageBridge.scope(forProfile: profile, in: store) ?? []
    }
}
