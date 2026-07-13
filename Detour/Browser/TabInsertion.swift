import Foundation

/// Computes the insertion index for a new tab given its parent and the existing tab list.
/// - Parameters:
///   - parentID: The ID of the parent tab (if any).
///   - existingTabs: The current tabs as (id, parentID) tuples.
///   - pinnedTabIDs: IDs of pinned tabs (parent in pinned section → insert at front of normal tabs).
/// - Returns: The index at which the new tab should be inserted.
func tabInsertionIndex(
    parentID: UUID?,
    existingTabs: [(id: UUID, parentID: UUID?)],
    pinnedTabIDs: Set<UUID>
) -> Int {
    guard let parentID else {
        return 0
    }

    let parentIsNormalTab = !pinnedTabIDs.contains(parentID)
        && existingTabs.contains(where: { $0.id == parentID })

    if parentIsNormalTab, let parentIndex = existingTabs.firstIndex(where: { $0.id == parentID }) {
        var lastSiblingIndex = parentIndex
        for i in (parentIndex + 1)..<existingTabs.count {
            if existingTabs[i].parentID == parentID { lastSiblingIndex = i }
            else { break }
        }
        return lastSiblingIndex + 1
    } else {
        // Pinned parent (or parent not found) → first normal tab, after existing siblings
        var lastSiblingIndex = -1
        for i in 0..<existingTabs.count {
            if existingTabs[i].parentID == parentID { lastSiblingIndex = i }
            else if lastSiblingIndex >= 0 { break }
        }
        return lastSiblingIndex + 1
    }
}

/// Adjusts an insertion index so it never lands between members of a split
/// group, snapping forward to the group's end. `groupIDs` is the per-tab
/// `splitGroupID` of the existing tabs, in order.
func snappedToSplitGroupBoundary(_ index: Int, groupIDs: [UUID?]) -> Int {
    var i = max(0, min(index, groupIDs.count))
    while i > 0, i < groupIDs.count, let group = groupIDs[i - 1], groupIDs[i] == group {
        i += 1
    }
    return i
}

/// Resolves a tab move in the presence of split groups: moving any member of a
/// group moves the whole contiguous block, and a destination inside another
/// group snaps past it. `destinationIndex` is where the block's first tab should
/// land in the post-removal array. Returns nil for out-of-range or no-op moves.
func resolveTabMove(
    sourceIndex: Int,
    destinationIndex: Int,
    groupIDs: [UUID?]
) -> (blockRange: Range<Int>, insertAt: Int)? {
    guard let blockRange = splitBlockRange(containing: sourceIndex, groupIDs: groupIDs) else { return nil }

    var remaining = groupIDs
    remaining.removeSubrange(blockRange)
    let insertAt = snappedToSplitGroupBoundary(
        max(0, min(destinationIndex, remaining.count)),
        groupIDs: remaining
    )
    guard insertAt != blockRange.lowerBound else { return nil }
    return (blockRange, insertAt)
}

/// Gap-based variant for drop handling: `gapIndex` is a pre-removal insertion
/// gap (0...count). Converts to post-removal coordinates by subtracting the
/// moved block's tabs that precede the gap — the block may be wider than one
/// tab, which a caller-side `gap - 1` cannot know.
func resolveTabMove(
    sourceIndex: Int,
    toGapIndex gapIndex: Int,
    groupIDs: [UUID?]
) -> (blockRange: Range<Int>, insertAt: Int)? {
    guard let blockRange = splitBlockRange(containing: sourceIndex, groupIDs: groupIDs) else { return nil }
    let clampedGap = max(0, min(gapIndex, groupIDs.count))
    let blockTabsBeforeGap = max(0, min(clampedGap, blockRange.upperBound) - blockRange.lowerBound)
    return resolveTabMove(
        sourceIndex: sourceIndex,
        destinationIndex: clampedGap - blockTabsBeforeGap,
        groupIDs: groupIDs
    )
}

/// The contiguous block to move when the tab at `index` moves: its whole split
/// group, or just itself when ungrouped. Nil when out of range.
private func splitBlockRange(containing index: Int, groupIDs: [UUID?]) -> Range<Int>? {
    guard index >= 0, index < groupIDs.count else { return nil }
    // Every index falls in exactly one run (ungrouped tabs are singleton runs).
    return splitRuns(of: groupIDs, groupID: { $0 }).first { $0.range.contains(index) }?.range
}
