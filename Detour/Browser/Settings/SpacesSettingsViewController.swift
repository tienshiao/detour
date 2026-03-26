import AppKit

class SpacesSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var tableView: NSTableView!
    private var nameField: NSTextField!
    private var emojiButton: NSButton!
    private var hiddenEmojiField: NSTextField!
    private var profilePopUp: NSPopUpButton!
    private var colorWell: NSColorWell!
    private var gridView: NSGridView!
    private var addButton: NSButton!
    private var deleteButton: NSButton!
    private var profileIDs: [UUID] = []

    private static let dragType = NSPasteboard.PasteboardType("com.detour.space-row")

    private var spaces: [Space] {
        TabStore.shared.spaces.filter { !$0.isIncognito }
    }

    private var selectedIndex: Int = 0

    private var selectedSpace: Space? {
        let list = spaces
        guard selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    override func loadView() {
        preferredContentSize = NSSize(width: 740, height: 400)
        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        self.view = container

        let margin: CGFloat = 20
        let spacing: CGFloat = 12

        // Description label
        let descLabel = NSTextField(wrappingLabelWithString:
            "Spaces are workspaces that group your tabs together. Each Space uses a Profile for its cookies, history, and extensions.")
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(descLabel)

        // Left side: list container
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
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("space"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.dragType])
        scrollView.documentView = tableView
        listContainer.addSubview(scrollView)

        // Separator above toolbar buttons
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(separator)

        // Toolbar buttons
        let buttonSize: CGFloat = 24

        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
                             target: self, action: #selector(addSpaceClicked))
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true

        deleteButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete")!,
                                target: self, action: #selector(deleteSpaceClicked))
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

        // Right side: settings grid
        nameField = NSTextField()
        nameField.placeholderString = "Space name"
        nameField.font = .systemFont(ofSize: 13)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        nameField.target = self
        nameField.action = #selector(nameChanged)

        // Emoji button + hidden text field for character palette input
        emojiButton = NSButton(title: "⭐️", target: self, action: #selector(showEmojiPicker))
        emojiButton.bezelStyle = .rounded
        emojiButton.font = .systemFont(ofSize: 20)
        emojiButton.translatesAutoresizingMaskIntoConstraints = false

        hiddenEmojiField = NSTextField()
        hiddenEmojiField.translatesAutoresizingMaskIntoConstraints = false
        hiddenEmojiField.alphaValue = 0
        hiddenEmojiField.delegate = self
        hiddenEmojiField.widthAnchor.constraint(equalToConstant: 1).isActive = true
        hiddenEmojiField.heightAnchor.constraint(equalToConstant: 1).isActive = true
        container.addSubview(hiddenEmojiField)

        // Profile dropdown
        profilePopUp = NSPopUpButton()
        profilePopUp.translatesAutoresizingMaskIntoConstraints = false
        profilePopUp.target = self
        profilePopUp.action = #selector(profileChanged)

        // Color well
        colorWell = NSColorWell()
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.colorWellStyle = .expanded
        colorWell.target = self
        colorWell.action = #selector(colorChanged)

        gridView = NSGridView(views: [
            [makeLabel("Name"), nameField],           // row 0
            [makeLabel("Emoji"), emojiButton],          // row 1
            [makeLabel("Profile"), profilePopUp],      // row 2
            [makeLabel("Color"), colorWell],            // row 3
        ])
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.rowSpacing = spacing
        gridView.columnSpacing = 8
        gridView.column(at: 0).xPlacement = .trailing
        gridView.column(at: 1).xPlacement = .leading

        // Wrap grid in a flipped scroll view
        let rightScrollView = NSScrollView()
        rightScrollView.hasVerticalScroller = true
        rightScrollView.borderType = .noBorder
        rightScrollView.drawsBackground = false
        rightScrollView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        rightScrollView.contentView = clipView
        rightScrollView.documentView = gridView

        container.addSubview(rightScrollView)

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

            rightScrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            rightScrollView.leadingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: margin),
            rightScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            rightScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),

            gridView.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 8),
            gridView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            gridView.trailingAnchor.constraint(lessThanOrEqualTo: clipView.trailingAnchor),

            hiddenEmojiField.leadingAnchor.constraint(equalTo: emojiButton.leadingAnchor),
            hiddenEmojiField.topAnchor.constraint(equalTo: emojiButton.topAnchor),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadProfileMenu()
        tableView.reloadData()
        if !spaces.isEmpty {
            selectedIndex = min(selectedIndex, spaces.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
        updateRightPane()
        updateButtonStates()
    }

    /// Select a space by ID (used when opening from sidebar).
    func selectSpace(id: UUID) {
        if let idx = spaces.firstIndex(where: { $0.id == id }) {
            selectedIndex = idx
            if isViewLoaded {
                tableView.reloadData()
                tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                updateRightPane()
                updateButtonStates()
            }
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        return label
    }

    private func reloadProfileMenu() {
        profilePopUp.removeAllItems()
        profileIDs.removeAll()

        let profiles = TabStore.shared.profiles.filter { !$0.isIncognito }
        for profile in profiles {
            profilePopUp.addItem(withTitle: profile.name)
            profileIDs.append(profile.id)
        }
    }

    private func updateRightPane() {
        guard let space = selectedSpace else { return }
        nameField.stringValue = space.name
        emojiButton.title = space.emoji
        hiddenEmojiField.stringValue = space.emoji
        colorWell.color = NSColor(hex: space.colorHex) ?? .controlAccentColor

        // Select the space's profile in the dropdown
        if let idx = profileIDs.firstIndex(of: space.profileID) {
            profilePopUp.selectItem(at: idx)
        }
    }

    private func updateButtonStates() {
        deleteButton.isEnabled = spaces.count > 1
    }

    private func saveSpace(_ space: Space, name: String? = nil, emoji: String? = nil, colorHex: String? = nil, profileID: UUID? = nil) {
        TabStore.shared.updateSpace(
            id: space.id,
            name: name ?? space.name,
            emoji: emoji ?? space.emoji,
            colorHex: colorHex ?? space.colorHex,
            profileID: profileID ?? space.profileID
        )
        tableView.reloadData(forRowIndexes: IndexSet(integer: selectedIndex),
                             columnIndexes: IndexSet(integer: 0))
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    // MARK: - Actions

    @objc private func nameChanged() {
        guard let space = selectedSpace else { return }
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else {
            nameField.stringValue = space.name
            return
        }
        saveSpace(space, name: newName)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === hiddenEmojiField else { return }
        guard let space = selectedSpace else { return }
        let newEmoji = hiddenEmojiField.stringValue
        guard !newEmoji.isEmpty else { return }
        let emoji = String(newEmoji.prefix(1))
        hiddenEmojiField.stringValue = emoji
        emojiButton.title = emoji
        saveSpace(space, emoji: emoji)
    }

    @objc private func showEmojiPicker() {
        view.window?.makeFirstResponder(hiddenEmojiField)
        NSApp.orderFrontCharacterPalette(nil)
    }

    @objc private func profileChanged() {
        guard let space = selectedSpace,
              let window = view.window else { return }
        let idx = profilePopUp.indexOfSelectedItem
        guard idx >= 0, idx < profileIDs.count else { return }
        let newProfileID = profileIDs[idx]
        guard newProfileID != space.profileID else { return }

        let spaceID = space.id
        let alert = NSAlert()
        alert.messageText = "Change Profile?"
        alert.informativeText = "Changing the profile will change which cookies and login sessions this space uses."
        alert.addButton(withTitle: "Change")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self,
                  let space = TabStore.shared.space(withID: spaceID) else { return }
            if response == .alertFirstButtonReturn {
                self.saveSpace(space, profileID: newProfileID)
            } else {
                if let oldIdx = self.profileIDs.firstIndex(of: space.profileID) {
                    self.profilePopUp.selectItem(at: oldIdx)
                }
            }
        }
    }

    @objc private func colorChanged() {
        guard let space = selectedSpace else { return }
        saveSpace(space, colorHex: colorWell.color.toHex())
    }

    @objc private func addSpaceClicked() {
        guard let profileID = TabStore.shared.profiles.first(where: { !$0.isIncognito })?.id
                ?? TabStore.shared.profiles.first?.id else { return }
        TabStore.shared.addSpace(name: "Space", emoji: "⭐️", colorHex: Space.presetColors[0], profileID: profileID)
        tableView.reloadData()
        selectedIndex = spaces.count - 1
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        updateRightPane()
        updateButtonStates()
    }

    @objc private func deleteSpaceClicked() {
        guard let space = selectedSpace, spaces.count > 1 else { return }
        TabStore.shared.deleteSpace(id: space.id)
        selectedIndex = max(0, selectedIndex - 1)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        updateRightPane()
        updateButtonStates()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        spaces.count
    }

    // MARK: - Drag and Drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowStr = item.string(forType: Self.dragType),
              let sourceRow = Int(rowStr) else { return false }

        // Convert table rows to indices in the full spaces array (skipping incognito)
        let nonIncognitoSpaces = spaces
        guard sourceRow >= 0, sourceRow < nonIncognitoSpaces.count else { return false }

        let allSpaces = TabStore.shared.spaces
        guard let sourceGlobalIndex = allSpaces.firstIndex(where: { $0.id == nonIncognitoSpaces[sourceRow].id }) else { return false }

        let destRow = row > sourceRow ? row - 1 : row
        let clampedDestRow = min(destRow, nonIncognitoSpaces.count - 1)
        guard clampedDestRow >= 0 else { return false }

        let destGlobalIndex: Int
        if clampedDestRow == sourceRow {
            return false
        } else {
            guard let idx = allSpaces.firstIndex(where: { $0.id == nonIncognitoSpaces[clampedDestRow].id }) else { return false }
            destGlobalIndex = idx
        }

        TabStore.shared.moveSpace(from: sourceGlobalIndex, to: destGlobalIndex)

        // Update selection to follow the moved space
        selectedIndex = clampedDestRow
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let space = spaces[row]
        let cellID = NSUserInterfaceItemIdentifier("SpaceCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let emojiLabel = NSTextField(labelWithString: "")
            emojiLabel.font = .systemFont(ofSize: 13)
            emojiLabel.translatesAutoresizingMaskIntoConstraints = false
            emojiLabel.tag = 1
            emojiLabel.setContentHuggingPriority(.required, for: .horizontal)
            cell.addSubview(emojiLabel)

            let nameLabel = NSTextField(labelWithString: "")
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.tag = 2
            nameLabel.lineBreakMode = .byTruncatingTail
            cell.addSubview(nameLabel)

            let profileLabel = NSTextField(labelWithString: "")
            profileLabel.font = .systemFont(ofSize: 11)
            profileLabel.textColor = .secondaryLabelColor
            profileLabel.translatesAutoresizingMaskIntoConstraints = false
            profileLabel.tag = 3
            profileLabel.setContentHuggingPriority(.required, for: .horizontal)
            cell.addSubview(profileLabel)

            NSLayoutConstraint.activate([
                emojiLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                emojiLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                nameLabel.leadingAnchor.constraint(equalTo: emojiLabel.trailingAnchor, constant: 4),
                nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                profileLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                profileLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: profileLabel.leadingAnchor, constant: -4),
            ])
        }

        if let emojiLabel = cell.viewWithTag(1) as? NSTextField {
            emojiLabel.stringValue = space.emoji
        }
        if let nameLabel = cell.viewWithTag(2) as? NSTextField {
            nameLabel.stringValue = space.name
        }
        if let profileLabel = cell.viewWithTag(3) as? NSTextField {
            profileLabel.stringValue = space.profile?.name ?? ""
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
