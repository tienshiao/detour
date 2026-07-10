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
    var currentTabID: UUID?
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
    /// The query the current suggestion list was built for; nil when showing
    /// defaults. Used to reject stale async search-suggestion responses.
    private var suggestionsQuery: String?
    private var selectedSuggestionIndex: Int? = nil
    private var debounceWorkItem: DispatchWorkItem?
    private var currentTask: Task<Void, Never>?

    /// Bumped every time the local suggestion list is rebuilt (typing or clearing).
    /// The background history read captures the value at dispatch and drops its
    /// result on arrival if this has advanced — mirrors the `suggestionsQuery`
    /// guard used for network search suggestions.
    private var localSuggestionGeneration = 0
    /// Serial queue for the per-keystroke history reads, so they run off the main
    /// thread in FIFO order (stale ones are still dropped via the generation).
    private let historyQueryQueue = DispatchQueue(label: "com.detourbrowser.mac.palette-history", qos: .userInitiated)

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
            let targetWindow = window
            dismiss()
            targetWindow?.sendEvent(event)
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
        // Invalidate any in-flight background history read so its result can't
        // overwrite the default list when it lands.
        localSuggestionGeneration &+= 1
        let items = suggestionProvider.defaultSuggestions(spaceID: spaceID.uuidString, tabs: gatherTabInfos())
        suggestionsQuery = nil
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
        let old = suggestions
        suggestions = items

        // Adjust the row count at the tail, then reconfigure changed rows in place.
        // Unchanged rows keep their views so the list stays stable while typing.
        tableView.beginUpdates()
        if items.count > old.count {
            tableView.insertRows(at: IndexSet(integersIn: old.count..<items.count), withAnimation: [])
        } else if items.count < old.count {
            tableView.removeRows(at: IndexSet(integersIn: items.count..<old.count), withAnimation: [])
        }
        tableView.endUpdates()

        for row in 0..<min(old.count, items.count) where old[row] != items[row] {
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SuggestionCellView {
                configureCell(cell, for: items[row])
            } else {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }

        setKeyboardSelection(to: items.isEmpty ? nil : 0)
        updatePanelHeight()
    }

    private func setKeyboardSelection(to index: Int?) {
        if let old = selectedSuggestionIndex, old != index, old < tableView.numberOfRows {
            (tableView.rowView(atRow: old, makeIfNecessary: false) as? CommandPaletteRowView)?.isKeyboardSelected = false
        }
        selectedSuggestionIndex = index
        if let new = index {
            (tableView.rowView(atRow: new, makeIfNecessary: false) as? CommandPaletteRowView)?.isKeyboardSelected = true
        }
    }

    private func updatePanelHeight() {
        let hasSuggestions = !suggestions.isEmpty
        separator.isHidden = !hasSuggestions
        scrollView.isHidden = !hasSuggestions

        if hasSuggestions {
            let height = min(CGFloat(suggestions.count) * rowHeight, 6 * rowHeight)
            scrollHeightConstraint.constant = height
            boxBottomToTextField.isActive = false
            boxBottomToScroll.isActive = true
        } else {
            boxBottomToScroll.isActive = false
            boxBottomToTextField.isActive = true
        }
    }

    private func fetchSearchSuggestions(for query: String) {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            let texts = await self.suggestionProvider.searchSuggestions(
                for: query, engine: self.profile?.searchEngine ?? .google)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.appendSearchSuggestions(texts, forQuery: query)
            }
        }
    }

    private func appendSearchSuggestions(_ texts: [String], forQuery query: String) {
        // Ignore responses that arrive after the list was rebuilt for different input.
        guard query == suggestionsQuery else { return }

        let room = SuggestionProvider.maxSuggestions - suggestions.count
        guard room > 0 else { return }
        let items = texts.prefix(min(SuggestionProvider.maxSearchSuggestions, room)).map { SuggestionItem.searchSuggestion(text: $0) }
        guard !items.isEmpty else { return }

        let start = suggestions.count
        suggestions.append(contentsOf: items)
        tableView.insertRows(at: IndexSet(integersIn: start..<suggestions.count), withAnimation: [])
        updatePanelHeight()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard !isUpdatingTextProgrammatically else { return }

        debounceWorkItem?.cancel()
        currentTask?.cancel()
        let raw = textField.stringValue
        userTypedText = raw
        inlineCompletionSuffix = nil

        // Autocomplete is suppressed on backspace and when there's trailing
        // whitespace (that means a multi-word search is being typed).
        let query = raw.trimmingCharacters(in: .whitespaces)
        let allowAutocomplete: Bool
        if suppressNextAutocomplete {
            suppressNextAutocomplete = false
            allowAutocomplete = false
        } else {
            allowAutocomplete = raw == query
        }

        refreshLocalSuggestions(allowAutocomplete: allowAutocomplete)
    }

    /// Schedules the debounced network search-suggestion fetch; results are
    /// appended below the local rows when they arrive.
    private func scheduleSearchSuggestionFetch(for query: String) {
        guard profile?.searchSuggestionsEnabled ?? true else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.fetchSearchSuggestions(for: query)
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
                setTextFieldQuietly(userTypedText)
                textField.currentEditor()?.selectedRange = NSRange(location: userTypedText.count, length: 0)
                suppressNextAutocomplete = true
                refreshLocalSuggestions(allowAutocomplete: false)
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
                refreshLocalSuggestions(allowAutocomplete: true)
                return true
            }
            return false
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        inlineCompletionSuffix = nil

        // Compute next index, allowing nil (no selection = restore user text)
        let newIndex: Int?
        if let current = selectedSuggestionIndex {
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

        setKeyboardSelection(to: newIndex)

        if let idx = newIndex {
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

    /// Rebuilds local suggestions for the current typed text and schedules the
    /// network search fetch. Shared by every path that changes the query: typing,
    /// and inline-completion accept (Tab) or reject (backspace/Escape).
    ///
    /// Two phases. First, an instant synchronous pass over the in-memory open
    /// tabs (no SQLite) shows tab matches and applies the tab-based inline
    /// autocomplete immediately, so typing never blocks on the database. Then a
    /// background pass runs the two history queries (`bestURLCompletion` frecency
    /// scan + FTS `searchHistory`) off the main thread and merges the full,
    /// authoritative list back in — dropped on arrival if the query has since
    /// changed.
    private func refreshLocalSuggestions(allowAutocomplete: Bool) {
        let query = userTypedText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            loadDefaultSuggestions()
            return
        }
        guard let spaceID = activeSpaceID else { return }
        let tabs = gatherTabInfos()

        // --- Instant synchronous pass: open tabs only ---
        let q = query.lowercased()
        var topHitTabID: UUID?
        var instantItems: [SuggestionItem] = []
        var appliedTabCompletion = false
        if allowAutocomplete,
           let tab = tabs.first(where: { $0.tabID != currentTabID && $0.displayURL.lowercased().hasPrefix(q) }) {
            instantItems.append(.openTab(tabID: tab.tabID, spaceID: tab.spaceID, url: tab.url, title: tab.title, favicon: tab.favicon))
            topHitTabID = tab.tabID
            applyInlineCompletion(tab.displayURL, for: query)
            appliedTabCompletion = true
        }
        instantItems.append(.searchInput(text: query))
        let matchingTabs = Array(tabs.filter {
            $0.tabID != topHitTabID && ($0.url.lowercased().contains(q) || $0.title.lowercased().contains(q))
        }.prefix(3))
        let tabItems: [SuggestionItem] = matchingTabs.map {
            .openTab(tabID: $0.tabID, spaceID: $0.spaceID, url: $0.url, title: $0.title, favicon: $0.favicon)
        }
        instantItems.append(contentsOf: tabItems)
        suggestionsQuery = query
        updateSuggestions(Array(instantItems.prefix(SuggestionProvider.maxSuggestions)))
        scheduleSearchSuggestionFetch(for: query)

        // --- Background pass: history queries off the main thread ---
        localSuggestionGeneration &+= 1
        let generation = localSuggestionGeneration
        let provider = suggestionProvider
        let spaceIDString = spaceID.uuidString
        let capturedTabID = currentTabID
        historyQueryQueue.async { [weak self] in
            // localSuggestions recomputes the open-tab matches too, but its two
            // SQLite reads are what we moved off the main thread. It touches no
            // shared mutable state, so it's safe to run here.
            let local = provider.localSuggestions(
                for: query, spaceID: spaceIDString, tabs: tabs,
                allowAutocomplete: allowAutocomplete, currentTabID: capturedTabID)
            DispatchQueue.main.async {
                guard let self else { return }
                // Drop stale results: a newer rebuild started, or the field text
                // changed since we dispatched (mirrors the network-suggestion guard).
                guard generation == self.localSuggestionGeneration,
                      self.userTypedText.trimmingCharacters(in: .whitespaces) == query else { return }
                // Apply the history-derived inline completion only if we didn't
                // already complete from an open tab and nothing has completed the
                // field since — applying it now, after the user typed more, would
                // fight their typing (which the staleness guard above prevents).
                if !appliedTabCompletion, self.inlineCompletionSuffix == nil {
                    self.applyInlineCompletion(local.inlineCompletion, for: query)
                }
                self.updateSuggestions(local.items)
            }
        }
    }

    private func activateSuggestion(at index: Int) {
        guard index < suggestions.count else { return }
        switch suggestions[index] {
        case .searchInput(let text):
            // Submit the row's own text, not the field's: with an inline
            // completion active the field holds the completed URL, but this row
            // means "go with what I actually typed".
            let input = text.trimmingCharacters(in: .whitespaces)
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

    /// Extends the text field with the completion's suffix, selected so that
    /// typing replaces it. `completion` is a display URL prefixed by `query`.
    private func applyInlineCompletion(_ completion: String?, for query: String) {
        guard let completion, completion.lowercased().hasPrefix(query.lowercased()) else { return }
        let suffix = String(completion.dropFirst(query.count))
        guard !suffix.isEmpty else { return }

        inlineCompletionSuffix = suffix

        setTextFieldQuietly(query + suffix)

        if let editor = textField.currentEditor() {
            editor.selectedRange = NSRange(location: query.count, length: suffix.count)
            // Selecting the suffix auto-scrolls a long completion so its tail is
            // visible; scroll back so the typed prefix stays in view instead.
            editor.scrollRangeToVisible(NSRange(location: query.count, length: 0))
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
            refreshLocalSuggestions(allowAutocomplete: false)
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
        configureCell(cell, for: suggestions[row])
        return cell
    }

    private func configureCell(_ cell: SuggestionCellView, for item: SuggestionItem) {
        switch item {
        case .searchInput(let text):
            let looksLikeURL = text.contains(".") && !text.contains(" ")
            cell.configure(title: text, url: nil, icon: nil, isSearch: !looksLikeURL, isGoTo: looksLikeURL)
        case .historyResult(let url, let title, let faviconURL):
            cell.configure(title: title, url: url, icon: nil, isSearch: false)
            if let faviconURL {
                cell.expectedFaviconURL = faviconURL
                suggestionProvider.loadFavicon(for: faviconURL) { [weak cell] image in
                    // The cell may have been reconfigured for another row by the
                    // time the favicon loads; don't stamp it with a stale icon.
                    guard let cell, cell.expectedFaviconURL == faviconURL, let image else { return }
                    cell.iconView.image = image
                    cell.iconView.contentTintColor = nil
                }
            }
        case .openTab(_, _, _, let title, let favicon):
            cell.configure(title: title, url: nil, icon: favicon, isSearch: false, switchToTab: true)
        case .searchSuggestion(let text):
            cell.configure(title: text, url: nil, icon: nil, isSearch: true)
        }
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
    var expectedFaviconURL: String?
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
        expectedFaviconURL = nil
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
