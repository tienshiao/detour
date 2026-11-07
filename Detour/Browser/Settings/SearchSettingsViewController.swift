import AppKit

/// Settings > Search (TASK-287): the site searches, one app-wide list. Each
/// row is a site's name, keyword and address; + adds one, − removes the
/// selected one, and the pencil (or a double-click) edits it. Adding and
/// editing go through `SiteSearchForm` in a sheet whose Save button stays
/// off while the store would refuse the entry, with the reason under the
/// fields. Each profile's default search engine stays in Profiles.
final class SearchSettingsViewController: SettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: SiteSearchStore
    private var entries: [SiteSearch] { store.entries }

    private(set) var tableView: NSTableView!
    private var listContainer: SettingsListContainerView!
    private var removeButton: NSButton!
    private var editButton: NSButton!
    private var emptyLabel: NSTextField!
    private var storeObserver: NSObjectProtocol?

    /// What the Keyword column says for a site search added from the site
    /// itself (TASK-288), which has no keyword until the user gives it one.
    static let discoveredLabel = "From site"
    static let discoveredToolTip =
        "Found on the site's own pages. Press Tab when the address bar completes to this site to search it, or edit it to give it a keyword."

    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let keywordColumn = NSUserInterfaceItemIdentifier("keyword")
    private static let addressColumn = NSUserInterfaceItemIdentifier("address")

    /// `siteSearches` is the store the pane shows and edits: the shared one in
    /// the app; tests pass a store over their own database.
    init(siteSearches: SiteSearchStore = .shared) {
        store = siteSearches
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Isolated: it tears down main-actor state; the object is released on
    /// the main thread in practice, and the teardown hops there otherwise.
    isolated deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    override var paneDescription: String? {
        "Search a site straight from the address bar: type the start of its name or address, or its keyword, and press Tab (Space works after a keyword too), then type what you're looking for. Sites that offer their own search are added when you visit them. Each profile's default search engine is set in Profiles."
    }

    override var minimumContentHeight: CGFloat? { SettingsMetrics.listPaneMinimumHeight }
    override var scrollsBodyAsWhole: Bool { false }

    /// Tall enough to show every site search without scrolling the list.
    override func idealBodyHeight(fittingHeight: CGFloat) -> CGFloat {
        let title = NSTextField.settingsSectionTitle("Site Search").fittingSize.height
        let header = tableView.headerView?.frame.height ?? 0
        let rows = CGFloat(max(entries.count, 1)) * SettingsMetrics.listRowHeight
        return max(fittingHeight, title + SettingsMetrics.sectionTitleToRows + header + rows
                   + SettingsMetrics.listBarHeight + 2)
    }

    // MARK: - Building

    override func makeBody() -> NSView {
        let container = NSView()

        let title = NSTextField.settingsSectionTitle("Site Search")
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        listContainer = SettingsListContainerView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(listContainer)

        let scroll = SettingsColumnScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.style = .plain
        tableView.rowHeight = SettingsMetrics.listRowHeight
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, heading, width) in [(Self.nameColumn, "Name", 170.0), (Self.keywordColumn, "Keyword", 100.0),
                                     (Self.addressColumn, "Address", 360.0)] {
            let column = NSTableColumn(identifier: id)
            column.title = heading
            column.width = width
            column.minWidth = 60
            column.resizingMask = id == Self.addressColumn ? .autoresizingMask : .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.setAccessibilityLabel("Site searches")
        scroll.documentView = tableView
        listContainer.addSubview(scroll)

        emptyLabel = NSTextField(labelWithString: "No site searches. Click + to add one.")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(emptyLabel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(separator)

        let addButton = Self.barButton(symbol: "plus", label: "Add Site Search", target: self,
                                       action: #selector(addClicked))
        removeButton = Self.barButton(symbol: "minus", label: "Remove Site Search", target: self,
                                      action: #selector(removeClicked))
        editButton = Self.barButton(symbol: "pencil", label: "Edit Site Search", target: self,
                                    action: #selector(editClicked))
        let buttons = NSStackView(views: [addButton, removeButton, editButton])
        buttons.orientation = .horizontal
        buttons.spacing = 0
        buttons.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(buttons)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            listContainer.topAnchor.constraint(equalTo: title.bottomAnchor, constant: SettingsMetrics.sectionTitleToRows),
            listContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            listContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            scroll.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -2),

            buttons.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 4),
            buttons.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -2),
        ])

        storeObserver = NotificationCenter.default.addMainObserver(
            forName: SiteSearchStore.didChangeNotification, object: store) { [weak self] _ in
            self?.reload()
        }
        reload()
        return container
    }

    private static func barButton(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                              target: target, action: action)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: SettingsMetrics.listButtonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: SettingsMetrics.listButtonSize).isActive = true
        return button
    }

    // MARK: - State

    private var selectedEntry: SiteSearch? {
        let row = tableView.selectedRow
        return entries.indices.contains(row) ? entries[row] : nil
    }

    /// Rebuilds the rows from the store, keeping the selected entry selected.
    private func reload() {
        let selectedID = selectedEntry?.id
        tableView.reloadData()
        if let selectedID, let row = entries.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        emptyLabel.isHidden = !entries.isEmpty
        updateButtons()
        contentHeightDidChange()
    }

    private func updateButtons() {
        removeButton.isEnabled = selectedEntry != nil
        editButton.isEnabled = selectedEntry != nil
    }

    // MARK: - Actions

    @objc private func addClicked() {
        presentForm(editing: nil)
    }

    @objc private func editClicked() {
        guard let entry = selectedEntry else { return }
        presentForm(editing: entry)
    }

    @objc private func tableDoubleClicked() {
        guard tableView.clickedRow >= 0 else { return }
        editClicked()
    }

    @objc private func removeClicked() {
        guard let entry = selectedEntry else { return }
        store.remove(id: entry.id)
    }

    /// The sheet that adds a site search (`editing` nil) or edits one.
    private func presentForm(editing entry: SiteSearch?) {
        guard let window = view.window else { return }
        let form = SiteSearchForm(store: store, editing: entry)
        let alert = NSAlert()
        alert.messageText = entry == nil ? "Add Site Search" : "Edit Site Search"
        alert.informativeText = "Use %s in the address where the search terms go."
        alert.accessoryView = form
        let save = alert.addButton(withTitle: entry == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        form.onValidityChange = { [weak save] isValid in save?.isEnabled = isValid }
        form.refresh()
        alert.window.initialFirstResponder = form.nameField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let saved = form.save()
            if let saved, let row = self.entries.firstIndex(where: { $0.id == saved.id }) {
                self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.tableView.scrollRowToVisible(row)
                self.updateButtons()
            }
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier, entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = (tableView.makeView(withIdentifier: column, owner: nil) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = column
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.toolTip = nil
        switch column {
        case Self.nameColumn:
            cell.textField?.stringValue = entry.name
            cell.textField?.textColor = .labelColor
        case Self.keywordColumn where entry.isDiscovered:
            // Discovered (TASK-288): no keyword yet, and where it came from.
            cell.textField?.stringValue = Self.discoveredLabel
            cell.textField?.textColor = .tertiaryLabelColor
            cell.toolTip = Self.discoveredToolTip
        case Self.keywordColumn:
            cell.textField?.stringValue = entry.keyword
            cell.textField?.textColor = .labelColor
        default:
            cell.textField?.stringValue = entry.urlTemplate
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}

// MARK: - SiteSearchForm

/// The fields of the add / edit sheet (TASK-287): name, keyword, address. It
/// says what the store would refuse the entry for, and `save()` adds or
/// updates through the store, so the sheet can never save what the store
/// would not.
final class SiteSearchForm: NSView, NSTextFieldDelegate {
    let nameField = NSTextField()
    let keywordField = NSTextField()
    let addressField = NSTextField()
    private let problemLabel = NSTextField(wrappingLabelWithString: "")

    private let store: SiteSearchStore
    private let original: SiteSearch?
    /// Called with whether the fields can be saved, after every edit.
    var onValidityChange: ((Bool) -> Void)?

    init(store: SiteSearchStore, editing original: SiteSearch?) {
        self.store = store
        self.original = original
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 150))

        nameField.placeholderString = "YouTube"
        keywordField.placeholderString = "Optional, such as yt"
        addressField.placeholderString = "https://www.youtube.com/results?search_query=%s"
        nameField.stringValue = original?.name ?? ""
        keywordField.stringValue = original?.keyword ?? ""
        addressField.stringValue = original?.urlTemplate ?? ""

        let grid = NSGridView(views: [
            [Self.label("Name:"), nameField],
            [Self.label("Keyword:"), keywordField],
            [Self.label("Address:"), addressField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        for field in [nameField, keywordField, addressField] {
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 270).isActive = true
        }
        nameField.setAccessibilityLabel("Name")
        keywordField.setAccessibilityLabel("Keyword")
        addressField.setAccessibilityLabel("Address")
        nameField.nextKeyView = keywordField
        keywordField.nextKeyView = addressField

        problemLabel.font = .systemFont(ofSize: 11)
        problemLabel.textColor = .secondaryLabelColor
        problemLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(problemLabel)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            problemLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            problemLabel.leadingAnchor.constraint(equalTo: addressField.leadingAnchor),
            problemLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    /// The entry the fields describe, with the edited entry's id.
    var entry: SiteSearch {
        SiteSearch(id: original?.id ?? formID, name: nameField.stringValue, keyword: keywordField.stringValue,
                   urlTemplate: addressField.stringValue)
    }

    /// One id for the new entry across edits, so the duplicate check skips
    /// nothing it should not.
    private let formID = UUID()

    /// Why the fields cannot be saved; empty when they can.
    var problems: [SiteSearchProblem] { store.problems(for: entry) }

    /// Whether the user has typed in the form: a new, empty form does not
    /// greet them with "Enter a name."; Save is off either way.
    private var hasEdited = false

    /// The sentence under the fields: the first problem, once there is
    /// something to judge (an edit, or an entry being edited).
    var problemMessage: String { problemLabel.stringValue }

    /// Shows the first problem and reports validity.
    func refresh() {
        let problems = problems
        problemLabel.stringValue = hasEdited || original != nil ? problems.first?.message ?? "" : ""
        onValidityChange?(problems.isEmpty)
    }

    func controlTextDidChange(_ obj: Notification) {
        hasEdited = true
        refresh()
    }

    /// Adds or updates the entry through the store; the stored entry, or nil
    /// when the store refused it.
    @discardableResult
    func save() -> SiteSearch? {
        if original != nil {
            return store.update(entry) ? store.entry(withID: entry.id) : nil
        }
        return store.add(entry)
    }
}
