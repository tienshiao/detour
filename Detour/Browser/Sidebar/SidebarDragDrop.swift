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

    init(_ kind: SidebarDragPayload.Kind) {
        switch kind {
        case .normalTab: self = .normalTab
        case .pinnedEntry: self = .pinnedEntry
        case .pinnedFolder: self = .pinnedFolder
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
}

/// A drop position normalized so that spacer/separator/new-tab rows map to the
/// nearest real insertion point.
enum SidebarDropDestination: Equatable {
    case intoFolder(folderID: UUID)
    /// Insert before the flattened pinned item at `flatIndex` (== items.count → end of pinned section).
    case beforePinnedItem(flatIndex: Int)
    /// Insert before the normal tab at `gapIndex` (== tab count → end of tab list).
    case beforeNormalTab(gapIndex: Int)
}

enum SidebarDropValidation: Equatable {
    case reject
    case accept
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
}

// MARK: - Drop Resolution

/// Validation for `tableView(_:validateDrop:...)`: decides whether a drag of `kind`
/// may drop at (`row`, `operation`) and whether the indicator should be retargeted.
func validateSidebarDrop(
    kind: SidebarDragKind,
    sourceItemID: UUID?,
    row: SidebarRow,
    operation: SidebarDropOperation,
    items: [PinnedItem]
) -> SidebarDropValidation {
    switch operation {
    case .on:
        // Only folder rows accept .on drops (placing the item inside the folder)
        guard case .pinnedItem(let idx) = row, idx < items.count,
              case .folder(let folder, _) = items[idx] else { return .reject }
        if kind == .pinnedFolder, sourceItemID == folder.id { return .reject }
        return .accept

    case .above:
        switch row {
        case .topSpacer:
            return .retargetToPinnedGap(index: 0)
        case .separator:
            return .retargetToPinnedGap(index: items.count)
        case .newTab:
            return kind == .pinnedFolder ? .reject : .retargetToNormalTabGap(index: 0)
        case .normalTab:
            return kind == .pinnedFolder ? .reject : .accept
        case .pinnedItem:
            return .accept
        }
    }
}

/// Normalizes a proposed drop row into a concrete insertion point.
func sidebarDropDestination(
    row: SidebarRow,
    operation: SidebarDropOperation,
    items: [PinnedItem]
) -> SidebarDropDestination? {
    switch operation {
    case .on:
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
