import AppKit

protocol TabSidebarDelegate: AnyObject {
    func tabSidebarDidRequestNewTab(_ sidebar: TabSidebarViewController)
    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectTabAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseTabAt index: Int)
    func tabSidebarDidRequestGoBack(_ sidebar: TabSidebarViewController)
    func tabSidebarDidRequestGoForward(_ sidebar: TabSidebarViewController)
    func tabSidebarDidRequestReload(_ sidebar: TabSidebarViewController)
    func tabSidebarDidRequestOpenCommandPalette(_ sidebar: TabSidebarViewController, anchorFrame: NSRect)
    func tabSidebarDidRequestToggleSidebar(_ sidebar: TabSidebarViewController)
    func tabSidebar(_ sidebar: TabSidebarViewController, didMoveTabFrom sourceIndex: Int, to destinationIndex: Int)
    func tabSidebarDidRequestSwitchToSpace(_ sidebar: TabSidebarViewController, spaceID: UUID)
    func tabSidebarDidRequestAddSpace(_ sidebar: TabSidebarViewController, sourceButton: NSButton)
    func tabSidebarDidRequestEditSpace(_ sidebar: TabSidebarViewController, spaceID: UUID, sourceButton: NSButton)
    func tabSidebarDidRequestDeleteSpace(_ sidebar: TabSidebarViewController, spaceID: UUID)
}

class DraggableTableView: NSTableView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func dragImageForRows(with dragRows: IndexSet, tableColumns: [NSTableColumn], event: NSEvent, offset dragImageOffset: NSPointPointer) -> NSImage {
        let image = super.dragImageForRows(with: dragRows, tableColumns: tableColumns, event: event, offset: dragImageOffset)
        guard let row = dragRows.first else { return image }
        let rowRect = rect(ofRow: row)
        let mouseInTable = convert(event.locationInWindow, from: nil)
        dragImageOffset.pointee = NSPoint(
            x: mouseInTable.x - rowRect.origin.x,
            y: mouseInTable.y - rowRect.origin.y
        )
        return image
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 {
            super.mouseDown(with: event)
        } else {
            window?.performDrag(with: event)
        }
    }
}

class DraggableScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { true }

    /// Return `true` to consume the event (suppress vertical scrolling).
    var onScrollWheel: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if onScrollWheel?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

class DraggableClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private class DraggableBarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private let tabReorderPasteboardType = NSPasteboard.PasteboardType("com.mybrowser.tab-reorder")

class TabSidebarViewController: NSViewController {
    weak var delegate: TabSidebarDelegate?
    var isIncognito = false

    // Active page views — updated by updateActivePage()
    private(set) var tableView = DraggableTableView()
    private var scrollView = DraggableScrollView()

    private(set) var fauxAddressBar = FauxAddressBar()
    private(set) var backButton = NSButton()
    private(set) var forwardButton = NSButton()
    private(set) var reloadButton = NSButton()
    private(set) var sidebarToggleButton = NSButton()

    private var suppressReload = false
    private var bottomBar = DraggableBarView()
    private var spaceButtonsContainer = NSStackView()
    private var addSpaceButton = NSButton()
    private var isAnimatingSwipe = false

    // Page strip: all spaces laid out side-by-side, clipped by pageClipView
    private let pageClipView = NSView()
    private let pageStripView = NSView()
    private var pageScrollViews: [DraggableScrollView] = []
    private var pageTableViews: [DraggableTableView] = []
    private var pageSpaceIDs: [UUID] = []
    private var activePageIndex = 0

    var activeSpaceID: UUID? {
        didSet { updateActivePage() }
    }

    var tabs: [BrowserTab] = [] {
        didSet {
            if !suppressReload { tableView.reloadData() }
        }
    }

    var tintColor: NSColor? {
        didSet {
            view.wantsLayer = true
            if let color = tintColor {
                view.layer?.backgroundColor = color.withAlphaComponent(0.1).cgColor
            } else {
                view.layer?.backgroundColor = nil
            }
            tableView.enumerateAvailableRowViews { rowView, _ in
                (rowView as? TabRowView)?.selectionColor = tintColor
            }
        }
    }

