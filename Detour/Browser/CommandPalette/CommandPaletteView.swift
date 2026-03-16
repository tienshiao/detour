import AppKit

protocol CommandPaletteDelegate: AnyObject {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String)
    func commandPaletteDidDismiss(_ palette: CommandPaletteView)
    func commandPalette(_ palette: CommandPaletteView, didRequestSwitchToTab tabID: UUID, in spaceID: UUID)
}

extension CommandPaletteDelegate {
    func commandPalette(_ palette: CommandPaletteView, didRequestSwitchToTab tabID: UUID, in spaceID: UUID) {}
}

class CommandPaletteTextField: NSTextField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

class CommandPaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: CommandPaletteDelegate?
    var tabStore: TabStore?
    var activeSpaceID: UUID?
    var profile: Profile?

    private let textField = CommandPaletteTextField()
    private let glassContainer = GlassContainerView(cornerRadius: 12)
    private var box: NSView { glassContainer.contentView }
    private let searchIcon = NSImageView()
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private let suggestionProvider = SuggestionProvider()
    private var suggestions: [SuggestionItem] = []
    private var selectedSuggestionIndex: Int? = nil
    private var debounceWorkItem: DispatchWorkItem?
    private var currentTask: Task<Void, Never>?

    private var scrollHeightConstraint: NSLayoutConstraint!
    private var boxBottomToTextField: NSLayoutConstraint!
    private var boxBottomToScroll: NSLayoutConstraint!

    // Default centered positioning constraints
    private var centerXConstraint: NSLayoutConstraint!
    private var centerYConstraint: NSLayoutConstraint!
    // Anchor-based positioning constraints (optional)
    private var anchorLeadingConstraint: NSLayoutConstraint?
    private var anchorTopConstraint: NSLayoutConstraint?

    private let rowHeight: CGFloat = 36

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        addSubview(glassContainer)

        // Search icon
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(searchIcon)

        // Text field
        textField.placeholderString = "Where do you want to go?"
        textField.font = .systemFont(ofSize: 18)
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.target = self
        textField.action = #selector(textFieldSubmitted)
        textField.delegate = self
        textField.onEscape = { [weak self] in self?.dismiss() }
        textField.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(textField)

        // Separator
        separator.boxType = .separator
        separator.isHidden = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(separator)

        // Table view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.target = self
        tableView.action = #selector(tableRowClicked)

        tableView.style = .plain

        scrollView.documentView = tableView
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.isHidden = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scrollView)

        scrollHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        boxBottomToTextField = textField.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12)
        boxBottomToScroll = scrollView.bottomAnchor.constraint(equalTo: box.bottomAnchor)

        centerXConstraint = glassContainer.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor)
        centerYConstraint = NSLayoutConstraint(item: glassContainer, attribute: .top, relatedBy: .equal,
                               toItem: self, attribute: .bottom, multiplier: 0.35, constant: 0)

        NSLayoutConstraint.activate([
            centerXConstraint,
            centerYConstraint,
            glassContainer.widthAnchor.constraint(equalToConstant: 500),

            searchIcon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: textField.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),

            textField.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            textField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: box.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scrollHeightConstraint,

            boxBottomToTextField,
        ])
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if !glassContainer.frame.contains(location) {
            dismiss()
        }
    }

    func show(in parentView: NSView, initialText: String? = nil, anchorFrame: NSRect? = nil) {
        if let initialText, !initialText.isEmpty {
            textField.stringValue = initialText
        }
        translatesAutoresizingMaskIntoConstraints = false
        parentView.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parentView.topAnchor),
            bottomAnchor.constraint(equalTo: parentView.bottomAnchor),
            leadingAnchor.constraint(equalTo: parentView.leadingAnchor),
            trailingAnchor.constraint(equalTo: parentView.trailingAnchor),
        ])

        if let anchorFrame {
            let localFrame = parentView.convert(anchorFrame, from: nil)
            centerXConstraint.isActive = false
            centerYConstraint.isActive = false
            // parentView uses non-flipped coords (origin bottom-left).
            // localFrame.maxY = top edge of anchor. Distance from parent top = parentView.bounds.height - localFrame.maxY.
            // The palette overlay is pinned to match parentView, so use the same offsets.
            anchorLeadingConstraint = glassContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: localFrame.minX)
            anchorTopConstraint = glassContainer.topAnchor.constraint(equalTo: topAnchor, constant: parentView.bounds.height - localFrame.maxY)
            anchorLeadingConstraint?.isActive = true
            anchorTopConstraint?.isActive = true
        }

        window?.makeFirstResponder(textField)
        if initialText != nil {
            textField.currentEditor()?.selectAll(nil)
        }
        loadDefaultSuggestions()
    }

    func dismiss() {
        currentTask?.cancel()
        debounceWorkItem?.cancel()

        // Restore default centered positioning for potential reuse
        anchorLeadingConstraint?.isActive = false
        anchorTopConstraint?.isActive = false
        anchorLeadingConstraint = nil
        anchorTopConstraint = nil
        centerXConstraint.isActive = true
        centerYConstraint.isActive = true

        removeFromSuperview()
        delegate?.commandPaletteDidDismiss(self)
    }

    // MARK: - Suggestions

    private func loadDefaultSuggestions() {
        guard let spaceID = activeSpaceID else { return }
        let items = suggestionProvider.defaultSuggestions(spaceID: spaceID.uuidString, tabs: gatherTabInfos())
        updateSuggestions(items)
    }

    private func gatherTabInfos() -> [SuggestionProvider.TabInfo] {
        (tabStore?.spaces ?? []).flatMap { space in
            (space.tabs + space.pinnedTabs).map { tab in
                SuggestionProvider.TabInfo(
                    tabID: tab.id,
                    spaceID: space.id,
                    url: tab.url?.absoluteString ?? "",
                    title: tab.title,
                    favicon: tab.favicon
                )
            }
        }
    }

    private func updateSuggestions(_ items: [SuggestionItem]) {
        suggestions = items
        selectedSuggestionIndex = nil
        tableView.reloadData()

        let hasSuggestions = !items.isEmpty
        separator.isHidden = !hasSuggestions
        scrollView.isHidden = !hasSuggestions

        if hasSuggestions {
            let height = min(CGFloat(items.count) * rowHeight, 6 * rowHeight)
            scrollHeightConstraint.constant = height
            boxBottomToTextField.isActive = false
            boxBottomToScroll.isActive = true
        } else {
            boxBottomToScroll.isActive = false
            boxBottomToTextField.isActive = true
        }
    }

    private func fetchSuggestions(for query: String) {
        guard let spaceID = activeSpaceID else { return }

        let tabInfos = gatherTabInfos()

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            let items = await self.suggestionProvider.suggestions(
                for: query, spaceID: spaceID.uuidString, tabs: tabInfos,
                searchEngine: self.profile?.searchEngine ?? .google,
                searchSuggestionsEnabled: self.profile?.searchSuggestionsEnabled ?? true)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.updateSuggestions(items)
            }
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        debounceWorkItem?.cancel()
        let query = textField.stringValue.trimmingCharacters(in: .whitespaces)

        if query.isEmpty {
            loadDefaultSuggestions()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.fetchSuggestions(for: query)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let index = selectedSuggestionIndex, index < suggestions.count {
                activateSuggestion(at: index)
                return true
            }
            return false // let default action handler fire
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let current = selectedSuggestionIndex ?? -1
        var next = current + delta
        if next < 0 { next = suggestions.count - 1 }
        if next >= suggestions.count { next = 0 }
        selectedSuggestionIndex = next
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func activateSuggestion(at index: Int) {
        guard index < suggestions.count else { return }
        switch suggestions[index] {
        case .historyResult(let url, _, _):
            delegate?.commandPalette(self, didSubmitInput: url)
        case .searchSuggestion(let text):
            delegate?.commandPalette(self, didSubmitInput: text)
        case .openTab(let tabID, let spaceID, _, _, _):
            delegate?.commandPalette(self, didRequestSwitchToTab: tabID, in: spaceID)
        }
    }

    @objc private func textFieldSubmitted() {
        let input = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        delegate?.commandPalette(self, didSubmitInput: input)
    }

    @objc private func tableRowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        activateSuggestion(at: row)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SuggestionCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? SuggestionCellView)
            ?? SuggestionCellView(identifier: id)

        let item = suggestions[row]
        switch item {
        case .historyResult(let url, let title, let faviconURL):
            cell.configure(title: title, url: url, icon: nil, isSearch: false)
            if let faviconURL {
                suggestionProvider.loadFavicon(for: faviconURL) { [weak cell] image in
                    cell?.iconView.image = image
                }
            }
        case .openTab(_, _, _, let title, let favicon):
            cell.configure(title: title, url: nil, icon: favicon, isSearch: false, switchToTab: true)
        case .searchSuggestion(let text):
            cell.configure(title: text, url: nil, icon: nil, isSearch: true)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CommandPaletteRowView()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedSuggestionIndex = row >= 0 ? row : nil
    }
}

