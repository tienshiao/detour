import Foundation

// Turns an `ArcImportSnapshot` and the user's choices into the exact list of
// things to add to Detour (TASK-293.2). Pure: it sees Detour only through
// `ArcImportExistingState`, so every rule here is unit-tested without a
// TabStore. `TabStore.applyArcImport` then carries the plan out.
//
// Rules (user decisions, 2026-11-12):
// - Each Arc profile goes to a NEW Detour profile named after it unless the
//   user picks an existing one, or it was imported before and that profile
//   still exists (`links`), in which case it goes back there.
// - Dedupe is by content only: a re-import adds whatever Detour does not
//   have, including things the user deleted since. The only memory kept is
//   where each Arc profile and space went (`links`), so a renamed space is
//   reused rather than duplicated.
// - Today tabs come over as sleeping normal tabs when chosen.
// - Detour splits have two panes: an Arc split's first two tabs become a
//   split and any further panes plain entries or tabs after it.

/// What the user chose in the import window.
nonisolated struct ArcImportOptions: Sendable, Equatable {
    nonisolated enum ProfileTarget: Sendable, Equatable {
        case newProfile
        case existing(UUID)
    }

    /// The Arc profiles to import: their favourites, history and spaces.
    var profiles: Set<ArcProfile.ID>
    /// Where each chosen Arc profile goes. A profile with no entry goes back
    /// to the Detour profile it went to before, else to a new one.
    var profileTargets: [ArcProfile.ID: ProfileTarget] = [:]
    /// The spaces to import, by `ArcSpace.sourceKey`; a space whose profile
    /// is not chosen is not imported either.
    var spaces: Set<String>
    var includePinned = true
    var includeFavorites = true
    var includeTodayTabs = true
    var includeHistory = true

    /// Everything in the snapshot.
    static func everything(in snapshot: ArcImportSnapshot) -> ArcImportOptions {
        ArcImportOptions(profiles: Set(snapshot.profiles.map(\.id)),
                         spaces: Set(snapshot.spaces.map(\.sourceKey)))
    }
}

/// The parts of Detour the planner needs to see.
nonisolated struct ArcImportExistingState: Sendable, Equatable {
    nonisolated struct Profile: Sendable, Equatable {
        var id: UUID
        var name: String
        var favoriteURLs: [String]
    }

    nonisolated struct Folder: Sendable, Equatable {
        var id: UUID
        var name: String
        var parentID: UUID?
        var sortOrder: Int
    }

    nonisolated struct Entry: Sendable, Equatable {
        var url: String
        var folderID: UUID?
        var sortOrder: Int
    }

    nonisolated struct Space: Sendable, Equatable {
        var id: UUID
        var name: String
        var profileID: UUID
        var folders: [Folder]
        var entries: [Entry]
        var tabURLs: [String]
    }

    /// Normal profiles only (never the Private profile).
    var profiles: [Profile]
    /// Normal spaces only.
    var spaces: [Space]
    /// Where earlier imports put each Arc profile and space: source key →
    /// Detour profile or space id. Stale ids are ignored.
    var links: [String: UUID]
}

