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

/// Groups adjacent tabs sharing a `splitGroupID` into split items. Defensive:
/// a groupID that appears on only one contiguous tab renders as a single (the
/// persistence sanity pass clears such IDs, but rendering must never trust it).
func tabListItems(from tabs: [BrowserTab]) -> [TabListItem] {
    var items: [TabListItem] = []
    var i = 0
    while i < tabs.count {
        let tab = tabs[i]
        if let groupID = tab.splitGroupID {
            var run = [tab]
            var j = i + 1
            while j < tabs.count, tabs[j].splitGroupID == groupID {
                run.append(tabs[j])
                j += 1
            }
            items.append(run.count >= 2 ? .split(groupID: groupID, members: run) : .single(tab))
            i = j
        } else {
            items.append(.single(tab))
            i += 1
        }
    }
    return items
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
/// groupID does not form exactly one contiguous run of two or more tabs
/// (partial writes, hand-edited databases). Mutates the tabs in place.
func sanitizeSplitGroups(_ tabs: [BrowserTab]) {
    var runsByGroup: [UUID: Int] = [:]
    var runLengths: [UUID: Int] = [:]

    var i = 0
    while i < tabs.count {
        guard let groupID = tabs[i].splitGroupID else { i += 1; continue }
        var j = i
        while j < tabs.count, tabs[j].splitGroupID == groupID { j += 1 }
        runsByGroup[groupID, default: 0] += 1
        runLengths[groupID] = j - i
        i = j
    }

    for tab in tabs {
        guard let groupID = tab.splitGroupID else { continue }
        let valid = runsByGroup[groupID] == 1 && (runLengths[groupID] ?? 0) >= 2
        if !valid {
            tab.splitGroupID = nil
            tab.splitFraction = nil
        }
    }
}
