import AppKit

protocol TabSidebarDelegate: AnyObject {
    func tabSidebarDidRequestNewTab(_ sidebar: TabSidebarViewController)
    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectTabAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectPinnedTabAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseTabAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestClosePinnedTabAt index: Int)
    func tabSidebarDidRequestGoBack(_ sidebar: TabSidebarViewController)
    func tabSidebarDidRequestGoForward(_ sidebar: TabSidebarViewController)
    func tabSidebarDidRequestReload(_ sidebar: TabSidebarViewController)
    func tabSidebarDidRequestStop(_ sidebar: TabSidebarViewController)
    func tabSidebarDidRequestOpenCommandPalette(_ sidebar: TabSidebarViewController, anchorFrame: NSRect)
    func tabSidebarDidRequestToggleSidebar(_ sidebar: TabSidebarViewController)
    func tabSidebar(_ sidebar: TabSidebarViewController, didMoveTab tabID: UUID, toGapIndex gapIndex: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragTabToPin tabID: UUID)
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragPinnedTabToUnpin entryID: UUID, toGapIndex gapIndex: Int)
    func tabSidebarDidRequestSwitchToSpace(_ sidebar: TabSidebarViewController, spaceID: UUID)
    func tabSidebarDidRequestAddSpace(_ sidebar: TabSidebarViewController, sourceButton: NSButton)
    func tabSidebarDidRequestEditSpace(_ sidebar: TabSidebarViewController, spaceID: UUID, sourceButton: NSButton)
    func tabSidebarDidRequestDeleteSpace(_ sidebar: TabSidebarViewController, spaceID: UUID)
    func tabSidebarDidRequestShowDownloads(_ sidebar: TabSidebarViewController, sourceButton: NSButton)
    func tabSidebarDidRequestShowSettings(_ sidebar: TabSidebarViewController, sourceButton: NSView)
    func tabSidebarDidRequestShowExtensionPopup(_ sidebar: TabSidebarViewController, extensionID: String, sourceButton: NSView)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestDuplicateTabAt index: Int, isPinned: Bool)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMoveTabAt index: Int, isPinned: Bool, toSpaceID: UUID)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestArchiveTabAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestArchiveTabsBelowIndex index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestPinTabAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestUnpinTabAt index: Int)
    func tabSidebarSpacesForContextMenu(_ sidebar: TabSidebarViewController) -> [(id: UUID, name: String, emoji: String, isCurrent: Bool)]

    // Split operations
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestSeparateSplit groupID: UUID)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseSplitGroup groupID: UUID)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestSplitWithNextTab tabID: UUID)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCreateSplit draggedTabID: UUID, withTabID targetTabID: UUID, edge: SplitEdge)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRemoveTabFromSplit tabID: UUID, toGapIndex gapIndex: Int)
    /// A local sidebar tab drag session started (true) or ended (false); drives
    /// the content-area split drop overlay in the window controller.
    func tabSidebar(_ sidebar: TabSidebarViewController, dragSessionDidChangeActive active: Bool)

    // Pinned split operations (§12)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestPinSplitGroup groupID: UUID)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestUnpinSplitGroup groupID: UUID, toGapIndex gapIndex: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestSeparatePinnedSplit groupID: UUID)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRemovePinnedEntryFromSplit entryID: UUID, folderID: UUID?, beforeItemID: UUID?)

    // Pinned entry operations
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestRenamePinnedTab entryID: UUID, newName: String)

    // Favorite operations
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragTabToFavorite tabID: UUID, isPinned: Bool, at index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRemoveFavoriteAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didReorderFavoriteFrom sourceIndex: Int, to destinationIndex: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didClickFavoriteAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didDoubleClickFavoriteAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragFavorite favoriteID: UUID, toTabGapIndex gapIndex: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragFavorite favoriteID: UUID, toPinnedAt pinnedIndex: Int)

    // Folder operations
    func tabSidebar(_ sidebar: TabSidebarViewController, didTogglePinnedFolder folderID: UUID)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestNewFolderIn parentFolderID: UUID?)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestRenamePinnedFolder folderID: UUID, newName: String)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestDeletePinnedFolder folderID: UUID)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMovePinnedTabToFolder tabID: UUID, folderID: UUID?, beforeItemID: UUID?)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMovePinnedFolder folderID: UUID, parentFolderID: UUID?, beforeItemID: UUID?)
}

extension TabSidebarDelegate {
    func tabSidebarDidRequestShowDownloads(_ sidebar: TabSidebarViewController, sourceButton: NSButton) {}
    func tabSidebarDidRequestShowSettings(_ sidebar: TabSidebarViewController, sourceButton: NSView) {}
    func tabSidebarDidRequestShowExtensionPopup(_ sidebar: TabSidebarViewController, extensionID: String, sourceButton: NSView) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectPinnedTabAt index: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestClosePinnedTabAt index: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragTabToPin tabID: UUID) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragPinnedTabToUnpin entryID: UUID, toGapIndex gapIndex: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestDuplicateTabAt index: Int, isPinned: Bool) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMoveTabAt index: Int, isPinned: Bool, toSpaceID: UUID) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestArchiveTabAt index: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestArchiveTabsBelowIndex index: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestPinTabAt index: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestUnpinTabAt index: Int) {}
    func tabSidebarSpacesForContextMenu(_ sidebar: TabSidebarViewController) -> [(id: UUID, name: String, emoji: String, isCurrent: Bool)] { [] }
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestSeparateSplit groupID: UUID) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseSplitGroup groupID: UUID) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestSplitWithNextTab tabID: UUID) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCreateSplit draggedTabID: UUID, withTabID targetTabID: UUID, edge: SplitEdge) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRemoveTabFromSplit tabID: UUID, toGapIndex gapIndex: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, dragSessionDidChangeActive active: Bool) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestPinSplitGroup groupID: UUID) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestUnpinSplitGroup groupID: UUID, toGapIndex gapIndex: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestSeparatePinnedSplit groupID: UUID) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRemovePinnedEntryFromSplit entryID: UUID, folderID: UUID?, beforeItemID: UUID?) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestRenamePinnedTab entryID: UUID, newName: String) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragTabToFavorite tabID: UUID, isPinned: Bool, at index: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRemoveFavoriteAt index: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didReorderFavoriteFrom sourceIndex: Int, to destinationIndex: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didClickFavoriteAt index: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didDoubleClickFavoriteAt index: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragFavorite favoriteID: UUID, toTabGapIndex gapIndex: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didDragFavorite favoriteID: UUID, toPinnedAt pinnedIndex: Int) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didTogglePinnedFolder folderID: UUID) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestNewFolderIn parentFolderID: UUID?) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestRenamePinnedFolder folderID: UUID, newName: String) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestDeletePinnedFolder folderID: UUID) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMovePinnedTabToFolder tabID: UUID, folderID: UUID?, beforeItemID: UUID?) {}
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestMovePinnedFolder folderID: UUID, parentFolderID: UUID?, beforeItemID: UUID?) {}
}

