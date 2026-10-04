import Foundation

/// A change `SessionSnapshot.repairingInvalidRows()` made to a row that the
/// database would have refused (TASK-154).
enum SessionSnapshotRepair: Equatable, CustomStringConvertible {
    /// A pinned folder whose parent is not one of its space's folders.
    case folderWithMissingParent(folderID: String, spaceID: String, parentFolderID: String)
    /// A pinned folder on a parent cycle (its own parent included).
    case folderInParentCycle(folderID: String, spaceID: String, parentFolderID: String)
    /// A pinned entry whose folder is not one of its space's folders.
    case entryWithMissingFolder(entryID: String, spaceID: String, folderID: String)

    var description: String {
        switch self {
        case let .folderWithMissingParent(folderID, spaceID, parentFolderID):
            return "pinned folder \(folderID) of space \(spaceID) moved to the root: its parent \(parentFolderID) does not exist"
        case let .folderInParentCycle(folderID, spaceID, parentFolderID):
            return "pinned folder \(folderID) of space \(spaceID) moved to the root: its parent \(parentFolderID) is inside it"
        case let .entryWithMissingFolder(entryID, spaceID, folderID):
            return "pinned entry \(entryID) of space \(spaceID) moved to the root: its folder \(folderID) does not exist"
        }
    }
}

extension AppDatabase.SessionSnapshot {
    /// The snapshot with the rows that could never be saved made valid, and
    /// what was changed. Pure: it reads nothing but the snapshot.
    ///
    /// `pinnedFolder.parentFolderID` and `pinnedTab.folderID` are foreign keys
    /// onto `pinnedFolder`, so a folder whose parent is missing, the folders of
    /// a parent cycle and an entry whose folder is missing are refused by the
    /// insert. The save is one transaction, so one such row would fail every
    /// save for as long as the store holds it. Each is moved to the root of its
    /// space instead, after what is already there:
    ///
    /// - a folder whose parent is not among its space's folders (a parent in
    ///   another space counts as missing: it would be saved, and then never
    ///   shown, because a space's tree is built from its own folders);
    /// - of each parent cycle, the folder that comes first in the store's
    ///   order — moving one folder opens the cycle, and the others keep their
    ///   parent;
    /// - an entry whose folder is not among its space's folders.
    ///
    /// Only the saved rows change. The store keeps what it holds, and loads the
    /// repaired tree at the next launch.
    func repairingInvalidRows() -> (snapshot: AppDatabase.SessionSnapshot, repairs: [SessionSnapshotRepair]) {
        var repairs: [SessionSnapshotRepair] = []
        var repaired = self
        repaired.pinnedItems = pinnedItems.map { Self.repairing($0, repairs: &repairs) }
        return (repaired, repairs)
    }

    private static func repairing(_ pinned: PinnedItems, repairs: inout [SessionSnapshotRepair]) -> PinnedItems {
        var folders = pinned.folders
        var tabs = pinned.tabs
        let folderIDs = Set(folders.map(\.id))
        // Folders and entries of one level share one run of sort orders, and a
        // new item takes the highest order of the space plus one
        // (`TabStore.addPinnedFolder`).
        var nextRootOrder = ((folders.map(\.sortOrder) + tabs.map(\.sortOrder)).max() ?? -1) + 1
        func takeRootOrder() -> Int {
            defer { nextRootOrder += 1 }
            return nextRootOrder
        }

        for index in folders.indices {
            guard let parentID = folders[index].parentFolderID, !folderIDs.contains(parentID) else { continue }
            repairs.append(.folderWithMissingParent(folderID: folders[index].id, spaceID: pinned.spaceID,
                                                    parentFolderID: parentID))
            folders[index].parentFolderID = nil
            folders[index].sortOrder = takeRootOrder()
        }

        // Every remaining parent exists. A folder is on a cycle when walking up
        // from it comes back to it; one that only hangs below a cycle reaches a
        // folder it has already passed instead, and is left alone. Each folder
        // has one parent, so cycles share no folder, and taking them in the
        // store's order moves the first folder of each.
        var parentOf: [String: String] = [:]
        for folder in folders {
            if let parentID = folder.parentFolderID, parentOf[folder.id] == nil { parentOf[folder.id] = parentID }
        }
        for index in folders.indices {
            let id = folders[index].id
            var seen: Set<String> = [id]
            var current = parentOf[id]
            while let ancestor = current, ancestor != id, seen.insert(ancestor).inserted {
                current = parentOf[ancestor]
            }
            guard current == id, let parentID = folders[index].parentFolderID else { continue }
            repairs.append(.folderInParentCycle(folderID: id, spaceID: pinned.spaceID, parentFolderID: parentID))
            parentOf[id] = nil
            folders[index].parentFolderID = nil
            folders[index].sortOrder = takeRootOrder()
        }

        for index in tabs.indices {
            guard let folderID = tabs[index].folderID, !folderIDs.contains(folderID) else { continue }
            repairs.append(.entryWithMissingFolder(entryID: tabs[index].id, spaceID: pinned.spaceID, folderID: folderID))
            tabs[index].folderID = nil
            tabs[index].sortOrder = takeRootOrder()
        }

        return PinnedItems(spaceID: pinned.spaceID, folders: folders, tabs: tabs)
    }
}
