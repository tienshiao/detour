import Foundation

/// Computes which tab to select after closing the tab at the given index,
/// using a tree-style strategy: next sibling → previous sibling → parent → adjacent fallback.
/// - Parameters:
///   - closingIndex: The index of the tab being closed.
///   - tabs: The current tabs as (id, parentID) tuples.
///   - isOpener: Whether an id is a tab the closing tab can return to — the
///     one opener rule, `Space.openerTab(id:)` (a normal, live pinned or live
///     favourite tab of the space; TASK-358). The parent is chosen only when it
///     is one; it need not be in `tabs`.
/// - Returns: The ID of the tab to select, or nil if no other tab is left to select.
func tabCloseSelectionID(
    closingIndex: Int,
    tabs: [(id: UUID, parentID: UUID?)],
    isOpener: (UUID) -> Bool
) -> UUID? {
    guard closingIndex >= 0, closingIndex < tabs.count else { return nil }

    let closingTab = tabs[closingIndex]

    if let parentID = closingTab.parentID {
        // 1. Next sibling — first tab after closingIndex with the same parentID.
        //    Siblings match on the raw id: two children of a closed opener are
        //    still siblings.
        for i in (closingIndex + 1)..<tabs.count where tabs[i].parentID == parentID {
            return tabs[i].id
        }

        // 2. Previous sibling — first tab before closingIndex with the same parentID
        for i in stride(from: closingIndex - 1, through: 0, by: -1) where tabs[i].parentID == parentID {
            return tabs[i].id
        }

        // 3. Parent — while it is an opener, in the list or not (a pinned tab
        //    or favourite), so a lone child still returns to it.
        if parentID != closingTab.id, isOpener(parentID) {
            return parentID
        }
    }

    // 4. Adjacent fallback — right neighbor, or left if rightmost
    guard tabs.count > 1 else { return nil }
    if closingIndex < tabs.count - 1 {
        return tabs[closingIndex + 1].id
    } else {
        return tabs[closingIndex - 1].id
    }
}
