import AppKit

protocol TabSidebarDelegate: AnyObject {
    func tabSidebarDidRequestNewTab(_ sidebar: TabSidebarViewController)
    func tabSidebar(_ sidebar: TabSidebarViewController, didSelectTabAt index: Int)
    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestCloseTabAt index: Int)
    func tabSidebarDidRequestGoBack(_ sidebar: TabSidebarViewController)
    func tabSidebarDidRequestGoForward(_ sidebar: TabSidebarViewController)
    func tabSidebarDidRequestReload(_ sidebar: TabSidebarViewController)
    func tabSidebar(_ sidebar: TabSidebarViewController, didSubmitAddressInput input: String)
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

    var onScrollWheel: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?(event)
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

    private(set) var tableView = DraggableTableView()
    private let scrollView = DraggableScrollView()
    private(set) var addressField = NSTextField()
    private(set) var backButton = NSButton()
    private(set) var forwardButton = NSButton()
    private(set) var reloadButton = NSButton()
    private(set) var sidebarToggleButton = NSButton()

    private var suppressReload = false
    private var bottomBar = DraggableBarView()
    private var spaceButtonsContainer = NSStackView()
    private var addSpaceButton = NSButton()
    private var isAnimatingSwipe = false

    var activeSpaceID: UUID?

    var tabs: [BrowserTab] = [] {
        didSet {
            if !suppressReload { tableView.reloadData() }
        }
    }

    var tintColor: NSColor? {
        didSet {
            view.wantsLayer = true
            if let color = tintColor {
                view.layer?.backgroundColor = color.withAlphaComponent(0.05).cgColor
            } else {
                view.layer?.backgroundColor = nil
            }
        }
    }

    var selectedTabIndex: Int {
        get { tableView.selectedRow }
        set {
            guard newValue >= 0, newValue < tabs.count else { return }
            tableView.selectRowIndexes(IndexSet(integer: newValue), byExtendingSelection: false)
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

        // Address field
        addressField.placeholderString = "Enter URL or search"
        addressField.font = .systemFont(ofSize: NSFont.systemFontSize)
        addressField.target = self
        addressField.action = #selector(addressFieldSubmitted(_:))
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.bezelStyle = .roundedBezel
        addressField.translatesAutoresizingMaskIntoConstraints = false

        // Tab list
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TabColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 36
        tableView.style = .sourceList
        tableView.registerForDraggedTypes([tabReorderPasteboardType])
        tableView.draggingDestinationFeedbackStyle = .sourceList

        scrollView.contentView = DraggableClipView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // New Tab button (styled like a tab cell)
        let newTabButton = HoverButton(frame: .zero)
        newTabButton.isBordered = false
        newTabButton.title = ""
        newTabButton.target = self
        newTabButton.action = #selector(addTabClicked)
        newTabButton.translatesAutoresizingMaskIntoConstraints = false

        let plusIcon = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")!)
        plusIcon.translatesAutoresizingMaskIntoConstraints = false

        let newTabLabel = NSTextField(labelWithString: "New Tab")
        newTabLabel.lineBreakMode = .byTruncatingTail
        newTabLabel.translatesAutoresizingMaskIntoConstraints = false

        newTabButton.addSubview(plusIcon)
        newTabButton.addSubview(newTabLabel)

        NSLayoutConstraint.activate([
            plusIcon.leadingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: 20),
            plusIcon.centerYAnchor.constraint(equalTo: newTabButton.centerYAnchor),
            plusIcon.widthAnchor.constraint(equalToConstant: 16),
            plusIcon.heightAnchor.constraint(equalToConstant: 16),

            newTabLabel.leadingAnchor.constraint(equalTo: plusIcon.trailingAnchor, constant: 8),
            newTabLabel.centerYAnchor.constraint(equalTo: newTabButton.centerYAnchor),
            newTabLabel.trailingAnchor.constraint(lessThanOrEqualTo: newTabButton.trailingAnchor, constant: -4),
        ])

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

        container.addSubview(sidebarToggleButton)
        container.addSubview(navStack)
        container.addSubview(addressField)
        container.addSubview(newTabButton)
        container.addSubview(scrollView)
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
            addressField.topAnchor.constraint(equalTo: container.topAnchor, constant: 38),
            addressField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            // New Tab button: below address field
            newTabButton.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: 8),
            newTabButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            newTabButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            newTabButton.heightAnchor.constraint(equalToConstant: 36),

            // Tab list: below new tab button, above bottom bar
            scrollView.topAnchor.constraint(equalTo: newTabButton.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            // Bottom bar: pinned to bottom
            bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 32),
        ])

        scrollView.onScrollWheel = { [weak self] in self?.handleSpaceSwipe($0) }

        container.allowedTouchTypes = .indirect
        self.view = container
    }

    func updateSpaceButtons(spaces: [Space], activeSpaceID: UUID?) {
        // Remove old buttons
        for view in spaceButtonsContainer.arrangedSubviews {
            spaceButtonsContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for space in spaces {
            let button = NSButton()
            button.title = space.emoji
            button.font = .systemFont(ofSize: 14)
            button.bezelStyle = .inline
            button.isBordered = false
            button.target = self
            button.action = #selector(spaceButtonClicked(_:))
            button.tag = spaces.firstIndex(where: { $0.id == space.id }) ?? 0
            button.toolTip = space.name
            button.wantsLayer = true

            if space.id == activeSpaceID {
                button.layer?.backgroundColor = space.color.withAlphaComponent(0.15).cgColor
                button.layer?.cornerRadius = 6
            }

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

            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])

            spaceButtonsContainer.addArrangedSubview(button)
        }
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

    @objc private func addressFieldSubmitted(_ sender: NSTextField) {
        delegate?.tabSidebar(self, didSubmitAddressInput: sender.stringValue)
    }

    @objc private func addTabClicked() {
        delegate?.tabSidebarDidRequestNewTab(self)
    }

    @objc private func toggleSidebarClicked() {
        delegate?.tabSidebarDidRequestToggleSidebar(self)
    }

    @objc private func spaceButtonClicked(_ sender: NSButton) {
        let spaces = TabStore.shared.spaces
        guard sender.tag >= 0, sender.tag < spaces.count else { return }
        let spaceID = spaces[sender.tag].id
        delegate?.tabSidebarDidRequestSwitchToSpace(self, spaceID: spaceID)
    }

    @objc private func addSpaceClicked() {
        delegate?.tabSidebarDidRequestAddSpace(self, sourceButton: addSpaceButton)
    }

    @objc private func editSpaceClicked(_ sender: NSMenuItem) {
        let spaces = TabStore.shared.spaces
        guard sender.tag >= 0, sender.tag < spaces.count else { return }
        let spaceID = spaces[sender.tag].id
        // Find the corresponding button in the container
        let button = spaceButtonsContainer.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .first { $0.tag == sender.tag } ?? addSpaceButton
        delegate?.tabSidebarDidRequestEditSpace(self, spaceID: spaceID, sourceButton: button)
    }

    @objc private func deleteSpaceClicked(_ sender: NSMenuItem) {
        let spaces = TabStore.shared.spaces
        guard sender.tag >= 0, sender.tag < spaces.count else { return }
        let spaceID = spaces[sender.tag].id
        delegate?.tabSidebarDidRequestDeleteSpace(self, spaceID: spaceID)
    }

    private var swipeAccumulatedX: CGFloat = 0
    private var isTrackingHorizontalSwipe = false

    private func handleSpaceSwipe(_ event: NSEvent) {
        // Only handle trackpad scroll events
        guard !isAnimatingSwipe, event.phase != [] || event.momentumPhase != [] else {
            return
        }

        if event.phase == .began {
            swipeAccumulatedX = 0
            isTrackingHorizontalSwipe = false
        }

        // Once we've committed to a horizontal swipe, keep tracking through .ended
        // Otherwise, only start tracking if horizontal-dominant
        if !isTrackingHorizontalSwipe {
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                  event.scrollingDeltaX != 0 else {
                return
            }
            isTrackingHorizontalSwipe = true
        }

        if event.phase == .ended || event.phase == .cancelled {
            isTrackingHorizontalSwipe = false
        }

        swipeAccumulatedX += event.scrollingDeltaX

        if event.phase == .ended || event.phase == .cancelled {
            let threshold: CGFloat = 50
            guard abs(swipeAccumulatedX) > threshold else {
                swipeAccumulatedX = 0
                return
            }

            let spaces = TabStore.shared.spaces
            guard let activeID = activeSpaceID,
                  let currentIndex = spaces.firstIndex(where: { $0.id == activeID }) else {
                swipeAccumulatedX = 0
                return
            }

            // Positive scrollingDeltaX = swipe right (fingers move right) = go to previous space
            let nextIndex = swipeAccumulatedX > 0 ? currentIndex - 1 : currentIndex + 1
            swipeAccumulatedX = 0

            guard nextIndex >= 0, nextIndex < spaces.count else { return }

            let targetSpaceID = spaces[nextIndex].id
            let slideDirection: CGFloat = nextIndex > currentIndex ? -1 : 1

            isAnimatingSwipe = true
            let width = scrollView.frame.width

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                scrollView.animator().alphaValue = 0
                scrollView.animator().frame = scrollView.frame.offsetBy(dx: slideDirection * width * 0.3, dy: 0)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.delegate?.tabSidebarDidRequestSwitchToSpace(self, spaceID: targetSpaceID)

                self.scrollView.frame = self.scrollView.frame.offsetBy(dx: -slideDirection * width * 0.6, dy: 0)
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.scrollView.animator().alphaValue = 1
                    self.view.layoutSubtreeIfNeeded()
                }, completionHandler: {
                    self.isAnimatingSwipe = false
                })
            })
        }
    }

    func reloadTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }
}

