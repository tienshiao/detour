import AppKit

/// The Archived Tabs page (TASK-119): the leftmost page of a non-incognito
/// sidebar's page strip, listing every space's closed-tab records under
/// relative-date headers, with search and a space filter.
///
/// The view holds no TabStore logic. `TabSidebarViewController` hands it the
/// entries and the space list, and hears restore / delete / clear through the
/// closures; row layout is the pure `archiveRows`.
final class ArchivePageView: NSView {
    struct SpaceInfo: Equatable {
        let id: UUID
        let emoji: String
        let name: String
    }

    /// The sidebar address bar's height (TabSidebarViewController).
    private static let searchRowHeight: CGFloat = 34
    private static let horizontalInset: CGFloat = 12
    /// The address bar's leading/trailing inset in the sidebar.
    private static let searchPillInset: CGFloat = 10
    private static let headerRowHeight: CGFloat = 26
    private static let entryRowHeight: CGFloat = 44
    static let disabledEntryAlpha: CGFloat = 0.45

    var onRestore: ((ArchiveEntry) -> Void)?
    var onDelete: ((ArchiveEntry) -> Void)?
    /// Clear Archive… for the current filter: the spaces it covers and how many
    /// entries they hold (ignoring the search). The receiver confirms first.
    var onClear: ((_ spaceIDs: [UUID], _ count: Int) -> Void)?

    private(set) var entries: [ArchiveEntry] = []
    private(set) var spaces: [SpaceInfo] = []
    /// The space the list is narrowed to; nil lists every space.
    private(set) var spaceFilter: UUID?
    private(set) var rows: [ArchiveRow] = []

    /// Styled like the sidebar's address bar (`FauxAddressBar`), whose row it
    /// takes on this page: same fill, hairline border, corner radius, height
    /// and insets, with the search icon where the bar shows its lock and the
    /// Filter button inside at the trailing end, like the bar's own buttons.
    private let searchPill = NSView()
    private let searchIcon = NSImageView()
    let searchField = NSTextField()
    private let clearButton = HoverButton()
    let filterButton = HoverButton()
    let scrollView = DraggableScrollView()
    let tableView = ArchiveTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let topFadeShadow = FadeShadowView(flipped: true)
    private let bottomFadeShadow = FadeShadowView(flipped: false)
    private let onScrollWheel: (NSEvent) -> Bool

    /// Whether the page's search field and list can take keyboard focus. Off
    /// while the page is off screen: it is the first page of the strip, so
    /// its search field is the window's first key view — the one AppKit
    /// focuses by itself when a window is first shown, and the one Tab from
    /// the end of a web page lands on (TASK-128).
    var acceptsKeyboardFocus = false {
        didSet { applyKeyboardFocus() }
    }

    private func applyKeyboardFocus() {
        searchField.refusesFirstResponder = !acceptsKeyboardFocus
        tableView.allowsKeyboardFocus = acceptsKeyboardFocus
    }

