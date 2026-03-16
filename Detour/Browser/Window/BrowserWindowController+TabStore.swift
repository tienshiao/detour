import AppKit

// MARK: - TabStoreObserver

extension BrowserWindowController: TabStoreObserver {
    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
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
        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
    }

    func tabStoreDidReorderTabs(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        if let selectedTabID, let index = currentTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.selectedTabIndex = index
        }
    }

    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.reloadTab(at: index)
    }

    // Pinned tab observer methods

    func tabStoreDidInsertPinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
    }

    func tabStoreDidRemovePinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        if tab.id == selectedTabID, window?.isKeyWindow == false {
            deselectAllTabs()
        }
        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
    }

    func tabStoreDidPinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
    }

    func tabStoreDidUnpinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
    }

    func tabStoreDidReorderPinnedTabs(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        if let selectedTabID, let index = space.pinnedTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.selectedPinnedTabIndex = index
        }
    }

    func tabStoreDidUpdatePinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.reloadPinnedTab(at: index)
    }

    func tabStoreDidResetPinnedTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.reloadPinnedTab(at: index)
    }

    func tabStoreDidUpdatePinnedFolders(in space: Space) {
        guard space.id == activeSpaceID else { return }
        tabSidebar.applyState(pinnedTabs: space.pinnedTabs, pinnedFolders: space.pinnedFolders,
                              tabs: space.tabs, selectedTabID: selectedTabID)
        // Restore selection after animation
        if let selectedTabID, let index = space.pinnedTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.selectedPinnedTabIndex = index
        } else if let selectedTabID, let index = currentTabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabSidebar.selectedTabIndex = index
        }
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

        // If our active space was deleted, switch to the first available space
        if activeSpaceID == nil || store.space(withID: activeSpaceID!) == nil, let firstSpace = nonIncognitoSpaces.first {
            setActiveSpace(id: firstSpace.id)
        }
    }
}