// MARK: - NSTableViewDataSource

extension TabSidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tabs.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: tabReorderPasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowString = item.string(forType: tabReorderPasteboardType),
              let sourceRow = Int(rowString) else { return false }

        let destinationRow = sourceRow < row ? row - 1 : row
        guard sourceRow != destinationRow else { return false }

        tableView.beginUpdates()
        tableView.moveRow(at: sourceRow, to: destinationRow)
        tableView.endUpdates()

        // Suppress reloadData during the synchronous observer callback chain
        suppressReload = true
        delegate?.tabSidebar(self, didMoveTabFrom: sourceRow, to: row)
        suppressReload = false
        return true
    }
}

// MARK: - NSTableViewDelegate

extension TabSidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("TabCell")
        let cell: TabCellView
        if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? TabCellView {
            cell = existing
        } else {
            cell = TabCellView()
            cell.identifier = cellID
        }

        let tab = tabs[row]
        cell.titleLabel.stringValue = tab.title
        cell.toolTip = tab.title
        cell.updateFavicon(tab.favicon)
        cell.onClose = { [weak self] in
            guard let self else { return }
            self.delegate?.tabSidebar(self, didRequestCloseTabAt: row)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TabRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        delegate?.tabSidebar(self, didSelectTabAt: row)
    }
}
