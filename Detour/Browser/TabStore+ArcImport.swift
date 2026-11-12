import AppKit

/// Carrying out an Arc import plan (TASK-293.2). The plan is computed by the
/// pure `ArcImportPlanner` from `arcImportExistingState()`; this file only
/// turns it into Detour objects, saves, and imports history.
extension TabStore {
    /// The `importLink.source` of Arc imports.
    nonisolated static let arcImportSource = "arc"

    /// Why `applyArcImport` refused a plan. Nothing was changed.
    enum ArcImportApplyError: Error, Equatable {
        /// The plan names a profile, space or folder that is no longer there
        /// (the store changed after the plan was made).
        case staleTarget
    }

    /// What one Arc profile's history import did.
    nonisolated struct ArcHistoryImportResult: Sendable, Equatable {
        var arcProfile: ArcProfile.ID
        /// Visits added, or nil when the history could not be read or written.
        var added: Int?
        var failure: String?
    }

    /// What the planner needs to see of this store.
    func arcImportExistingState() -> ArcImportExistingState {
        ArcImportExistingState(
            profiles: profiles.filter { !$0.isIncognito }.map { profile in
                .init(id: profile.id, name: profile.name, favoriteURLs: profile.favorites.map(\.url.absoluteString))
            },
            spaces: nonIncognitoSpaces.map { space in
                .init(id: space.id, name: space.name, profileID: space.profileID,
                      folders: space.pinnedFolders.map {
                          .init(id: $0.id, name: $0.name, parentID: $0.parentFolderID, sortOrder: $0.sortOrder)
                      },
                      entries: space.pinnedEntries.map {
                          .init(url: $0.pinnedURL.absoluteString, folderID: $0.folderID, sortOrder: $0.sortOrder)
                      },
                      tabURLs: space.tabs.compactMap { $0.url?.absoluteString })
            },
            links: appDB.loadImportLinks(source: Self.arcImportSource))
    }

    /// Adds everything in `plan` to the store in one pass and saves the
    /// session once. The plan is checked against the store first, so a plan
    /// that no longer fits changes nothing. Imported pinned entries and
    /// favourites are dormant and imported tabs asleep: no web view is made
    /// until the user opens one. An imported tab's archive clock starts now.
    /// There is no undo (user, 2026-11-12).
    @discardableResult
    func applyArcImport(_ plan: ArcImportPlan, now: Date = Date()) throws(ArcImportApplyError) -> SessionSaveOutcome {
        try validate(plan)

        for newProfile in plan.profiles {
            adoptImportedProfile(Profile(id: newProfile.id, name: newProfile.name))
        }
        for newSpace in plan.spaces {
            adoptImportedSpace(Space(id: newSpace.id, name: newSpace.name, emoji: newSpace.emoji,
                                     colorHex: newSpace.colorHex, profileID: newSpace.profileID))
        }

        var touchedSpaceIDs: [UUID] = []
        func touch(_ id: UUID) {
            if !touchedSpaceIDs.contains(id) { touchedSpaceIDs.append(id) }
        }

        for folder in plan.folders {
            space(withID: folder.spaceID)?.pinnedFolders.append(
                PinnedFolder(id: folder.id, name: folder.name, parentFolderID: folder.parentID,
                             sortOrder: folder.sortOrder))
            touch(folder.spaceID)
        }

        // Each list is assigned once per space: `pinnedEntries` and `tabs`
        // report their contents to the extension contexts on every set.
        for (spaceID, entries) in grouped(plan.pinnedEntries, by: \.spaceID) {
            guard let space = space(withID: spaceID) else { continue }
            space.pinnedEntries += entries.map { planned in
                let entry = PinnedEntry(id: planned.id, pinnedURL: planned.url, pinnedTitle: planned.title,
                                        faviconURL: faviconFallbackURL(for: planned.url),
                                        folderID: planned.folderID, sortOrder: planned.sortOrder)
                entry.splitGroupID = planned.splitGroupID
                entry.splitFraction = planned.splitFraction
                return entry
            }
            touch(spaceID)
        }

        for (spaceID, planned) in grouped(plan.tabs, by: \.spaceID) {
            guard let space = space(withID: spaceID) else { continue }
            let tabs = planned.map { planned in
                let tab = BrowserTab(id: planned.id, title: planned.title, url: planned.url,
                                     faviconURL: faviconFallbackURL(for: planned.url),
                                     cachedInteractionState: nil, spaceID: spaceID)
                tab.lastDeselectedAt = now
                tab.splitGroupID = planned.splitGroupID
                tab.splitFraction = planned.splitFraction
                return tab
            }
            space.tabs += tabs
            tabs.forEach { subscribeToTab($0) }
            touch(spaceID)
        }

        var favoriteProfiles: [Profile] = []
        for (profileID, planned) in grouped(plan.favorites, by: \.profileID) {
            guard let profile = profile(withID: profileID) else { continue }
            let start = (profile.favorites.map(\.sortOrder).max() ?? -1) + 1
            profile.favorites += planned.enumerated().map { offset, favorite in
                Favorite(id: favorite.id, url: favorite.url, title: favorite.title,
                         faviconURL: faviconFallbackURL(for: favorite.url), sortOrder: start + offset)
            }
            favoriteProfiles.append(profile)
        }

        if !plan.spaces.isEmpty { notifyObservers { $0.tabStoreDidUpdateSpaces() } }
        for space in touchedSpaceIDs.compactMap({ space(withID: $0) }) {
            notifyObservers { $0.tabStoreDidUpdatePinnedFolders(in: space) }
            notifyObservers { $0.tabStoreDidReorderTabs(in: space) }
        }
        for profile in favoriteProfiles {
            notifyObservers { $0.tabStoreDidUpdateFavorites(for: profile) }
        }

        let outcome = saveNow()
        // Links are recorded only for what reached the database: a space whose
        // unit the save refused, or any link after a save that wrote nothing,
        // waits for the import that comes after the next good save.
        let unsaved: Set<String>
        switch outcome {
        case .saved: unsaved = []
        case .savedExcept(let failures):
            unsaved = Set(failures.compactMap { failure -> String? in
                if case .space(let id) = failure.unit { return id.uppercased() }
                return nil
            })
        case .failed: return outcome
        }
        let links = plan.links.filter { $0.kind != .space || !unsaved.contains($0.detourID.uuidString) }
        appDB.saveImportLinks(source: Self.arcImportSource,
                              links.map { ($0.sourceKey, $0.kind.rawValue, $0.detourID) }, at: now)
        return outcome
    }

