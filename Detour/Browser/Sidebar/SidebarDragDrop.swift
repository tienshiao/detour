import AppKit

/// Pasteboard type for tab / pinned-item drags originating in a sidebar table.
let tabReorderPasteboardType = NSPasteboard.PasteboardType("com.mybrowser.tab-reorder")

/// Pasteboard type for favorite tile drags originating in a favorites bar.
let favoritePasteboardType = NSPasteboard.PasteboardType("com.mybrowser.favorite-reorder")

// MARK: - Drag Payloads

/// Identifies a dragged sidebar item by stable ID rather than row position, so the
/// drop stays valid if rows shift mid-drag (tab closed in background, folder collapsed)
/// and so drags from another window's sidebar can be recognized and rejected.
struct SidebarDragPayload: Codable, Equatable {
    enum Kind: String, Codable {
        case normalTab
        case pinnedEntry
        case pinnedFolder
        /// A whole split row; `itemID` is the group's FIRST member tab ID.
        case splitGroup
        /// One pane dragged out of a split row; `itemID` is that member's tab ID.
        case splitMember
        /// A whole pinned split row; `itemID` is the FIRST member's entry ID.
        case pinnedSplitGroup
        /// One pane dragged out of a pinned split row; `itemID` is that member's entry ID.
        case pinnedSplitMember
    }

    let kind: Kind
    let itemID: UUID
    let spaceID: UUID
    let sidebarID: UUID
}

/// Identifies a dragged favorite tile by stable ID (see `SidebarDragPayload`).
struct FavoriteDragPayload: Codable, Equatable {
    let favoriteID: UUID
    let sidebarID: UUID
}

extension SidebarDragPayload {
    var pasteboardString: String? { pasteboardEncode(self) }
    init?(pasteboardString: String) {
        guard let payload: Self = pasteboardDecode(pasteboardString) else { return nil }
        self = payload
    }
}

extension FavoriteDragPayload {
    var pasteboardString: String? { pasteboardEncode(self) }
    init?(pasteboardString: String) {
        guard let payload: Self = pasteboardDecode(pasteboardString) else { return nil }
        self = payload
    }
}

private func pasteboardEncode<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func pasteboardDecode<T: Decodable>(_ string: String) -> T? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

// MARK: - Drop Model

/// The kind of item being dragged, for validation purposes.
enum SidebarDragKind: Equatable {
    case normalTab
    case pinnedEntry
    case pinnedFolder
    case favorite
    case splitGroup
    case splitMember
    case pinnedSplitGroup
    case pinnedSplitMember

    init(_ kind: SidebarDragPayload.Kind) {
        switch kind {
        case .normalTab: self = .normalTab
        case .pinnedEntry: self = .pinnedEntry
        case .pinnedFolder: self = .pinnedFolder
        case .splitGroup: self = .splitGroup
        case .splitMember: self = .splitMember
        case .pinnedSplitGroup: self = .pinnedSplitGroup
        case .pinnedSplitMember: self = .pinnedSplitMember
        }
    }
}

/// Mirrors `NSTableView.DropOperation` so the drop logic stays AppKit-free and testable.
enum SidebarDropOperation: Equatable {
    case on
    case above
}

/// The dragged item resolved against the current model at drop time.
enum SidebarDragSource: Equatable {
    case normalTab(index: Int, tabID: UUID)
    case pinnedEntry(entryID: UUID)
    case pinnedFolder(folderID: UUID)
    /// A whole split row. `index` is the ITEM index; `memberTabIDs` its member
    /// tabs in visual order (left pane first).
    case splitGroup(index: Int, groupID: UUID, memberTabIDs: [UUID])
    /// One pane dragged out of its (still existing) split group.
    case splitMember(tabID: UUID, groupID: UUID)
    /// A whole pinned split row; `memberEntryIDs` in visual order (left first).
    case pinnedSplitGroup(groupID: UUID, memberEntryIDs: [UUID])
    /// One pane dragged out of its (still existing) pinned split.
    case pinnedSplitMember(entryID: UUID, groupID: UUID)
}

