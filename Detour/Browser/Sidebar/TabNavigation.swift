import Foundation

/// One keyboard-navigation stop (Cmd+Option+Up/Down, TASK-107): a selectable
/// sidebar row. A split — pinned or normal — is one stop, like its row.
struct TabNavigationStop: Equatable {
    enum Target: Equatable {
        /// A pinned row, selected through its entry (which may be dormant).
        /// For a pinned split this is the left pane's entry.
        case pinnedEntry(UUID)
        /// A normal-tab row, selected through its tab. For a split this is
        /// the left pane's tab.
        case tab(UUID)
    }

    let target: Target
    /// The live tabs the row stands for — how the current stop is found from
    /// the window's selected tab. Empty for a dormant pinned row.
    let tabIDs: [UUID]
}

/// The stops of a space in sidebar order: the flattened pinned rows (folder
/// rows skipped; entries inside collapsed folders are already absent from
/// `pinnedItems`), then the normal-tab items.
func tabNavigationStops(pinnedItems: [PinnedItem], tabItems: [TabListItem]) -> [TabNavigationStop] {
    var stops: [TabNavigationStop] = []
    for item in pinnedItems {
        guard let first = item.entries.first else { continue }
        stops.append(TabNavigationStop(target: .pinnedEntry(first.id),
                                       tabIDs: item.entries.compactMap { $0.tab?.id }))
    }
    for item in tabItems {
        guard let first = item.tabs.first else { continue }
        stops.append(TabNavigationStop(target: .tab(first.id), tabIDs: item.tabs.map(\.id)))
    }
    return stops
}

/// The stop `offset` rows away from the one holding `selectedTabID`, wrapping
/// at both ends. With no current stop (a favourite, a Peek or nothing is
/// selected) forward starts at the first stop and backward at the last. Nil
/// when there is nowhere else to go.
func tabNavigationTarget(in stops: [TabNavigationStop], selectedTabID: UUID?, offset: Int) -> TabNavigationStop? {
    guard !stops.isEmpty, offset != 0 else { return nil }
    guard let selectedTabID,
          let current = stops.firstIndex(where: { $0.tabIDs.contains(selectedTabID) }) else {
        return offset > 0 ? stops.first : stops.last
    }
    let count = stops.count
    let target = ((current + offset) % count + count) % count
    return target == current ? nil : stops[target]
}
