import Foundation

enum PinnedItem: Equatable {
    case entry(PinnedEntry, depth: Int)
    case folder(PinnedFolder, depth: Int)
    /// A pinned split rendered as one row: two adjacent sibling entries sharing
    /// a `splitGroupID`, in visual order (left pane first).
    case split(groupID: UUID, entries: [PinnedEntry], depth: Int)

    static func == (lhs: PinnedItem, rhs: PinnedItem) -> Bool {
        switch (lhs, rhs) {
        case (.entry(let a, let d1), .entry(let b, let d2)):
            return a.id == b.id && d1 == d2
        case (.folder(let a, let d1), .folder(let b, let d2)):
            return a.id == b.id && d1 == d2
        case (.split(let g1, let e1, let d1), .split(let g2, let e2, let d2)):
            return g1 == g2 && e1.map(\.id) == e2.map(\.id) && d1 == d2
        default:
            return false
        }
    }

    var depth: Int {
        switch self {
        case .entry(_, let d): return d
        case .folder(_, let d): return d
        case .split(_, _, let d): return d
        }
    }

    /// The entries this item renders (empty for folders).
    var entries: [PinnedEntry] {
        switch self {
        case .entry(let e, _): return [e]
        case .folder: return []
        case .split(_, let entries, _): return entries
        }
    }

    func contains(entryID: UUID) -> Bool {
        entries.contains { $0.id == entryID }
    }
}

func flattenPinnedTree(
    entries: [PinnedEntry],
    folders: [PinnedFolder],
    collapsedFolderIDs: Set<UUID>,
    selectedTabID: UUID?
) -> [PinnedItem] {
    var result: [PinnedItem] = []

    func flatten(parentID: UUID?, depth: Int) {
        let siblings = sortedSiblings(of: parentID, entries: entries, folders: folders)

        // Adjacent sibling entries sharing a splitGroupID render as one split
        // row. Defensive: a run of 1 renders as a plain entry (the persistence
        // sanity pass clears such groups, but rendering must never trust it)
        // — same rule as `tabListItems`.
        for run in splitRuns(of: siblings, groupID: siblingSplitGroupID) {
            if let groupID = run.groupID, run.range.count >= 2 {
                result.append(.split(groupID: groupID, entries: runEntries(run, in: siblings), depth: depth))
                continue
            }
            for sibling in siblings[run.range] {
                switch sibling {
                case .folder(let folder):
                    result.append(.folder(folder, depth: depth))
                    if collapsedFolderIDs.contains(folder.id) {
                        // Show selected tab as exposed row(s) if it's inside this collapsed folder
                        if let selectedTabID, let exposedEntry = findSelectedEntry(in: folder.id, entries: entries, folders: folders, selectedTabID: selectedTabID) {
                            result.append(contentsOf: exposedItems(for: exposedEntry, entries: entries, folders: folders, depth: depth + 1))
                        }
                    } else {
                        flatten(parentID: folder.id, depth: depth + 1)
                    }
                case .entry(let entry):
                    result.append(.entry(entry, depth: depth))
                }
            }
        }
    }

    flatten(parentID: nil, depth: 0)
    return result
}

/// The merged entry + folder children of one sibling level, in sort order —
/// the order `flattenPinnedTree` renders them.
private func sortedSiblings(of parentID: UUID?, entries: [PinnedEntry], folders: [PinnedFolder]) -> [Either] {
    var siblings: [(sortOrder: Int, kind: Either)] = []
    for folder in folders where folder.parentFolderID == parentID {
        siblings.append((sortOrder: folder.sortOrder, kind: .folder(folder)))
    }
    for entry in entries where entry.folderID == parentID {
        siblings.append((sortOrder: entry.sortOrder, kind: .entry(entry)))
    }
    siblings.sort { $0.sortOrder < $1.sortOrder }
    return siblings.map(\.kind)
}

/// Run key for the shared scan: only entries carry a group, so a folder
/// sorted between two members breaks their run.
private func siblingSplitGroupID(_ sibling: Either) -> UUID? {
    if case .entry(let entry) = sibling { return entry.splitGroupID }
    return nil
}

/// The entries of a grouped run (grouped runs contain only entries by
/// construction — folders never match a group ID).
private func runEntries(_ run: SplitRun, in siblings: [Either]) -> [PinnedEntry] {
    siblings[run.range].compactMap { sibling in
        if case .entry(let entry) = sibling { return entry }
        return nil
    }
}