/// A drop position normalized so that spacer/separator/new-tab rows map to the
/// nearest real insertion point.
enum SidebarDropDestination: Equatable {
    case intoFolder(folderID: UUID)
    /// Insert before the flattened pinned item at `flatIndex` (== items.count → end of pinned section).
    case beforePinnedItem(flatIndex: Int)
    /// Insert before the normal tab at `gapIndex` (== tab count → end of tab list).
    case beforeNormalTab(gapIndex: Int)
    /// Form a split: the dragged tab becomes `targetTabID`'s left or right pane.
    case intoSplit(targetTabID: UUID, edge: SplitEdge)
}

enum SidebarDropValidation: Equatable {
    case reject
    case accept
    /// Accept as a split-creating edge drop; the view should draw the half-row
    /// overlay for `edge` instead of relying on the whole-row `.on` highlight.
    case acceptIntoSplit(edge: SplitEdge)
    /// Redraw the insertion line above the pinned item at this flattened index.
    case retargetToPinnedGap(index: Int)
    /// Redraw the insertion line above the normal tab at this index.
    case retargetToNormalTabGap(index: Int)
}

/// The store mutation a completed drop should perform.
enum SidebarDropCommand: Equatable {
    case reorderNormalTab(tabID: UUID, fromIndex: Int, toGapIndex: Int)
    case pinTab(tabID: UUID, folderID: UUID?, beforeItemID: UUID?)
    case unpinEntry(entryID: UUID, toGapIndex: Int)
    case movePinnedEntry(entryID: UUID, folderID: UUID?, beforeItemID: UUID?)
    case movePinnedFolder(folderID: UUID, parentFolderID: UUID?, beforeItemID: UUID?)
    case createSplit(draggedTabID: UUID, targetTabID: UUID, edge: SplitEdge)
    case removeFromSplit(tabID: UUID, toGapIndex: Int)
    /// Pin a whole split row, PRESERVING the group as a pinned split (§12).
    /// `firstMemberTabID` anchors the pair like a single pinTab's move.
    case pinSplitGroup(groupID: UUID, firstMemberTabID: UUID, folderID: UUID?, beforeItemID: UUID?)
    /// Unpin a whole pinned split row back into the tab list as a normal split.
    case unpinSplitGroup(groupID: UUID, toGapIndex: Int)
    /// Reorder a pinned split row (both entries move as a block).
    case movePinnedSplitGroup(groupID: UUID, firstMemberEntryID: UUID, folderID: UUID?, beforeItemID: UUID?)
    /// Unpin one member of a pinned split (the pinned split dissolves).
    case unpinSplitMember(entryID: UUID, toGapIndex: Int)
    /// Break one member out of its pinned split into its own pinned row.
    case removeFromPinnedSplit(entryID: UUID, folderID: UUID?, beforeItemID: UUID?)
}

// MARK: - Drop Geometry

/// Where within a normal-tab row an `.on` drop sits, from the pointer position
/// in the row's coordinate space (y measured from the row's top, flipped).
/// The outer ~40% bands on each side form a split; the middle band retargets to
/// the nearest reorder gap so precise row-insertion drops stay easy to hit.
enum RowDropZone: Equatable {
    case splitEdge(SplitEdge)
    /// Retarget to a plain reorder gap: 0 = the gap above the row, 1 = below.
    case reorderGap(offset: Int)
}

func rowDropZone(forX x: CGFloat, y: CGFloat, rowSize: CGSize) -> RowDropZone {
    guard rowSize.width > 0 else { return .reorderGap(offset: 0) }
    let fraction = x / rowSize.width
    if fraction < 0.4 { return .splitEdge(.left) }
    if fraction > 0.6 { return .splitEdge(.right) }
    return .reorderGap(offset: rowSize.height > 0 && y > rowSize.height / 2 ? 1 : 0)
}

/// What a drag initiated at `x` within a split row grabs: the pane whose
/// favicon segment (the leading stretch of its half) is under the pointer,
/// or the whole group from anywhere else on the row.
enum SplitRowDragKind: Equatable {
    case member(SplitEdge)
    case group
}

