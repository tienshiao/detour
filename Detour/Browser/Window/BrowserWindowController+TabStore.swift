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
        if tab.id == selectedTabID, window?.isKeyWindow == false {
            deselectAllTabs()
        }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
    }

    func tabStoreDidReorderTabs(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        if let selectedTabID, let index = currentTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.selectedTabIndex = index
        }
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
    }

    func tabStoreDidPinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
    }

    func tabStoreDidUnpinTab(_ entry: PinnedEntry, fromIndex: Int, toIndex: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
    }

    func tabStoreDidReorderPinnedEntries(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        if let selectedTabID, let index = space.pinnedEntries.firstIndex(where: { $0.tab?.id == selectedTabID }) {
            tabSidebar.selectedPinnedTabIndex = index
        }
    }

    func tabStoreDidUpdatePinnedEntry(_ entry: PinnedEntry, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        // Pinned tab close fires Update (not Remove) — entries stay as dormant
        // slots. Key window handles deselect itself; background windows don't.
        if entry.tab == nil, selectedTabID != nil, selectedTab == nil, window?.isKeyWindow == false {
            deselectAllTabs()
        }
        tabSidebar.reloadPinnedEntry(at: index)
    }

    func tabStoreDidUpdatePinnedFolders(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedEntries: space.pinnedEntries, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        // Restore selection after animation
        if let selectedTabID, let index = space.pinnedEntries.firstIndex(where: { $0.tab?.id == selectedTabID }) {
            tabSidebar.selectedPinnedTabIndex = index
        } else if let selectedTabID, let index = currentTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.selectedTabIndex = index
        }
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