/// The row(s) exposed for the selected entry inside a collapsed folder. A
/// pinned-split member exposes its WHOLE group as the `.split` item the
/// expanded path would produce: a lone `.entry` row would render and drag as
/// a single tab while `movePinnedTabToFolder` block-moves both members —
/// silently pulling the hidden partner out of the folder. Falls back to the
/// plain entry when the group isn't a real run at the entry's sibling level.
private func exposedItems(
    for exposedEntry: PinnedEntry,
    entries: [PinnedEntry],
    folders: [PinnedFolder],
    depth: Int
) -> [PinnedItem] {
    guard let groupID = exposedEntry.splitGroupID else {
        return [.entry(exposedEntry, depth: depth)]
    }
    let siblings = sortedSiblings(of: exposedEntry.folderID, entries: entries, folders: folders)
    let runs = splitRuns(of: siblings, groupID: siblingSplitGroupID)
    guard let run = runs.first(where: { candidate in
        candidate.groupID == groupID && runEntries(candidate, in: siblings).contains { $0.id == exposedEntry.id }
    }), run.range.count >= 2 else {
        return [.entry(exposedEntry, depth: depth)]
    }
    return [.split(groupID: groupID, entries: runEntries(run, in: siblings), depth: depth)]
}

/// Recursively searches for the selected tab within a folder hierarchy.
private func findSelectedEntry(in folderID: UUID, entries: [PinnedEntry], folders: [PinnedFolder], selectedTabID: UUID) -> PinnedEntry? {
    // Check direct children
    if let entry = entries.first(where: { $0.folderID == folderID && $0.tab?.id == selectedTabID }) {
        return entry
    }
    // Check nested folders
    for childFolder in folders where childFolder.parentFolderID == folderID {
        if let entry = findSelectedEntry(in: childFolder.id, entries: entries, folders: folders, selectedTabID: selectedTabID) {
            return entry
        }
    }
    return nil
}

/// Returns the folderID that a drop at the given flattened index should inherit.
/// When dropping "above" an item that is inside a folder, the dropped item should join that folder.
func folderIDForDropIndex(_ index: Int, in items: [PinnedItem]) -> UUID? {
    guard index < items.count else { return nil }
    switch items[index] {
    case .entry(let entry, let depth):
        return depth > 0 ? entry.folderID : nil
    case .folder(let folder, let depth):
        return depth > 0 ? folder.parentFolderID : nil
    case .split(_, let entries, let depth):
        return depth > 0 ? entries.first?.folderID : nil
    }
}

/// Returns the item ID (entry or folder) at the given flattened drop index.
/// The dropped item should appear before this item. Returns nil if past the end.
/// For a split this is the FIRST member's entry ID: drop anchors must name a
/// real sibling entry, and anchoring before the left member keeps anything
/// from landing inside the group.
func itemIDAtDropIndex(_ index: Int, in items: [PinnedItem]) -> UUID? {
    guard index < items.count else { return nil }
    switch items[index] {
    case .entry(let entry, _): return entry.id
    case .folder(let folder, _): return folder.id
    case .split(_, let entries, _): return entries.first?.id
    }
}

/// Stable identity for diffing: the groupID for a split (matches the tab
/// section's split item ID, so pin/unpin diffs as one row moving sections).
func pinnedItemID(_ item: PinnedItem) -> UUID {
    switch item {
    case .entry(let e, _): return e.id
    case .folder(let f, _): return f.id
    case .split(let groupID, _, _): return groupID
    }
}

/// Load-time defense: clears `splitGroupID`/`splitFraction` from pinned entries
/// whose group is not exactly two same-folder entries adjacent in sibling sort
/// order (nothing — entry or folder — sorting between them). Mutates in place.
func sanitizePinnedSplitGroups(entries: [PinnedEntry], folders: [PinnedFolder]) {
    // Same run scan as rendering, applied per sibling level: a run never
    // crosses a folder boundary, and a folder sorted between two members
    // breaks their run.
    var runs: [SplitRun] = []
    for parentID in Set(entries.map(\.folderID)) {
        runs += splitRuns(of: sortedSiblings(of: parentID, entries: entries, folders: folders),
                          groupID: siblingSplitGroupID)
    }
    let valid = validSplitGroupIDs(in: runs)

    for entry in entries {
        guard let groupID = entry.splitGroupID, !valid.contains(groupID) else { continue }
        entry.splitGroupID = nil
        entry.splitFraction = nil
    }
}

private enum Either {
    case folder(PinnedFolder)
    case entry(PinnedEntry)
}
