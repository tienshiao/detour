import Foundation

enum SidebarRow: Equatable {
    case topSpacer
    case pinnedItem(index: Int)
    case separator
    case newTab
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

func rowForNormalTab(at tabIndex: Int, pinnedItemCount: Int) -> Int {
    return 1 + pinnedItemCount + 1 + 1 + tabIndex
}

func rowForPinnedItem(at index: Int) -> Int {
    return 1 + index
}

func totalSidebarRowCount(pinnedItemCount: Int, tabCount: Int) -> Int {
    return 1 + pinnedItemCount + 1 + 1 + tabCount
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
    oldTabs: [BrowserTab], newTabs: [BrowserTab]
) -> SidebarDiff {
    let oldPinnedIDs = oldPinnedItems.map { pinnedItemID($0) }
    let newPinnedIDs = newPinnedItems.map { pinnedItemID($0) }
    let oldTabIDs = oldTabs.map(\.id)
    let newTabIDs = newTabs.map(\.id)

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

    // Items NOT in the LIS need to be moved
    var moves: [(from: Int, to: Int)] = []
    for (i, pair) in pairs.enumerated() where !stableSet.contains(i) {
        moves.append((from: oldRow(pair.oldIdx), to: newRow(pair.newIdx)))
    }
    return moves
}

/// Returns the set of indices in `arr` that form the Longest Increasing Subsequence.
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

    // Trace back from the best endpoint
    var bestEnd = 0
    for i in 1..<n where dp[i] > dp[bestEnd] {
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