class TabSidebarViewController: NSViewController {
    private static let navSymbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)

    weak var delegate: TabSidebarDelegate?
    var isIncognito = false
    private var isBatchUpdating = false

    /// Identifies this sidebar as a drag source, so drops from another window's
    /// sidebar (whose payloads reference a different model) can be rejected.
    let sidebarID = UUID()

    private var isDarkBackground: Bool {
        view.effectiveAppearance.isDark
    }

    // Active page views — updated by updateActivePage()
    private(set) var tableView = DraggableTableView()
    private var scrollView = DraggableScrollView()

    private(set) var fauxAddressBar = FauxAddressBar()
    private(set) var backButton = HoverButton()
    private(set) var forwardButton = HoverButton()
    private(set) var reloadButton = HoverButton()
    private(set) var sidebarToggleButton = HoverButton()

    // Title-bar control alignment. The defaults match the traffic-light geometry
    // up through macOS 26 (Tahoe); on macOS 27+ the constants are re-derived from
    // the measured standardWindowButton frames (see alignTitleBarControls()). The
    // toggle button and address bar anchor to the nav stack, so these two
    // constraints position the whole title-bar row.
    private var toggleLeadingConstraint: NSLayoutConstraint!
    private var navTopConstraint: NSLayoutConstraint!
    private static let defaultToggleLeading: CGFloat = 74
    private static let defaultNavTop: CGFloat = 6
    private static let navButtonHeight: CGFloat = 24

    private var contextMenuTabID: UUID?
    private var contextMenuTabIsPinned: Bool = false
    private var contextMenuFolderID: UUID?
    private var contextMenuSplitGroupID: UUID?

    /// Context-menu targets resolved fresh against the current model — the tab list
    /// can change while the menu is open, so a stored index would go stale.
    private var contextMenuTab: BrowserTab? {
        guard !contextMenuTabIsPinned, let id = contextMenuTabID else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    private var contextMenuPinnedEntry: PinnedEntry? {
        guard contextMenuTabIsPinned, let id = contextMenuTabID else { return nil }
        return pinnedEntries.first(where: { $0.id == id })
    }

    private var contextMenuResolvedIndex: Int? {
        guard let id = contextMenuTabID else { return nil }
        return contextMenuTabIsPinned
            ? pinnedEntries.firstIndex(where: { $0.id == id })
            : tabs.firstIndex(where: { $0.id == id })
    }

    var pinnedFolders: [PinnedFolder] = []
    var flattenedPinnedItems: [PinnedItem] = []

    private(set) var downloadButton = HoverButton()
    private lazy var downloadBadge: NSView = {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        badge.layer?.cornerRadius = 3
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        return badge
    }()

    private var isDragging = false

    /// Rounded highlight over the half of a tab row where an edge drop would
    /// place the dragged tab as a split pane. NSTableView's `.sourceList`
    /// feedback can only mark the whole row, so this draws the half itself.
    private var splitDropOverlay: NSView?
    private var pendingInsertionOrigin: NSPoint?
    private var bottomBar = DraggableBarView()
    private let spaceClipView = NSView()
    private let spaceStripView = NSView()
    private var spaceButtons: [NSButton] = []
    private var spaceDots: [NSView] = []
    private var spaceButtonColors: [NSColor] = []  // cached sidebarSafe colors for blending
    private let spaceHighlightView: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = UIConstants.defaultCornerRadius
        return v
    }()
    private var spaceClipWidthConstraint: NSLayoutConstraint?
    private var addSpaceButton = HoverButton()
    private var isAnimatingSwipe = false
    private var isSwipingSpaces = false
    private var spaceClickAnimation: (timer: Timer, from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: Double)?
    private var lastSpaceCount = 0
    private var lastActiveSpaceIndex = -1
    private var lastBottomBarWidth: CGFloat = 0
    private var lastSpaceSignature = ""

    private let spaceButtonWidth: CGFloat = 28
    private let spaceButtonSpacing: CGFloat = 4
    private let spaceDotSize: CGFloat = 5
    private let spaceButtonHeight: CGFloat = 24
    private var maxVisibleSpaces = 1

    // Page strip: all spaces laid out side-by-side, clipped by pageClipView
    private let pageClipView = NSView()
    private let pageStripView = NSView()
    private var spacePages: [SpacePageView] = []
    private var pageSpaceIDs: [UUID] = []
    private var activePageIndex = 0

    var activeSpaceID: UUID? {
        didSet { updateActivePage() }
    }

    var pinnedEntries: [PinnedEntry] = []
    var tabs: [BrowserTab] = [] {
        didSet { tabItems = tabListItems(from: tabs) }
    }

    /// Rendered tab-section items derived from `tabs` — a split group is one item.
    /// Row math for the tab section is in item space; `.normalTab(index)` indexes here.
    private(set) var tabItems: [TabListItem] = []

    /// The selected normal tab's ID, tracked so a collapsed split row can pick its
    /// representative member (the selected pane, else the left pane). Set by the
    /// window through `selectedTabIndex`.
    private var selectedNormalTabID: UUID?

    /// The member of `item` whose title/state a collapsed split row represents.
    private func representativeTab(for item: TabListItem) -> BrowserTab {
        switch item {
        case .single(let tab):
            return tab
        case .split(_, let members):
            return representativeMember(members, selectedID: selectedNormalTabID, id: \.id)
        }
    }

    /// The selected pinned entry's ID, tracked so a pinned split row can pick
    /// its representative member (the selected pane, else the left pane). Set
    /// by the window through `selectedPinnedTabIndex`.
    private var selectedPinnedEntryID: UUID?

    /// The member whose title/state a collapsed pinned split row emphasizes.
    private func representativePinnedEntry(of entries: [PinnedEntry]) -> PinnedEntry {
        representativeMember(entries, selectedID: selectedPinnedEntryID, id: \.id)
    }

    /// Picks a split group's representative member: the one matching the
    /// selected-pane ID if present, else the first (left) member.
    private func representativeMember<Member>(_ members: [Member], selectedID: UUID?, id: (Member) -> UUID) -> Member {
        if let selectedID, let match = members.first(where: { id($0) == selectedID }) {
            return match
        }
        return members[0]
    }

    /// Pending state deferred during drag. The last applyState call during isDragging
    /// stores its args here; the drag handler applies it after clearing isDragging.
    private var pendingState: (pinnedEntries: [PinnedEntry], pinnedFolders: [PinnedFolder],
                               tabs: [BrowserTab], selectedTabID: UUID?)?

    /// Incremented every time state is actually applied (not deferred). Used to
    /// discard a queued pending-state application when newer state landed first.
    private var stateGeneration = 0

    private func resolveSelectedTabID(_ explicit: UUID?) -> UUID? {
        if let explicit { return explicit }
        let row = tableView.selectedRow
        if row >= 0, case .pinnedItem(let idx) = sidebarRow(for: row),
           idx < flattenedPinnedItems.count {
            switch flattenedPinnedItems[idx] {
            case .entry(let entry, _):
                return entry.tab?.id
            case .split(_, let entries, _):
                return representativePinnedEntry(of: entries).tab?.id
            case .folder:
                return nil
            }
        }
        return nil
    }

    func rebuildFlattenedPinnedItems(selectedTabID: UUID? = nil) {
        let collapsedIDs = Set(pinnedFolders.filter(\.isCollapsed).map(\.id))
        flattenedPinnedItems = flattenPinnedTree(
            entries: pinnedEntries,
            folders: pinnedFolders,
            collapsedFolderIDs: collapsedIDs,
            selectedTabID: resolveSelectedTabID(selectedTabID)
        )
    }

    // MARK: - Unified State Update

    func applyState(pinnedEntries newPinned: [PinnedEntry], pinnedFolders newFolders: [PinnedFolder],
                    tabs newTabs: [BrowserTab], selectedTabID: UUID? = nil) {
        // During drag, defer the update — the drag handler will apply it
        if isDragging {
            pendingState = (newPinned, newFolders, newTabs, selectedTabID)
            return
        }

        // Captured for the collapse animation's ghost content: a dissolved
        // split's continuation row needs the DEPARTED member's favicon/title,
        // which only the pre-mutation items still know.
        let oldTabItems = tabItems
        let oldPinnedItems = flattenedPinnedItems

        // Compute new flattened items from the incoming state (model not yet updated)
        let collapsedIDs = Set(newFolders.filter(\.isCollapsed).map(\.id))
        let resolvedID = resolveSelectedTabID(selectedTabID)
        let newPinnedItems = flattenPinnedTree(
            entries: newPinned, folders: newFolders,
            collapsedFolderIDs: collapsedIDs, selectedTabID: resolvedID
        )

        stateGeneration += 1

        let diff = diffSidebarState(
            oldPinnedItems: flattenedPinnedItems, newPinnedItems: newPinnedItems,
            oldTabs: tabItems, newTabs: tabListItems(from: newTabs)
        )

        if diff.hasChanges {
            let insertionOrigin = pendingInsertionOrigin
            pendingInsertionOrigin = nil

            // Declare operations first, then update model before endUpdates.
            // This ensures beginUpdates captures the old state, operations describe
            // the transition, and the data source reflects the new state at endUpdates.
            let insertAnimation: NSTableView.AnimationOptions = insertionOrigin != nil ? [] : .slideDown
            tableView.beginUpdates()
            tableView.removeRows(at: diff.removedRows, withAnimation: .effectFade)
            tableView.insertRows(at: diff.insertedRows, withAnimation: insertAnimation)
            for move in diff.movedRows {
                tableView.moveRow(at: move.from, to: move.to)
            }
            pinnedFolders = newFolders
            pinnedEntries = newPinned
            tabs = newTabs
            flattenedPinnedItems = newPinnedItems
            tableView.endUpdates()

            // Animate inserted row from the favorite tile's origin
            if let origin = insertionOrigin, let insertedRow = diff.insertedRows.first {
                let finalRect = tableView.rect(ofRow: insertedRow)
                if let rowView = tableView.rowView(atRow: insertedRow, makeIfNecessary: false) {
                    let startRect = NSRect(x: origin.x - finalRect.width / 2,
                                           y: origin.y - finalRect.height / 2,
                                           width: finalRect.width, height: finalRect.height)
                    rowView.frame = startRect
                    rowView.alphaValue = 0
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.25
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        rowView.animator().frame = finalRect
                        rowView.animator().alphaValue = 1
                    }
                }
            }
        } else {
            pinnedFolders = newFolders
            pinnedEntries = newPinned
            tabs = newTabs
            flattenedPinnedItems = newPinnedItems
        }

        // Refresh pinned cells (indentation, chevron, folder name)
        for (idx, item) in flattenedPinnedItems.enumerated() {
            let row = rowForPinnedItem(at: idx)
            switch item {
            case .entry(let entry, let depth):
                if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
                    cell.indentLevel = depth
                    cell.updatePinnedMode(entry: entry)
                    // A dissolved pinned split continues as this row (the diff
                    // aliases it, so no fresh cell from viewFor), so the reused
                    // cell must drop the vanished split's right segment — animated,
                    // so the vanishing pane collapses instead of blinking out.
                    // The ghost shows the DEPARTED entry, not whatever the right
                    // segment held (the survivor itself when the left one left).
                    let departed = departedPinnedSplitEntry(survivorID: entry.id, in: oldPinnedItems)
                    cell.updateSplitPane(favicon: nil, title: nil, animatedReveal: true,
                                         departingFavicon: departed?.displayFavicon,
                                         departingTitle: departed?.displayTitle)
                    cell.onClose = { [weak self] in
                        guard let self else { return }
                        let row = self.tableView.row(for: cell)
                        guard row >= 0, case .pinnedItem(let idx) = self.sidebarRow(for: row) else { return }
                        if case .entry(let e, _) = self.flattenedPinnedItems[idx] {
                            if let pinnedIdx = self.pinnedEntries.firstIndex(where: { $0.id == e.id }) {
                                self.delegate?.tabSidebar(self, didRequestClosePinnedTabAt: pinnedIdx)
                            }
                        }
                    }
                    cell.onToggleMute = { entry.tab?.toggleMute() }
                }
            case .folder(let folder, let depth):
                if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FolderCellView {
                    cell.configure(name: folder.name, isCollapsed: folder.isCollapsed, depth: depth, color: safeTintColor)
                }
            case .split(_, let entries, let depth):
                if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
                    // A visible cell going single→split here is a group forming
                    // around its row (the diff renders formation as a row
                    // continuation) — reveal the new segment in place.
                    configurePinnedSplitCell(cell, entries: entries, depth: depth, isActive: true,
                                             animatedReveal: true)
                }
            }
        }

        // Reconfigure normal tab cells (may have been reused from the pinned section
        // by moveRow, which keeps the cell's pinned-mode state and — critically —
        // its pinned onClose handler, whose row guard fails on a normal-tab row)
        for (i, item) in tabItems.enumerated() {
            let row = rowForNormalTab(at: i)
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
                // animatedReveal: a visible single cell reconfigured as a split
                // is a group forming around its row — see the pinned loop above.
                // A single that was a split member in the old items is a
                // dissolve continuation: hand the departed member's content to
                // the collapse so the ghost shows the tab that actually left.
                let departed: BrowserTab? = {
                    guard case .single(let tab) = item else { return nil }
                    return departedSplitMember(survivorID: tab.id, in: oldTabItems)
                }()
                configureItemCell(cell, item: item, isActive: true, animatedReveal: true,
                                  departingFavicon: departed?.favicon,
                                  departingTitle: departed?.title)
            }
        }

        recheckHoverForVisibleCells()
        if diff.hasChanges {
            // Rows animate to their final frames after the batch update; the
            // immediate recheck sees mid-flight positions, so check again once
            // the animation settles.
            recheckHoverForVisibleCells(afterDelay: 0.3)
        }
    }

    /// Non-animated state reset for space switches. Unlike `applyState`, this does
    /// not diff — it sets the model directly and reloads the table view.
    func resetState(pinnedEntries newPinned: [PinnedEntry], pinnedFolders newFolders: [PinnedFolder],
                    tabs newTabs: [BrowserTab], selectedTabID: UUID? = nil) {
        let collapsedIDs = Set(newFolders.filter(\.isCollapsed).map(\.id))
        let resolvedID = resolveSelectedTabID(selectedTabID)

        stateGeneration += 1
        pinnedFolders = newFolders
        pinnedEntries = newPinned
        tabs = newTabs
        flattenedPinnedItems = flattenPinnedTree(
            entries: newPinned, folders: newFolders,
            collapsedFolderIDs: collapsedIDs, selectedTabID: resolvedID
        )
        tableView.reloadData()
        recheckHoverForVisibleCells()
    }

    /// Apply the pending state deferred during drag, with full animation.
    /// Deferred to the next run loop tick so the drag session fully completes
    /// before we issue batch updates — moveRow doesn't work reliably during
    /// an active drag session.
    private func applyPendingState(selectTabID: UUID? = nil, insertionOrigin: NSPoint? = nil) {
        guard let pending = pendingState else { return }
        pendingState = nil
        let expectedGeneration = stateGeneration
        DispatchQueue.main.async { [self] in
            // Skip the (now stale) snapshot if newer state was applied while this
            // was queued — but still restore the selection below.
            if stateGeneration == expectedGeneration {
                if let insertionOrigin {
                    pendingInsertionOrigin = insertionOrigin
                }
                applyState(pinnedEntries: pending.pinnedEntries, pinnedFolders: pending.pinnedFolders,
                           tabs: pending.tabs, selectedTabID: pending.selectedTabID)
            }
            if let selectTabID {
                // Select in pinned section (a pinned split row matches when it
                // contains the entry — entry IDs equal their tabs' IDs at pin time)
                if let flatIdx = flattenedPinnedItems.firstIndex(where: {
                    $0.contains(entryID: selectTabID) || $0.entries.contains { $0.tab?.id == selectTabID }
                }) {
                    tableView.selectRowIndexes(IndexSet(integer: rowForPinnedItem(at: flatIdx)), byExtendingSelection: false)
                }
                // Select in normal section (highlight the containing item row).
                // Keep the focused-member cache in sync — representativeTab reads
                // it to pick which pane a split row titles/activates.
                else if let itemIdx = itemIndex(containingTabID: selectTabID, in: tabItems) {
                    selectedNormalTabID = selectTabID
                    tableView.selectRowIndexes(IndexSet(integer: rowForNormalTab(at: itemIdx)), byExtendingSelection: false)
                }
            }
        }
    }

    /// Runs a drop's store mutations with table updates deferred, then applies the
    /// final state in one animated pass. Any drop that issues more than one delegate
    /// call must go through this, or each call animates separately.
    private func performDropTransaction(selectTabID: UUID? = nil, insertionOrigin: NSPoint? = nil,
                                        _ mutations: () -> Void) {
        isDragging = true
        mutations()
        isDragging = false
        applyPendingState(selectTabID: selectTabID, insertionOrigin: insertionOrigin)
    }

    /// Content-area edge drop (SplitDropZoneView). Same transaction treatment as
    /// the table's own .createSplit drop: the mutation diffs as a row merge, which
    /// the table cannot batch-update while the source drag session is still live.
    func performContentAreaSplitDrop(draggedTabID: UUID, targetTabID: UUID, edge: SplitEdge) {
        performDropTransaction(selectTabID: selectedTabIDForCurrentRow()) {
            delegate?.tabSidebar(self, didRequestCreateSplit: draggedTabID, withTabID: targetTabID, edge: edge)
        }
    }

    // MARK: - Row Layout

    func sidebarRow(for row: Int, pinnedItemCount: Int? = nil) -> SidebarRow {
        let pc = pinnedItemCount ?? flattenedPinnedItems.count
        return Detour.sidebarRow(for: row, pinnedItemCount: pc)
    }

    private func totalRowCount(forTableView tv: NSTableView) -> Int {
        let pinnedCount = pinnedItemCountForTableView(tv)
        let itemCount = tabItemsForTableView(tv).count
        return totalSidebarRowCount(pinnedItemCount: pinnedCount, itemCount: itemCount)
    }

    /// `itemIndex` indexes the tab-section `[TabListItem]` list (a split is one item).
    func rowForNormalTab(at itemIndex: Int) -> Int {
        return Detour.rowForNormalTab(at: itemIndex, pinnedItemCount: flattenedPinnedItems.count)
    }

    func rowForPinnedItem(at index: Int) -> Int {
        return Detour.rowForPinnedItem(at: index)
    }

    private(set) var safeTintColor: NSColor?

    var tintColor: NSColor? {
        didSet {
            safeTintColor = tintColor?.sidebarSafe(darkBackground: isDarkBackground)
            let safeColor = safeTintColor
            view.wantsLayer = true
            if let color = safeColor ?? tintColor {
                view.layer?.backgroundColor = color.withAlphaComponent(0.1).cgColor
            } else {
                view.layer?.backgroundColor = nil
            }
            tableView.enumerateAvailableRowViews { rowView, row in
                (rowView as? TabRowView)?.selectionColor = safeColor
                if let folderCell = rowView.view(atColumn: 0) as? FolderCellView {
                    folderCell.updateColor(safeColor)
                }
            }
            for page in spacePages {
                page.favoritesBar.selectionColor = safeColor
            }
        }
    }

    /// Runs a block with `tableViewSelectionDidChange` suppressed, preventing re-entrant tab selection
    /// when programmatically changing the table view selection.
    func suppressingSelectionCallbacks(_ block: () -> Void) {
        isBatchUpdating = true
        defer { isBatchUpdating = false }
        block()
    }

    /// The selected tab as a TAB index into `tabs` (not an item index). Setting it
    /// highlights the item row that contains that tab; a split shows as selected
    /// when any member is selected.
    var selectedTabIndex: Int {
        get {
            let row = tableView.selectedRow
            guard case .normalTab(let itemIdx) = sidebarRow(for: row), itemIdx < tabItems.count else { return -1 }
            let rep = representativeTab(for: tabItems[itemIdx])
            return tabs.firstIndex(where: { $0.id == rep.id }) ?? -1
        }
        set {
            guard newValue >= 0, newValue < tabs.count else { return }
            selectedNormalTabID = tabs[newValue].id
            guard let itemIdx = itemIndex(forTabIndex: newValue, in: tabItems) else { return }
            tableView.selectRowIndexes(IndexSet(integer: rowForNormalTab(at: itemIdx)), byExtendingSelection: false)
        }
    }

    var selectedPinnedTabIndex: Int {
        get {
            let row = tableView.selectedRow
            switch sidebarRow(for: row) {
            case .pinnedItem(let index): return index
            default: return -1
            }
        }
        set {
            guard newValue >= 0, newValue < pinnedEntries.count else { return }
            let entryID = pinnedEntries[newValue].id
            selectedPinnedEntryID = entryID
            guard let flatIdx = flattenedPinnedItems.firstIndex(where: { $0.contains(entryID: entryID) }) else { return }
            tableView.selectRowIndexes(IndexSet(integer: rowForPinnedItem(at: flatIdx)), byExtendingSelection: false)
        }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))

        // Navigation buttons (right-aligned, sitting in the title bar area)
        backButton = makeNavButton(symbolName: "chevron.left", accessibilityLabel: "Back", action: #selector(goBackClicked))
        forwardButton = makeNavButton(symbolName: "chevron.right", accessibilityLabel: "Forward", action: #selector(goForwardClicked))
        reloadButton = makeNavButton(symbolName: "arrow.clockwise", accessibilityLabel: "Reload", action: #selector(reloadClicked))

        // Sidebar toggle button (positioned next to traffic lights)
        sidebarToggleButton = makeNavButton(symbolName: "sidebar.left", accessibilityLabel: "Toggle Sidebar", action: #selector(toggleSidebarClicked))
        sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = false

        let navStack = NSStackView(views: [backButton, forwardButton, reloadButton])
        navStack.orientation = .horizontal
        navStack.spacing = 2
        navStack.translatesAutoresizingMaskIntoConstraints = false

        // Faux address bar
        fauxAddressBar.translatesAutoresizingMaskIntoConstraints = false
        fauxAddressBar.onClick = { [weak self] in
            guard let self else { return }
            let frameInWindow = self.fauxAddressBar.convert(self.fauxAddressBar.bounds, to: nil)
            self.delegate?.tabSidebarDidRequestOpenCommandPalette(self, anchorFrame: frameInWindow)
        }
        fauxAddressBar.onSettingsClick = { [weak self] in
            guard let self else { return }
            self.delegate?.tabSidebarDidRequestShowSettings(self, sourceButton: self.fauxAddressBar.settingsButton)
        }
        fauxAddressBar.onPinnedExtensionClick = { [weak self] extensionID in
            guard let self else { return }
            // Find the pinned button to use as anchor
            let sourceButton = self.fauxAddressBar.pinnedExtensionStack.arrangedSubviews
                .first { $0.identifier?.rawValue == extensionID } ?? self.fauxAddressBar.settingsButton
            self.delegate?.tabSidebarDidRequestShowExtensionPopup(self, extensionID: extensionID, sourceButton: sourceButton)
        }

        // Bottom bar for spaces
        bottomBar.wantsLayer = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        // Space buttons: clip view (visible window) + strip view (all buttons)
        spaceClipView.wantsLayer = true
        spaceClipView.layer?.masksToBounds = true
        spaceClipView.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(spaceClipView)

        spaceStripView.wantsLayer = true
        spaceStripView.translatesAutoresizingMaskIntoConstraints = false
        spaceClipView.addSubview(spaceStripView)

        // Add space button
        addSpaceButton = HoverButton()
        addSpaceButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Space")?.withSymbolConfiguration(Self.navSymbolConfig)
        addSpaceButton.bezelStyle = .inline
        addSpaceButton.isBordered = false
        addSpaceButton.imagePosition = .imageOnly
        addSpaceButton.circular = true
        addSpaceButton.target = self
        addSpaceButton.action = #selector(addSpaceClicked)
        addSpaceButton.translatesAutoresizingMaskIntoConstraints = false
        addSpaceButton.toolTip = "Add Space"
        bottomBar.addSubview(addSpaceButton)

        // Download button
        downloadButton = HoverButton()
        downloadButton.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloads")?.withSymbolConfiguration(Self.navSymbolConfig)
        downloadButton.bezelStyle = .inline
        downloadButton.isBordered = false
        downloadButton.imagePosition = .imageOnly
        downloadButton.circular = true
        downloadButton.target = self
        downloadButton.action = #selector(downloadButtonClicked)
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.wantsLayer = true
        downloadButton.toolTip = "Downloads"
        bottomBar.addSubview(downloadButton)
        bottomBar.addSubview(downloadBadge)

        NSLayoutConstraint.activate([
            spaceClipView.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            spaceClipView.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor, constant: 0.5),
            spaceClipView.heightAnchor.constraint(equalToConstant: spaceButtonHeight),

            spaceStripView.topAnchor.constraint(equalTo: spaceClipView.topAnchor),
            spaceStripView.heightAnchor.constraint(equalTo: spaceClipView.heightAnchor),
            // Leading is NOT constrained — we position it manually via frame.origin.x

            downloadButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            downloadButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor, constant: 0.5),
            downloadButton.widthAnchor.constraint(equalToConstant: 24),
            downloadButton.heightAnchor.constraint(equalToConstant: 24),

            addSpaceButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            addSpaceButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor, constant: 0.5),
            addSpaceButton.widthAnchor.constraint(equalToConstant: 24),
            addSpaceButton.heightAnchor.constraint(equalToConstant: 24),

            downloadBadge.widthAnchor.constraint(equalToConstant: 6),
            downloadBadge.heightAnchor.constraint(equalToConstant: 6),
            downloadBadge.leadingAnchor.constraint(equalTo: downloadButton.trailingAnchor, constant: -9),
            downloadBadge.topAnchor.constraint(equalTo: downloadButton.topAnchor, constant: 1),
        ])

        // Page clip view (clips the horizontal page strip)
        pageClipView.wantsLayer = true
        pageClipView.layer?.masksToBounds = true
        pageClipView.translatesAutoresizingMaskIntoConstraints = false
        pageClipView.addSubview(pageStripView)

        container.addSubview(sidebarToggleButton)
        container.addSubview(navStack)
        container.addSubview(fauxAddressBar)
        container.addSubview(pageClipView)
        container.addSubview(bottomBar)

        // Title-bar row: created with the Tahoe defaults, re-derived from the real
        // traffic-light frames on macOS 27+ in alignTitleBarControls(). The toggle
        // and address bar follow the nav stack, so only these two constants move.
        toggleLeadingConstraint = sidebarToggleButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.defaultToggleLeading)
        navTopConstraint = navStack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.defaultNavTop)

        NSLayoutConstraint.activate([
            // Sidebar toggle button: in title bar area, right of traffic lights
            sidebarToggleButton.topAnchor.constraint(equalTo: navStack.topAnchor),
            toggleLeadingConstraint,

            // Nav buttons: pinned to top of view (title bar area), right-aligned
            navTopConstraint,
            navStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            navStack.heightAnchor.constraint(equalToConstant: Self.navButtonHeight),

            // Address field: below the nav row (38pt from top on Tahoe)
            fauxAddressBar.topAnchor.constraint(equalTo: navStack.bottomAnchor, constant: 8),
            fauxAddressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            fauxAddressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            // Page clip: below address field, above bottom bar
            fauxAddressBar.heightAnchor.constraint(equalToConstant: 34),

            pageClipView.topAnchor.constraint(equalTo: fauxAddressBar.bottomAnchor, constant: 4),
            pageClipView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pageClipView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pageClipView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            // Bottom bar: pinned to bottom
            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 32),
        ])

        container.allowedTouchTypes = .indirect
        self.view = container
    }

    private func updateFadeShadows() {
        guard activePageIndex < spacePages.count else { return }
        spacePages[activePageIndex].updateFadeShadows()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        alignTitleBarControls()
        relayoutPages()
        updateFadeShadows()
        rebuildAllSpaceButtons()
    }

    /// On macOS 27 (Golden Gate) the sidebar content extends to the window edge and
    /// the traffic lights sit lower and further right than on Tahoe, so the
    /// hardcoded Tahoe constants misalign. Derive the title-bar control positions
    /// from the measured traffic-light frames instead; fall back to the Tahoe
    /// defaults when the buttons can't be measured (e.g. fullscreen).
    private func alignTitleBarControls() {
        guard #available(macOS 27.0, *) else { return }

        var toggleLeading = Self.defaultToggleLeading
        var navTop = Self.defaultNavTop

        if let window = view.window,
           !window.styleMask.contains(.fullScreen),
           let zoomButton = window.standardWindowButton(.zoomButton),
           // Mid fullscreen/space transition the titlebar container is reparented
           // into an auxiliary window before styleMask reports .fullScreen —
           // converting across windows would yield a plausible-but-wrong frame.
           zoomButton.window === window,
           let zoomSuperview = zoomButton.superview {
            let zoomFrame = view.convert(zoomButton.frame, from: zoomSuperview)
            let centerFromTop = view.isFlipped ? zoomFrame.midY : view.bounds.height - zoomFrame.midY
            // The buttons must sit within the view for the derived row to fit.
            if zoomFrame.maxX > 0, centerFromTop > Self.navButtonHeight / 2 {
                toggleLeading = zoomFrame.maxX + 6
                navTop = centerFromTop - Self.navButtonHeight / 2
            }
        }

        toggleLeadingConstraint.constant = toggleLeading
        navTopConstraint.constant = navTop
    }

    // MARK: - Page Management

    func rebuildPages() {
        let spaces = relevantSpaces
        let newIDs = spaces.map { $0.id }
        guard newIDs != pageSpaceIDs else {
            // Space list unchanged, just update active page
            updateActivePage()
            return
        }
        pageSpaceIDs = newIDs

        // Tear down old pages
        for page in spacePages {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: page.scrollView.contentView)
            page.removeFromSuperview()
        }
        spacePages.removeAll()

        // Build one page per space
        for space in spaces {
            let page = SpacePageView(
                tableViewDataSource: self,
                tableViewDelegate: self,
                menuDelegate: self,
                onScrollWheel: { [weak self] in self?.handleSpaceSwipe($0) ?? false }
            )
            page.update(emoji: space.emoji, name: space.name)
            page.favoritesBar.delegate = self
            page.favoritesBar.sidebarID = sidebarID
            page.favoritesBar.selectionColor = safeTintColor
            // The delegate hears nothing when a drag leaves the table — clear
            // the split-edge highlight from the view's own exit notifications.
            page.tableView.onDragTargetingEnded = { [weak self] in self?.hideSplitDropOverlay() }

            // Update favorites from profile
            if let profile = space.profile {
                page.updateFavorites(profile.favorites)
            }

            pageStripView.addSubview(page)
            spacePages.append(page)
        }

        relayoutPages()
        updateActivePage()

        // Observe scroll (clip view bounds changes) to fix hover state on scroll
        for page in spacePages {
            page.scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewDidScroll(_:)),
                name: NSView.boundsDidChangeNotification,
                object: page.scrollView.contentView
            )
        }

        // Reload all non-active pages from TabStore
        for (i, page) in spacePages.enumerated() where i != activePageIndex {
            page.tableView.reloadData()
        }
    }

    private func relayoutPages() {
        let pageW = pageClipView.bounds.width
        let pageH = pageClipView.bounds.height
        guard pageW > 0 else { return }

        for (i, page) in spacePages.enumerated() {
            page.frame = NSRect(x: CGFloat(i) * pageW, y: 0, width: pageW, height: pageH)
        }
        pageStripView.frame = NSRect(
            x: -CGFloat(activePageIndex) * pageW,
            y: 0,
            width: CGFloat(max(1, spacePages.count)) * pageW,
            height: pageH)
    }

    private func updateActivePage() {
        let spaces = relevantSpaces
        let newIndex: Int
        if let id = activeSpaceID, let idx = spaces.firstIndex(where: { $0.id == id }) {
            newIndex = idx
        } else {
            newIndex = 0
        }
        guard newIndex < spacePages.count else { return }

        activePageIndex = newIndex
        scrollView = spacePages[newIndex].scrollView
        tableView = spacePages[newIndex].tableView

        // Snap strip to active page (no animation)
        let pageW = pageClipView.bounds.width
        if pageW > 0 {
            pageStripView.frame.origin.x = -CGFloat(newIndex) * pageW
        }

        updateFadeShadows()
    }

    private func updateSpaceLabels() {
        let spaces = relevantSpaces
        for (i, page) in spacePages.enumerated() where i < spaces.count {
            page.update(emoji: spaces[i].emoji, name: spaces[i].name)
        }
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              let scrollView = clipView.enclosingScrollView as? DraggableScrollView,
              let pageIndex = spacePages.firstIndex(where: { $0.scrollView === scrollView }) else { return }
        recheckHoverForVisibleCells(in: spacePages[pageIndex].tableView)

        if pageIndex == activePageIndex {
            updateFadeShadows()
        }
    }

    private func recheckHoverForVisibleCells(in tv: NSTableView? = nil, afterDelay delay: TimeInterval = 0) {
        let targetTV = tv ?? tableView
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak targetTV] in
            guard self != nil, let tv = targetTV else { return }
            let visibleRows = tv.rows(in: tv.visibleRect)
            for row in visibleRows.lowerBound..<visibleRows.upperBound {
                guard let cellView = tv.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
                if let tabCell = cellView as? TabCellView {
                    tabCell.recheckHover()
                } else if let newTabCell = cellView as? NewTabCellView {
                    newTabCell.recheckHover()
                }
            }
        }
    }

    func updateFavorites(_ favorites: [Favorite], selectedTabID: UUID? = nil) {
        guard activePageIndex < spacePages.count else { return }
        spacePages[activePageIndex].updateFavorites(favorites, selectedTabID: selectedTabID)
    }

    func updateFavoriteSelection(selectedTabID: UUID?) {
        guard activePageIndex < spacePages.count else { return }
        spacePages[activePageIndex].updateFavoriteSelection(selectedTabID: selectedTabID)
    }

    func updateSpaceButtons(spaces: [Space], activeSpaceID: UUID?) {
        rebuildAllSpaceButtons()
        rebuildPages()
        updateSpaceLabels()
    }

    /// Rebuilds ALL space buttons in the strip and positions the viewport.
    private func rebuildAllSpaceButtons() {
        let spaces = relevantSpaces
        let activeSpaceID = self.activeSpaceID
        let activeIndex = spaces.firstIndex(where: { $0.id == activeSpaceID }) ?? 0

        addSpaceButton.isHidden = isIncognito

        // Calculate how many buttons fit in the available space
        let availableWidth = addSpaceButton.frame.minX - downloadButton.frame.maxX - 16
        let needsDots = spaces.count > max(1, Int((availableWidth + spaceButtonSpacing) / (spaceButtonWidth + spaceButtonSpacing)))
        let dotSpace: CGFloat = needsDots ? 18 : 0  // 5px dot + 4px gap on each side
        let effectiveWidth = availableWidth - dotSpace
        maxVisibleSpaces = max(1, Int((effectiveWidth + spaceButtonSpacing) / (spaceButtonWidth + spaceButtonSpacing)))

        let currentWidth = bottomBar.bounds.width
        let clipReady = spaceClipView.bounds.width > 0
        let spaceSignature = spaces.map { $0.emoji + $0.colorHex }.joined()
        if spaces.count == lastSpaceCount && activeIndex == lastActiveSpaceIndex && currentWidth == lastBottomBarWidth && spaceSignature == lastSpaceSignature && clipReady {
            return
        }
        lastSpaceCount = spaces.count
        lastActiveSpaceIndex = activeIndex
        lastBottomBarWidth = currentWidth
        lastSpaceSignature = spaceSignature

        for btn in spaceButtons { btn.removeFromSuperview() }
        for dot in spaceDots { dot.removeFromSuperview() }
        spaceHighlightView.removeFromSuperview()
        spaceButtons.removeAll()
        spaceDots.removeAll()
        spaceButtonColors.removeAll()

        guard !spaces.isEmpty else { return }

        let dark = isDarkBackground
        let totalWidth = CGFloat(spaces.count) * spaceButtonWidth + CGFloat(max(0, spaces.count - 1)) * spaceButtonSpacing
        spaceStripView.frame = NSRect(x: 0, y: 0, width: totalWidth, height: spaceButtonHeight)

        spaceHighlightView.frame = NSRect(x: 0, y: 0, width: spaceButtonWidth, height: spaceButtonHeight)
        spaceStripView.addSubview(spaceHighlightView, positioned: .below, relativeTo: nil)

        for (i, space) in spaces.enumerated() {
            let button = NSButton()
            button.title = space.emoji
            button.font = .systemFont(ofSize: 14)
            button.bezelStyle = .inline
            button.isBordered = false
            button.target = self
            button.action = #selector(spaceButtonClicked(_:))
            button.tag = i
            button.toolTip = isIncognito ? "Private Browsing" : space.name
            button.wantsLayer = true
            button.layer?.cornerRadius = UIConstants.defaultCornerRadius

            if !isIncognito {
                let menu = NSMenu()
                let editItem = NSMenuItem(title: "Edit Space…", action: #selector(editSpaceClicked(_:)), keyEquivalent: "")
                editItem.target = self
                editItem.tag = i
                let deleteItem = NSMenuItem(title: "Delete Space", action: #selector(deleteSpaceClicked(_:)), keyEquivalent: "")
                deleteItem.target = self
                deleteItem.tag = i
                menu.addItem(editItem)
                menu.addItem(deleteItem)
                button.menu = menu
            }

            let x = CGFloat(i) * (spaceButtonWidth + spaceButtonSpacing)
            button.frame = NSRect(x: x, y: 0, width: spaceButtonWidth, height: spaceButtonHeight)
            spaceStripView.addSubview(button)
            spaceButtons.append(button)
            spaceButtonColors.append(space.color.sidebarSafe(darkBackground: dark))

            let dot = NSView(frame: NSRect(
                x: x + (spaceButtonWidth - spaceDotSize) / 2,
                y: (spaceButtonHeight - spaceDotSize) / 2,
                width: spaceDotSize, height: spaceDotSize
            ))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            dot.layer?.cornerRadius = spaceDotSize / 2
            dot.alphaValue = 0
            spaceStripView.addSubview(dot)
            spaceDots.append(dot)
        }

        // Size the clip view: visible buttons + padding for edge dots
        let buttonsWidth = CGFloat(maxVisibleSpaces) * spaceButtonWidth + CGFloat(max(0, maxVisibleSpaces - 1)) * spaceButtonSpacing
        let dotPadding: CGFloat = spaces.count > maxVisibleSpaces ? spaceButtonSpacing + spaceDotSize : 0
        let clipWidth = min(totalWidth, buttonsWidth + dotPadding * 2)
        if let constraint = spaceClipWidthConstraint {
            constraint.constant = clipWidth
        } else {
            let constraint = spaceClipView.widthAnchor.constraint(equalToConstant: clipWidth)
            constraint.isActive = true
            spaceClipWidthConstraint = constraint
        }

        bottomBar.layoutSubtreeIfNeeded()
        positionSpaceStrip(forActiveIndex: activeIndex)
        updateSpaceButtonAppearances(activeIndex: CGFloat(activeIndex))
    }

    /// Computes the clamped strip X position for a given fractional space index.
    private func spaceStripX(forIndex index: CGFloat) -> CGFloat? {
        let clipW = spaceClipView.bounds.width
        let totalWidth = spaceStripView.frame.width
        guard clipW > 0, totalWidth > 0 else { return nil }

        let step = spaceButtonWidth + spaceButtonSpacing
        let center = index * step + spaceButtonWidth / 2
        let x = clipW / 2 - center
        return max(clipW - totalWidth, min(0, x))
    }

    private func positionSpaceStrip(forActiveIndex activeIndex: Int) {
        guard !relevantSpaces.isEmpty,
              let x = spaceStripX(forIndex: CGFloat(activeIndex)) else { return }
        spaceStripView.frame.origin.x = x
    }

    private func updateSpaceButtonAppearances(activeIndex: CGFloat) {
        let clipW = spaceClipView.bounds.width
        guard clipW > 0, !spaceButtonColors.isEmpty else { return }
        let halfBtn = spaceButtonWidth / 2
        let cy = spaceButtonHeight / 2
        let step = spaceButtonWidth + spaceButtonSpacing

        let maxIdx = CGFloat(max(0, spaceButtons.count - 1))
        let clampedIndex = activeIndex.clamped(to: 0...maxIdx)
        let overscroll = activeIndex - clampedIndex
        let baseIdx = floor(clampedIndex)
        let frac = clampedIndex - baseIdx

        // Highlight frame: squish on overscroll, stretch during normal sliding
        let highlightFrame: NSRect
        if abs(overscroll) > 0.001 {
            let squish = min(abs(overscroll), 1.0)
            let compression = squish * spaceButtonWidth * 0.3
            let heightGrow = squish * 2
            let xOffset = overscroll > 0 ? compression : 0
            highlightFrame = NSRect(
                x: clampedIndex * step + xOffset,
                y: -heightGrow / 2,
                width: spaceButtonWidth - compression,
                height: spaceButtonHeight + heightGrow
            )
        } else if frac > 0 {
            let leadFrac = pow(frac, 0.6)
            let trailFrac = pow(frac, 1.6)
            let trailX = (baseIdx + trailFrac) * step
            let leadX = (baseIdx + leadFrac) * step + spaceButtonWidth
            let stretchAmount = 4 * frac * (1 - frac)
            highlightFrame = NSRect(
                x: trailX, y: stretchAmount,
                width: leadX - trailX,
                height: spaceButtonHeight - stretchAmount * 2
            )
        } else {
            highlightFrame = NSRect(
                x: baseIdx * step, y: 0,
                width: spaceButtonWidth, height: spaceButtonHeight
            )
        }
        spaceHighlightView.frame = highlightFrame

        // Blend color between adjacent spaces using cached NSColors
        let leftIdx = Int(baseIdx).clamped(to: 0...(spaceButtonColors.count - 1))
        let rightIdx = min(spaceButtonColors.count - 1, leftIdx + 1)
        let blended = spaceButtonColors[leftIdx].blended(withFraction: frac, of: spaceButtonColors[rightIdx])
            ?? spaceButtonColors[leftIdx]
        spaceHighlightView.layer?.backgroundColor = blended.withAlphaComponent(0.15).cgColor

        // Edge visibility for the highlight
        let hlCenterInClip = highlightFrame.midX + spaceStripView.frame.origin.x
        let hlEdgeT = (min(hlCenterInClip, clipW - hlCenterInClip) / halfBtn).clamped(to: 0...1)
        spaceHighlightView.alphaValue = hlEdgeT

        for (i, button) in spaceButtons.enumerated() {
            guard i < spaceButtonColors.count else { continue }

            let buttonCenterInClip = button.frame.midX + spaceStripView.frame.origin.x
            let distFromLeft = buttonCenterInClip
            let distFromRight = clipW - buttonCenterInClip
            let edgeDist = min(distFromLeft, distFromRight)
            let edgeT = (edgeDist / halfBtn).clamped(to: 0...1)

            let onLeftEdge = distFromLeft < distFromRight
            let cx = onLeftEdge ? spaceButtonWidth * 1.4: spaceButtonWidth * -0.4

            let scale = 0.2 + 0.8 * edgeT
            var transform = CATransform3DIdentity
            transform = CATransform3DTranslate(transform, cx, cy, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            transform = CATransform3DTranslate(transform, -cx, -cy, 0)
            button.layer?.transform = transform
            button.alphaValue = edgeT

            if i < spaceDots.count {
                spaceDots[i].alphaValue = 1.0 - edgeT
                spaceDots[i].frame.origin.x = onLeftEdge
                    ? button.frame.maxX - spaceDotSize
                    : button.frame.minX
            }
        }
    }

    private func makeNavButton(symbolName: String, accessibilityLabel: String, action: Selector) -> HoverButton {
        let button = HoverButton()
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?.withSymbolConfiguration(Self.navSymbolConfig)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.circular = true
        button.circularPadding = -1
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.navButtonHeight).isActive = true
        return button
    }

    // MARK: - Actions

    @objc private func goBackClicked() {
        delegate?.tabSidebarDidRequestGoBack(self)
    }

    @objc private func goForwardClicked() {
        delegate?.tabSidebarDidRequestGoForward(self)
    }

    @objc private func reloadClicked() {
        delegate?.tabSidebarDidRequestReload(self)
    }

    @objc private func stopClicked() {
        delegate?.tabSidebarDidRequestStop(self)
    }

    func updateReloadButton(isLoading: Bool) {
        if isLoading {
            reloadButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop")?.withSymbolConfiguration(Self.navSymbolConfig)
            reloadButton.action = #selector(stopClicked)
        } else {
            reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")?.withSymbolConfiguration(Self.navSymbolConfig)
            reloadButton.action = #selector(reloadClicked)
        }
    }

    @objc private func addTabClicked() {
        delegate?.tabSidebarDidRequestNewTab(self)
    }

    @objc private func toggleSidebarClicked() {
        delegate?.tabSidebarDidRequestToggleSidebar(self)
    }

    @objc private func spaceButtonClicked(_ sender: NSButton) {
        let spaces = relevantSpaces
        guard sender.tag >= 0, sender.tag < spaces.count else { return }
        animateToSpace(id: spaces[sender.tag].id)
    }

    private func stopSpaceClickAnimation() {
        spaceClickAnimation?.timer.invalidate()
        spaceClickAnimation = nil
    }

    func animateToSpace(id: UUID) {
        stopSpaceClickAnimation()
        let spaces = relevantSpaces
        guard let targetIndex = spaces.firstIndex(where: { $0.id == id }),
              targetIndex != activePageIndex,
              !isAnimatingSwipe else {
            delegate?.tabSidebarDidRequestSwitchToSpace(self, spaceID: id)
            return
        }

        let pageW = pageClipView.bounds.width
        guard pageW > 0 else {
            delegate?.tabSidebarDidRequestSwitchToSpace(self, spaceID: id)
            return
        }

        isAnimatingSwipe = true
        let targetX = -CGFloat(targetIndex) * pageW
        let distance = abs(pageStripView.frame.origin.x - targetX)
        let duration = min(0.15, max(0.08, Double(distance / pageW) * 0.12))
        let targetColor = spaces[targetIndex].color

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            var frame = pageStripView.frame
            frame.origin.x = targetX
            pageStripView.animator().frame = frame
            view.animator().layer?.backgroundColor = targetColor.withAlphaComponent(0.1).cgColor
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isAnimatingSwipe = false
            self.delegate?.tabSidebarDidRequestSwitchToSpace(self, spaceID: id)
        })

        // Drive highlight through fractional positions so the stretch effect is visible
        let startIndex = CGFloat(activePageIndex)
        let endIndex = CGFloat(targetIndex)
        let startTime = CACurrentMediaTime()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let rawT = (elapsed / duration).clamped(to: 0...1)
            let t = rawT < 0.5 ? 2 * rawT * rawT : 1 - pow(-2 * rawT + 2, 2) / 2
            let currentIndex = startIndex + (endIndex - startIndex) * CGFloat(t)

            if let x = self.spaceStripX(forIndex: currentIndex) {
                self.spaceStripView.frame.origin.x = x
            }
            self.updateSpaceButtonAppearances(activeIndex: currentIndex)

            if rawT >= 1 {
                timer.invalidate()
                self.spaceClickAnimation = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spaceClickAnimation = (timer, startIndex, endIndex, startTime, duration)
    }

    @objc private func downloadButtonClicked() {
        delegate?.tabSidebarDidRequestShowDownloads(self, sourceButton: downloadButton)
    }

    func updateDownloadBadge(hasActive: Bool) {
        downloadBadge.isHidden = !hasActive
    }

    @objc private func addSpaceClicked() {
        delegate?.tabSidebarDidRequestAddSpace(self, sourceButton: addSpaceButton)
    }

    @objc private func editSpaceClicked(_ sender: NSMenuItem) {
        let spaces = relevantSpaces
        guard sender.tag >= 0, sender.tag < spaces.count else { return }
        let spaceID = spaces[sender.tag].id
        let button = spaceButtons.first { $0.tag == sender.tag } ?? addSpaceButton
        delegate?.tabSidebarDidRequestEditSpace(self, spaceID: spaceID, sourceButton: button)
    }

    @objc private func deleteSpaceClicked(_ sender: NSMenuItem) {
        let spaces = relevantSpaces
        guard sender.tag >= 0, sender.tag < spaces.count else { return }
        let spaceID = spaces[sender.tag].id
        delegate?.tabSidebarDidRequestDeleteSpace(self, spaceID: spaceID)
    }

    // MARK: - Swipe Paging

    private var swipeAccumulatedX: CGFloat = 0
    private var isTrackingHorizontalSwipe = false
    private var swipeStartTintColor: NSColor?
    private var swipeEventMonitor: Any?
    private var lastProcessedSwipeEvent: NSEvent?


    /// Returns `true` when the event is consumed by horizontal swipe handling.
    @discardableResult
    private func handleSpaceSwipe(_ event: NSEvent) -> Bool {
        if isIncognito { return false }

        // Already tracking — delegate to the shared processor (deduplicates with monitor)
        if isTrackingHorizontalSwipe {
            return processSwipeEvent(event)
        }

        // Momentum events with no active tracking — ignore
        if event.phase == [] { return false }

        if event.phase.contains(.began) {
            // If the previous gesture left the strip displaced, snap it back
            if isAnimatingSwipe {
                isAnimatingSwipe = false
                isSwipingSpaces = false
                positionSpaceStrip(forActiveIndex: activePageIndex)
                updateSpaceButtonAppearances(activeIndex: CGFloat(activePageIndex))
                let pageW = pageClipView.bounds.width
                if pageW > 0 {
                    pageStripView.frame.origin.x = -CGFloat(activePageIndex) * pageW
                }
                if let startColor = swipeStartTintColor {
                    view.layer?.backgroundColor = startColor.withAlphaComponent(0.1).cgColor
                }
            }
            swipeAccumulatedX = 0
        }

        guard !isAnimatingSwipe else { return true }

        // Detect horizontal swipe start
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
              event.scrollingDeltaX != 0 else { return false }
        isTrackingHorizontalSwipe = true
        swipeStartTintColor = tintColor
        isSwipingSpaces = true
        stopSpaceClickAnimation()
        installSwipeMonitor()
        return processSwipeEvent(event)
    }

    /// Processes a single scroll event for the horizontal swipe. Returns true if consumed.
    /// Called from both the scroll view handler and the app-level monitor;
    /// deduplicates via identity check so each event is processed exactly once.
    @discardableResult
    private func processSwipeEvent(_ event: NSEvent) -> Bool {
        if event === lastProcessedSwipeEvent { return true }
        lastProcessedSwipeEvent = event

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) || event.phase == [] {
            isTrackingHorizontalSwipe = false
            removeSwipeMonitor()
            handleSwipeEnd()
            return true
        }

        swipeAccumulatedX += event.scrollingDeltaX
        updateStripPosition()
        return true
    }

    /// App-level monitor that captures ALL scroll events during a horizontal swipe,
    /// so the swipe continues even when the view moves out from under the cursor.
    private func installSwipeMonitor() {
        removeSwipeMonitor()
        swipeEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isTrackingHorizontalSwipe else { return event }
            self.processSwipeEvent(event)
            return event
        }
    }

    private func removeSwipeMonitor() {
        if let monitor = swipeEventMonitor {
            NSEvent.removeMonitor(monitor)
            swipeEventMonitor = nil
        }
    }

    private func updateStripPosition() {
        let pageW = pageClipView.bounds.width
        guard pageW > 0 else { return }

        let baseX = -CGFloat(activePageIndex) * pageW
        let maxX: CGFloat = 0
        let minX = -CGFloat(max(0, spacePages.count - 1)) * pageW

        var targetX = baseX + swipeAccumulatedX
        // Rubber-band at edges — logarithmic curve for gradually increasing resistance
        if targetX > maxX {
            let overflow = targetX - maxX
            targetX = maxX + pageW * (1 - 1 / (overflow / pageW + 1))
        } else if targetX < minX {
            let overflow = minX - targetX
            targetX = minX - pageW * (1 - 1 / (overflow / pageW + 1))
        }

        pageStripView.frame.origin.x = targetX

        // Interpolate tint color between adjacent space colors
        let fractionalPage = -targetX / pageW
        let leftIndex = Int(floor(fractionalPage))
        let rightIndex = leftIndex + 1
        let fraction = fractionalPage - CGFloat(leftIndex)
        let spaces = relevantSpaces
        if leftIndex >= 0, rightIndex < spaces.count {
            let leftColor = spaces[leftIndex].color
            let rightColor = spaces[rightIndex].color
            if let blended = leftColor.blended(withFraction: fraction, of: rightColor) {
                view.layer?.backgroundColor = blended.withAlphaComponent(0.1).cgColor
            }
        } else if !spaces.isEmpty {
            // Edge rubber-band: use the edge space's color
            let edgeIndex = fractionalPage < 0 ? 0 : spaces.count - 1
            view.layer?.backgroundColor = spaces[edgeIndex].color.withAlphaComponent(0.1).cgColor
        }

        // Drive space button strip position and appearances proportionally to swipe
        updateSpaceButtonsDuringSwipe(fractionalPage: fractionalPage)
    }

    private func updateSpaceButtonsDuringSwipe(fractionalPage: CGFloat) {
        guard isSwipingSpaces,
              let x = spaceStripX(forIndex: fractionalPage) else { return }
        spaceStripView.frame.origin.x = x
        updateSpaceButtonAppearances(activeIndex: fractionalPage)
    }

    private func handleSwipeEnd() {
        let pageW = pageClipView.bounds.width
        guard pageW > 0 else { return }

        let currentOffset = -pageStripView.frame.origin.x
        let fractionalPage = currentOffset / pageW

        // Snap to nearest page, biased toward the swipe direction
        let targetPage: Int
        if abs(swipeAccumulatedX) > pageW * 0.5 {
            if swipeAccumulatedX > 0 {
                targetPage = max(0, activePageIndex - 1)
            } else {
                targetPage = min(spacePages.count - 1, activePageIndex + 1)
            }
        } else {
            targetPage = Int(round(fractionalPage)).clamped(to: 0...(max(0, spacePages.count - 1)))
        }

        let targetX = -CGFloat(targetPage) * pageW
        let distance = abs(pageStripView.frame.origin.x - targetX)
        let duration = min(0.25, max(0.08, Double(distance / pageW) * 0.25))

        isAnimatingSwipe = true

        let committing = targetPage != activePageIndex

        let spaceTargetX = spaceStripX(forIndex: CGFloat(targetPage)) ?? spaceStripView.frame.origin.x

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true

            var frame = pageStripView.frame
            frame.origin.x = targetX
            pageStripView.animator().frame = frame

            // Animate space button strip to target position
            var spaceFrame = spaceStripView.frame
            spaceFrame.origin.x = spaceTargetX
            spaceStripView.animator().frame = spaceFrame
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isAnimatingSwipe = false
            self.isSwipingSpaces = false

            if committing {
                let spaces = self.relevantSpaces
                guard targetPage < spaces.count else { return }
                self.delegate?.tabSidebarDidRequestSwitchToSpace(self, spaceID: spaces[targetPage].id)
            } else {
                // Cancelled — restore button appearances and tint
                self.positionSpaceStrip(forActiveIndex: self.activePageIndex)
                self.updateSpaceButtonAppearances(activeIndex: CGFloat(self.activePageIndex))
                if let startColor = self.swipeStartTintColor {
                    self.view.layer?.backgroundColor = startColor.withAlphaComponent(0.1).cgColor
                }
            }
        })

        swipeAccumulatedX = 0
    }

    // MARK: - Helpers

    /// Returns the spaces relevant to this sidebar — only the incognito space in incognito mode,
    /// or only non-incognito spaces in regular mode.
    private var relevantSpaces: [Space] {
        if isIncognito {
            return TabStore.shared.spaces.filter { $0.isIncognito && $0.id == activeSpaceID }
        }
        return TabStore.shared.spaces.filter { !$0.isIncognito }
    }

    private func tabItemsForTableView(_ tv: NSTableView) -> [TabListItem] {
        guard let index = spacePages.firstIndex(where: { $0.tableView === tv }) else { return tabItems }
        if index == activePageIndex { return tabItems }
        let spaces = relevantSpaces
        guard index < spaces.count else { return [] }
        return tabListItems(from: spaces[index].tabs)
    }

    private func pinnedItemCountForTableView(_ tv: NSTableView) -> Int {
        guard let index = spacePages.firstIndex(where: { $0.tableView === tv }) else {
            return flattenedPinnedItems.count
        }
        if index == activePageIndex { return flattenedPinnedItems.count }
        // Non-active pages: compute from the space's raw data (honoring collapsed
        // folders, without selected-tab exposure)
        let spaces = relevantSpaces
        guard index < spaces.count else { return 0 }
        let space = spaces[index]
        let items = flattenPinnedTree(
            entries: space.pinnedEntries,
            folders: space.pinnedFolders,
            collapsedFolderIDs: Set(space.pinnedFolders.filter(\.isCollapsed).map(\.id)),
            selectedTabID: nil
        )
        return items.count
    }

    func reloadTab(at index: Int) {
        guard index >= 0, index < tabs.count,
              let itemIdx = itemIndex(forTabIndex: index, in: tabItems) else { return }
        let row = rowForNormalTab(at: itemIdx)
        let item = tabItems[itemIdx]
        // Update existing cell in-place if visible (preserves hover state, enables smooth animation)
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
            // A split row's state is a fold over both members — reconfigure it whole.
            if case .split = item {
                configureItemCell(cell, item: item, isActive: true)
                return
            }
            let tab = tabs[index]
            cell.titleLabel.stringValue = tab.title
            cell.toolTip = tab.title
            cell.updateFavicon(tab.favicon)
            cell.updatePeekFavicon(tab.displayPeekFavicon)
            cell.updateSplitPane(favicon: nil, title: nil)
            cell.updateSleeping(tab.isSleeping)
            cell.updateLoading(tab.isLoading)
            cell.updateProgress(tab.estimatedProgress)
            cell.updateAudio(isPlaying: tab.isPlayingAudio, isMuted: tab.isMuted)
            return
        }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        // After reload the new cell has no hover state — recheck since mouse may already be over it
        DispatchQueue.main.async { [weak self] in
            guard let self, row < self.tableView.numberOfRows else { return }
            if let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
                cell.recheckHover()
            }
        }
    }

    func reloadPinnedEntry(at index: Int) {
        guard index >= 0, index < pinnedEntries.count else { return }
        let entryID = pinnedEntries[index].id
        guard let flatIdx = flattenedPinnedItems.firstIndex(where: { $0.contains(entryID: entryID) }) else { return }
        let row = rowForPinnedItem(at: flatIdx)
        // A pinned split row's state is a fold over both members — reconfigure it whole.
        if case .split(_, let entries, let depth) = flattenedPinnedItems[flatIdx] {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
                configurePinnedSplitCell(cell, entries: entries, depth: depth, isActive: true)
            } else {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
            return
        }
        // Update existing cell in-place if visible (preserves hover state, enables smooth animation)
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
            let entry = pinnedEntries[index]
            let tab = entry.tab
            cell.titleLabel.stringValue = entry.displayTitle
            cell.toolTip = entry.pinnedTitle
            cell.updateFavicon(entry.displayFavicon)
            cell.updatePeekFavicon(tab?.displayPeekFavicon)
            cell.updateSplitPane(favicon: nil, title: nil)
            cell.updateSleeping((tab?.isSleeping ?? false) || !entry.isLive)
            cell.updateLoading(tab?.isLoading ?? false)
            cell.updateProgress(tab?.estimatedProgress ?? 0)
            cell.updateAudio(isPlaying: tab?.isPlayingAudio ?? false, isMuted: tab?.isMuted ?? false)
            cell.updatePinnedMode(entry: entry)
            cell.onClose = { [weak self] in
                guard let self else { return }
                let row = self.tableView.row(for: cell)
                guard row >= 0, case .pinnedItem(let idx) = self.sidebarRow(for: row) else { return }
                if case .entry(let e, _) = self.flattenedPinnedItems[idx] {
                    if let pinnedIdx = self.pinnedEntries.firstIndex(where: { $0.id == e.id }) {
                        self.delegate?.tabSidebar(self, didRequestClosePinnedTabAt: pinnedIdx)
                    }
                }
            }
            cell.onToggleMute = { entry.tab?.toggleMute() }
            return
        }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        // After reload the new cell has no hover state — recheck since mouse may already be over it
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView {
                cell.recheckHover()
            }
        }
    }
}

