import Foundation

enum SidebarRow: Equatable {
    case topSpacer
    case pinnedItem(index: Int)
    case separator
    case newTab
    /// Index into the space's `[TabListItem]` list (a split group is one item),
    /// NOT into `space.tabs`. Convert via `TabListItems.swift` helpers.
    case normalTab(index: Int)
}

func sidebarRow(for row: Int, pinnedItemCount: Int) -> SidebarRow {
    if row == 0 { return .topSpacer }
    let adjusted = row - 1
    if adjusted < pinnedItemCount {
        return .pinnedItem(index: adjusted)
    }
    if adjusted == pinnedItemCount {
        return .separator
    }
    let afterSeparator = adjusted - pinnedItemCount - 1
    if afterSeparator == 0 {
        return .newTab
    }
    return .normalTab(index: afterSeparator - 1)
}

/// `itemIndex` indexes the space's `[TabListItem]` list (splits are one item each).
func rowForNormalTab(at itemIndex: Int, pinnedItemCount: Int) -> Int {
    return 1 + pinnedItemCount + 1 + 1 + itemIndex
}

func rowForPinnedItem(at index: Int) -> Int {
    return 1 + index
}

func totalSidebarRowCount(pinnedItemCount: Int, itemCount: Int) -> Int {
    return 1 + pinnedItemCount + 1 + 1 + itemCount
}

// MARK: - Sidebar Diff

struct SidebarDiff {
    let removedRows: IndexSet              // row indices in OLD layout
    let insertedRows: IndexSet             // row indices in NEW layout
    let movedRows: [(from: Int, to: Int)]  // (old-layout row, new-layout row)
    var hasChanges: Bool { !removedRows.isEmpty || !insertedRows.isEmpty || !movedRows.isEmpty }
}