// MARK: - CommandPaletteRowView

private class CommandPaletteRowView: NSTableRowView {
    private var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isHovered && !isSelected {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            let rect = bounds.insetBy(dx: 4, dy: 1)
            NSBezierPath(roundedRect: rect, xRadius: UIConstants.defaultCornerRadius, yRadius: UIConstants.defaultCornerRadius).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let alpha: CGFloat = isEmphasized ? 0.15 : 0.08
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        let rect = bounds.insetBy(dx: 4, dy: 1)
        NSBezierPath(roundedRect: rect, xRadius: UIConstants.defaultCornerRadius, yRadius: UIConstants.defaultCornerRadius).fill()
    }
}

// MARK: - SuggestionCellView

private class SuggestionCellView: NSTableCellView {
    let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "")
    private let badgeIcon = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingTail
        urlLabel.alignment = .right
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        addSubview(urlLabel)

        badgeIcon.image = NSImage(systemSymbolName: "arrow.right.arrow.left", accessibilityDescription: nil)
        badgeIcon.contentTintColor = .secondaryLabelColor
        badgeIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeIcon)

        badgeLabel.stringValue = "Switch to Tab"
        badgeLabel.font = .systemFont(ofSize: 11)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            urlLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            urlLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            urlLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            urlLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            badgeIcon.widthAnchor.constraint(equalToConstant: 12),
            badgeIcon.heightAnchor.constraint(equalToConstant: 12),
            badgeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeIcon.leadingAnchor, constant: -4),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            badgeIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, url: String?, icon: NSImage?, isSearch: Bool, switchToTab: Bool = false) {
        titleLabel.stringValue = title.isEmpty ? (url ?? "") : title

        let showURL = !switchToTab && url != nil
        urlLabel.stringValue = url ?? ""
        urlLabel.isHidden = !showURL
        badgeIcon.isHidden = !switchToTab
        badgeLabel.isHidden = !switchToTab

        if isSearch {
            iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
        } else if let icon {
            iconView.image = icon
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
        }
    }
}
