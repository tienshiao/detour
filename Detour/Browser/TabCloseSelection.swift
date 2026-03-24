import Foundation

/// Computes which tab to select after closing the tab at the given index,
/// using a tree-style strategy: next sibling → previous sibling → parent → adjacent fallback.
/// - Parameters:
///   - closingIndex: The index of the tab being closed.
///   - tabs: The current tabs as (id, parentID) tuples.
///   - pinnedTabIDs: IDs of pinned tabs (parents in pinned section are not selectable here).
/// - Returns: The ID of the tab to select, or nil if no tabs remain.
func tabCloseSelectionID(
    closingIndex: Int,
    tabs: [(id: UUID, parentID: UUID?)],
    pinnedTabIDs: Set<UUID>
) -> UUID? {
    guard tabs.count > 1, closingIndex >= 0, closingIndex < tabs.count else { return nil }

    let closingTab = tabs[closingIndex]
    let parentID = closingTab.parentID

    // 1. Next sibling — first tab after closingIndex with the same parentID
    if let parentID {
        for i in (closingIndex + 1)..<tabs.count {
            if tabs[i].parentID == parentID { return tabs[i].id }
        }

        // 2. Previous sibling — first tab before closingIndex with the same parentID
        for i in stride(from: closingIndex - 1, through: 0, by: -1) {
            if tabs[i].parentID == parentID { return tabs[i].id }
        }

        // 3. Parent — if it's a normal tab (not pinned), select it
        if !pinnedTabIDs.contains(parentID),
           let parent = tabs.first(where: { $0.id == parentID }) {
            return parent.id
        }
    }

    // 4. Adjacent fallback — right neighbor, or left if rightmost
    if closingIndex < tabs.count - 1 {
        return tabs[closingIndex + 1].id
    } else {
        return tabs[closingIndex - 1].id
    }
}