func diffSidebarState(
    oldPinnedItems: [PinnedItem], newPinnedItems: [PinnedItem],
    oldTabs: [TabListItem], newTabs: [TabListItem]
) -> SidebarDiff {
    // A split forming or dissolving within one update is a row CONTINUATION,
    // not remove+insert: alias the group's ID to the member single it morphs
    // from/into, so the row stays put (or moves) and only the other member's
    // row enters/leaves. Aliases are section-scoped — pin/unpin of a whole
    // group keeps its groupID in both sections and diffs as a move unchanged.
    let pinnedAliases = splitContinuationAliases(
        old: oldPinnedItems.map { (id: pinnedItemID($0), memberIDs: $0.entries.map(\.id)) },
        new: newPinnedItems.map { (id: pinnedItemID($0), memberIDs: $0.entries.map(\.id)) }
    )
    let tabAliases = splitContinuationAliases(
        old: oldTabs.map { (id: $0.itemID, memberIDs: $0.tabs.map(\.id)) },
        new: newTabs.map { (id: $0.itemID, memberIDs: $0.tabs.map(\.id)) }
    )

    let oldPinnedIDs = oldPinnedItems.map { pinnedAliases[pinnedItemID($0)] ?? pinnedItemID($0) }
    let newPinnedIDs = newPinnedItems.map { pinnedAliases[pinnedItemID($0)] ?? pinnedItemID($0) }
    let oldTabIDs = oldTabs.map { tabAliases[$0.itemID] ?? $0.itemID }
    let newTabIDs = newTabs.map { tabAliases[$0.itemID] ?? $0.itemID }

    let oldPinnedSet = Set(oldPinnedIDs)
    let newPinnedSet = Set(newPinnedIDs)
    let oldTabSet = Set(oldTabIDs)
    let newTabSet = Set(newTabIDs)

    // Collect all old and new IDs with their row positions
    let allOldIDs = Set(oldPinnedIDs + oldTabIDs)
    let allNewIDs = Set(newPinnedIDs + newTabIDs)

    // Build ID → row mappings
    var oldRowByID: [UUID: Int] = [:]
    for (i, id) in oldPinnedIDs.enumerated() { oldRowByID[id] = rowForPinnedItem(at: i) }
    for (i, id) in oldTabIDs.enumerated() { oldRowByID[id] = rowForNormalTab(at: i, pinnedItemCount: oldPinnedItems.count) }

    var newRowByID: [UUID: Int] = [:]
    for (i, id) in newPinnedIDs.enumerated() { newRowByID[id] = rowForPinnedItem(at: i) }
    for (i, id) in newTabIDs.enumerated() { newRowByID[id] = rowForNormalTab(at: i, pinnedItemCount: newPinnedItems.count) }

    var removed = IndexSet()
    var inserted = IndexSet()
    var movedRows: [(from: Int, to: Int)] = []

    // Pure removals: in old but not in new at all
    for id in allOldIDs where !allNewIDs.contains(id) {
        removed.insert(oldRowByID[id]!)
    }
    // Pure insertions: in new but not in old at all
    for id in allNewIDs where !allOldIDs.contains(id) {
        inserted.insert(newRowByID[id]!)
    }

    // Cross-section moves: ID exists in both but switched section (pin/unpin)
    let crossSectionIDs = allOldIDs.intersection(allNewIDs).filter { id in
        let wasPinned = oldPinnedSet.contains(id)
        let isPinned = newPinnedSet.contains(id)
        return wasPinned != isPinned
    }
    for id in crossSectionIDs {
        movedRows.append((from: oldRowByID[id]!, to: newRowByID[id]!))
    }

    // Within-section moves (items that stayed in same section but changed relative order)
    movedRows += computeMoves(
        oldIDs: oldPinnedIDs, newIDs: newPinnedIDs,
        commonIDs: oldPinnedSet.intersection(newPinnedSet),
        oldRow: { rowForPinnedItem(at: $0) },
        newRow: { rowForPinnedItem(at: $0) }
    )

    movedRows += computeMoves(
        oldIDs: oldTabIDs, newIDs: newTabIDs,
        commonIDs: oldTabSet.intersection(newTabSet),
        oldRow: { rowForNormalTab(at: $0, pinnedItemCount: oldPinnedItems.count) },
        newRow: { rowForNormalTab(at: $0, pinnedItemCount: newPinnedItems.count) }
    )

    return SidebarDiff(removedRows: removed, insertedRows: inserted, movedRows: movedRows)
}

/// Identity aliases for split groups that form or dissolve between two item
/// lists of one section. A forming group (in `new` only) is a continuation of
/// the member single row it replaced; a dissolving group (in `old` only)
/// continues as the member single row that takes its place. In both cases the
/// chosen member is the one whose single row sits nearest the group's item
/// index — in practice the drop target (merge) or the member left in place
/// (dissolve) — so the row morphs in place while only the OTHER member's row
/// is inserted/removed. Returns groupID → member ID, to be applied to both
/// lists' identities. Groups with no vanished/appeared member single (e.g. a
/// whole group pinned across sections) get no alias and diff as before.
func splitContinuationAliases(
    old: [(id: UUID, memberIDs: [UUID])],
    new: [(id: UUID, memberIDs: [UUID])]
) -> [UUID: UUID] {
    let oldIDs = Set(old.map(\.id))
    let newIDs = Set(new.map(\.id))
    var aliases: [UUID: UUID] = [:]

    func continuation(of group: (id: UUID, memberIDs: [UUID]), at index: Int,
                      among singles: [(id: UUID, memberIDs: [UUID])],
                      absentFrom otherSideIDs: Set<UUID>) -> UUID? {
        let members = Set(group.memberIDs)
        let candidates = singles.enumerated().filter { _, item in
            item.memberIDs.count == 1 && members.contains(item.id) && !otherSideIDs.contains(item.id)
        }
        // Nearest single row wins. Ties break to the LATER row: a merge ties
        // only when the drag came from above, where the later candidate is the
        // drop target; a dissolve ties when the departed member re-landed just
        // above the group, where the later candidate is the member that held
        // the group's position.
        return candidates.min { a, b in
            let (da, db) = (abs(a.offset - index), abs(b.offset - index))
            return da != db ? da < db : a.offset > b.offset
        }?.element.id
    }

    // Both directions are the same rule with the sides swapped: a group present
    // on only one side (`side`) continues the lone member on the OTHER side that
    // vanished/appeared. First tuple = merges (group new, continues an old single
    // that vanished); second = dissolves (group old, continues a new single that
    // appeared).
    for (side, sideIDs, other, otherIDs) in [(new, newIDs, old, oldIDs), (old, oldIDs, new, newIDs)] {
        for (index, item) in side.enumerated() where item.memberIDs.count > 1 && !otherIDs.contains(item.id) {
            if let member = continuation(of: item, at: index, among: other, absentFrom: sideIDs) {
                aliases[item.id] = member
            }
        }
    }
    return aliases
}