/// What an import will add. Every id is new except where it names an
/// existing profile, space or folder.
nonisolated struct ArcImportPlan: Sendable, Equatable {
    nonisolated struct NewProfile: Sendable, Equatable {
        var id: UUID
        var name: String
    }

    nonisolated struct NewSpace: Sendable, Equatable {
        var id: UUID
        var name: String
        var emoji: String
        var colorHex: String
        var profileID: UUID
    }

    nonisolated struct NewFolder: Sendable, Equatable {
        var id: UUID
        var spaceID: UUID
        var name: String
        var parentID: UUID?
        var sortOrder: Int
    }

    nonisolated struct NewPinnedEntry: Sendable, Equatable {
        var id: UUID
        var spaceID: UUID
        var url: URL
        var title: String
        var folderID: UUID?
        var sortOrder: Int
        var splitGroupID: UUID?
        var splitFraction: Double?
    }

    nonisolated struct NewFavorite: Sendable, Equatable {
        var id: UUID
        var profileID: UUID
        var url: URL
        var title: String
    }

    /// A sleeping normal tab, appended to its space's tab list in plan order.
    nonisolated struct NewTab: Sendable, Equatable {
        var id: UUID
        var spaceID: UUID
        var url: URL
        var title: String
        var splitGroupID: UUID?
        var splitFraction: Double?
    }

    /// One Arc profile's history and the space its visits are filed under.
    nonisolated struct HistoryImport: Sendable, Equatable {
        var arcProfile: ArcProfile.ID
        var historyFile: URL
        var spaceID: UUID
    }

    nonisolated struct Link: Sendable, Equatable {
        nonisolated enum Kind: String, Sendable {
            case profile, space
        }
        var sourceKey: String
        var kind: Kind
        var detourID: UUID
    }

    var profiles: [NewProfile] = []
    var spaces: [NewSpace] = []
    var folders: [NewFolder] = []
    var pinnedEntries: [NewPinnedEntry] = []
    var favorites: [NewFavorite] = []
    var tabs: [NewTab] = []
    var history: [HistoryImport] = []
    /// Arc profiles whose history has nowhere to go: no space of theirs is
    /// imported and their Detour profile has none.
    var historyWithoutSpace: [ArcProfile.ID] = []
    /// Where each imported Arc profile and space went, to record for the next import.
    var links: [Link] = []
    /// Existing spaces that receive something (for the window's summary).
    var reusedSpaceIDs: [UUID] = []
    /// Tabs and favourites left out because Detour already has them there.
    var alreadyPresent = 0

    var isEmpty: Bool {
        profiles.isEmpty && spaces.isEmpty && folders.isEmpty && pinnedEntries.isEmpty
            && favorites.isEmpty && tabs.isEmpty && history.isEmpty
    }
}

