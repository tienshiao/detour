import Foundation

enum PinnedItem: Equatable {
    case tab(BrowserTab, depth: Int)
    case folder(PinnedFolder, depth: Int)

    static func == (lhs: PinnedItem, rhs: PinnedItem) -> Bool {
        switch (lhs, rhs) {
        case (.tab(let a, let d1), .tab(let b, let d2)):
            return a.id == b.id && d1 == d2
        case (.folder(let a, let d1), .folder(let b, let d2)):
            return a.id == b.id && d1 == d2
        default:
            return false
        }
    }

    var depth: Int {
        switch self {
        case .tab(_, let d): return d
        case .folder(_, let d): return d
        }
    }
}

func flattenPinnedTree(
    tabs: [BrowserTab],
    folders: [PinnedFolder],
    collapsedFolderIDs: Set<UUID>,
    selectedTabID: UUID?
) -> [PinnedItem] {
    // Build lookup structures
    let foldersByParent = Dictionary(grouping: folders.sorted(by: { $0.sortOrder < $1.sortOrder })) { $0.parentFolderID }
    let tabsByFolder = Dictionary(grouping: tabs.sorted(by: { ($0.pinnedSortOrder ?? 0) < ($1.pinnedSortOrder ?? 0) })) { $0.folderID }

    var result: [PinnedItem] = []

    func flatten(parentID: UUID?, depth: Int) {
        // Merge folders and top-level tabs at this level, sorted by sortOrder
        var items: [(sortOrder: Int, kind: Either)] = []

        if let childFolders = foldersByParent[parentID] {
            for folder in childFolders {
                items.append((sortOrder: folder.sortOrder, kind: .folder(folder)))
            }
        }
        if let childTabs = tabsByFolder[parentID] {
            for tab in childTabs {
                items.append((sortOrder: tab.pinnedSortOrder ?? 0, kind: .tab(tab)))
            }
        }

        items.sort { $0.sortOrder < $1.sortOrder }

        for item in items {
            switch item.kind {
            case .folder(let folder):
                result.append(.folder(folder, depth: depth))
                let isCollapsed = collapsedFolderIDs.contains(folder.id)
                if isCollapsed {
                    // Show selected tab as exposed row if it's inside this collapsed folder
                    if let selectedTabID, let exposedTab = findSelectedTab(in: folder.id, tabs: tabs, folders: folders, selectedTabID: selectedTabID) {
                        result.append(.tab(exposedTab, depth: depth + 1))
                    }
                } else {
                    flatten(parentID: folder.id, depth: depth + 1)
                }
            case .tab(let tab):
                result.append(.tab(tab, depth: depth))
            }
        }
    }

    flatten(parentID: nil, depth: 0)
    return result
}

/// Recursively searches for the selected tab within a folder hierarchy.
private func findSelectedTab(in folderID: UUID, tabs: [BrowserTab], folders: [PinnedFolder], selectedTabID: UUID) -> BrowserTab? {
    // Check direct children
    if let tab = tabs.first(where: { $0.folderID == folderID && $0.id == selectedTabID }) {
        return tab
    }
    // Check nested folders
    for childFolder in folders where childFolder.parentFolderID == folderID {
        if let tab = findSelectedTab(in: childFolder.id, tabs: tabs, folders: folders, selectedTabID: selectedTabID) {
            return tab
        }
    }
    return nil
}

/// Returns the folderID that a drop at the given flattened index should inherit.
/// When dropping "above" an item that is inside a folder, the dropped item should join that folder.
func folderIDForDropIndex(_ index: Int, in items: [PinnedItem]) -> UUID? {
    guard index < items.count else { return nil }
    switch items[index] {
    case .tab(let tab, let depth):
        return depth > 0 ? tab.folderID : nil
    case .folder(let folder, let depth):
        return depth > 0 ? folder.parentFolderID : nil
    }
}

/// Returns the item ID (tab or folder) at the given flattened drop index.
/// The dropped item should appear before this item. Returns nil if past the end.
func itemIDAtDropIndex(_ index: Int, in items: [PinnedItem]) -> UUID? {
    guard index < items.count else { return nil }
    switch items[index] {
    case .tab(let tab, _): return tab.id
    case .folder(let folder, _): return folder.id
    }
}

func pinnedItemID(_ item: PinnedItem) -> UUID {
    switch item {
    case .tab(let t, _): return t.id
    case .folder(let f, _): return f.id
    }
}

private enum Either {
    case folder(PinnedFolder)
    case tab(BrowserTab)
}
