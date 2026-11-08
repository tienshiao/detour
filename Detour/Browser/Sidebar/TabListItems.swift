import Foundation

/// Which side of a split a tab occupies (or is dropped onto).
enum SplitEdge: Equatable {
    case left
    case right
}

/// A renderable item in the sidebar's normal-tab section: a lone tab, or a
/// split group shown as a single row. Computed from `space.tabs` by
/// `tabListItems(from:)` — the tabs array remains the source of truth.
enum TabListItem: Equatable {
    case single(BrowserTab)
    case split(groupID: UUID, members: [BrowserTab])

    /// Stable identity for diffing: the tab's ID, or the group's ID (which
    /// survives member navigation and focus changes).
    var itemID: UUID {
        switch self {
        case .single(let tab): return tab.id
        case .split(let groupID, _): return groupID
        }
    }

    var tabs: [BrowserTab] {
        switch self {
        case .single(let tab): return [tab]
        case .split(_, let members): return members
        }
    }

    func contains(tabID: UUID) -> Bool {
        tabs.contains { $0.id == tabID }
    }
}

/// A maximal run of adjacent elements sharing one non-nil split group ID, as
/// produced by `splitRuns(of:groupID:)`. An element without a group ID is a
/// singleton run whose `groupID` is nil.
struct SplitRun: Equatable {
    let groupID: UUID?
    let range: Range<Int>
}

/// THE run scan: partitions `elements`, in order, into contiguous runs of
/// adjacent elements sharing the same non-nil group ID (nil-keyed elements
/// become singleton runs). Every element belongs to exactly one run. All
/// split-group adjacency logic — tab items, pinned flattening, block moves,
/// both load-time sanitizers — goes through this one function.
func splitRuns<Element>(of elements: [Element], groupID: (Element) -> UUID?) -> [SplitRun] {
    var runs: [SplitRun] = []
    var i = 0
    while i < elements.count {
        guard let group = groupID(elements[i]) else {
            runs.append(SplitRun(groupID: nil, range: i..<(i + 1)))
            i += 1
            continue
        }
        var j = i + 1
        while j < elements.count, groupID(elements[j]) == group { j += 1 }
        runs.append(SplitRun(groupID: group, range: i..<j))
        i = j
    }
    return runs
}

/// Split-invariant validity over runs: a group ID is valid iff it forms
/// exactly one contiguous run of exactly two members (a split is EXACTLY two
/// adjacent members). For pinned entries, accumulate the runs of every
/// sibling level before calling — validity is judged across all of them.
func validSplitGroupIDs(in runs: [SplitRun]) -> Set<UUID> {
    var runCounts: [UUID: Int] = [:]
    var runLengths: [UUID: Int] = [:]
    for run in runs {
        guard let groupID = run.groupID else { continue }
        runCounts[groupID, default: 0] += 1
        runLengths[groupID] = run.range.count
    }
    return Set(runCounts.compactMap { groupID, count in
        count == 1 && runLengths[groupID] == 2 ? groupID : nil
    })
}

/// Groups adjacent tabs sharing a `splitGroupID` into split items. Defensive:
/// a groupID that appears on only one contiguous tab renders as a single (the
/// persistence sanity pass clears such IDs, but rendering must never trust it).
func tabListItems(from tabs: [BrowserTab]) -> [TabListItem] {
    splitRuns(of: tabs, groupID: { $0.splitGroupID }).map { run in
        if let groupID = run.groupID, run.range.count >= 2 {
            return .split(groupID: groupID, members: Array(tabs[run.range]))
        }
        return .single(tabs[run.range.lowerBound])
    }
}

/// Index of the item containing the tab at `tabIndex` in the underlying tabs array.
func itemIndex(forTabIndex tabIndex: Int, in items: [TabListItem]) -> Int? {
    var consumed = 0
    for (i, item) in items.enumerated() {
        consumed += item.tabs.count
        if tabIndex < consumed { return i }
    }
    return nil
}

func itemIndex(containingTabID tabID: UUID, in items: [TabListItem]) -> Int? {
    items.firstIndex { $0.contains(tabID: tabID) }
}