/// Computes the minimal set of moves for items that exist in both old and new
/// but changed relative order. Items in the Longest Increasing Subsequence of
/// old-indices (ordered by new position) stay in place; the rest need moves.
private func computeMoves(
    oldIDs: [UUID], newIDs: [UUID], commonIDs: Set<UUID>,
    oldRow: (Int) -> Int, newRow: (Int) -> Int
) -> [(from: Int, to: Int)] {
    guard commonIDs.count >= 2 else { return [] }

    // Map each common ID to its old index
    var oldIndexByID: [UUID: Int] = [:]
    for (i, id) in oldIDs.enumerated() where commonIDs.contains(id) {
        oldIndexByID[id] = i
    }

    // Walk common IDs in new order, collecting (newIdx, oldIdx) pairs
    var pairs: [(newIdx: Int, oldIdx: Int, id: UUID)] = []
    for (newIdx, id) in newIDs.enumerated() where commonIDs.contains(id) {
        if let oldIdx = oldIndexByID[id] {
            pairs.append((newIdx: newIdx, oldIdx: oldIdx, id: id))
        }
    }

    // Find LIS of oldIdx values — these items keep their relative order
    let oldIndices = pairs.map(\.oldIdx)
    let stableSet = longestIncreasingSubsequenceIndices(oldIndices)

    // Items NOT in the LIS need to be moved.
    // Sort by destination ascending — NSTableView processes moves sequentially,
    // so upward moves (lower destination) must be applied first.
    var moves: [(from: Int, to: Int)] = []
    for (i, pair) in pairs.enumerated() where !stableSet.contains(i) {
        moves.append((from: oldRow(pair.oldIdx), to: newRow(pair.newIdx)))
    }
    moves.sort { $0.to < $1.to }
    return moves
}

/// Returns the set of indices in `arr` that form the Longest Increasing Subsequence.
/// When multiple LIS of equal length exist, prefers keeping items with lower values
/// (lower old indices) stable — this makes the "moved" items be the ones the user
/// dragged, and produces upward moves which work correctly with sequential processing.
/// O(n²) — fine for sidebar-sized lists.
private func longestIncreasingSubsequenceIndices(_ arr: [Int]) -> Set<Int> {
    let n = arr.count
    guard n >= 2 else { return Set(0..<n) }

    var dp = [Int](repeating: 1, count: n)
    var prev = [Int](repeating: -1, count: n)

    for i in 1..<n {
        for j in 0..<i {
            if arr[j] < arr[i] && dp[j] + 1 > dp[i] {
                dp[i] = dp[j] + 1
                prev[i] = j
            }
        }
    }

    // Trace back from the best endpoint — prefer the latest index (>=)
    // so that items with lower old indices are kept stable
    var bestEnd = 0
    for i in 1..<n where dp[i] >= dp[bestEnd] {
        bestEnd = i
    }

    var result = Set<Int>()
    var idx = bestEnd
    while idx >= 0 {
        result.insert(idx)
        idx = prev[idx]
    }
    return result
}