// MARK: - NSTableViewDataSource

extension TabSidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        totalRowCount(forTableView: tableView)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === self.tableView, let spaceID = activeSpaceID else { return nil }

        let payload: SidebarDragPayload
        switch sidebarRow(for: row) {
        case .pinnedItem(let index):
            guard index < flattenedPinnedItems.count else { return nil }
            switch flattenedPinnedItems[index] {
            case .entry(let entry, _):
                payload = SidebarDragPayload(kind: .pinnedEntry, itemID: entry.id, spaceID: spaceID, sidebarID: sidebarID)
            case .folder(let folder, _):
                payload = SidebarDragPayload(kind: .pinnedFolder, itemID: folder.id, spaceID: spaceID, sidebarID: sidebarID)
            case .split(_, let entries, let depth):
                // Same grab semantics as a normal split row: a pane's favicon
                // segment drags that member; anywhere else drags the whole row.
                // Folder depth shifts the left favicon (TabCellView indents by
                // 16pt per level) — pass it so the grab band tracks the icon.
                let rowRect = self.tableView.rect(ofRow: row)
                let downX = (self.tableView.lastMouseDownPoint?.x ?? rowRect.midX) - rowRect.minX
                switch splitRowDragKind(forX: downX, rowWidth: rowRect.width, indent: CGFloat(depth) * 16) {
                case .member(let edge):
                    let member = (edge == .left ? entries.first : entries.last) ?? entries[0]
                    payload = SidebarDragPayload(kind: .pinnedSplitMember, itemID: member.id, spaceID: spaceID, sidebarID: sidebarID)
                case .group:
                    payload = SidebarDragPayload(kind: .pinnedSplitGroup, itemID: entries[0].id, spaceID: spaceID, sidebarID: sidebarID)
                }
            }
        case .normalTab(let index):
            guard index < tabItems.count, let first = tabItems[index].tabs.first else { return nil }
            switch tabItems[index] {
            case .single:
                payload = SidebarDragPayload(kind: .normalTab, itemID: first.id, spaceID: spaceID, sidebarID: sidebarID)
            case .split(_, let members):
                // Grabbing a pane's favicon segment drags that member out on its
                // own; anywhere else the row travels as a unit — the .splitGroup
                // kind lets the drop resolver reject pin/folder/favorite targets
                // that would scatter it.
                let rowRect = self.tableView.rect(ofRow: row)
                let downX = (self.tableView.lastMouseDownPoint?.x ?? rowRect.midX) - rowRect.minX
                switch splitRowDragKind(forX: downX, rowWidth: rowRect.width) {
                case .member(let edge):
                    let member = (edge == .left ? members.first : members.last) ?? first
                    payload = SidebarDragPayload(kind: .splitMember, itemID: member.id, spaceID: spaceID, sidebarID: sidebarID)
                case .group:
                    payload = SidebarDragPayload(kind: .splitGroup, itemID: first.id, spaceID: spaceID, sidebarID: sidebarID)
                }
            }
        default:
            return nil
        }

        guard let string = payload.pasteboardString else { return nil }
        let item = NSPasteboardItem()
        item.setString(string, forType: tabReorderPasteboardType)
        return item
    }

    /// Decodes the tab/pinned-item payload from a drag, or nil if this drag is not
    /// ours (another window's sidebar, another space, or a foreign pasteboard type).
    private func localDragPayload(from info: any NSDraggingInfo) -> SidebarDragPayload? {
        guard let string = info.draggingPasteboard.pasteboardItems?.first?.string(forType: tabReorderPasteboardType),
              let payload = SidebarDragPayload(pasteboardString: string),
              let activeSpaceID,
              payload.isLocal(sidebarID: sidebarID, spaceID: activeSpaceID) else { return nil }
        return payload
    }

    /// Decodes the favorite payload from a drag, or nil if not a local favorite drag.
    private func localFavoritePayload(from info: any NSDraggingInfo) -> FavoriteDragPayload? {
        guard let string = info.draggingPasteboard.pasteboardItems?.first?.string(forType: favoritePasteboardType),
              let payload = FavoriteDragPayload(pasteboardString: string),
              payload.sidebarID == sidebarID else { return nil }
        return payload
    }

    /// Resolves the dragged item against the current model. Returns nil if the item
    /// no longer exists (e.g. the tab closed mid-drag).
    private func resolveDragSource(_ payload: SidebarDragPayload) -> SidebarDragSource? {
        switch payload.kind {
        case .normalTab:
            // Source index is an ITEM index — resolveSidebarDrop compares it against
            // item-space gap indices.
            guard let index = itemIndex(containingTabID: payload.itemID, in: tabItems) else { return nil }
            return .normalTab(index: index, tabID: payload.itemID)
        case .pinnedEntry:
            guard pinnedEntries.contains(where: { $0.id == payload.itemID }) else { return nil }
            return .pinnedEntry(entryID: payload.itemID)
        case .pinnedFolder:
            guard pinnedFolders.contains(where: { $0.id == payload.itemID }) else { return nil }
            return .pinnedFolder(folderID: payload.itemID)
        case .splitGroup:
            // Re-resolve as a split only if the group survived mid-drag mutations;
            // a dissolved group degrades to a plain tab drag.
            guard let index = itemIndex(containingTabID: payload.itemID, in: tabItems) else { return nil }
            if case .split(let groupID, let members) = tabItems[index] {
                return .splitGroup(index: index, groupID: groupID, memberTabIDs: members.map(\.id))
            }
            return .normalTab(index: index, tabID: payload.itemID)
        case .splitMember:
            // Same degradation rule: if the group dissolved mid-drag the pane is
            // just a normal tab now.
            guard let index = itemIndex(containingTabID: payload.itemID, in: tabItems) else { return nil }
            if case .split(let groupID, _) = tabItems[index] {
                return .splitMember(tabID: payload.itemID, groupID: groupID)
            }
            return .normalTab(index: index, tabID: payload.itemID)
        case .pinnedSplitGroup, .pinnedSplitMember:
            // A pinned split dissolved mid-drag degrades to a plain entry drag.
            guard let entry = pinnedEntries.first(where: { $0.id == payload.itemID }) else { return nil }
            guard let groupID = entry.splitGroupID else { return .pinnedEntry(entryID: entry.id) }
            if payload.kind == .pinnedSplitMember {
                return .pinnedSplitMember(entryID: entry.id, groupID: groupID)
            }
            let members = pinnedEntries.filter { $0.splitGroupID == groupID }
                .sorted { $0.sortOrder < $1.sortOrder }
            return .pinnedSplitGroup(groupID: groupID, memberEntryIDs: members.map(\.id))
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        // Before the drag-image guard below: its early return must not skip the
        // begin signal, since the end signal in endedAt fires unconditionally.
        delegate?.tabSidebar(self, dragSessionDidChangeActive: true)

        guard let row = rowIndexes.first,
              let rowView = tableView.rowView(atRow: row, makeIfNecessary: false),
              let cellView = rowView.view(atColumn: 0) as? NSView else { return }

        // The visual rounded-corner area extends 6pt beyond the cell on each side
        let visualRect = cellView.bounds.insetBy(dx: -6, dy: 1)
        let imageSize = visualRect.size

        let image = NSImage(size: imageSize)
        image.lockFocus()

        // Draw the rounded-corner background (matches hover style)
        let bgRect = NSRect(origin: .zero, size: imageSize)
        UIConstants.hoverBackgroundColor.setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6).fill()

        // Draw cell content offset so it aligns within the background
        if let bitmapRep = cellView.bitmapImageRepForCachingDisplay(in: cellView.bounds) {
            cellView.cacheDisplay(in: cellView.bounds, to: bitmapRep)
            let cellOrigin = NSPoint(x: -visualRect.origin.x, y: -visualRect.origin.y)
            bitmapRep.draw(in: NSRect(origin: cellOrigin, size: cellView.bounds.size))
        }

        image.unlockFocus()

        // Replace the dragging item's image with our rounded-corner version
        session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { draggingItem, _, _ in
            let origin = NSPoint(x: draggingItem.draggingFrame.origin.x - 6, y: draggingItem.draggingFrame.origin.y)
            draggingItem.setDraggingFrame(NSRect(origin: origin, size: imageSize), contents: image)
        }

        // Show favorites drop zone on active page
        if activePageIndex < spacePages.count {
            spacePages[activePageIndex].setDragSessionActive(true)
        }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Hide favorites drop zone
        if activePageIndex < spacePages.count {
            spacePages[activePageIndex].setDragSessionActive(false)
        }
        // Not gated on activePageIndex — the begin/end pair must always balance.
        delegate?.tabSidebar(self, dragSessionDidChangeActive: false)
        // mouseExited isn't delivered while a drag session is active, and rows shift
        // under the cursor to open the drop gap, so cells can be left with a stale
        // hover background — including on cancelled and no-op drops, where no model
        // change triggers a recheck. Re-evaluate now, and again after the drop /
        // slide-back animations settle.
        recheckHoverForVisibleCells()
        recheckHoverForVisibleCells(afterDelay: 0.35)
    }

    /// The pointer's position within the proposed row, for `.on` proposals on
    /// normal-tab rows — decides split-edge drops vs middle-band reorders.
    private func dropZone(for info: any NSDraggingInfo, tableView: NSTableView,
                          row: Int, dropOperation: NSTableView.DropOperation) -> RowDropZone? {
        guard dropOperation == .on, case .normalTab = sidebarRow(for: row) else { return nil }
        let rowRect = tableView.rect(ofRow: row)
        let point = tableView.convert(info.draggingLocation, from: nil)
        return rowDropZone(forX: point.x - rowRect.minX, y: point.y - rowRect.minY, rowSize: rowRect.size)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let kind: SidebarDragKind
        let sourceItemID: UUID?
        if let favorite = localFavoritePayload(from: info) {
            kind = .favorite
            sourceItemID = favorite.favoriteID
        } else if let payload = localDragPayload(from: info) {
            kind = SidebarDragKind(payload.kind)
            sourceItemID = payload.itemID
        } else {
            return []
        }

        let validation = validateSidebarDrop(
            kind: kind, sourceItemID: sourceItemID,
            row: sidebarRow(for: row),
            operation: dropOperation == .on ? .on : .above,
            items: flattenedPinnedItems,
            tabItems: tabItems,
            dropZone: dropZone(for: info, tableView: tableView, row: row, dropOperation: dropOperation)
        )
        if case .acceptIntoSplit = validation {} else { hideSplitDropOverlay() }
        switch validation {
        case .reject:
            return []
        case .accept:
            return .move
        case .acceptIntoSplit(let edge):
            showSplitDropOverlay(forRow: row, edge: edge)
            return .move
        case .retargetToPinnedGap(let index):
            tableView.setDropRow(rowForPinnedItem(at: index), dropOperation: .above)
            return .move
        case .retargetToNormalTabGap(let index):
            tableView.setDropRow(rowForNormalTab(at: index), dropOperation: .above)
            return .move
        }
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        hideSplitDropOverlay()
        let destRow = sidebarRow(for: row)
        let operation: SidebarDropOperation = dropOperation == .on ? .on : .above

        if let favorite = localFavoritePayload(from: info) {
            return acceptFavoriteDrop(favorite, row: destRow, operation: operation)
        }

        guard let payload = localDragPayload(from: info),
              let source = resolveDragSource(payload),
              let destination = sidebarDropDestination(
                  row: destRow, operation: operation, items: flattenedPinnedItems,
                  tabItems: tabItems,
                  dropZone: dropZone(for: info, tableView: tableView, row: row, dropOperation: dropOperation)
              ),
              let command = resolveSidebarDrop(source: source, destination: destination, items: flattenedPinnedItems)
        else { return false }

        switch command {
        // Single-delegate cases: let the observer's applyState animate directly.
        // Gap indices arrive in item space — convert to tab-array gaps for the
        // tab-index-based delegate methods (TabStore.moveTab / unpinTab).
        case .reorderNormalTab(let tabID, _, let gapIndex):
            delegate?.tabSidebar(self, didMoveTab: tabID, toGapIndex: tabGapIndex(forItemGap: gapIndex, in: tabItems))
        case .unpinEntry(let entryID, let gapIndex):
            delegate?.tabSidebar(self, didDragPinnedTabToUnpin: entryID, toGapIndex: tabGapIndex(forItemGap: gapIndex, in: tabItems))
        case .movePinnedEntry(let entryID, let folderID, let beforeItemID):
            delegate?.tabSidebar(self, didRequestMovePinnedTabToFolder: entryID,
                                 folderID: folderID, beforeItemID: beforeItemID)
        case .movePinnedFolder(let folderID, let parentFolderID, let beforeItemID):
            delegate?.tabSidebar(self, didRequestMovePinnedFolder: folderID,
                                 parentFolderID: parentFolderID, beforeItemID: beforeItemID)
        // Split create/break rewrite rows structurally (remove + insert, not just
        // moves). Issued synchronously they run while the drag session is still
        // live, which NSTableView does not survive (see applyPendingState) — the
        // aborted drop then strands the whole session mid-drag. The transaction
        // defers the table update past the session's end.
        case .createSplit(let draggedTabID, let targetTabID, let edge):
            performDropTransaction(selectTabID: selectedTabIDForCurrentRow()) {
                delegate?.tabSidebar(self, didRequestCreateSplit: draggedTabID, withTabID: targetTabID, edge: edge)
            }
        case .removeFromSplit(let tabID, let gapIndex):
            let tabGap = tabGapIndex(forItemGap: gapIndex, in: tabItems)
            performDropTransaction(selectTabID: selectedTabIDForCurrentRow()) {
                delegate?.tabSidebar(self, didRemoveTabFromSplit: tabID, toGapIndex: tabGap)
            }

        // Multi-delegate cases: defer intermediate updates, animate at the end
        case .pinTab(let tabID, let folderID, let beforeItemID):
            performDropTransaction(selectTabID: tabID) {
                delegate?.tabSidebar(self, didDragTabToPin: tabID)
                delegate?.tabSidebar(self, didRequestMovePinnedTabToFolder: tabID,
                                     folderID: folderID, beforeItemID: beforeItemID)
            }
        case .pinSplitGroup(let groupID, let firstMemberTabID, let folderID, let beforeItemID):
            // Pin the whole split, keeping the group (§12); the anchor move
            // then places the pair as a block (the store moves grouped entries
            // together).
            performDropTransaction(selectTabID: selectedTabIDForCurrentRow()) {
                delegate?.tabSidebar(self, didRequestPinSplitGroup: groupID)
                delegate?.tabSidebar(self, didRequestMovePinnedTabToFolder: firstMemberTabID,
                                     folderID: folderID, beforeItemID: beforeItemID)
            }
        case .movePinnedSplitGroup(_, let firstMemberEntryID, let folderID, let beforeItemID):
            // A pure row move (the split item's identity is its groupID) — the
            // store moves the pair as a block.
            delegate?.tabSidebar(self, didRequestMovePinnedTabToFolder: firstMemberEntryID,
                                 folderID: folderID, beforeItemID: beforeItemID)
        case .unpinSplitGroup(let groupID, let gapIndex):
            let tabGap = tabGapIndex(forItemGap: gapIndex, in: tabItems)
            performDropTransaction(selectTabID: selectedTabIDForCurrentRow()) {
                delegate?.tabSidebar(self, didRequestUnpinSplitGroup: groupID, toGapIndex: tabGap)
            }
        // Member break-outs rewrite the pinned split row structurally
        // (remove + insert) — defer past the drag session like the other
        // split create/break drops above.
        case .unpinSplitMember(let entryID, let gapIndex):
            let tabGap = tabGapIndex(forItemGap: gapIndex, in: tabItems)
            performDropTransaction(selectTabID: selectedTabIDForCurrentRow()) {
                delegate?.tabSidebar(self, didDragPinnedTabToUnpin: entryID, toGapIndex: tabGap)
            }
        case .removeFromPinnedSplit(let entryID, let folderID, let beforeItemID):
            performDropTransaction(selectTabID: selectedTabIDForCurrentRow()) {
                delegate?.tabSidebar(self, didRemovePinnedEntryFromSplit: entryID,
                                     folderID: folderID, beforeItemID: beforeItemID)
            }
        }
        return true
    }

    /// The tab whose row is currently selected, captured before a structural
    /// drop. Unlike moveRow, the remove+insert batch a split create/break
    /// produces does not carry row selection across, so the transaction
    /// re-selects this tab's (possibly merged or newly single) row afterwards.
    private func selectedTabIDForCurrentRow() -> UUID? {
        let row = tableView.selectedRow
        guard row >= 0 else { return nil }
        switch sidebarRow(for: row) {
        case .normalTab(let idx) where idx < tabItems.count:
            return representativeTab(for: tabItems[idx]).id
        case .pinnedItem(let idx) where idx < flattenedPinnedItems.count:
            let entries = flattenedPinnedItems[idx].entries
            guard !entries.isEmpty else { return nil }
            let rep = entries.count > 1 ? representativePinnedEntry(of: entries) : entries[0]
            return rep.tab?.id ?? rep.id
        default:
            return nil
        }
    }

    /// Highlights the half of `row` the split-edge drop targets. Geometry
    /// mirrors `TabCellView.hoverBackgroundFrame`: the visual row extends 6pt
    /// beyond the cell and each half stops 4pt short of the centered divider.
    private func showSplitDropOverlay(forRow row: Int, edge: SplitEdge) {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else {
            hideSplitDropOverlay()
            return
        }
        let visual = tableView.convert(cell.bounds.insetBy(dx: -6, dy: 1), from: cell)
        let frame = edge == .left
            ? NSRect(x: visual.minX, y: visual.minY, width: visual.midX - 4 - visual.minX, height: visual.height)
            : NSRect(x: visual.midX + 4, y: visual.minY, width: visual.maxX - (visual.midX + 4), height: visual.height)

        let overlay: NSView
        if let existing = splitDropOverlay {
            overlay = existing
        } else {
            overlay = NSView()
            overlay.wantsLayer = true
            overlay.layer?.cornerRadius = UIConstants.defaultCornerRadius
            overlay.layer?.borderWidth = UIConstants.splitDropAccentBorderWidth
            splitDropOverlay = overlay
        }
        overlay.layer?.backgroundColor = UIConstants.splitDropAccentFillColor.cgColor
        overlay.layer?.borderColor = UIConstants.splitDropAccentBorderColor.cgColor
        overlay.frame = frame
        if overlay.superview !== tableView {
            tableView.addSubview(overlay)
        }
    }

    private func hideSplitDropOverlay() {
        splitDropOverlay?.removeFromSuperview()
    }

    /// Handles a favorite tile dropped into the table (restore as tab or pinned entry).
    private func acceptFavoriteDrop(_ payload: FavoriteDragPayload, row destRow: SidebarRow, operation: SidebarDropOperation) -> Bool {
        guard activePageIndex < spacePages.count else { return false }
        let favBar = spacePages[activePageIndex].favoritesBar
        guard let favoriteIndex = favBar.index(ofFavoriteID: payload.favoriteID),
              let destination = sidebarDropDestination(row: destRow, operation: operation, items: flattenedPinnedItems)
        else { return false }

        let animOrigin: NSPoint? = favBar.tileFrame(at: favoriteIndex).map { frame in
            tableView.convert(NSPoint(x: frame.midX, y: frame.midY), from: favBar)
        }

        switch destination {
        case .beforeNormalTab(let gapIndex):
            pendingInsertionOrigin = animOrigin
            // gapIndex is an item-space gap; restore inserts into the tabs array.
            delegate?.tabSidebar(self, didDragFavorite: payload.favoriteID, toTabGapIndex: tabGapIndex(forItemGap: gapIndex, in: tabItems))
        case .beforePinnedItem(let flatIndex):
            dropFavoriteIntoPinned(favoriteID: payload.favoriteID,
                                   folderID: folderIDForFlattenedIndex(flatIndex),
                                   beforeItemID: itemIDAtDropIndex(flatIndex, in: flattenedPinnedItems),
                                   insertionOrigin: animOrigin)
        case .intoFolder(let folderID):
            dropFavoriteIntoPinned(favoriteID: payload.favoriteID, folderID: folderID,
                                   beforeItemID: nil, insertionOrigin: animOrigin)
        case .intoSplit:
            // Favorites never validate as split sources (and this path passes no
            // drop geometry, so the destination can't produce .intoSplit anyway).
            return false
        }
        return true
    }

    private func dropFavoriteIntoPinned(favoriteID: UUID, folderID: UUID?, beforeItemID: UUID?, insertionOrigin: NSPoint?) {
        let oldIDs = Set(pinnedEntries.map(\.id))
        performDropTransaction(insertionOrigin: insertionOrigin) {
            delegate?.tabSidebar(self, didDragFavorite: favoriteID, toPinnedAt: pinnedEntries.count)
            // The restore created a new entry; position it at the drop target
            if let newEntry = pendingState?.pinnedEntries.first(where: { !oldIDs.contains($0.id) }) {
                delegate?.tabSidebar(self, didRequestMovePinnedTabToFolder: newEntry.id, folderID: folderID, beforeItemID: beforeItemID)
            }
        }
    }

    private func folderIDForFlattenedIndex(_ index: Int) -> UUID? {
        folderIDForDropIndex(index, in: flattenedPinnedItems)
    }
}

