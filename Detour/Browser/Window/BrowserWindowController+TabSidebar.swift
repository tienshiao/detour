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

    func tabSidebarDidRequestOpenCommandPalette(_ sidebar: TabSidebarViewController, anchorFrame: NSRect) {
        commandPaletteNavigatesInPlace = displayTab === selectedTab
        showCommandPalette(initialText: displayTab?.url?.absoluteString, anchorFrame: anchorFrame)
    }

    func tabSidebarDidRequestToggleSidebar(_ sidebar: TabSidebarViewController) {
        toggleSidebarAutoHide()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectPinnedTabAt index: Int) {
        guard let space = activeSpace, index >= 0, index < space.pinnedTabs.count else { return }
        selectTab(id: space.pinnedTabs[index].id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestClosePinnedTabAt index: Int) {
        guard let space = activeSpace, index >= 0, index < space.pinnedTabs.count else { return }
        let tab = space.pinnedTabs[index]
        let wasSelected = tab.id == selectedTabID
        if wasSelected {
            closePinnedTab(at: index)
        } else {
            store.closePinnedTab(id: tab.id, in: space)
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
        guard let space = activeSpace, index >= 0, index < space.pinnedTabs.count else { return }
        store.unpinTab(id: space.pinnedTabs[index].id, in: space, at: destinationIndex)
    }

    func tabSidebarDidRequestSwitchToSpace(_ sidebar: TabSidebarViewController, spaceID: UUID) {
        setActiveSpace(id: spaceID)
    }

    func tabSidebarDidRequestAddSpace(_ sidebar: TabSidebarViewController, sourceButton: NSButton) {
        showAddSpacePopover(relativeTo: sourceButton)
    }

    func tabSidebarDidRequestEditSpace(_ sidebar: TabSidebarViewController, spaceID: UUID, sourceButton: NSButton) {
        showEditSpacePopover(spaceID: spaceID, relativeTo: sourceButton)
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
        let tabs = isPinned ? space.pinnedTabs : space.tabs
        guard index >= 0, index < tabs.count, let url = tabs[index].url else { return }
        let newTab = store.addTab(in: space, url: url)
        selectTab(id: newTab.id)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMoveTabAt index: Int, isPinned: Bool, toSpaceID: UUID) {
        guard let srcSpace = activeSpace, let dstSpace = store.space(withID: toSpaceID) else { return }
        let tabs = isPinned ? srcSpace.pinnedTabs : srcSpace.tabs
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs[index]
        guard let url = tab.url else { return }
        if isPinned {
            store.closePinnedTab(id: tab.id, in: srcSpace)
        } else {
            let wasSelected = tab.id == selectedTabID
            if wasSelected {
                closeTab(at: index, wasSelected: true)
            } else {
                store.closeTab(id: tab.id, in: srcSpace)
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
        guard let space = activeSpace, index >= 0, index < space.pinnedTabs.count else { return }
        store.unpinTab(id: space.pinnedTabs[index].id, in: space)
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

    func tabSidebarDidRequestDeleteSpace(_ sidebar: TabSidebarViewController, spaceID: UUID) {
        guard let space = store.space(withID: spaceID) else { return }

        if !space.tabs.isEmpty || !space.pinnedTabs.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Space"
            alert.informativeText = "Close or move all tabs first before deleting this space."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete \"\(space.name)\"?"
        alert.informativeText = "This action cannot be undone."
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