    var selectedTabIndex: Int {
        get { tableView.selectedRow - 1 }
        set {
            guard newValue >= 0, newValue < tabs.count else { return }
            tableView.selectRowIndexes(IndexSet(integer: newValue + 1), byExtendingSelection: false)
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

        // Bottom bar for spaces
        bottomBar.wantsLayer = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        // Space buttons container (centered)
        spaceButtonsContainer.orientation = .horizontal
        spaceButtonsContainer.spacing = 4
        spaceButtonsContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(spaceButtonsContainer)

        // Add space button
        addSpaceButton = NSButton()
        addSpaceButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Space")
        addSpaceButton.bezelStyle = .inline
        addSpaceButton.isBordered = false
        addSpaceButton.imagePosition = .imageOnly
        addSpaceButton.target = self
        addSpaceButton.action = #selector(addSpaceClicked)
        addSpaceButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(addSpaceButton)

        NSLayoutConstraint.activate([
            spaceButtonsContainer.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            spaceButtonsContainer.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor, constant: 0.5),

            addSpaceButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            addSpaceButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor, constant: 0.5),
            addSpaceButton.widthAnchor.constraint(equalToConstant: 24),
            addSpaceButton.heightAnchor.constraint(equalToConstant: 24),
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

        NSLayoutConstraint.activate([
            // Sidebar toggle button: in title bar area, right of traffic lights
            sidebarToggleButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            sidebarToggleButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 74),

            // Nav buttons: pinned to top of view (title bar area), right-aligned
            navStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            navStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            navStack.heightAnchor.constraint(equalToConstant: 24),

            // Address field: below title bar area
            fauxAddressBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 38),
            fauxAddressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            fauxAddressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            // Page clip: below address field, above bottom bar
            fauxAddressBar.heightAnchor.constraint(equalToConstant: 34),

            pageClipView.topAnchor.constraint(equalTo: fauxAddressBar.bottomAnchor, constant: 8),
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

    override func viewDidLayout() {
        super.viewDidLayout()
        relayoutPages()
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
        for sv in pageScrollViews { sv.removeFromSuperview() }
        pageScrollViews.removeAll()
        pageTableViews.removeAll()

        // Build one scroll view + table view per space
        for _ in spaces {
            let tv = DraggableTableView()
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TabColumn"))
            tv.addTableColumn(column)
            tv.headerView = nil
            tv.rowHeight = 36
            tv.style = .sourceList
            tv.dataSource = self
            tv.delegate = self
            tv.registerForDraggedTypes([tabReorderPasteboardType])
            tv.draggingDestinationFeedbackStyle = .sourceList

            let sv = DraggableScrollView()
            sv.contentView = DraggableClipView()
            sv.documentView = tv
            sv.hasVerticalScroller = true
            sv.horizontalScrollElasticity = .none
            sv.drawsBackground = false
            sv.onScrollWheel = { [weak self] in self?.handleSpaceSwipe($0) ?? false }

            pageStripView.addSubview(sv)
            pageScrollViews.append(sv)
            pageTableViews.append(tv)
        }

        relayoutPages()
        updateActivePage()

        // Reload all non-active pages from TabStore
        for (i, tv) in pageTableViews.enumerated() where i != activePageIndex {
            tv.reloadData()
        }
    }

    private func relayoutPages() {
        let pageW = pageClipView.bounds.width
        let pageH = pageClipView.bounds.height
        guard pageW > 0 else { return }

        for (i, sv) in pageScrollViews.enumerated() {
            sv.frame = NSRect(x: CGFloat(i) * pageW, y: 0, width: pageW, height: pageH)
        }
        pageStripView.frame = NSRect(
            x: -CGFloat(activePageIndex) * pageW,
            y: 0,
            width: CGFloat(max(1, pageScrollViews.count)) * pageW,
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
        guard newIndex < pageScrollViews.count else { return }

        activePageIndex = newIndex
        scrollView = pageScrollViews[newIndex]
        tableView = pageTableViews[newIndex]

        // Snap strip to active page (no animation)
        let pageW = pageClipView.bounds.width
        if pageW > 0 {
            pageStripView.frame.origin.x = -CGFloat(newIndex) * pageW
        }
    }

    func updateSpaceButtons(spaces: [Space], activeSpaceID: UUID?) {
        // Remove old buttons
        for view in spaceButtonsContainer.arrangedSubviews {
            spaceButtonsContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Hide "Add Space" button in incognito mode
        addSpaceButton.isHidden = isIncognito

        for space in spaces {
            let button = NSButton()
            button.title = space.emoji
            button.font = .systemFont(ofSize: 14)
            button.bezelStyle = .inline
            button.isBordered = false
            button.target = self
            button.action = #selector(spaceButtonClicked(_:))
            button.tag = spaces.firstIndex(where: { $0.id == space.id }) ?? 0
            button.toolTip = isIncognito ? "Private Browsing" : space.name
            button.wantsLayer = true

            if space.id == activeSpaceID {
                button.layer?.backgroundColor = space.color.withAlphaComponent(0.15).cgColor
                button.layer?.cornerRadius = 6
            }

            // No context menu in incognito mode
            if !isIncognito {
                let menu = NSMenu()
                let editItem = NSMenuItem(title: "Edit Space…", action: #selector(editSpaceClicked(_:)), keyEquivalent: "")
                editItem.target = self
                editItem.tag = button.tag
                let deleteItem = NSMenuItem(title: "Delete Space", action: #selector(deleteSpaceClicked(_:)), keyEquivalent: "")
                deleteItem.target = self
                deleteItem.tag = button.tag
                menu.addItem(editItem)
                menu.addItem(deleteItem)
                button.menu = menu
            }

            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])

            spaceButtonsContainer.addArrangedSubview(button)
        }

        rebuildPages()
    }

    private func makeNavButton(symbolName: String, accessibilityLabel: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
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

    private func animateToSpace(id: UUID) {
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
    }

    @objc private func addSpaceClicked() {
        delegate?.tabSidebarDidRequestAddSpace(self, sourceButton: addSpaceButton)
    }

    @objc private func editSpaceClicked(_ sender: NSMenuItem) {
        let spaces = relevantSpaces
        guard sender.tag >= 0, sender.tag < spaces.count else { return }
        let spaceID = spaces[sender.tag].id
        let button = spaceButtonsContainer.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .first { $0.tag == sender.tag } ?? addSpaceButton
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
        let minX = -CGFloat(max(0, pageScrollViews.count - 1)) * pageW

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
                targetPage = min(pageScrollViews.count - 1, activePageIndex + 1)
            }
        } else {
            targetPage = Int(round(fractionalPage)).clamped(to: 0...(max(0, pageScrollViews.count - 1)))
        }

        let targetX = -CGFloat(targetPage) * pageW
        let distance = abs(pageStripView.frame.origin.x - targetX)
        let duration = min(0.25, max(0.08, Double(distance / pageW) * 0.25))

        isAnimatingSwipe = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var frame = pageStripView.frame
            frame.origin.x = targetX
            pageStripView.animator().frame = frame
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isAnimatingSwipe = false

            if targetPage != self.activePageIndex {
                let spaces = self.relevantSpaces
                guard targetPage < spaces.count else { return }
                self.delegate?.tabSidebarDidRequestSwitchToSpace(self, spaceID: spaces[targetPage].id)
            } else if let startColor = self.swipeStartTintColor {
                // Cancelled — restore original tint
                self.view.layer?.backgroundColor = startColor.withAlphaComponent(0.1).cgColor
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

    private func tabsForTableView(_ tv: NSTableView) -> [BrowserTab] {
        guard let index = pageTableViews.firstIndex(where: { $0 === tv }) else { return tabs }
        if index == activePageIndex { return tabs }
        let spaces = relevantSpaces
        guard index < spaces.count else { return [] }
        return spaces[index].tabs
    }

    func reloadTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index + 1), columnIndexes: IndexSet(integer: 0))
    }
}

// MARK: - NSTableViewDataSource

extension TabSidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tabsForTableView(tableView).count + 1
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === self.tableView, row >= 1 else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: tabReorderPasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above, row >= 1 else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard row >= 1,
              let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowString = item.string(forType: tabReorderPasteboardType),
              let sourceRow = Int(rowString),
              sourceRow >= 1 else { return false }

        let destinationRow = sourceRow < row ? row - 1 : row
        guard sourceRow != destinationRow else { return false }

        tableView.beginUpdates()
        tableView.moveRow(at: sourceRow, to: destinationRow)
        tableView.endUpdates()

        suppressReload = true
        delegate?.tabSidebar(self, didMoveTabFrom: sourceRow - 1, to: row - 1)
        suppressReload = false
        return true
    }
}

