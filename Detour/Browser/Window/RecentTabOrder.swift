import Foundation

/// One Control+Tab switcher entry (TASK-108): a lone tab or a split, which
/// switches as one item like its sidebar row.
struct RecentTabCandidate: Equatable {
    /// The item's tabs in visual order (a split's left pane first).
    let tabIDs: [UUID]
    /// When the item was last left in this session (the newest member's
    /// `switcherPreviewAt`); nil when it has not been left since launch.
    let lastLeftAt: Date?
}

/// The switcher's list, most recent first: the item holding `selectedTabID`,
/// then every item left this session, newest first. Items not visited since
/// launch are not listed — the switcher only offers pages it has a preview of.
func recentTabOrder(_ candidates: [RecentTabCandidate], selectedTabID: UUID?) -> [RecentTabCandidate] {
    let current = selectedTabID.flatMap { id in candidates.first { $0.tabIDs.contains(id) } }
    let others = candidates
        .filter { $0 != current && $0.lastLeftAt != nil }
        .sorted { $0.lastLeftAt! > $1.lastLeftAt! }
    return (current.map { [$0] } ?? []) + others
}

/// The highlight while Control is held. Index 0 is the current item, so a
/// forward start lands on the previous tab and a backward start on the
/// oldest; both directions wrap. With no current item (nothing selected in
/// the window) index 0 is already the most recent tab, so a forward start
/// lands there and a single item is enough to switch to.
struct RecentTabSwitcherState: Equatable {
    let count: Int
    private(set) var index: Int

    /// Nil when there is nothing to switch to.
    init?(count: Int, backward: Bool, hasCurrent: Bool = true) {
        guard count >= (hasCurrent ? 2 : 1) else { return nil }
        self.count = count
        self.index = backward ? count - 1 : (hasCurrent ? 1 : 0)
    }

    mutating func advance(backward: Bool) {
        index = ((index + (backward ? -1 : 1)) % count + count) % count
    }

    /// Pointing at an item (hover) moves the highlight there.
    mutating func highlight(_ newIndex: Int) {
        guard newIndex >= 0, newIndex < count else { return }
        index = newIndex
    }
}