/// `indent` shifts the LEFT member's grab band past folder indentation (the
/// favicon sits at 4 + depth*16, see TabCellView) — the indent gutter itself
/// drags the whole group. The right band needs no shift: the divider is
/// centered in the row regardless of depth.
func splitRowDragKind(forX x: CGFloat, rowWidth: CGFloat, indent: CGFloat = 0) -> SplitRowDragKind {
    let grabWidth: CGFloat = 34  // favicon + its padding at each half's leading edge
    let mid = rowWidth / 2
    if x >= indent, x < min(indent + grabWidth, mid) { return .member(.left) }
    if x >= mid, x < min(mid + grabWidth, rowWidth) { return .member(.right) }
    return .group
}

// MARK: - Drop Resolution

/// Validation for `tableView(_:validateDrop:...)`: decides whether a drag of `kind`
/// may drop at (`row`, `operation`) and whether the indicator should be retargeted.
/// `dropZone` is the pointer's position within the row (`.on` proposals only) —
/// it decides between a split-edge drop and a middle-band reorder retarget.
func validateSidebarDrop(
    kind: SidebarDragKind,
    sourceItemID: UUID?,
    row: SidebarRow,
    operation: SidebarDropOperation,
    items: [PinnedItem],
    tabItems: [TabListItem] = [],
    dropZone: RowDropZone? = nil
) -> SidebarDropValidation {
    switch operation {
    case .on:
        switch row {
        case .pinnedItem(let idx):
            // Folder rows accept .on drops (placing the item inside the folder).
            // Whole split rows (normal or pinned) enter folders as pairs; a
            // lone pane can't pin or enter a folder in v1.
            guard kind != .splitMember, kind != .pinnedSplitMember,
                  idx < items.count,
                  case .folder(let folder, _) = items[idx] else { return .reject }
            if kind == .pinnedFolder, sourceItemID == folder.id { return .reject }
            return .accept

        case .normalTab(let idx):
            // Edge drops onto a single tab's row form a split (v1: only an
            // ungrouped normal tab may join, and only a single row is a target).
            guard kind == .normalTab, let dropZone,
                  idx < tabItems.count, case .single(let target) = tabItems[idx]
            else { return .reject }
            switch dropZone {
            case .splitEdge(let edge):
                return target.id == sourceItemID ? .reject : .acceptIntoSplit(edge: edge)
            case .reorderGap(let offset):
                return .retargetToNormalTabGap(index: idx + offset)
            }

        default:
            return .reject
        }

    case .above:
        switch row {
        case .topSpacer:
            // A whole split row may pin (both members); a lone pane may not.
            // (A pinned split MEMBER may drop to a pinned gap — it breaks out
            // into its own pinned row.)
            return kind == .splitMember ? .reject : .retargetToPinnedGap(index: 0)
        case .separator:
            return kind == .splitMember ? .reject : .retargetToPinnedGap(index: items.count)
        case .newTab:
            return kind == .pinnedFolder ? .reject : .retargetToNormalTabGap(index: 0)
        case .normalTab:
            return kind == .pinnedFolder ? .reject : .accept
        case .pinnedItem:
            return kind == .splitMember ? .reject : .accept
        }
    }
}

/// Normalizes a proposed drop row into a concrete insertion point.
func sidebarDropDestination(
    row: SidebarRow,
    operation: SidebarDropOperation,
    items: [PinnedItem],
    tabItems: [TabListItem] = [],
    dropZone: RowDropZone? = nil
) -> SidebarDropDestination? {
    switch operation {
    case .on:
        if case .normalTab(let idx) = row {
            guard let dropZone, idx < tabItems.count,
                  case .single(let target) = tabItems[idx] else { return nil }
            switch dropZone {
            case .splitEdge(let edge):
                return .intoSplit(targetTabID: target.id, edge: edge)
            case .reorderGap(let offset):
                // Validation retargets the middle band to an .above gap, but a
                // final drop can arrive before the retargeted proposal — resolve
                // it to the same gap rather than dropping it on the floor.
                return .beforeNormalTab(gapIndex: idx + offset)
            }
        }
        guard case .pinnedItem(let idx) = row, idx < items.count,
              case .folder(let folder, _) = items[idx] else { return nil }
        return .intoFolder(folderID: folder.id)

    case .above:
        switch row {
        case .topSpacer:
            return .beforePinnedItem(flatIndex: 0)
        case .pinnedItem(let idx):
            return .beforePinnedItem(flatIndex: idx)
        case .separator:
            return .beforePinnedItem(flatIndex: items.count)
        case .newTab:
            return .beforeNormalTab(gapIndex: 0)
        case .normalTab(let idx):
            return .beforeNormalTab(gapIndex: idx)
        }
    }
}