nonisolated enum ArcImportPlanner {
    /// The emoji a space gets when Arc shows a symbol instead of an emoji.
    static let defaultEmoji = "⭐️"

    static func plan(_ snapshot: ArcImportSnapshot, options: ArcImportOptions,
                     existing: ArcImportExistingState,
                     presetColors: [String] = Space.presetColors,
                     makeID: @escaping () -> UUID = UUID.init) -> ArcImportPlan {
        var builder = Builder(existing: existing, makeID: makeID)

        let chosenProfiles = snapshot.profiles.filter { options.profiles.contains($0.id) }
        let chosenSpaces = snapshot.spaces.filter {
            options.spaces.contains($0.sourceKey) && options.profiles.contains($0.profileID)
        }

        // A new profile is only made for an Arc profile that brings something
        // a profile can hold: a space or a favourite. History alone needs a
        // space to be filed under.
        for profile in chosenProfiles {
            let bringsSpace = chosenSpaces.contains { $0.profileID == profile.id }
            let bringsFavorites = options.includeFavorites && !profile.favorites.isEmpty
            let target = options.profileTargets[profile.id]
            if case .existing(let id) = target, builder.profileExists(id) {
                builder.assign(profile, to: id)
            } else if target != .newProfile, let linked = existing.links[profile.sourceKey],
                      builder.profileExists(linked) {
                builder.assign(profile, to: linked)
            } else if bringsSpace || bringsFavorites {
                builder.createProfile(for: profile)
            }
        }

        for (index, space) in chosenSpaces.enumerated() {
            guard let profileID = builder.profileIDs[space.profileID] else { continue }
            let spaceID = builder.space(for: space, profileID: profileID,
                                        fallbackColor: presetColors.isEmpty
                                            ? "007AFF" : presetColors[index % presetColors.count])
            if options.includePinned {
                builder.addPinned(space.pinned, to: spaceID, parent: nil)
            }
            if options.includeTodayTabs {
                builder.addTabs(space.unpinned.flatMap(\.flattenedForTabList), to: spaceID)
            }
        }

        if options.includeFavorites {
            for profile in chosenProfiles {
                guard let profileID = builder.profileIDs[profile.id] else { continue }
                for tab in profile.favorites {
                    builder.addFavorite(tab, to: profileID)
                }
            }
        }

        if options.includeHistory {
            for profile in chosenProfiles {
                guard let file = profile.historyFile else { continue }
                if let profileID = builder.profileIDs[profile.id],
                   let spaceID = builder.firstSpace(ofArcProfile: profile.id, chosenSpaces: chosenSpaces)
                    ?? builder.firstSpace(ofDetourProfile: profileID) {
                    builder.plan.history.append(.init(arcProfile: profile.id, historyFile: file, spaceID: spaceID))
                } else {
                    builder.plan.historyWithoutSpace.append(profile.id)
                }
            }
        }

        return builder.plan
    }

    /// Picks a profile name no existing or planned profile uses: the Arc
    /// name, else "<name> (Arc)", else "<name> (Arc 2)", …
    static func uniqueProfileName(_ name: String, taken: [String]) -> String {
        let takenSet = Set(taken.map { $0.lowercased() })
        if !takenSet.contains(name.lowercased()) { return name }
        var candidate = "\(name) (Arc)"
        var number = 2
        while takenSet.contains(candidate.lowercased()) {
            candidate = "\(name) (Arc \(number))"
            number += 1
        }
        return candidate
    }

    // MARK: - Builder

    private struct Builder {
        var plan = ArcImportPlan()
        let existing: ArcImportExistingState
        let makeID: () -> UUID

        /// Arc profile → the Detour profile it goes to.
        var profileIDs: [ArcProfile.ID: UUID] = [:]
        /// Arc space source key → the Detour space it goes to.
        var spaceIDs: [String: UUID] = [:]
        /// Per Detour space: folders by (parent, name), sibling orders,
        /// entry URLs per folder, and normal-tab URLs, existing and planned.
        var folderIndex: [UUID: [FolderKey: UUID]] = [:]
        var nextOrder: [UUID: [UUID?: Int]] = [:]
        var entryURLs: [UUID: [UUID?: Set<String>]] = [:]
        var tabURLs: [UUID: Set<String>] = [:]
        var favoriteURLs: [UUID: Set<String>] = [:]
        var loadedSpaces: Set<UUID> = []
        /// Per existing space, the URLs pinned in it before this import.
        var preexistingPinnedURLs: [UUID: Set<String>] = [:]

        struct FolderKey: Hashable {
            var parentID: UUID?
            var name: String
        }

        init(existing: ArcImportExistingState, makeID: @escaping () -> UUID) {
            self.existing = existing
            self.makeID = makeID
            for profile in existing.profiles {
                favoriteURLs[profile.id] = Set(profile.favoriteURLs)
            }
        }

        func profileExists(_ id: UUID) -> Bool {
            existing.profiles.contains { $0.id == id } || plan.profiles.contains { $0.id == id }
        }

        mutating func assign(_ profile: ArcProfile, to id: UUID) {
            profileIDs[profile.id] = id
            plan.links.append(.init(sourceKey: profile.sourceKey, kind: .profile, detourID: id))
        }

        mutating func createProfile(for profile: ArcProfile) {
            let taken = existing.profiles.map(\.name) + plan.profiles.map(\.name)
            let id = makeID()
            plan.profiles.append(.init(id: id, name: ArcImportPlanner.uniqueProfileName(profile.name, taken: taken)))
            favoriteURLs[id] = []
            assign(profile, to: id)
        }

        /// The Detour space an Arc space goes to: the one it went to before,
        /// else a space of the same name in the target profile, else a new one.
        /// Either must be in the target profile: a profile the user points
        /// elsewhere this time (or asks to be new) takes its spaces with it.
        mutating func space(for space: ArcSpace, profileID: UUID, fallbackColor: String) -> UUID {
            if let id = spaceIDs[space.sourceKey] { return id }
            let reused = existing.links[space.sourceKey].flatMap { linked in
                existing.spaces.first { $0.id == linked && $0.profileID == profileID }
            } ?? existing.spaces.first {
                $0.profileID == profileID
                    && $0.name.compare(space.title, options: [.caseInsensitive]) == .orderedSame
            }
            let id: UUID
            if let reused {
                id = reused.id
                load(reused)
                if !plan.reusedSpaceIDs.contains(id) { plan.reusedSpaceIDs.append(id) }
            } else {
                id = makeID()
                plan.spaces.append(.init(id: id, name: space.title, emoji: space.emoji ?? ArcImportPlanner.defaultEmoji,
                                         colorHex: space.colorHex ?? fallbackColor, profileID: profileID))
                loadedSpaces.insert(id)
            }
            spaceIDs[space.sourceKey] = id
            plan.links.append(.init(sourceKey: space.sourceKey, kind: .space, detourID: id))
            return id
        }

        private mutating func load(_ space: ArcImportExistingState.Space) {
            guard loadedSpaces.insert(space.id).inserted else { return }
            preexistingPinnedURLs[space.id] = Set(space.entries.map(\.url))
            var folders: [FolderKey: UUID] = [:]
            var orders: [UUID?: Int] = [:]
            var urls: [UUID?: Set<String>] = [:]
            for folder in space.folders {
                let key = FolderKey(parentID: folder.parentID, name: folder.name)
                if folders[key] == nil { folders[key] = folder.id }
                orders[folder.parentID] = max(orders[folder.parentID] ?? 0, folder.sortOrder + 1)
            }
            for entry in space.entries {
                orders[entry.folderID] = max(orders[entry.folderID] ?? 0, entry.sortOrder + 1)
                urls[entry.folderID, default: []].insert(entry.url)
            }
            folderIndex[space.id] = folders
            nextOrder[space.id] = orders
            entryURLs[space.id] = urls
            tabURLs[space.id] = Set(space.tabURLs)
        }

        private mutating func takeOrder(in spaceID: UUID, parent: UUID?) -> Int {
            let order = nextOrder[spaceID, default: [:]][parent] ?? 0
            nextOrder[spaceID, default: [:]][parent] = order + 1
            return order
        }

        mutating func addPinned(_ nodes: [ArcSidebarNode], to spaceID: UUID, parent: UUID?) {
            for node in nodes {
                switch node {
                case .tab(let tab):
                    addEntry(tab, to: spaceID, folder: parent)
                case .folder(let folder):
                    let key = FolderKey(parentID: parent, name: folder.title)
                    let folderID: UUID
                    if let found = folderIndex[spaceID]?[key] {
                        folderID = found
                    } else {
                        folderID = makeID()
                        plan.folders.append(.init(id: folderID, spaceID: spaceID, name: folder.title, parentID: parent,
                                                  sortOrder: takeOrder(in: spaceID, parent: parent)))
                        folderIndex[spaceID, default: [:]][key] = folderID
                    }
                    addPinned(folder.children, to: spaceID, parent: folderID)
                case .split(let split):
                    let pair = Array(split.tabs.prefix(2))
                    if pair.count == 2, pair[0].url != pair[1].url,
                       !pair.contains(where: { hasEntry($0.url, in: spaceID, folder: parent) }) {
                        // Both of the first two panes are new: they become a split.
                        let groupID = makeID()
                        let fraction = split.tabs.count == 2 ? split.leadingFraction : nil
                        for tab in pair {
                            addEntry(tab, to: spaceID, folder: parent, splitGroupID: groupID, splitFraction: fraction)
                        }
                        for tab in split.tabs.dropFirst(2) { addEntry(tab, to: spaceID, folder: parent) }
                    } else {
                        for tab in split.tabs { addEntry(tab, to: spaceID, folder: parent) }
                    }
                }
            }
        }

        private func hasEntry(_ url: URL, in spaceID: UUID, folder: UUID?) -> Bool {
            entryURLs[spaceID]?[folder]?.contains(url.absoluteString) == true
        }

        private mutating func addEntry(_ tab: ArcTab, to spaceID: UUID, folder: UUID?,
                                       splitGroupID: UUID? = nil, splitFraction: Double? = nil) {
            guard !hasEntry(tab.url, in: spaceID, folder: folder) else {
                plan.alreadyPresent += 1
                return
            }
            entryURLs[spaceID, default: [:]][folder, default: []].insert(tab.url.absoluteString)
            plan.pinnedEntries.append(.init(id: makeID(), spaceID: spaceID, url: tab.url, title: tab.title,
                                            folderID: folder, sortOrder: takeOrder(in: spaceID, parent: folder),
                                            splitGroupID: splitGroupID, splitFraction: splitFraction))
        }

        /// Today tabs: each item is one tab, or the first two panes of a split.
        mutating func addTabs(_ items: [ArcTabListItem], to spaceID: UUID) {
            // A URL pinned anywhere in the space is not brought in again as a
            // Today tab: an export lists top-level pinned tabs among them, so
            // an export imported after a direct import would duplicate them.
            let pinned = entryURLs[spaceID]?.values.reduce(into: Set<String>()) { $0.formUnion($1) } ?? []
            for item in items {
                var fresh: [ArcTab] = []
                for tab in item.tabs {
                    let url = tab.url.absoluteString
                    if pinned.contains(url) {
                        // Counted as "already in Detour" only when it was
                        // pinned there before this import.
                        if preexistingPinnedURLs[spaceID]?.contains(url) == true { plan.alreadyPresent += 1 }
                    } else if tabURLs[spaceID, default: []].insert(url).inserted {
                        fresh.append(tab)
                    } else {
                        plan.alreadyPresent += 1
                    }
                }
                // A split only when both panes are new; otherwise what is new
                // comes over as plain tabs.
                let isSplit = item.tabs.count == 2 && fresh.count == 2
                let groupID: UUID? = isSplit ? makeID() : nil
                for tab in fresh {
                    plan.tabs.append(.init(id: makeID(), spaceID: spaceID, url: tab.url, title: tab.title,
                                           splitGroupID: groupID, splitFraction: isSplit ? item.splitFraction : nil))
                }
            }
        }

        mutating func addFavorite(_ tab: ArcTab, to profileID: UUID) {
            guard favoriteURLs[profileID, default: []].insert(tab.url.absoluteString).inserted else {
                plan.alreadyPresent += 1
                return
            }
            plan.favorites.append(.init(id: makeID(), profileID: profileID, url: tab.url, title: tab.title))
        }

        func firstSpace(ofArcProfile id: ArcProfile.ID, chosenSpaces: [ArcSpace]) -> UUID? {
            chosenSpaces.lazy.filter { $0.profileID == id }.compactMap { spaceIDs[$0.sourceKey] }.first
        }

        func firstSpace(ofDetourProfile id: UUID) -> UUID? {
            existing.spaces.first { $0.profileID == id }?.id ?? plan.spaces.first { $0.profileID == id }?.id
        }
    }
}

/// One item of a space's tab list: a tab, or the two panes of a split with
/// the first pane's width share.
nonisolated struct ArcTabListItem: Sendable, Equatable {
    var tabs: [ArcTab]
    var splitFraction: Double? = nil
}

extension ArcSidebarNode {
    /// A Today-tab node as the tab list holds it: a split's first two panes
    /// stay together as one split item (with Arc's width share when the split
    /// had exactly two), its other panes and a folder's tabs (Arc has no
    /// folders among Today tabs, but an export could) become items of their own.
    nonisolated var flattenedForTabList: [ArcTabListItem] {
        switch self {
        case .tab(let tab):
            [ArcTabListItem(tabs: [tab])]
        case .split(let split):
            [ArcTabListItem(tabs: Array(split.tabs.prefix(2)),
                            splitFraction: split.tabs.count == 2 ? split.leadingFraction : nil)]
                + split.tabs.dropFirst(2).map { ArcTabListItem(tabs: [$0]) }
        case .folder(let folder):
            folder.children.flatMap(\.flattenedForTabList)
        }
    }
}
