import AppKit

// MARK: - TabSidebarDelegate

extension BrowserWindowController: TabSidebarDelegate {
    func tabSidebarDidRequestNewTab(_ sidebar: TabSidebarViewController) {
        showCommandPalette()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectTabAt index: Int) {
        let tabs = currentTabs
        guard index >= 0, index < tabs.count else { return }
        selectTab(id: tabs[index].id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseTabAt index: Int) {
        let tabs = currentTabs
        guard index >= 0, index < tabs.count else { return }
        closeTab(at: index, wasSelected: tabs[index].id == selectedTabID)
    }

    func tabSidebarDidRequestGoBack(_ sidebar: TabSidebarViewController) {
        navigateBackOrCloseChildTab()
    }

    func tabSidebarDidRequestGoForward(_ sidebar: TabSidebarViewController) {
        goForward(nil)
    }

    func tabSidebarDidRequestReload(_ sidebar: TabSidebarViewController) {
        reloadPage(nil)
    }

    func tabSidebarDidRequestStop(_ sidebar: TabSidebarViewController) {
        selectedTab?.webView?.stopLoading()
    }

    func tabSidebarDidRequestOpenCommandPalette(_ sidebar: TabSidebarViewController, anchorFrame: NSRect) {
        commandPaletteNavigatesInPlace = displayTab === selectedTab
        showCommandPalette(initialText: displayTab?.url?.absoluteString, anchorFrame: anchorFrame)
    }

    func tabSidebarDidRequestToggleSidebar(_ sidebar: TabSidebarViewController) {
        toggleSidebarAutoHide()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectPinnedTabAt index: Int) {
        guard let space = activeSpace, index >= 0, index < space.pinnedEntries.count else { return }
        let entry = space.pinnedEntries[index]
        if let tab = entry.tab {
            selectTab(id: tab.id)
        } else {
            // Dormant — activate the pinned entry and select the new tab
            let entryID = entry.id
            DispatchQueue.main.async { [weak self] in
                guard let self, let space = self.activeSpace else { return }
                self.store.activatePinnedEntry(id: entryID, in: space)
                if let entry = space.pinnedEntries.first(where: { $0.id == entryID }),
                   let tab = entry.tab {
                    self.selectTab(id: tab.id)
                }
            }
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestClosePinnedTabAt index: Int) {
        guard let space = activeSpace, index >= 0, index < space.pinnedEntries.count else { return }
        let entry = space.pinnedEntries[index]
        if entry.tab == nil {
            // Dormant — delete the entry entirely
            store.deletePinnedEntry(id: entry.id, in: space)
        } else {
            let wasSelected = entry.tab?.id == selectedTabID
            if wasSelected {
                closePinnedTab(at: index)
            } else {
                store.closePinnedTab(id: entry.id, in: space)
            }
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didMoveTabFrom sourceIndex: Int, to destinationIndex: Int) {
        guard let space = activeSpace else { return }
        let adjustedDestination = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        store.moveTab(from: sourceIndex, to: adjustedDestination, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragTabToPinAt index: Int, destinationIndex: Int) {
        guard let space = activeSpace, index >= 0, index < space.tabs.count else { return }
        let tab = space.tabs[index]
        guard tab.url != nil else { return }
        store.pinTab(id: tab.id, in: space, at: destinationIndex)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragPinnedTabToUnpinAt index: Int, destinationIndex: Int) {
        guard let space = activeSpace, index >= 0, index < space.pinnedEntries.count else { return }
        store.unpinTab(id: space.pinnedEntries[index].id, in: space, at: destinationIndex)
    }

    func tabSidebarDidRequestSwitchToSpace(_ sidebar: TabSidebarViewController, spaceID: UUID) {
        setActiveSpace(id: spaceID)
    }

    func tabSidebarDidRequestAddSpace(_ sidebar: TabSidebarViewController, sourceButton: NSButton) {
        SettingsWindowController.shared.showSpacesPane()
    }

    func tabSidebarDidRequestEditSpace(_ sidebar: TabSidebarViewController, spaceID: UUID, sourceButton: NSButton) {
        SettingsWindowController.shared.showSpacesPane(selectSpaceID: spaceID)
    }

    func tabSidebarDidRequestShowDownloads(_ sidebar: TabSidebarViewController, sourceButton: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 300)
        popover.contentViewController = DownloadPopoverViewController()
        popover.show(relativeTo: sourceButton.bounds, of: sourceButton, preferredEdge: .minY)
    }

    func tabSidebarDidRequestShowContentBlocker(_ sidebar: TabSidebarViewController, sourceButton: NSView) {
        guard let host = displayTab?.url?.host else { return }
        let profileID = activeSpace?.profile?.id ?? UUID()
        let isWhitelisted = ContentBlockerManager.shared.whitelist.isWhitelisted(host: host, profileID: profileID)

        let vc = ContentBlockerPopoverViewController()
        vc.host = host
        vc.isBlockingEnabled = !isWhitelisted
        vc.blockedCount = displayTab?.blockedCount ?? 0
        vc.onToggle = { [weak self] in
            guard let self, let profile = self.activeSpace?.profile else { return }
            ContentBlockerManager.shared.whitelist.toggleHost(host, profileID: profile.id) {
                DispatchQueue.main.async {
                    self.updateContentBlockerStatus()
                    ContentBlockerManager.shared.reapplyRuleLists()
                }
            }
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 260, height: 120)
        popover.contentViewController = vc
        popover.show(relativeTo: sourceButton.bounds, of: sourceButton, preferredEdge: .maxY)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestDuplicateTabAt index: Int, isPinned: Bool) {
        guard let space = activeSpace else { return }
        let url: URL?
        if isPinned {
            guard index >= 0, index < space.pinnedEntries.count else { return }
            let entry = space.pinnedEntries[index]
            url = entry.tab?.url ?? entry.pinnedURL
        } else {
            guard index >= 0, index < space.tabs.count else { return }
            url = space.tabs[index].url
        }
        guard let url else { return }
        let newTab = store.addTab(in: space, url: url)
        selectTab(id: newTab.id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMoveTabAt index: Int, isPinned: Bool, toSpaceID: UUID) {
        guard let srcSpace = activeSpace, let dstSpace = store.space(withID: toSpaceID) else { return }
        let url: URL?
        let entryOrTabID: UUID
        if isPinned {
            guard index >= 0, index < srcSpace.pinnedEntries.count else { return }
            let entry = srcSpace.pinnedEntries[index]
            url = entry.tab?.url ?? entry.pinnedURL
            entryOrTabID = entry.id
        } else {
            guard index >= 0, index < srcSpace.tabs.count else { return }
            let tab = srcSpace.tabs[index]
            url = tab.url
            entryOrTabID = tab.id
        }
        guard let url else { return }
        if isPinned {
            store.closePinnedTab(id: entryOrTabID, in: srcSpace)
        } else {
            let wasSelected = entryOrTabID == selectedTabID
            if wasSelected {
                closeTab(at: index, wasSelected: true)
            } else {
                store.closeTab(id: entryOrTabID, in: srcSpace)
            }
        }
        store.addTab(in: dstSpace, url: url)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestArchiveTabAt index: Int) {
        guard let space = activeSpace, index >= 0, index < space.tabs.count else { return }
        let tab = space.tabs[index]
        if tab.id == selectedTabID {
            closeTab(at: index, wasSelected: true)
        } else {
            store.closeTab(id: tab.id, in: space)
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestArchiveTabsBelowIndex index: Int) {
        guard let space = activeSpace else { return }
        let tabs = space.tabs
        for i in stride(from: tabs.count - 1, through: index + 1, by: -1) {
            let tab = tabs[i]
            if tab.id == selectedTabID {
                closeTab(at: i, wasSelected: true)
            } else {
                store.closeTab(id: tab.id, in: space)
            }
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestPinTabAt index: Int) {
        guard let space = activeSpace, index >= 0, index < space.tabs.count else { return }
        let tab = space.tabs[index]
        guard tab.url != nil else { return }
        store.pinTab(id: tab.id, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestUnpinTabAt index: Int) {
        guard let space = activeSpace, index >= 0, index < space.pinnedEntries.count else { return }
        store.unpinTab(id: space.pinnedEntries[index].id, in: space)
    }

    func tabSidebarSpacesForContextMenu(_ sidebar: TabSidebarViewController) -> [(id: UUID, name: String, emoji: String, isCurrent: Bool)] {
        store.spaces.filter { !$0.isIncognito }.map {
            (id: $0.id, name: $0.name, emoji: $0.emoji, isCurrent: $0.id == activeSpaceID)
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didTogglePinnedFolder folderID: UUID) {
        guard let space = activeSpace else { return }
        store.togglePinnedFolderCollapsed(id: folderID, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestNewFolderIn parentFolderID: UUID?) {
        guard let space = activeSpace else { return }
        store.addPinnedFolder(name: "New Folder", parentFolderID: parentFolderID, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestRenamePinnedTab entryID: UUID, newName: String) {
        guard let space = activeSpace else { return }
        store.renamePinnedEntry(id: entryID, name: newName, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestRenamePinnedFolder folderID: UUID, newName: String) {
        guard let space = activeSpace else { return }
        store.renamePinnedFolder(id: folderID, name: newName, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestDeletePinnedFolder folderID: UUID) {
        guard let space = activeSpace else { return }
        store.deletePinnedFolder(id: folderID, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMovePinnedTabToFolder tabID: UUID, folderID: UUID?, beforeItemID: UUID?) {
        guard let space = activeSpace else { return }
        store.movePinnedTabToFolder(tabID: tabID, folderID: folderID, beforeItemID: beforeItemID, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMovePinnedFolder folderID: UUID, parentFolderID: UUID?, beforeItemID: UUID?) {
        guard let space = activeSpace else { return }
        store.movePinnedFolder(folderID: folderID, parentFolderID: parentFolderID, beforeItemID: beforeItemID, in: space)
    }

    // MARK: - Favorites

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragTabToFavoriteAtRow tabRow: Int, at index: Int) {
        guard let space = activeSpace, let profileID = space.profile?.id else { return }
        let sRow = sidebar.sidebarRow(for: tabRow)

        switch sRow {
        case .normalTab(let idx):
            guard idx >= 0, idx < space.tabs.count else { return }
            let tab = space.tabs[idx]
            let wasSelected = tab.id == selectedTabID
            store.detachTab(id: tab.id, from: space)
            store.addFavorite(from: tab, profileID: profileID, at: index)
            if wasSelected { selectTab(id: tab.id) }

        case .pinnedItem(let idx):
            guard idx < sidebar.flattenedPinnedItems.count else { return }
            if case .entry(let entry, _) = sidebar.flattenedPinnedItems[idx] {
                let wasSelected = entry.tab?.id == selectedTabID
                if let tab = store.detachPinnedEntry(id: entry.id, from: space) {
                    store.addFavorite(from: tab, profileID: profileID, at: index)
                    if wasSelected { selectTab(id: tab.id) }
                } else {
                    store.addFavoriteFromEntry(url: entry.pinnedURL, title: entry.pinnedTitle,
                                               faviconURL: entry.faviconURL, favicon: entry.favicon,
                                               profileID: profileID, at: index)
                    if wasSelected { deselectAllTabs() }
                }
            }

        default:
            return
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRemoveFavoriteAt index: Int) {
        guard let space = activeSpace, let profile = space.profile else { return }
        guard index >= 0, index < profile.favorites.count else { return }
        store.removeFavorite(id: profile.favorites[index].id, profileID: profile.id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didReorderFavoriteFrom sourceIndex: Int, to destinationIndex: Int) {
        guard let space = activeSpace, let profile = space.profile else { return }
        store.reorderFavorite(from: sourceIndex, to: destinationIndex, profileID: profile.id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didClickFavoriteAt index: Int) {
        guard let fav = activeFavorite(at: index) else { return }
        selectTab(id: fav.tab!.id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDoubleClickFavoriteAt index: Int) {
        guard let fav = activeFavorite(at: index) else { return }
        fav.tab!.load(fav.url)
        selectTab(id: fav.tab!.id)
    }

    /// Ensures the favorite at `index` is activated (has a backing tab). Returns nil if invalid.
    private func activeFavorite(at index: Int) -> Favorite? {
        guard let space = activeSpace, let profile = space.profile else { return nil }
        guard index >= 0, index < profile.favorites.count else { return nil }
        let fav = profile.favorites[index]
        if fav.tab == nil {
            store.activateFavorite(id: fav.id, profileID: profile.id, in: space)
        }
        guard fav.tab != nil else { return nil }
        return fav
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragFavoriteAt favoriteIndex: Int, toTabAt tabIndex: Int) {
        guard let space = activeSpace, let profile = space.profile else { return }
        guard favoriteIndex >= 0, favoriteIndex < profile.favorites.count else { return }
        let fav = profile.favorites[favoriteIndex]
        let wasSelected = fav.tab?.id == selectedTabID
        store.restoreFavoriteAsTab(id: fav.id, profileID: profile.id, in: space, at: tabIndex)
        if wasSelected {
            let insertAt = min(tabIndex, space.tabs.count - 1)
            if insertAt >= 0 { selectTab(id: space.tabs[insertAt].id) }
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragFavoriteAt favoriteIndex: Int, toPinnedAt pinnedIndex: Int) {
        guard let space = activeSpace, let profile = space.profile else { return }
        guard favoriteIndex >= 0, favoriteIndex < profile.favorites.count else { return }
        let fav = profile.favorites[favoriteIndex]
        let wasSelected = fav.tab?.id == selectedTabID
        store.restoreFavoriteAsPinned(id: fav.id, profileID: profile.id, in: space, at: pinnedIndex)
        if wasSelected {
            if let entry = space.pinnedEntries.first(where: { $0.tab?.id != nil }),
               let tabID = entry.tab?.id {
                selectTab(id: tabID)
            }
        }
    }

    func tabSidebarDidRequestDeleteSpace(_ sidebar: TabSidebarViewController, spaceID: UUID) {
        guard let space = store.space(withID: spaceID) else { return }

        if !space.tabs.isEmpty || !space.pinnedEntries.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Space"
            alert.informativeText = "Close or move all tabs first before deleting this space."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete \"\(space.name)\"?"
        alert.informativeText = "This space will be removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let wasActive = (activeSpaceID == spaceID)
        store.deleteSpace(id: spaceID)

        if wasActive, let firstSpace = store.spaces.first {
            setActiveSpace(id: firstSpace.id)
        }
    }
}
