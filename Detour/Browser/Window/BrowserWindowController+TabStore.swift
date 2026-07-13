import AppKit

// MARK: - TabStoreObserver

extension BrowserWindowController: TabStoreObserver {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)

        if sidebarItem.isCollapsed {
            toastManager.show(message: "Opened new tab in background")
        }
    }

    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        // If our selected tab is still the one being removed, this removal did
        // not come through our own closeTab (which settles selection before
        // removing) — e.g. an extension chrome.tabs.remove or an undo. Advance
        // selection to an adjacent tab regardless of key state, so a key window
        // isn't left with a stale selection and a blank content pane.
        if tab.id == selectedTabID {
            selectAdjacentTabAfterRemoval(at: index, in: space)
        }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        // A removed pane dissolves its group; collapse the hosted split view.
        refreshSplitHostingIfNeeded()
    }

    /// Pick a sensible tab to select after the current selection was removed
    /// out from under this window. Uses post-removal state (the tab is already
    /// gone from `space.tabs`).
    private func selectAdjacentTabAfterRemoval(at index: Int, in space: Space) {
        let tabs = space.tabs
        if !tabs.isEmpty {
            selectTab(id: tabs[min(index, tabs.count - 1)].id)
        } else if let liveEntry = space.pinnedEntries.first(where: { $0.tab != nil }), let tab = liveEntry.tab {
            selectTab(id: tab.id)
        } else {
            deselectAllTabs()
        }
    }

    func tabStoreDidReorderTabs(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        // Suppressed: a re-entrant tableViewSelectionDidChange → selectTab here
        // would run selection side effects (dormant-partner activation, focus
        // retarget) for a purely programmatic highlight restore.
        if let selectedTabID, let index = currentTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.suppressingSelectionCallbacks {
                tabSidebar.selectedTabIndex = index
            }
        }
        // Split create/separate around the selected tab lands here (group
        // membership changes coincide with reorders); match hosting to it.
        refreshSplitHostingIfNeeded()
    }

    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.reloadTab(at: index)
    }

    // Pinned entry observer methods

    func tabStoreDidInsertPinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
    }

    func tabStoreDidRemovePinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        if entry.tab?.id == selectedTabID, window?.isKeyWindow == false {
            deselectAllTabs()
        }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        // Deleting a pinned split member dissolves its group; collapse hosting.
        refreshSplitHostingIfNeeded()
    }

    func tabStoreDidPinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        // pinTab leaves the split silently; undo-of-unpin rejoins a pinned
        // split. Either way the selected group's pane count may have changed —
        // converge hosting to it.
        refreshSplitHostingIfNeeded()
    }

    func tabStoreDidUnpinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        // unpinTab silently dissolves a pinned split — collapse a now-stale
        // two-pane hosting to match.
        refreshSplitHostingIfNeeded()
    }

    func tabStoreDidReorderPinnedEntries(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        if let selectedTabID, let index = space.pinnedEntries.firstIndex(where: { $0.tab?.id == selectedTabID }) {
            tabSidebar.suppressingSelectionCallbacks {
                tabSidebar.selectedPinnedTabIndex = index
            }
        }
    }

    func tabStoreDidUpdatePinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        // Pinned tab close fires Update (not Remove) — entries stay as dormant
        // slots. Key window handles deselect itself; background windows don't.
        if entry.tab == nil, selectedTabID != nil, selectedTab == nil, window?.isKeyWindow == false {
            // A closed pinned-split pane leaves a live partner on screen —
            // follow it like the closing window does instead of blanking this
            // one (and clobbering the space's selectedTabID it just set).
            if let groupID = entry.splitGroupID,
               let partnerTab = store.pinnedSplitEntries(groupID: groupID, in: space)
                   .first(where: { $0.id != entry.id })?.tab {
                selectTab(id: partnerTab.id)
            } else {
                deselectAllTabs()
            }
        }
        tabSidebar.reloadPinnedEntry(at: index)
        // A pinned split member going dormant (or waking) changes how many
        // panes the selected group hosts — converge the content view.
        refreshSplitHostingIfNeeded()
    }

    func tabStoreDidUpdatePinnedFolders(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        // Restore selection after animation. Suppressed: an unguarded
        // selectRowIndexes fires tableViewSelectionDidChange → selectTab,
        // whose §12 wake block would resurrect a deliberately-closed dormant
        // split partner on any folder mutation.
        tabSidebar.suppressingSelectionCallbacks {
            if let selectedTabID, let index = space.pinnedEntries.firstIndex(where: { $0.tab?.id == selectedTabID }) {
                tabSidebar.selectedPinnedTabIndex = index
            } else if let selectedTabID, let index = currentTabs.firstIndex(where: { $0.id == selectedTabID }) {
                tabSidebar.selectedTabIndex = index
            }
        }
        // Pin/unpin/separate of a split around the selection lands here —
        // match hosting to the selected tab's (possibly pinned) group state.
        refreshSplitHostingIfNeeded()
    }

    func tabStoreDidUpdateFavorites(for profile: Profile) {
        guard let space = activeSpace, space.profileID == profile.id else { return }
        tabSidebar.updateFavorites(profile.favorites, selectedTabID: selectedTabID)
    }

    func tabStoreDidUpdateSpaces() {
        if isIncognito {
            // Incognito windows only show their own space; never switch away
            if let space = activeSpace {
                tabSidebar.updateSpaceButtons(spaces: [space], activeSpaceID: activeSpaceID)
            }
            return
        }

        let nonIncognitoSpaces = store.spaces.filter { !$0.isIncognito }
        tabSidebar.updateSpaceButtons(spaces: nonIncognitoSpaces, activeSpaceID: activeSpaceID)

        if let space = activeSpace {
            let newColor = space.color
            if tabSidebar.tintColor?.toHex() != newColor.toHex() {
                tabSidebar.tintColor = newColor
            }
        }

        // If our active space was deleted, switch to the first available space
        if activeSpaceID == nil || store.space(withID: activeSpaceID!) == nil, let firstSpace = nonIncognitoSpaces.first {
            setActiveSpace(id: firstSpace.id)
        }
    }
}
