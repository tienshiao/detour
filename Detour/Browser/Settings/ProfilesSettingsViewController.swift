import AppKit

class ProfilesSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var tableView: NSTableView!
    private var archivePopUp: NSPopUpButton!
    private var searchEnginePopUp: NSPopUpButton!
    private var suggestionsSwitch: NSSwitch!
    private var addButton: NSButton!
    private var deleteButton: NSButton!

    private var profiles: [Profile] { TabStore.shared.profiles.filter { !$0.isIncognito } }
    private var selectedIndex: Int = 0

    private var selectedProfile: Profile? {
        let list = profiles
        guard selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    override func loadView() {
        preferredContentSize = NSSize(width: 680, height: 380)
        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        self.view = container

        let margin: CGFloat = 20
        let spacing: CGFloat = 12

        // Description label
        let descLabel = NSTextField(wrappingLabelWithString:
            "Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces.")
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(descLabel)

        // Left side: list container (table + segmented control in a bordered box)
        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.wantsLayer = true
        listContainer.layer?.borderWidth = 1
        listContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        listContainer.layer?.cornerRadius = 4
        container.addSubview(listContainer)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("profile"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        listContainer.addSubview(scrollView)

        // Separator above toolbar buttons
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(separator)

        // Toolbar buttons (borderless, no background)
        let buttonSize: CGFloat = 24

        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
                             target: self, action: #selector(addProfileClicked))
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true

        deleteButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete")!,
                                target: self, action: #selector(deleteProfileClicked))
        deleteButton.bezelStyle = .recessed
        deleteButton.isBordered = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        deleteButton.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true

        let buttonStack = NSStackView(views: [addButton, deleteButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 0
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(buttonStack)

        // Right side: settings
        let rightStack = NSStackView()
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = spacing
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rightStack)

        // Search engine row
        let searchRow = makeRow(label: "Search engine")
        searchEnginePopUp = NSPopUpButton()
        for engine in SearchEngine.allCases {
            searchEnginePopUp.addItem(withTitle: engine.name)
        }
        searchEnginePopUp.target = self
        searchEnginePopUp.action = #selector(searchEngineChanged)
        searchRow.addArrangedSubview(searchEnginePopUp)
        rightStack.addArrangedSubview(searchRow)

        // Search suggestions row
        let suggestRow = makeRow(label: "Include search engine suggestions")
        suggestionsSwitch = NSSwitch()
        suggestionsSwitch.target = self
        suggestionsSwitch.action = #selector(suggestionsToggled)
        suggestRow.addArrangedSubview(suggestionsSwitch)
        rightStack.addArrangedSubview(suggestRow)

        // Archive threshold row
        let archiveRow = makeRow(label: "Archive tabs after")
        archivePopUp = NSPopUpButton()
        for threshold in ArchiveThreshold.allCases {
            archivePopUp.addItem(withTitle: thresholdTitle(threshold))
            archivePopUp.lastItem?.representedObject = threshold
        }
        archivePopUp.target = self
        archivePopUp.action = #selector(archiveThresholdChanged)
        archiveRow.addArrangedSubview(archivePopUp)
        rightStack.addArrangedSubview(archiveRow)

        // Layout
        NSLayoutConstraint.activate([
            descLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            descLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            descLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            listContainer.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: spacing),
            listContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            listContainer.widthAnchor.constraint(equalToConstant: 220),
            listContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),

            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -2),

            buttonStack.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 4),
            buttonStack.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -2),

            rightStack.topAnchor.constraint(equalTo: listContainer.topAnchor, constant: 8),
            rightStack.leadingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: margin),
            rightStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        tableView.reloadData()
        if !profiles.isEmpty {
            selectedIndex = min(selectedIndex, profiles.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
        updateRightPane()
        updateButtonStates()
    }

    // MARK: - Helpers

    private func makeRow(label: String) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [labelField])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func thresholdTitle(_ t: ArchiveThreshold) -> String {
        switch t {
        case .twelveHours: return "12 hours"
        case .twentyFourHours: return "24 hours"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .never: return "Never"
        }
    }

    private func spaceCount(for profile: Profile) -> Int {
        TabStore.shared.spaces.filter { $0.profileID == profile.id && !$0.isIncognito }.count
    }

    private func updateRightPane() {
        guard let profile = selectedProfile else { return }
        if let index = ArchiveThreshold.allCases.firstIndex(of: profile.archiveThreshold) {
            archivePopUp.selectItem(at: index)
        }
        searchEnginePopUp.selectItem(at: profile.searchEngine.rawValue)
        suggestionsSwitch.state = profile.searchSuggestionsEnabled ? .on : .off
    }

    private func updateButtonStates() {
        let canDelete = profiles.count > 1 && selectedProfile != nil
        deleteButton.isEnabled = canDelete
    }

    // MARK: - Actions

    @objc private func archiveThresholdChanged() {
        guard let profile = selectedProfile,
              let threshold = archivePopUp.selectedItem?.representedObject as? ArchiveThreshold else { return }
        profile.archiveThreshold = threshold
        TabStore.shared.updateProfile(profile)
    }

    @objc private func searchEngineChanged() {
        guard let profile = selectedProfile,
              let engine = SearchEngine(rawValue: searchEnginePopUp.indexOfSelectedItem) else { return }
        profile.searchEngine = engine
        TabStore.shared.updateProfile(profile)
    }

    @objc private func suggestionsToggled() {
        guard let profile = selectedProfile else { return }
        profile.searchSuggestionsEnabled = (suggestionsSwitch.state == .on)
        TabStore.shared.updateProfile(profile)
    }

    @objc private func addProfileClicked() {
        let addVC = AddProfileViewController()
        addVC.onCreate = { [weak self] name in
            guard let self else { return }
            self.dismiss(nil)
            TabStore.shared.addProfile(name: name)
            self.tableView.reloadData()
            self.selectedIndex = self.profiles.count - 1
            self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
            self.updateRightPane()
            self.updateButtonStates()
        }
        presentAsSheet(addVC)
    }

    @objc private func deleteProfileClicked() {
        guard let profile = selectedProfile else { return }
        guard profiles.count > 1 else { return }

        let count = spaceCount(for: profile)
        if count > 0 {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Profile"
            alert.informativeText = "\(profile.name) is used by \(count) space\(count == 1 ? "" : "s"). Remove or reassign those spaces first."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: view.window!, completionHandler: nil)
            return
        }

        TabStore.shared.deleteProfile(id: profile.id)
        selectedIndex = max(0, selectedIndex - 1)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        updateRightPane()
        updateButtonStates()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        profiles.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let profile = profiles[row]
        let cellID = NSUserInterfaceItemIdentifier("ProfileCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let nameLabel = NSTextField(labelWithString: "")
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.tag = 1
            cell.addSubview(nameLabel)

            let countLabel = NSTextField(labelWithString: "")
            countLabel.font = .systemFont(ofSize: 11)
            countLabel.textColor = .secondaryLabelColor
            countLabel.translatesAutoresizingMaskIntoConstraints = false
            countLabel.tag = 2
            countLabel.setContentHuggingPriority(.required, for: .horizontal)
            cell.addSubview(countLabel)

            NSLayoutConstraint.activate([
                nameLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                countLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                countLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -4),
            ])
        }

        if let nameLabel = cell.viewWithTag(1) as? NSTextField {
            nameLabel.stringValue = profile.name
        }
        if let countLabel = cell.viewWithTag(2) as? NSTextField {
            let count = spaceCount(for: profile)
            countLabel.stringValue = "\(count) Space\(count == 1 ? "" : "s")"
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        selectedIndex = row
        updateRightPane()
        updateButtonStates()
    }
}