    /// Reads each planned profile's Arc history off the main thread and
    /// writes it under its space, one profile at a time. Visits older than
    /// Detour's history retention are left out. Call after `applyArcImport`
    /// saved the spaces the visits are filed under.
    func importArcHistory(_ imports: [ArcImportPlan.HistoryImport],
                          now: Date = Date()) async -> [ArcHistoryImportResult] {
        let cutoff = now.timeIntervalSince1970 - HistoryDatabase.visitRetention
        let historyDB = self.historyDB
        var results: [ArcHistoryImportResult] = []
        for item in imports {
            let read = await Task.detached(priority: .utility) { () -> Result<[ArcHistoryVisit], ArcImportError> in
                do throws(ArcImportError) {
                    return .success(try ArcHistoryReader.readVisits(historyFile: item.historyFile, since: cutoff))
                } catch {
                    return .failure(error)
                }
            }.value
            switch read {
            case .failure(let error):
                results.append(.init(arcProfile: item.arcProfile, added: nil, failure: error.localizedDescription))
            case .success(let visits):
                let imported = visits.map {
                    HistoryDatabase.ImportedVisit(url: $0.url, title: $0.title, visitTime: $0.visitTime,
                                                  isTyped: $0.isTyped)
                }
                let written = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Int, any Error>, Never>) in
                    historyDB.importVisits(imported, spaceID: item.spaceID.uuidString) { result in
                        continuation.resume(returning: result)
                    }
                }
                switch written {
                case .success(let added):
                    results.append(.init(arcProfile: item.arcProfile, added: added, failure: nil))
                case .failure(let error):
                    results.append(.init(arcProfile: item.arcProfile, added: nil,
                                         failure: error.localizedDescription))
                }
            }
        }
        return results
    }

    // MARK: - Helpers

    /// Every id the plan points at must be in the store or in the plan.
    private func validate(_ plan: ArcImportPlan) throws(ArcImportApplyError) {
        let profileIDs = Set(profiles.filter { !$0.isIncognito }.map(\.id)).union(plan.profiles.map(\.id))
        let spaceIDs = Set(nonIncognitoSpaces.map(\.id)).union(plan.spaces.map(\.id))
        // Folder id → its space: a folder or entry must stay inside its own space.
        var folderSpaces: [UUID: UUID] = [:]
        for space in nonIncognitoSpaces {
            for folder in space.pinnedFolders { folderSpaces[folder.id] = space.id }
        }
        func fits(_ folderID: UUID?, in spaceID: UUID) -> Bool {
            folderID.map { folderSpaces[$0] == spaceID } ?? true
        }
        guard Set(plan.profiles.map(\.id)).isDisjoint(with: profiles.map(\.id)),
              Set(plan.spaces.map(\.id)).isDisjoint(with: spaces.map(\.id)),
              plan.spaces.allSatisfy({ profileIDs.contains($0.profileID) }),
              plan.favorites.allSatisfy({ profileIDs.contains($0.profileID) }),
              plan.tabs.allSatisfy({ spaceIDs.contains($0.spaceID) }),
              plan.history.allSatisfy({ spaceIDs.contains($0.spaceID) }) else {
            throw .staleTarget
        }
        // Folders arrive parents first, so a folder may name one planned before it.
        for folder in plan.folders {
            guard spaceIDs.contains(folder.spaceID), fits(folder.parentID, in: folder.spaceID) else {
                throw .staleTarget
            }
            folderSpaces[folder.id] = folder.spaceID
        }
        guard plan.pinnedEntries.allSatisfy({ entry in
            spaceIDs.contains(entry.spaceID) && fits(entry.folderID, in: entry.spaceID)
        }) else { throw .staleTarget }
    }

    /// Items grouped by key, keys in first-seen order, items in plan order.
    private func grouped<Item>(_ items: [Item], by key: (Item) -> UUID) -> [(UUID, [Item])] {
        var order: [UUID] = []
        var groups: [UUID: [Item]] = [:]
        for item in items {
            let id = key(item)
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(item)
        }
        return order.map { ($0, groups[$0]!) }
    }
}
