import AppKit

class AddSpaceViewController: NSViewController {
    var onCreate: ((String, String, String, UUID) -> Void)?
    var existingSpace: (name: String, emoji: String, colorHex: String, profileID: UUID)?
    private var selectedColorHex = Space.presetColors[0]
    private var selectedProfileID: UUID!
    private var colorButtons: [NSButton] = []
    private var actionButton: NSButton!
    private var nameField: NSTextField!
    private var emojiButton: NSButton!
    private var selectedEmoji = "⭐️"
    private var profilePopUp: NSPopUpButton!
    private var profileIDs: [UUID] = []

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 210))

        nameField = NSTextField()
        nameField.placeholderString = "Space name"
        nameField.translatesAutoresizingMaskIntoConstraints = false

        emojiButton = NSButton(title: "⭐️", target: self, action: #selector(showEmojiPicker))
        emojiButton.bezelStyle = .rounded
        emojiButton.font = .systemFont(ofSize: 20)
        emojiButton.translatesAutoresizingMaskIntoConstraints = false

        // Profile dropdown
        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.font = .systemFont(ofSize: 12)
        profileLabel.translatesAutoresizingMaskIntoConstraints = false

        profilePopUp = NSPopUpButton()
        profilePopUp.translatesAutoresizingMaskIntoConstraints = false
        reloadProfileMenu()

        // Select existing profile if editing
        if let existing = existingSpace, let idx = profileIDs.firstIndex(of: existing.profileID) {
            profilePopUp.selectItem(at: idx)
            selectedProfileID = existing.profileID
        }

        let colorStack = NSStackView()
        colorStack.orientation = .horizontal
        colorStack.spacing = 6
        colorStack.translatesAutoresizingMaskIntoConstraints = false

        let initialColorHex = existingSpace?.colorHex ?? Space.presetColors[0]
        selectedColorHex = initialColorHex
        let selectedIndex = Space.presetColors.firstIndex(of: initialColorHex) ?? 0

        for (i, hex) in Space.presetColors.enumerated() {
            let btn = NSButton()
            btn.wantsLayer = true
            btn.isBordered = false
            btn.title = ""
            btn.layer?.cornerRadius = 10
            btn.layer?.backgroundColor = (NSColor(hex: hex) ?? .controlAccentColor).cgColor
            btn.tag = i
            btn.target = self
            btn.action = #selector(colorSelected(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 20),
                btn.heightAnchor.constraint(equalToConstant: 20),
            ])
            if i == selectedIndex {
                btn.layer?.borderWidth = 2
                btn.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.5).cgColor
            }
            colorButtons.append(btn)
            colorStack.addArrangedSubview(btn)
        }

        let buttonTitle = existingSpace != nil ? "Save" : "Create"
        actionButton = NSButton(title: buttonTitle, target: self, action: #selector(createClicked))
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        if let existing = existingSpace {
            nameField.stringValue = existing.name
            selectedEmoji = existing.emoji
            emojiButton.title = existing.emoji
        }

        container.addSubview(nameField)
        container.addSubview(emojiButton)
        container.addSubview(profileLabel)
        container.addSubview(profilePopUp)
        container.addSubview(colorStack)
        container.addSubview(actionButton)

        NSLayoutConstraint.activate([
            nameField.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            emojiButton.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),
            emojiButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            profileLabel.topAnchor.constraint(equalTo: emojiButton.bottomAnchor, constant: 12),
            profileLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            profilePopUp.centerYAnchor.constraint(equalTo: profileLabel.centerYAnchor),
            profilePopUp.leadingAnchor.constraint(equalTo: profileLabel.trailingAnchor, constant: 8),
            profilePopUp.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            colorStack.topAnchor.constraint(equalTo: profilePopUp.bottomAnchor, constant: 12),
            colorStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            actionButton.topAnchor.constraint(equalTo: colorStack.bottomAnchor, constant: 12),
            actionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])

        self.view = container
    }

    private func reloadProfileMenu() {
        profilePopUp.removeAllItems()
        profileIDs.removeAll()

        let profiles = TabStore.shared.profiles.filter { !$0.isIncognito }
        for profile in profiles {
            profilePopUp.addItem(withTitle: profile.name)
            profileIDs.append(profile.id)
        }
        profilePopUp.menu?.addItem(.separator())
        profilePopUp.addItem(withTitle: "New Profile...")

        if selectedProfileID == nil {
            selectedProfileID = profiles.first?.id
        }

        profilePopUp.target = self
        profilePopUp.action = #selector(profileChanged(_:))
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx < profileIDs.count {
            selectedProfileID = profileIDs[idx]
        } else {
            // "New Profile..." selected — show sheet
            let addProfileVC = AddProfileViewController()
            addProfileVC.onCreate = { [weak self] name in
                guard let self else { return }
                self.dismiss(addProfileVC)
                let newProfile = TabStore.shared.addProfile(name: name)
                self.selectedProfileID = newProfile.id
                self.reloadProfileMenu()
                if let newIdx = self.profileIDs.firstIndex(of: newProfile.id) {
                    self.profilePopUp.selectItem(at: newIdx)
                }
            }
            presentAsSheet(addProfileVC)
        }
    }

    @objc private func colorSelected(_ sender: NSButton) {
        selectedColorHex = Space.presetColors[sender.tag]
        for btn in colorButtons {
            btn.layer?.borderWidth = 0
        }
        sender.layer?.borderWidth = 2
        sender.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.5).cgColor
    }

    @objc private func showEmojiPicker() {
        EmojiPickerViewController.showPicker(relativeTo: emojiButton) { [weak self] emoji in
            guard let self else { return }
            self.selectedEmoji = emoji
            self.emojiButton.title = emoji
        }
    }

    @objc private func createClicked() {
        let name = nameField.stringValue
        let finalName = name.isEmpty ? "Space" : name
        let finalEmoji = selectedEmoji

        // Warn if editing and profile changed
        if let existing = existingSpace, existing.profileID != selectedProfileID {
            let alert = NSAlert()
            alert.messageText = "Change Profile?"
            alert.informativeText = "Changing the profile will change which cookies and login sessions this space uses."
            alert.addButton(withTitle: "Change")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
        }

        onCreate?(finalName, finalEmoji, selectedColorHex, selectedProfileID)
    }
}