    init(onScrollWheel: @escaping (NSEvent) -> Bool) {
        self.onScrollWheel = onScrollWheel
        super.init(frame: .zero)
        applyKeyboardFocus()

        searchPill.wantsLayer = true
        searchPill.layer?.cornerRadius = UIConstants.defaultCornerRadius
        searchPill.layer?.borderWidth = 0.5
        searchPill.translatesAutoresizingMaskIntoConstraints = false
        updateSearchPillColors()
        addSubview(searchPill)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchPill.addSubview(searchIcon)

        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        searchField.font = font
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.lineBreakMode = .byTruncatingTail
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search Archive…",
            attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: font])
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchPill.addSubview(searchField)

        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear Search")
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.fixedHoverSize = 22
        clearButton.target = self
        clearButton.action = #selector(clearSearchClicked(_:))
        clearButton.isHidden = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        searchPill.addSubview(clearButton)

        filterButton.bezelStyle = .inline
        filterButton.isBordered = false
        filterButton.imagePosition = .imageOnly
        filterButton.fixedHoverSize = 22
        filterButton.target = self
        filterButton.action = #selector(filterButtonClicked(_:))
        filterButton.toolTip = "Filter"
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        searchPill.addSubview(filterButton)
        updateFilterButton()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ArchiveColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked(_:))
        tableView.onReturn = { [weak self] in self?.restoreSelectedRow() }
        tableView.onDelete = { [weak self] in self?.deleteSelectedRow() }
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.contentView = DraggableClipView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.onScrollWheel = onScrollWheel
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        for shadow in [topFadeShadow, bottomFadeShadow] {
            shadow.translatesAutoresizingMaskIntoConstraints = false
            shadow.alphaValue = 0
            addSubview(shadow, positioned: .above, relativeTo: scrollView)
        }

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            // Exactly where the space pages' address bar sits, so the search
            // takes its place as the strip slides.
            searchPill.topAnchor.constraint(equalTo: topAnchor),
            searchPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.searchPillInset),
            searchPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.searchPillInset),
            searchPill.heightAnchor.constraint(equalToConstant: Self.searchRowHeight),

            searchIcon.leadingAnchor.constraint(equalTo: searchPill.leadingAnchor, constant: 8),
            searchIcon.centerYAnchor.constraint(equalTo: searchPill.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),
            searchIcon.heightAnchor.constraint(equalToConstant: 14),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.centerYAnchor.constraint(equalTo: searchPill.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),

            clearButton.centerYAnchor.constraint(equalTo: searchPill.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -2),

            filterButton.centerYAnchor.constraint(equalTo: searchPill.centerYAnchor),
            filterButton.trailingAnchor.constraint(equalTo: searchPill.trailingAnchor, constant: -6),

            // The same 4pt gap the space pages leave below the address bar.
            scrollView.topAnchor.constraint(equalTo: searchPill.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            topFadeShadow.topAnchor.constraint(equalTo: scrollView.topAnchor),
            topFadeShadow.leadingAnchor.constraint(equalTo: leadingAnchor),
            topFadeShadow.trailingAnchor.constraint(equalTo: trailingAnchor),
            topFadeShadow.heightAnchor.constraint(equalToConstant: 12),

            bottomFadeShadow.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomFadeShadow.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomFadeShadow.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomFadeShadow.heightAnchor.constraint(equalToConstant: 12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.horizontalInset),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalInset),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// A horizontal swipe over the search row (outside the scroll view) pages
    /// the strip too.
    override func scrollWheel(with event: NSEvent) {
        if onScrollWheel(event) { return }
        super.scrollWheel(with: event)
    }

    // MARK: - Content

    /// Replaces the listing. The selection survives by record id, and a filter
    /// on a space that no longer exists is dropped.
    func update(entries: [ArchiveEntry], spaces: [SpaceInfo]) {
        self.entries = entries
        self.spaces = spaces
        dropStaleSpaceFilter()
        reloadRows()
    }

    /// Replaces the space list (a rename, emoji change, add or delete) and
    /// re-renders the rows.
    func updateSpaces(_ spaces: [SpaceInfo]) {
        guard spaces != self.spaces else { return }
        self.spaces = spaces
        dropStaleSpaceFilter()
        reloadRows()
    }

    private func dropStaleSpaceFilter() {
        guard let filter = spaceFilter, !spaces.contains(where: { $0.id == filter }) else { return }
        spaceFilter = nil
        updateFilterButton()
    }

    /// Entries the current filter covers, ignoring the search — what Clear
    /// Archive… would delete.
    var entriesInFilterScope: [ArchiveEntry] {
        guard let spaceFilter else { return entries }
        return entries.filter { $0.spaceID == spaceFilter }
    }

    private var query: String { searchField.stringValue }

    private func reloadRows() {
        let selectedID = selectedEntry?.id
        rows = archiveRows(entries: entries, query: query, spaceFilter: spaceFilter,
                           now: Date(), calendar: .current)
        clearButton.isHidden = query.isEmpty
        tableView.reloadData()
        if let selectedID, let row = rows.firstIndex(where: {
            if case .entry(let entry) = $0 { return entry.id == selectedID }
            return false
        }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        let isEmpty = rows.isEmpty
        emptyLabel.stringValue = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "No archived tabs" : "No matching tabs"
        emptyLabel.isHidden = !isEmpty
        updateFadeShadows()
    }

    private var showsSpaceBadges: Bool { spaces.count > 1 && spaceFilter == nil }

    private func entry(at row: Int) -> ArchiveEntry? {
        guard row >= 0, row < rows.count, case .entry(let entry) = rows[row] else { return nil }
        return entry
    }

    private var selectedEntry: ArchiveEntry? { entry(at: tableView.selectedRow) }

    // MARK: - Actions

    @objc private func clearSearchClicked(_ sender: Any?) {
        searchField.stringValue = ""
        reloadRows()
        window?.makeFirstResponder(searchField)
    }

    // MARK: - Search pill

    /// The address bar's fill and border (`FauxAddressBar`). Layer colors don't
    /// follow the appearance by themselves, so they are re-resolved on change.
    private func updateSearchPillColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            searchPill.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            searchPill.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSearchPillColors()
    }

    @objc private func tableClicked(_ sender: Any?) {
        guard let entry = entry(at: tableView.clickedRow) else { return }
        onRestore?(entry)
    }

    private func restoreSelectedRow() {
        guard let entry = selectedEntry else { return }
        onRestore?(entry)
    }

    private func deleteSelectedRow() {
        guard let entry = selectedEntry else { return }
        onDelete?(entry)
    }

    // MARK: - Filter

    private func updateFilterButton() {
        let symbol = spaceFilter == nil
            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        filterButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Filter")?
            .withSymbolConfiguration(config)
        filterButton.contentTintColor = spaceFilter == nil ? nil : .controlAccentColor
    }

    /// The Filter menu: All Spaces, one item per space (a checkmark on the
    /// current choice), then Clear Archive….
    func makeFilterMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let all = NSMenuItem(title: "All Spaces", action: #selector(filterMenuChoseSpace(_:)), keyEquivalent: "")
        all.target = self
        all.state = spaceFilter == nil ? .on : .off
        menu.addItem(all)
        for space in spaces {
            let item = NSMenuItem(title: "\(space.emoji) \(space.name)",
                                  action: #selector(filterMenuChoseSpace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space.id
            item.state = spaceFilter == space.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Archive…", action: #selector(filterMenuClear(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !entriesInFilterScope.isEmpty
        menu.addItem(clear)
        return menu
    }

    @objc private func filterButtonClicked(_ sender: NSButton) {
        let menu = makeFilterMenu()
        let y = sender.isFlipped ? sender.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
    }

    @objc private func filterMenuChoseSpace(_ sender: NSMenuItem) {
        setSpaceFilter(sender.representedObject as? UUID)
    }

    func setSpaceFilter(_ spaceID: UUID?) {
        guard spaceFilter != spaceID else { return }
        spaceFilter = spaceID
        updateFilterButton()
        reloadRows()
        tableView.scrollRowToVisible(0)
    }

    @objc private func filterMenuClear(_ sender: NSMenuItem) {
        let scope = entriesInFilterScope
        guard !scope.isEmpty else { return }
        let spaceIDs = spaceFilter.map { [$0] } ?? spaces.map(\.id)
        onClear?(spaceIDs, scope.count)
    }

    // MARK: - Fade shadows

    @objc private func scrollBoundsChanged(_ notification: Notification) {
        updateFadeShadows()
    }

    override func layout() {
        super.layout()
        updateFadeShadows()
    }

    func updateFadeShadows() {
        let clipView = scrollView.contentView
        guard let documentView = scrollView.documentView else { return }
        let visibleHeight = clipView.bounds.height
        guard visibleHeight > 0 else { return }
        let scrollY = clipView.bounds.origin.y
        let topAlpha: CGFloat = scrollY > 0 ? 1 : 0
        let bottomAlpha: CGFloat = documentView.frame.height - visibleHeight - scrollY > 0.5 ? 1 : 0
        guard topFadeShadow.alphaValue != topAlpha || bottomFadeShadow.alphaValue != bottomAlpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            topFadeShadow.animator().alphaValue = topAlpha
            bottomFadeShadow.animator().alphaValue = bottomAlpha
        }
    }
}

