import Foundation

/// Which spaces' open tabs a command palette may offer as suggestions
/// ("Switch to Tab" rows, the open-tab top hit and its inline completion).
///
/// The rule (TASK-137): a Private window's tabs are never offered outside that
/// window, and a Private window is offered nothing but its own space.
enum PaletteTabScope {
    /// The two facts about a space the rule needs.
    struct SpaceRef: Equatable {
        let id: UUID
        let isIncognito: Bool
    }

    /// The ids of the spaces whose tabs the palette of one window may list.
    ///
    /// - Parameters:
    ///   - spaces: every space in the store, Private windows' spaces included.
    ///   - windowIsPrivate: whether the palette's window is a Private window.
    ///   - activeSpaceID: the space that window is showing.
    ///
    /// A normal window is offered every non-incognito space. A Private window
    /// is offered its own space only. The window also counts as Private when
    /// the space it shows is incognito, whatever `windowIsPrivate` says: the
    /// flag reaches the palette through an optional profile, and a missing one
    /// must not widen the list.
    static func offeredSpaceIDs(spaces: [SpaceRef], windowIsPrivate: Bool, activeSpaceID: UUID?) -> Set<UUID> {
        let activeSpace = spaces.first { $0.id == activeSpaceID }
        if windowIsPrivate || activeSpace?.isIncognito == true {
            return activeSpace.map { [$0.id] } ?? []
        }
        return Set(spaces.filter { !$0.isIncognito }.map(\.id))
    }
}
