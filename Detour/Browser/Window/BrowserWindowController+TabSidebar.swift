import AppKit

// MARK: - TabSidebarDelegate

extension BrowserWindowController: TabSidebarDelegate {
    func tabSidebarDidRequestNewTab(_ sidebar: TabSidebarViewController) {
        showCommandPalette()
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectTabAt index: Int) {
        let tabs = currentTabs
        guard index >= 0, index < tabs.count else { return }
        var id = tabs[index].id
        // Selecting a split row focuses the group's remembered pane; the
        // sidebar's representative (selected member, else left pane) is the
        // fallback when this window has no focus memory for the group.
        if let space = activeSpace,
           let group = store.splitGroup(containing: id, in: space),
           let remembered = lastFocusedSplitMember[group.groupID],
           group.members.contains(where: { $0.id == remembered }) {
            id = remembered
        }
        selectTab(id: id)
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
        var entry = space.pinnedEntries[index]
        // Selecting a pinned split row focuses the group's remembered pane,
        // mirroring didSelectTabAt for normal split rows.
        if let groupID = entry.splitGroupID,
           let rememberedTabID = lastFocusedSplitMember[groupID],
           let remembered = store.pinnedSplitEntries(groupID: groupID, in: space)
               .first(where: { $0.tab?.id == rememberedTabID }) {
            entry = remembered
        }
        if let tab = entry.tab {
            selectTab(id: tab.id)
        } else {
            // Dormant — activate the pinned entry and select the new tab
            let entryID = entry.id
            DispatchQueue.main.async { [weak self] in
                guard let self, let space = self.activeSpace,
                      let entry = space.pinnedEntries.first(where: { $0.id == entryID }) else { return }
                self.store.activatePinnedEntry(id: entry.id, in: space)
                if let tab = entry.tab {
                    self.selectTab(id: tab.id)
                } else {
                    // The tile stays dormant; the click did nothing visible (TASK-37).
                    self.showDormantTileRefusal(urls: [entry.pinnedURL])
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

    func tabSidebar(_ sidebar: TabSidebarViewController, didMoveTab tabID: UUID, toGapIndex gapIndex: Int) {
        guard let space = activeSpace else { return }
        // The gap→destination conversion lives in TabStore: only the store knows
        // the moved block's width (a split row moves 2 tabs, not 1).
        store.moveTab(id: tabID, toGapIndex: gapIndex, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragTabToPin tabID: UUID) {
        guard let space = activeSpace,
              let tab = space.tabs.first(where: { $0.id == tabID }),
              tab.url != nil else { return }
        store.pinTab(id: tabID, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragPinnedTabToUnpin entryID: UUID, toGapIndex gapIndex: Int) {
        guard let space = activeSpace,
              let entry = space.pinnedEntries.first(where: { $0.id == entryID }) else { return }
        // Harmless for non-split unpins: the separation-context guards fail
        // and the defer clears the flag.
        animateNextSplitSeparation = true
        defer { animateNextSplitSeparation = false }
        if !store.unpinTab(id: entry.id, in: space, at: gapIndex) {
            // The entry stayed pinned; the drop did nothing visible (TASK-37).
            showDormantTileRefusal(urls: [entry.pinnedURL])
        }
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

    func tabSidebarDidRequestShowSettings(_ sidebar: TabSidebarViewController, sourceButton: NSView) {
        let host = displayTab?.url?.host ?? ""
        let profileID = activeSpace?.profile?.id ?? UUID()
        let isWhitelisted = host.isEmpty ? false : ContentBlockerManager.shared.whitelist.isWhitelisted(host: host, profileID: profileID)

        let vc = SettingsPopoverViewController()
        vc.host = host
        vc.isBlockingEnabled = !isWhitelisted
        vc.blockedCount = displayTab?.blockedCount ?? 0

        // Populate extensions list (fetch pinned IDs once to avoid per-extension DB queries)
        let enabledExts = ExtensionManager.shared.enabledExtensions(for: profileID)
            .filter { $0.manifest.action != nil }
        let pinnedIDs = Set(AppDatabase.shared.pinnedExtensionIDs(for: profileID.uuidString))
        vc.extensions = enabledExts.map { ext in
            SettingsPopoverViewController.ExtensionItem(
                id: ext.id,
                name: ExtensionManager.shared.displayName(for: ext.id),
                icon: ExtensionManager.iconImage(for: ext.id, ext: ext),
                isPinned: pinnedIDs.contains(ext.id)
            )
        }

        vc.onBlockingToggle = { [weak self] in
            guard let self, let profile = self.activeSpace?.profile, !host.isEmpty else { return }
            ContentBlockerManager.shared.whitelist.toggleHost(host, profileID: profile.id)
            // The switch takes effect per navigation (the page's
            // `WKWebpagePreferences`), so the page has to load again — the way
            // Safari's per-site switch reloads the tab (TASK-69). Every pane this
            // window has on screen for that host, not just `displayTab`: the
            // other pane of a split would otherwise keep the old blocking state
            // while its popover, reading the same whitelist, reports the new.
            var panes = self.selectedTab.map { self.splitMembers(of: $0) } ?? []
            if let peek = self.selectedTab?.peekTab { panes.append(peek) }
            for pane in panes
            where pane.url?.host.map({ ContentBlockerWhitelist.covers(host: $0, whitelistedHosts: [host]) }) == true {
                pane.reload()
            }
        }

        vc.onPinToggle = { [weak self] extensionID in
            guard let profile = self?.activeSpace?.profile else { return }
            ExtensionManager.shared.toggleExtensionPinned(extensionID, profileID: profile.id)
        }

        vc.onExtensionClick = { [weak self] extensionID in
            guard let self else { return }
            let popover = ExtensionPopoverController(extensionID: extensionID)
            popover.show(relativeTo: sourceButton.bounds, of: sourceButton, preferredEdge: .maxY)
            objc_setAssociatedObject(self, "extensionPopover", popover, .OBJC_ASSOCIATION_RETAIN)
        }

        vc.onOpenExtensionSettings = {
            SettingsWindowController.shared.showExtensionsPane()
        }

        let fauxBar = tabSidebar.fauxAddressBar
        fauxBar.keepButtonsVisible = true

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        let closeHandler = FauxAddressBarPopoverDelegate(fauxAddressBar: fauxBar)
        popover.delegate = closeHandler
        objc_setAssociatedObject(popover, "popoverDelegate", closeHandler, .OBJC_ASSOCIATION_RETAIN)
        popover.show(relativeTo: sourceButton.bounds, of: sourceButton, preferredEdge: .maxY)
    }

    func tabSidebarDidRequestShowExtensionPopup(_ sidebar: TabSidebarViewController, extensionID: String, sourceButton: NSView) {
        guard ExtensionManager.shared.context(for: extensionID) != nil else { return }
        let fauxBar = tabSidebar.fauxAddressBar
        fauxBar.keepButtonsVisible = true

        let popover = ExtensionPopoverController(extensionID: extensionID)
        popover.onClose = { [weak fauxBar] in
            fauxBar?.dismissPopoverKeep()
        }
        popover.show(relativeTo: sourceButton.bounds, of: sourceButton, preferredEdge: .maxY)
        objc_setAssociatedObject(self, "extensionPopover", popover, .OBJC_ASSOCIATION_RETAIN)
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

    /// "Move to Space" moves the tab or pinned entry itself (TASK-38) — it used
    /// to close it and create a new tab from the URL in the destination, which
    /// lost the back/forward list, unpinned a pinned entry, left a Close Tab
    /// undo and a closed-tab record behind, and built an extension page from the
    /// destination *space's* configuration, which cannot load the scheme at all.
    ///
    /// The store refuses a move whose page the destination profile cannot serve
    /// (an extension not installed or not enabled there) and leaves everything
    /// where it was; that is the one case with nothing to see, so it is
    /// explained like any other refused tile (TASK-37) — classified against the
    /// *destination* profile, the one that cannot serve the page, which is what
    /// `moveTabRefusal` / `movePinnedEntryRefusal` do.
    ///
    /// The store is asked BEFORE the window touches anything. Settling selection
    /// is not free — it can wake a dormant pinned tile, and refuse to, with its
    /// own toast — so a refused move must not have run it: there is nothing to
    /// put back if it never happened. Only once the move is certain is selection
    /// settled (ahead of the move, as for a close, so the removal notification
    /// does not advance it with a blunter pick).
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMoveTabAt index: Int, isPinned: Bool, toSpaceID: UUID) {
        guard let srcSpace = activeSpace, let dstSpace = store.space(withID: toSpaceID),
              srcSpace.id != dstSpace.id else { return }
        if isPinned {
            guard index >= 0, index < srcSpace.pinnedEntries.count else { return }
            let entry = srcSpace.pinnedEntries[index]
            guard store.canMovePinnedEntry(id: entry.id, from: srcSpace, to: dstSpace) else {
                if let refusal = store.movePinnedEntryRefusal(id: entry.id, from: srcSpace, to: dstSpace) {
                    toastManager.show(message: refusal.message)
                }
                return
            }
            if entry.tab?.id == selectedTabID {
                settleSelectionLeaving(pinnedEntry: entry, in: srcSpace)
            }
            store.movePinnedEntry(id: entry.id, from: srcSpace, to: dstSpace)
        } else {
            guard index >= 0, index < srcSpace.tabs.count else { return }
            let tab = srcSpace.tabs[index]
            guard store.canMoveTab(id: tab.id, from: srcSpace, to: dstSpace) else {
                if let refusal = store.moveTabRefusal(id: tab.id, from: srcSpace, to: dstSpace) {
                    toastManager.show(message: refusal.message)
                }
                return
            }
            if tab.id == selectedTabID { settleSelectionLeaving(tabAt: index, in: srcSpace) }
            store.moveTab(id: tab.id, from: srcSpace, to: dstSpace)
        }
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
        let entry = space.pinnedEntries[index]
        if !store.unpinTab(id: entry.id, in: space) {
            // The entry stayed pinned; the menu command did nothing (TASK-37).
            showDormantTileRefusal(urls: [entry.pinnedURL])
        }
    }

    func tabSidebarSpacesForContextMenu(_ sidebar: TabSidebarViewController) -> [(id: UUID, name: String, emoji: String, isCurrent: Bool)] {
        store.spaces.filter { !$0.isIncognito }.map {
            (id: $0.id, name: $0.name, emoji: $0.emoji, isCurrent: $0.id == activeSpaceID)
        }
    }

    // MARK: - Splits

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestSeparateSplit groupID: UUID) {
        guard let space = activeSpace else { return }
        // Same one-shot idiom as didRequestCreateSplit: observers re-claim
        // synchronously inside the mutation, the defer covers gestures that
        // never claim. Undo intentionally stays unanimated in both directions
        // — only user-witnessed gestures animate.
        animateNextSplitSeparation = true
        defer { animateNextSplitSeparation = false }
        store.separateSplit(groupID: groupID, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseSplitGroup groupID: UUID) {
        guard let space = activeSpace else { return }
        let memberIDs = space.tabs.filter { $0.splitGroupID == groupID }.map(\.id)
        guard !memberIDs.isEmpty else { return }

        // Settle selection off the split BEFORE the close, mirroring
        // closeTab(at:wasSelected:) — never select a member the same gesture closes.
        if let selectedTabID, memberIDs.contains(selectedTabID) {
            // The members are closed next: no picture-in-picture on the way out.
            settlingSelectionForClose {
                let remaining = space.tabs.filter { !memberIDs.contains($0.id) }
                let firstMemberIndex = space.tabs.firstIndex { $0.id == memberIDs[0] } ?? 0
                if !remaining.isEmpty {
                    selectTab(id: remaining[min(firstMemberIndex, remaining.count - 1)].id)
                } else if let firstLiveEntry = space.pinnedEntries.first(where: { $0.tab != nil }),
                          let tab = firstLiveEntry.tab {
                    selectTab(id: tab.id)
                } else if let firstDormantEntry = space.pinnedEntries.first {
                    store.activatePinnedEntry(id: firstDormantEntry.id, in: space)
                    if let tab = firstDormantEntry.tab { selectTab(id: tab.id) }
                    else {
                        // A refused tile explains itself (TASK-37).
                        deselectAllTabs()
                        showDormantTileRefusal(urls: [firstDormantEntry.pinnedURL])
                    }
                } else {
                    deselectAllTabs()
                }
            }
        }

        store.closeSplitGroup(groupID: groupID, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCreateSplit draggedTabID: UUID, withTabID targetTabID: UUID, edge: SplitEdge) {
        guard let space = activeSpace else { return }
        // The store's observers re-claim this window's content synchronously
        // inside createSplit; the defer covers drops that never claim (the
        // formed group doesn't involve the selected tab).
        animateNextSplitClaim = true
        defer { animateNextSplitClaim = false }
        store.createSplit(draggedTabID: draggedTabID, targetTabID: targetTabID, edge: edge, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRemoveTabFromSplit tabID: UUID, toGapIndex gapIndex: Int) {
        guard let space = activeSpace else { return }
        animateNextSplitSeparation = true
        defer { animateNextSplitSeparation = false }
        store.removeTabFromSplit(tabID: tabID, toGapIndex: gapIndex, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, dragSessionDidChangeActive active: Bool) {
        if active { installSplitDropZone() } else { removeSplitDropZone() }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestSplitWithNextTab tabID: UUID) {
        guard let space = activeSpace,
              let index = space.tabs.firstIndex(where: { $0.id == tabID }),
              index + 1 < space.tabs.count else { return }
        let nextTab = space.tabs[index + 1]
        animateNextSplitClaim = true
        defer { animateNextSplitClaim = false }
        store.createSplit(draggedTabID: nextTab.id, targetTabID: tabID, edge: .right, in: space)
    }

    // MARK: - Pinned Splits (§12)

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestPinSplitGroup groupID: UUID) {
        guard let space = activeSpace else { return }
        // Every member must have a real URL — matching didDragTabToPin's guard.
        // pinSplitGroup coerces a nil URL to about:blank, which would pin (and
        // later restore) a URL-less pane as a dead about:blank entry.
        let members = space.tabs.filter { $0.splitGroupID == groupID }
        guard !members.isEmpty, members.allSatisfy({ $0.url != nil }) else { return }
        store.pinSplitGroup(groupID: groupID, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestUnpinSplitGroup groupID: UUID, toGapIndex gapIndex: Int) {
        guard let space = activeSpace else { return }
        // Either member's page can refuse the whole group, so offer both URLs.
        let memberURLs = store.pinnedSplitEntries(groupID: groupID, in: space).map(\.pinnedURL)
        if !store.unpinSplitGroup(groupID: groupID, toGapIndex: gapIndex, in: space) {
            showDormantTileRefusal(urls: memberURLs)
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestSeparatePinnedSplit groupID: UUID) {
        guard let space = activeSpace else { return }
        animateNextSplitSeparation = true
        defer { animateNextSplitSeparation = false }
        store.separatePinnedSplit(groupID: groupID, in: space)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRemovePinnedEntryFromSplit entryID: UUID, folderID: UUID?, beforeItemID: UUID?) {
        guard let space = activeSpace else { return }
        animateNextSplitSeparation = true
        defer { animateNextSplitSeparation = false }
        store.removePinnedEntryFromSplit(entryID: entryID, folderID: folderID, beforeItemID: beforeItemID, in: space)
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

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragTabToFavorite tabID: UUID, isPinned: Bool, at index: Int) {
        guard let space = activeSpace, let profileID = space.profile?.id else { return }

        if isPinned, let entry = space.pinnedEntries.first(where: { $0.id == tabID }), entry.tab == nil {
            // Dormant: add the favourite first. A page of an uninstalled
            // extension is refused (TASK-34), and the entry then stays pinned.
            // A dormant entry has no backing tab, so it cannot be the selection.
            guard store.addFavoriteFromEntry(url: entry.pinnedURL, title: entry.pinnedTitle,
                                             faviconURL: entry.faviconURL, favicon: entry.favicon,
                                             profileID: profileID, at: index) else {
                // The tile snapped back; the drop did nothing visible (TASK-37).
                showDormantTileRefusal(urls: [entry.pinnedURL])
                return
            }
            _ = store.detachPinnedEntry(id: entry.id, from: space)
            return
        }

        // Live, from either section: the backing tab moves as it is. A refused
        // move (a tab with no URL yet) leaves the row where it was.
        let tab = isPinned
            ? space.pinnedEntries.first(where: { $0.id == tabID })?.tab
            : space.tabs.first(where: { $0.id == tabID })
        guard let tab else { return }
        let wasSelected = tab.id == selectedTabID
        guard store.moveTabToFavorites(id: tabID, from: space, profileID: profileID, at: index) else { return }
        if wasSelected { selectTab(id: tab.id) }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didRemoveFavoriteAt index: Int) {
        guard let space = activeSpace, let profile = space.profile else { return }
        guard index >= 0, index < profile.favorites.count else { return }
        // Removing the favourite discards its live backing tab, so if that tab
        // was the selection the window has to let go of it — same order as the
        // favourite branch of `closeCurrentTab`: store teardown, then deselect.
        let fav = profile.favorites[index]
        let wasSelected = fav.tab?.id == selectedTabID
        store.removeFavorite(id: fav.id, profileID: profile.id)
        if wasSelected { deselectAllTabs() }
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
        if fav.tab == nil, !store.activateFavorite(id: fav.id, profileID: profile.id, in: space) {
            // The tile stays dormant; the click did nothing visible (TASK-37).
            showDormantTileRefusal(urls: [fav.url])
            return nil
        }
        guard fav.tab != nil else { return nil }
        return fav
    }

    /// Explains a refused dormant tile (TASK-37). The store leaves a tile whose
    /// extension is disabled or uninstalled exactly where it was, so a click,
    /// drop or menu command that did nothing needs a reason. Shows the first of
    /// `urls` that has one; silent when none does (nothing was refused for this
    /// reason). Only user-driven paths call it — a click, a drop, a menu
    /// command, or the selection a close leaves behind; the store's own
    /// activations (waking a split partner, restore) stay silent.
    func showDormantTileRefusal(urls: [URL]) {
        let profile = activeSpace?.profile
        guard let refusal = urls.lazy.compactMap({ self.store.dormantTileRefusal(url: $0, in: profile) }).first
        else { return }
        toastManager.show(message: refusal.message)
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragFavorite favoriteID: UUID, toTabGapIndex gapIndex: Int) {
        guard let space = activeSpace, let profile = space.profile,
              let fav = profile.favorites.first(where: { $0.id == favoriteID }) else { return }
        let wasSelected = fav.tab?.id == selectedTabID
        guard store.restoreFavoriteAsTab(id: favoriteID, profileID: profile.id, in: space, at: gapIndex) else { return }
        if wasSelected {
            let insertAt = min(gapIndex, space.tabs.count - 1)
            if insertAt >= 0 { selectTab(id: space.tabs[insertAt].id) }
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, didDragFavorite favoriteID: UUID, toPinnedAt pinnedIndex: Int) {
        guard let space = activeSpace, let profile = space.profile,
              let fav = profile.favorites.first(where: { $0.id == favoriteID }) else { return }
        // Capture the dragged favorite's live tab id so we can re-select exactly
        // that tab after it becomes a pinned entry — not just the first live
        // pinned entry, which may be an unrelated earlier tab.
        let draggedTabID = fav.tab?.id
        let wasSelected = draggedTabID == selectedTabID
        guard store.restoreFavoriteAsPinned(id: favoriteID, profileID: profile.id, in: space, at: pinnedIndex) else { return }
        if wasSelected, let draggedTabID {
            selectTab(id: draggedTabID)
        }
    }

    func tabSidebar(_ sidebar: TabSidebarViewController, dropTargetsForFavorite favoriteID: UUID) -> FavoriteDropTargets {
        guard let profile = activeSpace?.profile else { return [] }
        return store.favoriteDropTargets(id: favoriteID, profileID: profile.id)
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

// MARK: - Popover delegate to keep faux address bar buttons visible

class FauxAddressBarPopoverDelegate: NSObject, NSPopoverDelegate {
    private weak var fauxAddressBar: FauxAddressBar?

    init(fauxAddressBar: FauxAddressBar) {
        self.fauxAddressBar = fauxAddressBar
    }

    func popoverDidClose(_ notification: Notification) {
        fauxAddressBar?.dismissPopoverKeep()
    }
}