// MARK: - NSTableViewDelegate

extension TabSidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let itemCount = pinnedItemCountForTableView(tableView)
        let sRow = sidebarRow(for: row, pinnedItemCount: itemCount)
        let isActive = tableView === self.tableView

        switch sRow {
        case .topSpacer:
            return NSView()
        case .newTab:
            let newTabID = NSUserInterfaceItemIdentifier("NewTabCell")
            if let existing = tableView.makeView(withIdentifier: newTabID, owner: nil) as? NewTabCellView {
                return existing
            }
            let cell = NewTabCellView()
            cell.identifier = newTabID
            return cell

        case .separator:
            let sepID = NSUserInterfaceItemIdentifier("SeparatorCell")
            if let existing = tableView.makeView(withIdentifier: sepID, owner: nil) as? SeparatorCellView {
                return existing
            }
            let cell = SeparatorCellView()
            cell.identifier = sepID
            return cell

        case .pinnedItem(let index):
            guard index < flattenedPinnedItems.count else { return makeTabCell(tableView) }
            let item = flattenedPinnedItems[index]
            switch item {
            case .entry(let entry, let depth):
                let cell = makeTabCell(tableView)
                let tab = entry.tab
                let title = entry.displayTitle
                let favicon = entry.displayFavicon
                let isLoading = tab?.isLoading ?? false
                let isSleeping = tab?.isSleeping ?? false
                let progress = tab?.estimatedProgress ?? 0
                let isPlayingAudio = tab?.isPlayingAudio ?? false
                let isMuted = tab?.isMuted ?? false
                cell.titleLabel.stringValue = title
                cell.toolTip = entry.pinnedTitle
                cell.updateFavicon(favicon)
                cell.updatePeekFavicon(tab?.displayPeekFavicon)
                cell.updateSplitPane(favicon: nil, title: nil)
                cell.updateSleeping(isSleeping || !entry.isLive)
                cell.updateLoading(isLoading)
                cell.updateProgress(progress)
                cell.updateAudio(isPlaying: isPlayingAudio, isMuted: isMuted)
                cell.updatePinnedMode(entry: entry)
                cell.indentLevel = depth
                if isActive {
                    cell.onClose = { [weak self] in
                        guard let self else { return }
                        let row = self.tableView.row(for: cell)
                        guard row >= 0, case .pinnedItem(let idx) = self.sidebarRow(for: row) else { return }
                        if case .entry(let e, _) = self.flattenedPinnedItems[idx] {
                            if let pinnedIdx = self.pinnedEntries.firstIndex(where: { $0.id == e.id }) {
                                self.delegate?.tabSidebar(self, didRequestClosePinnedTabAt: pinnedIdx)
                            }
                        }
                    }
                    cell.onToggleMute = { tab?.toggleMute() }
                } else {
                    cell.onClose = nil
                    cell.onToggleMute = nil
                }
                return cell
            case .folder(let folder, let depth):
                let cell = makeFolderCell(tableView)
                configureFolderCell(cell, folder: folder, depth: depth, isActive: isActive)
                return cell
            case .split(_, let entries, let depth):
                let cell = makeTabCell(tableView)
                configurePinnedSplitCell(cell, entries: entries, depth: depth, isActive: isActive)
                return cell
            }

        case .normalTab(let itemIndex):
            let items = tabItemsForTableView(tableView)
            guard itemIndex < items.count else { return makeTabCell(tableView) }
            let cell = makeTabCell(tableView)
            configureItemCell(cell, item: items[itemIndex], isActive: isActive)
            return cell
        }
    }

    private func makeTabCell(_ tableView: NSTableView) -> TabCellView {
        let cellID = NSUserInterfaceItemIdentifier("TabCell")
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? TabCellView {
            return existing
        }
        let cell = TabCellView()
        cell.identifier = cellID
        return cell
    }

    /// Configures a tab-section cell for a `TabListItem` (single tab or split row).
    private func configureItemCell(_ cell: TabCellView, item: TabListItem, isActive: Bool,
                                   animatedReveal: Bool = false,
                                   departingFavicon: NSImage? = nil, departingTitle: String? = nil) {
        switch item {
        case .single(let tab):
            configureTabCell(cell, tab: tab, title: tab.title, isActive: isActive,
                             animatedReveal: animatedReveal,
                             departingFavicon: departingFavicon,
                             departingTitle: departingTitle) { [weak self] row in
                guard let self, case .normalTab(let idx) = self.sidebarRow(for: row),
                      let tabIdx = firstTabIndex(forItemIndex: idx, in: self.tabItems) else { return }
                self.delegate?.tabSidebar(self, didRequestCloseTabAt: tabIdx)
            }
        case .split(_, let members):
            configureSplitCell(cell, item: item, members: members, isActive: isActive,
                               animatedReveal: animatedReveal)
        }
    }

    /// One half of a split row: favicon (globe fallback applied at render),
    /// title, and whether its title is emphasized (the focused/representative
    /// pane). Section-agnostic — normal and pinned adapters fill it from a
    /// `BrowserTab` or a `PinnedEntry` respectively.
    private struct SplitCellHalf {
        let favicon: NSImage?
        let title: String
        let emphasized: Bool
    }

    /// Section-agnostic description of a split row. The two-half rendering is
    /// shared; the section-specific semantics (title source, sleeping rule,
    /// pinned-mode close glyphs, indent, close handlers) are resolved by the
    /// adapters and passed in here.
    private struct SplitCellDescriptor {
        let left: SplitCellHalf
        let right: SplitCellHalf
        let tooltip: String
        let isSleeping: Bool
        let isLoading: Bool
        let progress: Double
        let audioIsPlaying: Bool
        let audioIsMuted: Bool
        let indentLevel: Int
        /// Applies the per-half close glyphs (normal xmark vs pinned live/dormant).
        let applyCloseGlyphs: (TabCellView) -> Void
        /// Closes the pane on `side` (0 = left, 1 = right) of the row hosting the cell.
        let closeMember: (TabCellView, Int) -> Void
        let onToggleMute: () -> Void
    }

    /// Renders a split group as one row of two equal halves — each member gets
    /// favicon + title on its side of a centered divider, in visual pane order,
    /// with the focused (representative) member's title emphasized. Loading/audio
    /// reflect any member; the row dims per the descriptor's sleeping rule; each
    /// half's close button closes its own pane. Shared by the normal and pinned
    /// split adapters below.
    private func configureSplitCell(_ cell: TabCellView, descriptor: SplitCellDescriptor, isActive: Bool,
                                    animatedReveal: Bool = false) {
        cell.titleLabel.stringValue = descriptor.left.title
        cell.titleLabel.textColor = descriptor.left.emphasized ? .labelColor : .secondaryLabelColor
        cell.toolTip = descriptor.tooltip
        cell.updateFavicon(descriptor.left.favicon)
        cell.updatePeekFavicon(nil)
        cell.updateSplitPane(favicon: descriptor.right.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website"),
                             title: descriptor.right.title,
                             emphasized: descriptor.right.emphasized,
                             animatedReveal: animatedReveal)
        cell.updateSleeping(descriptor.isSleeping)
        cell.updateLoading(descriptor.isLoading)
        cell.updateProgress(descriptor.progress)
        cell.updateAudio(isPlaying: descriptor.audioIsPlaying, isMuted: descriptor.audioIsMuted)
        descriptor.applyCloseGlyphs(cell)
        cell.indentLevel = descriptor.indentLevel
        if isActive {
            // Each half's close button closes its own pane (the group dissolves
            // in the store); the context menu's "Close Both Splits" covers the whole row.
            let closeMember = descriptor.closeMember
            cell.onCloseLeft = { closeMember(cell, 0) }
            cell.onClose = { closeMember(cell, 1) }
            cell.onToggleMute = descriptor.onToggleMute
        } else {
            cell.onClose = nil
            cell.onCloseLeft = nil
            cell.onToggleMute = nil
        }
    }

    /// Normal-section adapter: builds a split descriptor from live `BrowserTab`
    /// members. Titles and sleeping mirror the single normal-tab cell
    /// (`tab.title`, `tab.isSleeping`); close glyphs are plain xmarks.
    private func configureSplitCell(_ cell: TabCellView, item: TabListItem, members: [BrowserTab], isActive: Bool,
                                    animatedReveal: Bool = false) {
        let left = members[0]
        let right = members.count > 1 ? members[1] : members[0]
        let rep = representativeTab(for: item)
        let audioMember = members.first { $0.isPlayingAudio || $0.isMuted }
        let descriptor = SplitCellDescriptor(
            left: SplitCellHalf(favicon: left.favicon, title: left.title, emphasized: rep === left),
            right: SplitCellHalf(favicon: right.favicon, title: right.title, emphasized: rep === right),
            tooltip: "\(left.title) — \(right.title)",
            isSleeping: members.allSatisfy { $0.isSleeping },
            isLoading: members.contains { $0.isLoading },
            progress: members.map(\.estimatedProgress).max() ?? 0,
            audioIsPlaying: audioMember?.isPlayingAudio ?? false,
            audioIsMuted: audioMember?.isMuted ?? false,
            indentLevel: 0,
            applyCloseGlyphs: { $0.updatePinnedMode(entry: nil) },
            closeMember: { [weak self] cell, side in self?.closeSplitMember(of: cell, side: side) },
            onToggleMute: { audioMember?.toggleMute() }
        )
        configureSplitCell(cell, descriptor: descriptor, isActive: isActive, animatedReveal: animatedReveal)
    }

    /// Pinned-section adapter: builds a split descriptor from `PinnedEntry`
    /// members. Titles and sleeping mirror the single pinned-entry cell
    /// (`entry.displayTitle`, dormant when not live); close glyphs carry the
    /// pinned per-half semantics (live → dormant, dormant → delete entry).
    private func configurePinnedSplitCell(_ cell: TabCellView, entries: [PinnedEntry], depth: Int, isActive: Bool,
                                          animatedReveal: Bool = false) {
        let left = entries[0]
        let right = entries.count > 1 ? entries[1] : entries[0]
        let rep = representativePinnedEntry(of: entries)
        let audioTab = entries.compactMap(\.tab).first { $0.isPlayingAudio || $0.isMuted }
        let descriptor = SplitCellDescriptor(
            left: SplitCellHalf(favicon: left.displayFavicon, title: left.displayTitle, emphasized: rep === left),
            right: SplitCellHalf(favicon: right.displayFavicon, title: right.displayTitle, emphasized: rep === right),
            tooltip: "\(left.displayTitle) — \(right.displayTitle)",
            isSleeping: entries.allSatisfy { !$0.isLive || $0.tab?.isSleeping == true },
            isLoading: entries.contains { $0.tab?.isLoading == true },
            progress: entries.compactMap { $0.tab?.estimatedProgress }.max() ?? 0,
            audioIsPlaying: audioTab?.isPlayingAudio ?? false,
            audioIsMuted: audioTab?.isMuted ?? false,
            indentLevel: depth,
            applyCloseGlyphs: { $0.updateSplitPinnedMode(left: left, right: right) },
            closeMember: { [weak self] cell, side in self?.closePinnedSplitMember(of: cell, side: side) },
            onToggleMute: { audioTab?.toggleMute() }
        )
        configureSplitCell(cell, descriptor: descriptor, isActive: isActive, animatedReveal: animatedReveal)
    }

    /// The member that left a split whose row now continues as the survivor's
    /// single row (nil when the survivor wasn't in a split before). The
    /// collapse ghost must show this member — the right segment otherwise
    /// holds the old right pane's content, which is the survivor itself
    /// whenever the LEFT pane departed.
    private func departedSplitMember(survivorID: UUID, in oldItems: [TabListItem]) -> BrowserTab? {
        for case .split(_, let members) in oldItems where members.contains(where: { $0.id == survivorID }) {
            return members.first { $0.id != survivorID }
        }
        return nil
    }

    /// Pinned-section analog of `departedSplitMember`.
    private func departedPinnedSplitEntry(survivorID: UUID, in oldItems: [PinnedItem]) -> PinnedEntry? {
        for case .split(_, let entries, _) in oldItems where entries.contains(where: { $0.id == survivorID }) {
            return entries.first { $0.id != survivorID }
        }
        return nil
    }

    /// Closes one pane of the pinned split row hosting `cell`, through the
    /// ordinary per-entry pinned close path (live → dormant keeps the group;
    /// dormant → delete dissolves it).
    private func closePinnedSplitMember(of cell: TabCellView, side: Int) {
        let row = tableView.row(for: cell)
        guard row >= 0, case .pinnedItem(let idx) = sidebarRow(for: row),
              idx < flattenedPinnedItems.count,
              case .split(_, let entries, _) = flattenedPinnedItems[idx],
              side < entries.count,
              let pinnedIdx = pinnedEntries.firstIndex(where: { $0.id == entries[side].id }) else { return }
        delegate?.tabSidebar(self, didRequestClosePinnedTabAt: pinnedIdx)
    }

    /// Closes one pane of the split row hosting `cell`. Resolves the member at
    /// click time via the row (rows shift under cells), then routes through the
    /// ordinary single-tab close path — closing a member dissolves its group.
    private func closeSplitMember(of cell: TabCellView, side: Int) {
        let row = tableView.row(for: cell)
        guard row >= 0, case .normalTab(let idx) = sidebarRow(for: row),
              idx < tabItems.count, case .split(_, let members) = tabItems[idx],
              side < members.count,
              let tabIdx = tabs.firstIndex(where: { $0.id == members[side].id }) else { return }
        delegate?.tabSidebar(self, didRequestCloseTabAt: tabIdx)
    }

    private func configureTabCell(_ cell: TabCellView, tab: BrowserTab, title: String, isActive: Bool, indentLevel: Int = 0, animatedReveal: Bool = false, departingFavicon: NSImage? = nil, departingTitle: String? = nil, onClose: @escaping (Int) -> Void) {
        cell.titleLabel.stringValue = title
        cell.toolTip = tab.title
        cell.updateFavicon(tab.favicon)
        cell.updatePeekFavicon(tab.displayPeekFavicon)
        cell.updateSplitPane(favicon: nil, title: nil, animatedReveal: animatedReveal,
                             departingFavicon: departingFavicon, departingTitle: departingTitle)
        cell.updateSleeping(tab.isSleeping)
        cell.updateLoading(tab.isLoading)
        cell.updateProgress(tab.estimatedProgress)
        cell.updateAudio(isPlaying: tab.isPlayingAudio, isMuted: tab.isMuted)
        cell.updatePinnedMode(entry: nil)
        cell.indentLevel = indentLevel
        if isActive {
            cell.onClose = { [weak self] in
                guard let self else { return }
                let row = self.tableView.row(for: cell)
                guard row >= 0 else { return }
                onClose(row)
            }
            cell.onToggleMute = { tab.toggleMute() }
        } else {
            cell.onClose = nil
            cell.onToggleMute = nil
        }
    }

    private func makeFolderCell(_ tableView: NSTableView) -> FolderCellView {
        let cellID = NSUserInterfaceItemIdentifier("FolderCell")
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? FolderCellView {
            return existing
        }
        let cell = FolderCellView()
        cell.identifier = cellID
        return cell
    }

    private func configureFolderCell(_ cell: FolderCellView, folder: PinnedFolder, depth: Int, isActive: Bool) {
        cell.configure(name: folder.name, isCollapsed: folder.isCollapsed, depth: depth, color: safeTintColor)
        if isActive {
            cell.onToggleCollapse = { [weak self] in
                guard let self else { return }
                self.delegate?.tabSidebar(self, didTogglePinnedFolder: folder.id)
            }
        } else {
            cell.onToggleCollapse = nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let itemCount = pinnedItemCountForTableView(tableView)
        switch sidebarRow(for: row, pinnedItemCount: itemCount) {
        case .topSpacer: return 2
        case .separator: return 12
        default: return 36
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let itemCount = pinnedItemCountForTableView(tableView)
        switch sidebarRow(for: row, pinnedItemCount: itemCount) {
        case .topSpacer, .newTab, .separator:
            return NSTableRowView()
        default:
            let rowView = TabRowView()
            rowView.selectionColor = safeTintColor
            return rowView
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        let itemCount = pinnedItemCountForTableView(tableView)
        switch sidebarRow(for: row, pinnedItemCount: itemCount) {
        case .topSpacer, .separator: return false
        default: return true
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isBatchUpdating,
              let notifyingTable = notification.object as? NSTableView,
              notifyingTable === tableView else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }

        switch sidebarRow(for: row) {
        case .newTab:
            tableView.deselectRow(row)
            delegate?.tabSidebarDidRequestNewTab(self)
        case .pinnedItem(let index):
            guard index < flattenedPinnedItems.count else { break }
            switch flattenedPinnedItems[index] {
            case .entry(let entry, _):
                if let pinnedIdx = pinnedEntries.firstIndex(where: { $0.id == entry.id }) {
                    delegate?.tabSidebar(self, didSelectPinnedTabAt: pinnedIdx)
                }
            case .split(_, let entries, _):
                // Selecting a pinned split row selects its representative
                // member; the window applies its own focus memory on top.
                let rep = representativePinnedEntry(of: entries)
                if let pinnedIdx = pinnedEntries.firstIndex(where: { $0.id == rep.id }) {
                    delegate?.tabSidebar(self, didSelectPinnedTabAt: pinnedIdx)
                }
            case .folder(let folder, _):
                tableView.deselectRow(row)
                delegate?.tabSidebar(self, didTogglePinnedFolder: folder.id)
            }
        case .normalTab(let itemIdx):
            guard itemIdx < tabItems.count else { break }
            // The delegate API is tab-index-based; a split selects its representative member.
            let rep = representativeTab(for: tabItems[itemIdx])
            if let tabIdx = tabs.firstIndex(where: { $0.id == rep.id }) {
                delegate?.tabSidebar(self, didSelectTabAt: tabIdx)
            }
        case .topSpacer, .separator:
            break
        }
    }
}

// MARK: - Context Menu

extension TabSidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0 else {
            buildSpaceContextMenu(menu)
            return
        }

        let row = sidebarRow(for: clickedRow)
        let tabIndex: Int
        let isPinned: Bool

        switch row {
        case .pinnedItem(let index):
            guard index < flattenedPinnedItems.count else {
                buildSpaceContextMenu(menu)
                return
            }
            // Check if folder
            if case .folder(let folder, _) = flattenedPinnedItems[index] {
                buildFolderContextMenu(menu, folder: folder)
                return
            }
            // A pinned split row gets its own menu.
            if case .split(let groupID, let entries, _) = flattenedPinnedItems[index] {
                buildPinnedSplitContextMenu(menu, groupID: groupID, entries: entries)
                return
            }
            tabIndex = index
            isPinned = true
        case .normalTab(let itemIdx):
            guard itemIdx < tabItems.count else {
                buildSpaceContextMenu(menu)
                return
            }
            // A split row gets its own menu; a single resolves to its tab index.
            if case .split(let groupID, let members) = tabItems[itemIdx] {
                buildSplitContextMenu(menu, groupID: groupID, members: members)
                return
            }
            guard case .single(let singleTab) = tabItems[itemIdx],
                  let resolvedIndex = tabs.firstIndex(where: { $0.id == singleTab.id }) else {
                buildSpaceContextMenu(menu)
                return
            }
            tabIndex = resolvedIndex
            isPinned = false
        default:
            buildSpaceContextMenu(menu)
            return
        }

        contextMenuTabIsPinned = isPinned
        contextMenuFolderID = nil
        contextMenuSplitGroupID = nil

        let tab: BrowserTab?
        let entry: PinnedEntry?
        if isPinned {
            if case .entry(let e, _) = flattenedPinnedItems[tabIndex] {
                entry = e
                tab = e.tab
                contextMenuTabID = e.id
            } else {
                return
            }
        } else {
            tab = tabs[tabIndex]
            entry = nil
            contextMenuTabID = tab?.id
        }
        let isSelectedTab = clickedRow == tableView.selectedRow

        let tabURL = tab?.url ?? (isPinned ? entry?.pinnedURL : nil)

        // Copy URL / Copy Link
        if tabURL != nil {
            let copyItem = NSMenuItem(
                title: isSelectedTab ? "Copy URL" : "Copy Link",
                action: #selector(contextMenuCopyURL(_:)),
                keyEquivalent: isSelectedTab ? "C" : ""
            )
            if isSelectedTab {
                copyItem.keyEquivalentModifierMask = [.command, .shift]
            }
            copyItem.target = self
            menu.addItem(copyItem)
        }

        // Share submenu
        if let url = tabURL {
            let picker = NSSharingServicePicker(items: [url])
            menu.addItem(picker.standardShareMenuItem)
        }

        menu.addItem(.separator())

        // Duplicate
        if tabURL != nil {
            let dupItem = NSMenuItem(title: "Duplicate", action: #selector(contextMenuDuplicate(_:)), keyEquivalent: "")
            dupItem.target = self
            menu.addItem(dupItem)
        }

        // Move to Space submenu
        let spaces = delegate?.tabSidebarSpacesForContextMenu(self) ?? []
        if spaces.count > 1 {
            let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let moveMenu = NSMenu()
            for space in spaces {
                let spaceItem = NSMenuItem(
                    title: "\(space.emoji) \(space.name)",
                    action: #selector(contextMenuMoveToSpace(_:)),
                    keyEquivalent: ""
                )
                spaceItem.target = self
                spaceItem.representedObject = space.id
                if space.isCurrent {
                    spaceItem.state = .on
                }
                moveMenu.addItem(spaceItem)
            }
            moveItem.submenu = moveMenu
            menu.addItem(moveItem)
        }

        if !isIncognito {
            menu.addItem(.separator())

            if isPinned {
                let renameItem = NSMenuItem(title: "Rename…", action: #selector(contextMenuRenamePinnedTab(_:)), keyEquivalent: "")
                renameItem.target = self
                menu.addItem(renameItem)

                let unpinItem = NSMenuItem(title: "Unpin Tab", action: #selector(contextMenuUnpinTab(_:)), keyEquivalent: "")
                unpinItem.target = self
                menu.addItem(unpinItem)
            } else {
                if tabURL != nil {
                    let pinItem = NSMenuItem(title: "Pin Tab", action: #selector(contextMenuPinTab(_:)), keyEquivalent: "")
                    pinItem.target = self
                    menu.addItem(pinItem)
                }

                let archiveItem = NSMenuItem(title: "Archive Tab", action: #selector(contextMenuArchiveTab(_:)), keyEquivalent: "")
                archiveItem.target = self
                menu.addItem(archiveItem)

                let archiveBelowItem = NSMenuItem(title: "Archive Tabs Below", action: #selector(contextMenuArchiveTabsBelow(_:)), keyEquivalent: "")
                archiveBelowItem.target = self
                if tabIndex >= tabs.count - 1 {
                    archiveBelowItem.isEnabled = false
                }
                menu.addItem(archiveBelowItem)
            }
        }

        // Split with Next Tab: temporary creation path (real DnD lands in a later
        // phase). Only for a single normal tab with an ungrouped next tab.
        if !isPinned, tabIndex + 1 < tabs.count,
           tabs[tabIndex].splitGroupID == nil, tabs[tabIndex + 1].splitGroupID == nil {
            menu.addItem(.separator())
            let splitItem = NSMenuItem(title: "Split with Next Tab", action: #selector(contextMenuSplitWithNext(_:)), keyEquivalent: "")
            splitItem.target = self
            menu.addItem(splitItem)
        }
    }

    private func buildSplitContextMenu(_ menu: NSMenu, groupID: UUID, members: [BrowserTab]) {
        contextMenuTabIsPinned = false
        contextMenuFolderID = nil
        contextMenuSplitGroupID = groupID
        let rep = representativeTab(for: .split(groupID: groupID, members: members))
        contextMenuTabID = rep.id

        if rep.url != nil {
            let copyItem = NSMenuItem(title: "Copy URL", action: #selector(contextMenuCopyURL(_:)), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
            menu.addItem(.separator())
        }

        let separateItem = NSMenuItem(title: "Separate Tabs", action: #selector(contextMenuSeparateSplit(_:)), keyEquivalent: "")
        separateItem.target = self
        menu.addItem(separateItem)

        let closeItem = NSMenuItem(title: "Close Both Splits", action: #selector(contextMenuCloseSplit(_:)), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
    }

    /// Context menu for a pinned split row: Copy URL (representative member) and
    /// Separate Tabs (the entries stay adjacent as two pinned rows). Per-half
    /// close lives on the row's hover buttons; unpin happens by drag.
    private func buildPinnedSplitContextMenu(_ menu: NSMenu, groupID: UUID, entries: [PinnedEntry]) {
        contextMenuTabIsPinned = true
        contextMenuFolderID = nil
        contextMenuSplitGroupID = groupID
        let rep = representativePinnedEntry(of: entries)
        contextMenuTabID = rep.id

        let copyItem = NSMenuItem(title: "Copy URL", action: #selector(contextMenuCopyURL(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(.separator())

        let separateItem = NSMenuItem(title: "Separate Tabs", action: #selector(contextMenuSeparatePinnedSplit(_:)), keyEquivalent: "")
        separateItem.target = self
        menu.addItem(separateItem)
    }

    @objc private func contextMenuSeparatePinnedSplit(_ sender: NSMenuItem) {
        guard let groupID = contextMenuSplitGroupID else { return }
        delegate?.tabSidebar(self, didRequestSeparatePinnedSplit: groupID)
    }

    @objc private func contextMenuSeparateSplit(_ sender: NSMenuItem) {
        guard let groupID = contextMenuSplitGroupID else { return }
        delegate?.tabSidebar(self, didRequestSeparateSplit: groupID)
    }

    @objc private func contextMenuCloseSplit(_ sender: NSMenuItem) {
        guard let groupID = contextMenuSplitGroupID else { return }
        delegate?.tabSidebar(self, didRequestCloseSplitGroup: groupID)
    }

    @objc private func contextMenuSplitWithNext(_ sender: NSMenuItem) {
        guard let tab = contextMenuTab else { return }
        delegate?.tabSidebar(self, didRequestSplitWithNextTab: tab.id)
    }

    @objc private func contextMenuCopyURL(_ sender: NSMenuItem) {
        let url: URL?
        if let entry = contextMenuPinnedEntry {
            url = entry.tab?.url ?? entry.pinnedURL
        } else {
            url = contextMenuTab?.url
        }
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func contextMenuDuplicate(_ sender: NSMenuItem) {
        guard let index = contextMenuResolvedIndex else { return }
        delegate?.tabSidebar(self, didRequestDuplicateTabAt: index, isPinned: contextMenuTabIsPinned)
    }

    @objc private func contextMenuMoveToSpace(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? UUID,
              let index = contextMenuResolvedIndex else { return }
        delegate?.tabSidebar(self, didRequestMoveTabAt: index, isPinned: contextMenuTabIsPinned, toSpaceID: spaceID)
    }

    @objc private func contextMenuPinTab(_ sender: NSMenuItem) {
        guard let index = contextMenuResolvedIndex else { return }
        delegate?.tabSidebar(self, didRequestPinTabAt: index)
    }

    @objc private func contextMenuUnpinTab(_ sender: NSMenuItem) {
        guard let index = contextMenuResolvedIndex else { return }
        delegate?.tabSidebar(self, didRequestUnpinTabAt: index)
    }

    @objc private func contextMenuRenamePinnedTab(_ sender: NSMenuItem) {
        guard let entry = contextMenuPinnedEntry else { return }
        guard let flatIdx = flattenedPinnedItems.firstIndex(where: {
            if case .entry(let e, _) = $0, e.id == entry.id { return true }
            return false
        }) else { return }
        let row = rowForPinnedItem(at: flatIdx)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCellView else { return }
        cell.titleLabel.stringValue = entry.pinnedTitle
        cell.onRename = { [weak self] newName in
            guard let self else { return }
            self.delegate?.tabSidebar(self, didRequestRenamePinnedTab: entry.id, newName: newName)
        }
        cell.beginEditing()
    }

    @objc private func contextMenuArchiveTab(_ sender: NSMenuItem) {
        guard let index = contextMenuResolvedIndex, !contextMenuTabIsPinned else { return }
        delegate?.tabSidebar(self, didRequestArchiveTabAt: index)
    }

    @objc private func contextMenuArchiveTabsBelow(_ sender: NSMenuItem) {
        guard let index = contextMenuResolvedIndex, !contextMenuTabIsPinned else { return }
        delegate?.tabSidebar(self, didRequestArchiveTabsBelowIndex: index)
    }

    @objc private func contextMenuNewFolder(_ sender: NSMenuItem) {
        let parentID = sender.representedObject as? UUID
        delegate?.tabSidebar(self, didRequestNewFolderIn: parentID)
    }

    @objc private func contextMenuRenameFolder(_ sender: NSMenuItem) {
        guard let folderID = contextMenuFolderID else { return }
        guard let flatIdx = flattenedPinnedItems.firstIndex(where: {
            if case .folder(let f, _) = $0, f.id == folderID { return true }
            return false
        }) else { return }
        let row = rowForPinnedItem(at: flatIdx)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FolderCellView else { return }
        cell.onRename = { [weak self] newName in
            self?.delegate?.tabSidebar(self!, didRequestRenamePinnedFolder: folderID, newName: newName)
        }
        cell.beginEditing()
    }

    @objc private func contextMenuDeleteFolder(_ sender: NSMenuItem) {
        guard let folderID = contextMenuFolderID else { return }
        delegate?.tabSidebar(self, didRequestDeletePinnedFolder: folderID)
    }

    private func buildFolderContextMenu(_ menu: NSMenu, folder: PinnedFolder) {
        contextMenuFolderID = folder.id

        let newFolderItem = NSMenuItem(title: "New Nested Folder", action: #selector(contextMenuNewFolder(_:)), keyEquivalent: "")
        newFolderItem.target = self
        newFolderItem.representedObject = folder.id
        menu.addItem(newFolderItem)

        let renameItem = NSMenuItem(title: "Rename…", action: #selector(contextMenuRenameFolder(_:)), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete Folder", action: #selector(contextMenuDeleteFolder(_:)), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)
    }

    private func buildSpaceContextMenu(_ menu: NSMenu) {
        guard !isIncognito, activeSpaceID != nil else { return }

        let editItem = NSMenuItem(title: "Edit Space…", action: #selector(editSpaceClicked(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.tag = activePageIndex

        let deleteItem = NSMenuItem(title: "Delete Space", action: #selector(deleteSpaceClicked(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.tag = activePageIndex

        menu.addItem(editItem)
        menu.addItem(deleteItem)
        menu.addItem(.separator())

        let folderItem = NSMenuItem(title: "New Folder", action: #selector(contextMenuNewFolder(_:)), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)
    }
}

// MARK: - FavoritesBarDelegate

extension TabSidebarViewController: FavoritesBarDelegate {
    func favoritesBar(_ bar: FavoritesBarView, didReceiveDropOfTab payload: SidebarDragPayload, at index: Int) {
        guard payload.spaceID == activeSpaceID else { return }

        let sourceRow: Int?
        let isPinned: Bool
        switch payload.kind {
        case .normalTab:
            sourceRow = itemIndex(containingTabID: payload.itemID, in: tabItems).map { rowForNormalTab(at: $0) }
            isPinned = false
        case .pinnedEntry:
            sourceRow = flattenedPinnedItems.firstIndex { pinnedItemID($0) == payload.itemID }.map(rowForPinnedItem)
            isPinned = true
        case .pinnedFolder, .splitGroup, .splitMember, .pinnedSplitGroup, .pinnedSplitMember:
            // FavoritesBarView already rejects these at the drop gate; defense here too.
            return
        }

        // Capture the source row's position so the new tile can animate from it
        if let sourceRow {
            let rowRect = tableView.rect(ofRow: sourceRow)
            if !rowRect.isEmpty {
                let rowCenter = NSPoint(x: rowRect.midX, y: rowRect.midY)
                bar.setAnimationOrigin(bar.convert(rowCenter, from: tableView))
            }
        }
        delegate?.tabSidebar(self, didDragTabToFavorite: payload.itemID, isPinned: isPinned, at: index)
    }

    func favoritesBar(_ bar: FavoritesBarView, didClickFavoriteAt index: Int) {
        delegate?.tabSidebar(self, didClickFavoriteAt: index)
    }

    func favoritesBar(_ bar: FavoritesBarView, didDoubleClickFavoriteAt index: Int) {
        delegate?.tabSidebar(self, didDoubleClickFavoriteAt: index)
    }

    func favoritesBar(_ bar: FavoritesBarView, didReorderFavoriteFrom sourceIndex: Int, to destinationIndex: Int) {
        delegate?.tabSidebar(self, didReorderFavoriteFrom: sourceIndex, to: destinationIndex)
    }

    func favoritesBar(_ bar: FavoritesBarView, didRemoveFavoriteAt index: Int) {
        delegate?.tabSidebar(self, didRemoveFavoriteAt: index)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