// MARK: - NSTextFieldDelegate

extension ArchivePageView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reloadRows()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape clears the search (and keeps focus in the field).
            guard !searchField.stringValue.isEmpty else { return false }
            searchField.stringValue = ""
            reloadRows()
            return true
        case #selector(NSResponder.moveDown(_:)):
            // Down arrow hands the keyboard to the list, on its first entry.
            guard let first = rows.firstIndex(where: { if case .entry = $0 { return true }; return false })
            else { return false }
            window?.makeFirstResponder(tableView)
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            tableView.scrollRowToVisible(first)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Return restores the only match — or the first one.
            guard let first = rows.lazy.compactMap({ row -> ArchiveEntry? in
                if case .entry(let entry) = row { return entry }
                return nil
            }).first else { return false }
            onRestore?(first)
            return true
        default:
            return false
        }
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension ArchivePageView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return Self.entryRowHeight }
        if case .header = rows[row] { return Self.headerRowHeight }
        return Self.entryRowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        entry(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TabRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let bucket):
            let id = NSUserInterfaceItemIdentifier("ArchiveHeaderCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ArchiveHeaderCellView
                ?? ArchiveHeaderCellView()
            cell.identifier = id
            cell.label.stringValue = archiveBucketTitle(bucket)
            return cell
        case .entry(let entry):
            let id = NSUserInterfaceItemIdentifier("ArchiveEntryCell")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ArchiveEntryCellView
                ?? ArchiveEntryCellView()
            cell.identifier = id
            let badge = showsSpaceBadges ? spaces.first(where: { $0.id == entry.spaceID })?.emoji : nil
            cell.configure(entry: entry, spaceBadge: badge)
            return cell
        }
    }
}