/// Resolves a validated drop into the mutation to perform. Returns nil for no-op
/// drops (item dropped back onto its own position) and structurally invalid moves
/// (folder into itself or a descendant).
func resolveSidebarDrop(
    source: SidebarDragSource,
    destination: SidebarDropDestination,
    items: [PinnedItem]
) -> SidebarDropCommand? {
    switch (source, destination) {
    case (.normalTab(let fromIndex, let tabID), .beforeNormalTab(let gap)):
        // Gaps adjacent to the source are no-ops
        guard gap != fromIndex, gap != fromIndex + 1 else { return nil }
        return .reorderNormalTab(tabID: tabID, fromIndex: fromIndex, toGapIndex: gap)

    case (.normalTab(_, let tabID), .intoSplit(let targetTabID, let edge)):
        guard tabID != targetTabID else { return nil }
        return .createSplit(draggedTabID: tabID, targetTabID: targetTabID, edge: edge)

    case (.normalTab(_, let tabID), .beforePinnedItem(let flat)):
        return .pinTab(tabID: tabID,
                       folderID: folderIDForDropIndex(flat, in: items),
                       beforeItemID: itemIDAtDropIndex(flat, in: items))

    case (.normalTab(_, let tabID), .intoFolder(let folderID)):
        return .pinTab(tabID: tabID, folderID: folderID, beforeItemID: nil)

    case (.pinnedEntry(let entryID), .beforePinnedItem(let flat)):
        let beforeItemID = itemIDAtDropIndex(flat, in: items)
        // Dropped back onto its own position — no-op. (The store excludes the moved
        // item from its sibling scan, so passing the item as its own anchor would
        // append it to the end of its level instead.)
        guard beforeItemID != entryID else { return nil }
        return .movePinnedEntry(entryID: entryID,
                                folderID: folderIDForDropIndex(flat, in: items),
                                beforeItemID: beforeItemID)

    case (.pinnedEntry(let entryID), .intoFolder(let folderID)):
        return .movePinnedEntry(entryID: entryID, folderID: folderID, beforeItemID: nil)

    case (.pinnedEntry(let entryID), .beforeNormalTab(let gap)):
        return .unpinEntry(entryID: entryID, toGapIndex: gap)

    case (.pinnedFolder(let folderID), .beforePinnedItem(let flat)):
        let beforeItemID = itemIDAtDropIndex(flat, in: items)
        guard beforeItemID != folderID else { return nil }
        let parentID = folderIDForDropIndex(flat, in: items)
        guard !wouldCreateFolderCycle(moving: folderID, into: parentID, items: items) else { return nil }
        return .movePinnedFolder(folderID: folderID, parentFolderID: parentID, beforeItemID: beforeItemID)

    case (.pinnedFolder(let folderID), .intoFolder(let destFolderID)):
        guard destFolderID != folderID,
              !wouldCreateFolderCycle(moving: folderID, into: destFolderID, items: items) else { return nil }
        return .movePinnedFolder(folderID: folderID, parentFolderID: destFolderID, beforeItemID: nil)

    case (.pinnedFolder, .beforeNormalTab):
        return nil

    case (.splitGroup(let fromIndex, _, let memberIDs), .beforeNormalTab(let gap)):
        guard gap != fromIndex, gap != fromIndex + 1, let firstTabID = memberIDs.first else { return nil }
        return .reorderNormalTab(tabID: firstTabID, fromIndex: fromIndex, toGapIndex: gap)

    // Pinning a split row keeps the group: both members become adjacent
    // pinned entries sharing it (§12), anchored like a single pinTab.
    case (.splitGroup(_, let groupID, let memberIDs), .beforePinnedItem(let flat)):
        guard let firstTabID = memberIDs.first else { return nil }
        return .pinSplitGroup(groupID: groupID, firstMemberTabID: firstTabID,
                              folderID: folderIDForDropIndex(flat, in: items),
                              beforeItemID: itemIDAtDropIndex(flat, in: items))

    case (.splitGroup(_, let groupID, let memberIDs), .intoFolder(let folderID)):
        guard let firstTabID = memberIDs.first else { return nil }
        return .pinSplitGroup(groupID: groupID, firstMemberTabID: firstTabID,
                              folderID: folderID, beforeItemID: nil)

    case (.splitGroup, .intoSplit):
        return nil

    // Dragging a pane to a reorder gap breaks it out into its own row. Every
    // gap is a real change (the group dissolves) — no adjacent-gap no-ops.
    case (.splitMember(let tabID, _), .beforeNormalTab(let gap)):
        return .removeFromSplit(tabID: tabID, toGapIndex: gap)

    // Leave-one-split-and-join-another is explicitly v2; pinning a lone pane
    // by drag is rejected in validation.
    case (.splitMember, .intoSplit), (.splitMember, .beforePinnedItem), (.splitMember, .intoFolder):
        return nil

    // Reordering a pinned split row moves both entries as a block. Dropping
    // right before itself (the anchor is one of its own members) is a no-op.
    case (.pinnedSplitGroup(let groupID, let memberIDs), .beforePinnedItem(let flat)):
        let beforeItemID = itemIDAtDropIndex(flat, in: items)
        if let beforeItemID, memberIDs.contains(beforeItemID) { return nil }
        guard let firstEntryID = memberIDs.first else { return nil }
        return .movePinnedSplitGroup(groupID: groupID, firstMemberEntryID: firstEntryID,
                                     folderID: folderIDForDropIndex(flat, in: items),
                                     beforeItemID: beforeItemID)

    case (.pinnedSplitGroup(let groupID, let memberIDs), .intoFolder(let folderID)):
        guard let firstEntryID = memberIDs.first else { return nil }
        return .movePinnedSplitGroup(groupID: groupID, firstMemberEntryID: firstEntryID,
                                     folderID: folderID, beforeItemID: nil)

    // Unpinning a pinned split row restores it as a normal split.
    case (.pinnedSplitGroup(let groupID, _), .beforeNormalTab(let gap)):
        return .unpinSplitGroup(groupID: groupID, toGapIndex: gap)

    case (.pinnedSplitGroup, .intoSplit):
        return nil

    // A pinned split member dragged to a tab gap unpins alone (dissolving the
    // pinned split); to a pinned gap it breaks out into its own pinned row.
    case (.pinnedSplitMember(let entryID, _), .beforeNormalTab(let gap)):
        return .unpinSplitMember(entryID: entryID, toGapIndex: gap)

    case (.pinnedSplitMember(let entryID, _), .beforePinnedItem(let flat)):
        // Every pinned gap is a real change (the group dissolves). An anchor
        // naming the dragged member itself (left pane dropped above its own
        // row) retargets to the partner — the member lands above it.
        var beforeItemID = itemIDAtDropIndex(flat, in: items)
        if beforeItemID == entryID {
            beforeItemID = items.first { $0.contains(entryID: entryID) }?
                .entries.first { $0.id != entryID }?.id
        }
        return .removeFromPinnedSplit(entryID: entryID,
                                      folderID: folderIDForDropIndex(flat, in: items),
                                      beforeItemID: beforeItemID)

    case (.pinnedSplitMember, .intoFolder), (.pinnedSplitMember, .intoSplit):
        return nil

    // Only an ungrouped normal tab can become a pane in v1.
    case (.pinnedEntry, .intoSplit), (.pinnedFolder, .intoSplit):
        return nil
    }
}

/// True when reparenting `folderID` under `targetParentID` would create a cycle,
/// judged from the flattened item list (descendants of a collapsed folder are not
/// visible, but they also can't be drop targets). `TabStore.movePinnedFolder`
/// re-checks against the full tree as the authoritative guard.
func wouldCreateFolderCycle(moving folderID: UUID, into targetParentID: UUID?, items: [PinnedItem]) -> Bool {
    guard let targetParentID else { return false }
    if targetParentID == folderID { return true }
    guard let idx = items.firstIndex(where: {
        if case .folder(let f, _) = $0 { return f.id == folderID }
        return false
    }) else { return false }
    let depth = items[idx].depth
    for item in items[(idx + 1)...] {
        if item.depth <= depth { break }
        if case .folder(let f, _) = item, f.id == targetParentID { return true }
    }
    return false
}
