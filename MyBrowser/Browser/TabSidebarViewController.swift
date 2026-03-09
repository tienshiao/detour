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
}

class DraggableTableView: NSTableView {
    override var mouseDownCanMoveWindow: Bool { true }

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
}

class DraggableClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool { true }
}

class TabSidebarViewController: NSViewController {
    weak var delegate: TabSidebarDelegate?

    private(set) var tableView = DraggableTableView()
    private let scrollView = DraggableScrollView()
    private(set) var addressField = NSTextField()
    private(set) var backButton = NSButton()
    private(set) var forwardButton = NSButton()
    private(set) var reloadButton = NSButton()
    private(set) var sidebarToggleButton = NSButton()

    var tabs: [BrowserTab] = [] {
        didSet { tableView.reloadData() }
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

        scrollView.contentView = DraggableClipView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
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

        container.addSubview(sidebarToggleButton)
        container.addSubview(navStack)
        container.addSubview(addressField)
        container.addSubview(newTabButton)
        container.addSubview(scrollView)

        // The title bar is ~38px tall. Nav buttons sit in that area, right-aligned.
        // Traffic lights occupy roughly the left 70px, so right-aligning the nav buttons avoids overlap.
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

            // Tab list: below new tab button, fills remaining space
            scrollView.topAnchor.constraint(equalTo: newTabButton.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
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

// MARK: - Tab Cell View

class TabRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // Let the default source list selection draw as normal
        super.drawSelection(in: dirtyRect)
    }

    /// The inset rect the source list uses for its selection highlight
    var selectionRect: NSRect {
        // Source list selection is inset ~10pt horizontally, ~1pt vertically, with 6pt corner radius
        return bounds.insetBy(dx: 10, dy: 1)
    }
}

class TabCellView: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let faviconImageView = NSImageView()
    private let closeButton: NSButton
    private var trackingArea: NSTrackingArea?
    private var titleTrailingDefault: NSLayoutConstraint!
    private var titleTrailingHover: NSLayoutConstraint!
    private var titleLeadingToFavicon: NSLayoutConstraint!
    private let hoverBackground = NSView()
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
            target: nil,
            action: nil
        )
        super.init(frame: frameRect)

        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 6
        hoverBackground.isHidden = true
        addSubview(hoverBackground, positioned: .below, relativeTo: nil)

        faviconImageView.imageScaling = .scaleProportionallyUpOrDown
        faviconImageView.translatesAutoresizingMaskIntoConstraints = false
        faviconImageView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(faviconImageView)
        addSubview(titleLabel)
        addSubview(closeButton)

        titleTrailingDefault = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        titleTrailingHover = titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4)
        titleLeadingToFavicon = titleLabel.leadingAnchor.constraint(equalTo: faviconImageView.trailingAnchor, constant: 8)

        NSLayoutConstraint.activate([
            faviconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            faviconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconImageView.widthAnchor.constraint(equalToConstant: 16),
            faviconImageView.heightAnchor.constraint(equalToConstant: 16),

            titleLeadingToFavicon,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleTrailingDefault,

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Match the source list selection inset (same as TabRowView.selectionRect)
        hoverBackground.frame = bounds.insetBy(dx: -6, dy: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        titleTrailingDefault.isActive = false
        titleTrailingHover.isActive = true
        hoverBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        hoverBackground.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        titleTrailingHover.isActive = false
        titleTrailingDefault.isActive = true
        hoverBackground.isHidden = true
    }

    func updateFavicon(_ image: NSImage?) {
        faviconImageView.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")
    }

    @objc private func closeTapped() {
        onClose?()
    }
}

// MARK: - Hover Button

class HoverButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private let hoverBackground = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 6
        hoverBackground.isHidden = true
        addSubview(hoverBackground, positioned: .below, relativeTo: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Match the source list selection inset: 10pt from each side of the full sidebar width
        hoverBackground.frame = bounds.insetBy(dx: 10, dy: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        hoverBackground.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverBackground.isHidden = true
    }
}
