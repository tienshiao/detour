import AppKit

protocol CommandPaletteDelegate: AnyObject {
    func commandPalette(_ palette: CommandPaletteView, didSubmitInput input: String)
    func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String)
    func commandPaletteDidDismiss(_ palette: CommandPaletteView)
    func commandPalette(_ palette: CommandPaletteView, didRequestSwitchToTab tabID: UUID, in spaceID: UUID)
}

extension CommandPaletteDelegate {
    func commandPalette(_ palette: CommandPaletteView, didSubmitSearch query: String) {}
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

    private var userTypedText: String = ""
    private var isUpdatingTextProgrammatically = false
    private var inlineCompletionSuffix: String?
    private var suppressNextAutocomplete = false
    private var wasPrepopulated = false

    /// Set text field value without triggering `controlTextDidChange`.
    private func setTextFieldQuietly(_ text: String) {
        isUpdatingTextProgrammatically = true
        textField.stringValue = text
        isUpdatingTextProgrammatically = false
    }

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
        textField.onEscape = { [weak self] in self?.handleEscape() }
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        box.addSubview(scrollView)

        scrollHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        boxBottomToTextField = textField.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12)
        boxBottomToScroll = scrollView.bottomAnchor.constraint(equalTo: box.bottomAnchor)

        centerXConstraint = glassContainer.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor)
        let maxPaletteHeight: CGFloat = 12 + 24 + 8 + 1 + 6 * rowHeight  // top pad + textfield + gap + separator + max suggestions
        centerYConstraint = NSLayoutConstraint(item: glassContainer, attribute: .top, relatedBy: .equal,
                               toItem: self, attribute: .bottom, multiplier: 0.5, constant: -maxPaletteHeight / 2)

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
        userTypedText = ""
        inlineCompletionSuffix = nil
        wasPrepopulated = initialText?.isEmpty == false
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

    var isAnchored: Bool {
        anchorLeadingConstraint != nil
    }

    func switchToCentered() {
        anchorLeadingConstraint?.isActive = false
        anchorTopConstraint?.isActive = false
        anchorLeadingConstraint = nil
        anchorTopConstraint = nil
        centerXConstraint.isActive = true
        centerYConstraint.isActive = true

        userTypedText = ""
        inlineCompletionSuffix = nil
        textField.stringValue = ""
        window?.makeFirstResponder(textField)
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
        let isIncognito = profile?.isIncognito ?? false
        let spaces = (tabStore?.spaces ?? []).filter { !isIncognito || $0.id == activeSpaceID }
        return spaces.flatMap { space in
            (space.tabs + space.pinnedEntries.compactMap(\.tab)).map { tab in
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
        updateFirstSearchInput(text: inlineCompletionSuffix.map { userTypedText + $0 })
        selectedSuggestionIndex = items.isEmpty ? nil : 0
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

    private func fetchSuggestions(for query: String, tabInfos: [SuggestionProvider.TabInfo]? = nil) {
        guard let spaceID = activeSpaceID else { return }

        let tabInfos = tabInfos ?? gatherTabInfos()

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
        guard !isUpdatingTextProgrammatically else { return }

        debounceWorkItem?.cancel()
        let raw = textField.stringValue
        userTypedText = raw
        inlineCompletionSuffix = nil

        let query = raw.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            loadDefaultSuggestions()
            return
        }

        // Gather tab infos and apply inline autocomplete (suppressed on backspace)
        var tabInfos: [SuggestionProvider.TabInfo]?
        if suppressNextAutocomplete {
            suppressNextAutocomplete = false
        } else if raw == query {
            // Only autocomplete when there's no trailing whitespace;
            // a trailing space means the user is typing a multi-word search.
            let infos = gatherTabInfos()
            applyInlineAutocomplete(for: query, tabInfos: infos)
            tabInfos = infos
        }

        // Debounced full suggestion fetch
        let work = DispatchWorkItem { [weak self] in
            self?.fetchSuggestions(for: query, tabInfos: tabInfos)
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
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            if inlineCompletionSuffix != nil {
                inlineCompletionSuffix = nil
                updateFirstSearchInput(text: userTypedText, reloadRow: true)
                setTextFieldQuietly(userTypedText)
                textField.currentEditor()?.selectedRange = NSRange(location: userTypedText.count, length: 0)
                suppressNextAutocomplete = true
                return true
            }
            suppressNextAutocomplete = true
            return false
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            if let suffix = inlineCompletionSuffix {
                userTypedText = userTypedText + suffix
                inlineCompletionSuffix = nil
                textField.currentEditor()?.selectedRange = NSRange(location: userTypedText.count, length: 0)
                return true
            }
            return false
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let oldIndex = selectedSuggestionIndex
        inlineCompletionSuffix = nil

        // Deselect old row
        if let old = oldIndex {
            (tableView.rowView(atRow: old, makeIfNecessary: false) as? CommandPaletteRowView)?.isKeyboardSelected = false
        }

        // Compute next index, allowing nil (no selection = restore user text)
        let newIndex: Int?
        if let current = oldIndex {
            let next = current + delta
            if next < 0 || next >= suggestions.count {
                newIndex = nil // moved past boundary → restore user text
            } else {
                newIndex = next
            }
        } else {
            // Currently no selection
            newIndex = delta > 0 ? 0 : suggestions.count - 1
        }

        selectedSuggestionIndex = newIndex

        if let idx = newIndex {
            (tableView.rowView(atRow: idx, makeIfNecessary: false) as? CommandPaletteRowView)?.isKeyboardSelected = true
            tableView.scrollRowToVisible(idx)

            let displayText = suggestionDisplayText(at: idx)
            setTextFieldQuietly(displayText)
            textField.currentEditor()?.selectAll(nil)
        } else {
            setTextFieldQuietly(userTypedText)
            textField.currentEditor()?.selectedRange = NSRange(location: userTypedText.count, length: 0)
        }
    }

    private func suggestionDisplayText(at index: Int) -> String {
        switch suggestions[index] {
        case .searchInput(let text):
            return text
        case .historyResult(let url, _, _):
            return url
        case .openTab(_, _, let url, _, _):
            return url
        case .searchSuggestion(let text):
            return text
        }
    }

    private func updateFirstSearchInput(text: String?, reloadRow: Bool = false) {
        guard let text, !suggestions.isEmpty, case .searchInput = suggestions[0] else { return }
        suggestions[0] = .searchInput(text: text)
        if reloadRow {
            tableView.reloadData(forRowIndexes: IndexSet(integer: 0), columnIndexes: IndexSet(integer: 0))
        }
    }

    private func activateSuggestion(at index: Int) {
        guard index < suggestions.count else { return }
        switch suggestions[index] {
        case .searchInput:
            let input = textField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !input.isEmpty else { return }
            delegate?.commandPalette(self, didSubmitInput: input)
        case .historyResult(let url, _, _):
            delegate?.commandPalette(self, didSubmitInput: url)
        case .searchSuggestion(let text):
            delegate?.commandPalette(self, didSubmitSearch: text)
        case .openTab(let tabID, let spaceID, _, _, _):
            delegate?.commandPalette(self, didRequestSwitchToTab: tabID, in: spaceID)
        }
    }

    @objc private func textFieldSubmitted() {
        let input = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        delegate?.commandPalette(self, didSubmitInput: input)
    }

    private func applyInlineAutocomplete(for query: String, tabInfos: [SuggestionProvider.TabInfo]) {
        guard let spaceID = activeSpaceID else { return }

        guard let match = suggestionProvider.bestAutocomplete(for: query, spaceID: spaceID.uuidString, tabs: tabInfos) else { return }

        // The match is a display URL (scheme-stripped). Find where the user's query ends in it.
        guard match.lowercased().hasPrefix(query.lowercased()) else { return }
        let suffix = String(match.dropFirst(query.count))
        guard !suffix.isEmpty else { return }

        inlineCompletionSuffix = suffix

        updateFirstSearchInput(text: query + suffix, reloadRow: true)

        setTextFieldQuietly(query + suffix)

        if let editor = textField.currentEditor() {
            editor.selectedRange = NSRange(location: query.count, length: suffix.count)
        }
    }

    private func handleEscape() {
        // Prepopulated mode (Cmd+L / sidebar click): Escape dismisses immediately
        if wasPrepopulated {
            dismiss()
            return
        }

        // Multi-stage escape for user-typed input
        if inlineCompletionSuffix != nil {
            inlineCompletionSuffix = nil
            setTextFieldQuietly(userTypedText)
            textField.currentEditor()?.selectedRange = NSRange(location: userTypedText.count, length: 0)
        } else if !textField.stringValue.isEmpty {
            setTextFieldQuietly("")
            userTypedText = ""
            loadDefaultSuggestions()
        } else {
            dismiss()
        }
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        for row in visibleRows.lowerBound..<visibleRows.upperBound {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? CommandPaletteRowView)?.recheckHover()
        }
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
        case .searchInput(let text):
            let looksLikeURL = text.contains(".") && !text.contains(" ")
            cell.configure(title: text, url: nil, icon: nil, isSearch: !looksLikeURL, isGoTo: looksLikeURL)
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
        let rowView = CommandPaletteRowView()
        rowView.isKeyboardSelected = (row == selectedSuggestionIndex)
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }
}

// MARK: - CommandPaletteRowView

private class CommandPaletteRowView: NSTableRowView {
    var isKeyboardSelected = false { didSet { needsDisplay = true } }
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

    func recheckHover() {
        guard let window else { return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInSelf = convert(mouseInWindow, from: nil)
        let shouldHover = bounds.contains(mouseInSelf)
        guard shouldHover != isHovered else { return }
        isHovered = shouldHover
        needsDisplay = true
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isKeyboardSelected {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            let rect = bounds.insetBy(dx: 4, dy: 1)
            NSBezierPath(roundedRect: rect, xRadius: UIConstants.defaultCornerRadius, yRadius: UIConstants.defaultCornerRadius).fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            let rect = bounds.insetBy(dx: 4, dy: 1)
            NSBezierPath(roundedRect: rect, xRadius: UIConstants.defaultCornerRadius, yRadius: UIConstants.defaultCornerRadius).fill()
        }
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

    func configure(title: String, url: String?, icon: NSImage?, isSearch: Bool, switchToTab: Bool = false, isGoTo: Bool = false) {
        titleLabel.stringValue = title.isEmpty ? (url ?? "") : title

        let showURL = !switchToTab && url != nil
        urlLabel.stringValue = url ?? ""
        urlLabel.isHidden = !showURL
        badgeIcon.isHidden = !switchToTab
        badgeLabel.isHidden = !switchToTab

        if isSearch {
            iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
        } else if isGoTo {
            iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
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
