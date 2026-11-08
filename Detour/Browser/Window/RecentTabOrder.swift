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
    private(set) var count: Int
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

    /// The highlighted item was closed (Control+W, TASK-308): it leaves the
    /// list and the highlight moves to the item after it, wrapping to the
    /// first when it was the last. Returns whether the switcher stays open:
    /// as at the start, only while something is left to switch to —
    /// `hasCurrent` says whether the window's current item is still among the
    /// rest, which it is not when the closed item was the current one.
    mutating func removeHighlighted(hasCurrent: Bool) -> Bool {
        count -= 1
        if index >= count { index = 0 }
        return count >= (hasCurrent ? 2 : 1)
    }
}

// MARK: - Closing a card (TASK-308)

/// What one tab of a switcher card is, for Control+W.
enum RecentTabCardMember: Equatable {
    /// A tab in the space's normal section, in a split or not.
    case normal(splitGroupID: UUID?)
    /// The backing tab of a pinned entry.
    case pinned(entryID: UUID)
    /// The backing tab of a favourite.
    case favorite(favoriteID: UUID)
}

/// What Control+W does to the highlighted card: what Cmd+W does to its tab,
/// except that a split card is one thing and closes whole (the user's rule,
/// Nov 8 2026).
enum RecentTabCloseAction: Equatable {
    /// A lone normal tab: closed as Cmd+W closes it (a closed-tab record,
    /// undoable, Reopen Closed Tab brings it back).
    case closeTab(UUID)
    /// Both tabs of a normal split, closed together under one undo that
    /// brings the split back.
    case closeSplitGroup(UUID)
    /// Pinned entries (one, or a pinned split's two): made dormant, as Cmd+W
    /// does. A dormant tile is not offered by the switcher, so it leaves.
    case makePinnedDormant(entryIDs: [UUID])
    /// A favourite: deactivated, as Cmd+W does; it leaves the switcher too.
    case deactivateFavorite(UUID)
}

/// The close action for a card of `tabIDs`, given what each tab is. Nil when
/// a tab is unknown (closed since the switcher listed it) or the card is
/// not one the switcher builds (members of different kinds, a split that is
/// not one group).
func recentTabCloseAction(card tabIDs: [UUID], members: [UUID: RecentTabCardMember]) -> RecentTabCloseAction? {
    let kinds = tabIDs.compactMap { members[$0] }
    guard !kinds.isEmpty, kinds.count == tabIDs.count else { return nil }
    switch kinds[0] {
    case .normal(let groupID):
        if kinds.count == 1 { return .closeTab(tabIDs[0]) }
        guard let groupID, kinds.allSatisfy({ $0 == .normal(splitGroupID: groupID) }) else { return nil }
        return .closeSplitGroup(groupID)
    case .pinned:
        let entryIDs = kinds.compactMap { kind -> UUID? in
            if case .pinned(let entryID) = kind { return entryID } else { return nil }
        }
        return entryIDs.count == kinds.count ? .makePinnedDormant(entryIDs: entryIDs) : nil
    case .favorite(let favoriteID):
        return kinds.count == 1 ? .deactivateFavorite(favoriteID) : nil
    }
}