// MARK: - NSTableViewDelegate

extension TabSidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == 0 {
            let newTabID = NSUserInterfaceItemIdentifier("NewTabCell")
            if let existing = tableView.makeView(withIdentifier: newTabID, owner: nil) as? NewTabCellView {
                return existing
            }
            let cell = NewTabCellView()
            cell.identifier = newTabID
            return cell
        }

        let tabsForTable = tabsForTableView(tableView)
        let tabIndex = row - 1
        let isActive = tableView === self.tableView

        let cellID = NSUserInterfaceItemIdentifier("TabCell")
        let cell: TabCellView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? TabCellView {
            cell = existing
        } else {
            cell = TabCellView()
            cell.identifier = cellID
        }

        guard tabIndex < tabsForTable.count else { return cell }
        let tab = tabsForTable[tabIndex]
        cell.titleLabel.stringValue = tab.title
        cell.toolTip = tab.title
        cell.updateFavicon(tab.favicon)
        cell.updateLoading(tab.isLoading)
        cell.updateProgress(tab.estimatedProgress)
        cell.updateAudio(isPlaying: tab.isPlayingAudio, isMuted: tab.isMuted)
        if isActive {
            cell.onClose = { [weak self] in
                guard let self else { return }
                self.delegate?.tabSidebar(self, didRequestCloseTabAt: tabIndex)
            }
            cell.onToggleMute = { tab.toggleMute() }
        } else {
            cell.onClose = nil
            cell.onToggleMute = nil
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if row == 0 { return NSTableRowView() }
        let rowView = TabRowView()
        rowView.selectionColor = tintColor
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let notifyingTable = notification.object as? NSTableView,
              notifyingTable === tableView else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        if row == 0 {
            tableView.deselectRow(0)
            delegate?.tabSidebarDidRequestNewTab(self)
            return
        }
        delegate?.tabSidebar(self, didSelectTabAt: row - 1)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