/// Index in the underlying tabs array of the first tab of the item at `itemIndex`.
func firstTabIndex(forItemIndex itemIndex: Int, in items: [TabListItem]) -> Int? {
    guard itemIndex >= 0, itemIndex < items.count else { return nil }
    return items[..<itemIndex].reduce(0) { $0 + $1.tabs.count }
}

/// Converts an item-gap index (0...items.count, as produced by item-based drop
/// destinations) to a gap index in the underlying tabs array (0...tabs.count).
func tabGapIndex(forItemGap itemGap: Int, in items: [TabListItem]) -> Int {
    let clamped = max(0, min(itemGap, items.count))
    return items[..<clamped].reduce(0) { $0 + $1.tabs.count }
}

/// Load-time defense: clears `splitGroupID`/`splitFraction` from tabs whose
/// groupID does not form exactly one contiguous run of exactly two tabs
/// (partial writes, hand-edited databases, legacy oversized groups). Mutates
/// the tabs in place.
func sanitizeSplitGroups(_ tabs: [BrowserTab]) {
    let valid = validSplitGroupIDs(in: splitRuns(of: tabs, groupID: { $0.splitGroupID }))
    for tab in tabs {
        guard let groupID = tab.splitGroupID, !valid.contains(groupID) else { continue }
        tab.splitGroupID = nil
        tab.splitFraction = nil
    }
}

// MARK: - Tab group stripes (TASK-132.11)

/// How a tab-section row shows the tab group it belongs to: a stripe in the
/// group's colour at the row's leading edge. The stripe runs on into the row
/// above or below when that row is in the same group, so a group's rows read
/// as one bar with rounded ends.
struct TabGroupStripe: Equatable {
    let groupID: UUID
    let color: TabGroupColor
    /// The group's own title, as stored (may be empty).
    let title: String
    let continuesAbove: Bool
    let continuesBelow: Bool

    /// The title a person reads (`tabGroupDisplayTitle`).
    var displayTitle: String { tabGroupDisplayTitle(title) }
}

/// A tab group's title as a person reads it: trimmed, and "Unnamed group"
/// (Chrome's wording) for a group without one.
func tabGroupDisplayTitle(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Unnamed group" : trimmed
}

/// The tab group an item's row shows: the group every tab of the item names,
/// when it is one of `groups`. A split row stands for its pair, so it shows
/// the group once. Defensive, like `tabListItems`: a pair whose panes name
/// different groups, or an id naming no group, gets no stripe (TabStore keeps
/// neither from happening, but rendering must never trust group data).
func tabGroup(of item: TabListItem, in groups: [TabGroup]) -> TabGroup? {
    let tabs = item.tabs
    guard let id = tabs.first?.tabGroupID, tabs.allSatisfy({ $0.tabGroupID == id }) else { return nil }
    return groups.first { $0.id == id }
}

/// The stripe of the item at `index`, or nil for a row outside any group.
func tabGroupStripe(at index: Int, in items: [TabListItem], groups: [TabGroup]) -> TabGroupStripe? {
    guard items.indices.contains(index), let group = tabGroup(of: items[index], in: groups) else { return nil }
    func sameGroup(_ neighbour: Int) -> Bool {
        items.indices.contains(neighbour) && tabGroup(of: items[neighbour], in: groups)?.id == group.id
    }
    return makeTabGroupStripe(group, continuesAbove: sameGroup(index - 1), continuesBelow: sameGroup(index + 1))
}

/// Every item's stripe, in item order. Resolves each item's group once.
func tabGroupStripes(for items: [TabListItem], groups: [TabGroup]) -> [TabGroupStripe?] {
    let itemGroups = items.map { tabGroup(of: $0, in: groups) }
    return itemGroups.indices.map { i in
        guard let group = itemGroups[i] else { return nil }
        func sameGroup(_ neighbour: Int) -> Bool {
            itemGroups.indices.contains(neighbour) && itemGroups[neighbour]?.id == group.id
        }
        return makeTabGroupStripe(group, continuesAbove: sameGroup(i - 1), continuesBelow: sameGroup(i + 1))
    }
}

private func makeTabGroupStripe(_ group: TabGroup, continuesAbove: Bool, continuesBelow: Bool) -> TabGroupStripe {
    TabGroupStripe(groupID: group.id, color: group.color, title: group.title,
                   continuesAbove: continuesAbove, continuesBelow: continuesBelow)
}