// MARK: - Context menu

extension ArchivePageView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        guard let entry = entry(at: tableView.clickedRow) else { return }
        let restore = NSMenuItem(title: "Restore", action: #selector(contextMenuRestore(_:)), keyEquivalent: "")
        restore.target = self
        restore.representedObject = entry.id
        restore.isEnabled = entry.isRestorable
        menu.addItem(restore)
        let delete = NSMenuItem(title: "Delete", action: #selector(contextMenuDelete(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = entry.id
        menu.addItem(delete)
    }

    private func entry(withID id: Any?) -> ArchiveEntry? {
        guard let id = id as? Int64 else { return nil }
        return entries.first { $0.id == id }
    }

    @objc private func contextMenuRestore(_ sender: NSMenuItem) {
        guard let entry = entry(withID: sender.representedObject) else { return }
        onRestore?(entry)
    }

    @objc private func contextMenuDelete(_ sender: NSMenuItem) {
        guard let entry = entry(withID: sender.representedObject) else { return }
        onDelete?(entry)
    }
}

// MARK: - Table and cells

/// The archive list's table: Return restores the selected row, Delete and
/// Backspace delete it.
final class ArchiveTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    /// See `ArchivePageView.acceptsKeyboardFocus`.
    var allowsKeyboardFocus = true
    override var acceptsFirstResponder: Bool { allowsKeyboardFocus && super.acceptsFirstResponder }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, keypad Enter
            onReturn?()
        case 51, 117:  // Delete (backspace), forward delete
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }
}

final class ArchiveHeaderCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ArchiveEntryCellView: NSTableCellView {
    private let faviconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private var badgeWidthConstraint: NSLayoutConstraint!
    private var faviconURL: URL?

    init() {
        super.init(frame: .zero)
        faviconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingTail
        badgeLabel.font = .systemFont(ofSize: 11)
        badgeLabel.alignment = .right
        for view in [faviconView, titleLabel, urlLabel, badgeLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for label in [titleLabel, urlLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        badgeWidthConstraint = badgeLabel.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: 16),
            faviconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: badgeLabel.leadingAnchor, constant: -4),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            urlLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            urlLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            urlLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeWidthConstraint,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(entry: ArchiveEntry, spaceBadge: String?) {
        titleLabel.stringValue = entry.title.isEmpty ? archiveDisplayURL(entry.url) : entry.title
        urlLabel.stringValue = archiveDisplayURL(entry.url)
        badgeLabel.stringValue = spaceBadge ?? ""
        badgeWidthConstraint.constant = spaceBadge == nil ? 0 : 18
        alphaValue = entry.isRestorable ? 1 : ArchivePageView.disabledEntryAlpha
        toolTip = entry.isRestorable ? nil : "The extension for this page is disabled"

        let placeholder = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        faviconURL = entry.faviconURL
        faviconView.image = placeholder
        faviconView.contentTintColor = .secondaryLabelColor
        guard let url = entry.faviconURL else { return }
        FaviconLoader.shared.load(from: url) { [weak self] image in
            // The cell may have been reused for another row meanwhile.
            guard let self, self.faviconURL == url, let image else { return }
            self.faviconView.image = image
            self.faviconView.contentTintColor = nil
        }
    }
}
