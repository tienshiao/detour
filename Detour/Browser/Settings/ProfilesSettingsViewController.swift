import AppKit

class ProfilesSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var tableView: NSTableView!
    private var archivePopUp: NSPopUpButton!
    private var sleepPopUp: NSPopUpButton!
    private var isolationWarningLabel: NSTextField!
    private var searchEnginePopUp: NSPopUpButton!
    private var suggestionsSwitch: NSSwitch!
    private var perTabIsolationSwitch: NSSwitch!
    private var userAgentPopUp: NSPopUpButton!
    private var customUserAgentField: NSTextField!
    private var profileNameField: NSTextField!
    private var privateNoteLabel: NSTextField!
    private var uaPreviewLabel: NSTextField!
    private var adBlockSwitch: NSSwitch!
    private var easyListSwitch: NSSwitch!
    private var easyPrivacySwitch: NSSwitch!
    private var easyListCookieSwitch: NSSwitch!
    private var malwareFilterSwitch: NSSwitch!
    private var gridView: NSGridView!
    private var addButton: NSButton!
    private var deleteButton: NSButton!
    private var extensionTogglesBox: NSBox!
    private var extensionTogglesStack: NSStackView!

    /// All profiles including the built-in incognito profile.
    private var profiles: [Profile] {
        TabStore.shared.profiles.filter { !$0.isIncognito || $0.id == TabStore.incognitoProfileID }
    }
    private var selectedIndex: Int = 0

    private var selectedProfile: Profile? {
        let list = profiles
        guard selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    override func loadView() {
        preferredContentSize = NSSize(width: 740, height: 580)
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

        // Right side: settings (NSGridView for right-aligned labels)
        profileNameField = NSTextField()
        profileNameField.placeholderString = "Profile name"
        profileNameField.font = .systemFont(ofSize: 13)
        profileNameField.translatesAutoresizingMaskIntoConstraints = false
        profileNameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        profileNameField.target = self
        profileNameField.action = #selector(profileNameChanged)

        privateNoteLabel = NSTextField(wrappingLabelWithString: "This profile is used for Private Windows.")
        privateNoteLabel.font = .systemFont(ofSize: 11)
        privateNoteLabel.textColor = .secondaryLabelColor
        privateNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        privateNoteLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        searchEnginePopUp = NSPopUpButton()
        for engine in SearchEngine.allCases {
            searchEnginePopUp.addItem(withTitle: engine.name)
        }
        searchEnginePopUp.target = self
        searchEnginePopUp.action = #selector(searchEngineChanged)

        suggestionsSwitch = NSSwitch()
        suggestionsSwitch.target = self
        suggestionsSwitch.action = #selector(suggestionsToggled)

        archivePopUp = NSPopUpButton()
        for threshold in ArchiveThreshold.allCases {
            archivePopUp.addItem(withTitle: thresholdTitle(threshold))
            archivePopUp.lastItem?.representedObject = threshold
        }
        archivePopUp.target = self
        archivePopUp.action = #selector(archiveThresholdChanged)

        sleepPopUp = NSPopUpButton()
        for threshold in SleepThreshold.allCases {
            sleepPopUp.addItem(withTitle: sleepThresholdTitle(threshold))
            sleepPopUp.lastItem?.representedObject = threshold
        }
        sleepPopUp.target = self
        sleepPopUp.action = #selector(sleepThresholdChanged)

        isolationWarningLabel = NSTextField(wrappingLabelWithString:
            "Sleeping tabs will lose session data when per-tab isolation is enabled.")
        isolationWarningLabel.font = .systemFont(ofSize: 11)
        isolationWarningLabel.textColor = .secondaryLabelColor
        isolationWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        isolationWarningLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        perTabIsolationSwitch = NSSwitch()
        perTabIsolationSwitch.target = self
        perTabIsolationSwitch.action = #selector(perTabIsolationToggled)

        adBlockSwitch = NSSwitch()
        adBlockSwitch.target = self
        adBlockSwitch.action = #selector(adBlockToggled)

        easyListSwitch = NSSwitch()
        easyListSwitch.target = self
        easyListSwitch.action = #selector(easyListToggled)
        easyListSwitch.controlSize = .small

        easyPrivacySwitch = NSSwitch()
        easyPrivacySwitch.target = self
        easyPrivacySwitch.action = #selector(easyPrivacyToggled)
        easyPrivacySwitch.controlSize = .small

        easyListCookieSwitch = NSSwitch()
        easyListCookieSwitch.target = self
        easyListCookieSwitch.action = #selector(easyListCookieToggled)
        easyListCookieSwitch.controlSize = .small

        malwareFilterSwitch = NSSwitch()
        malwareFilterSwitch.target = self
        malwareFilterSwitch.action = #selector(malwareFilterToggled)
        malwareFilterSwitch.controlSize = .small

        // Group filter list switches inside a bordered box
        let filterListBox = NSBox()
        filterListBox.boxType = .custom
        filterListBox.borderColor = .separatorColor
        filterListBox.borderWidth = 1
        filterListBox.cornerRadius = 6
        filterListBox.fillColor = .clear
        filterListBox.contentViewMargins = NSSize(width: 10, height: 8)
        filterListBox.translatesAutoresizingMaskIntoConstraints = false

        let filterStack = NSStackView(views: [
            makeFilterRow(filterSwitch: easyListSwitch, title: "EasyList (ads)"),
            makeFilterRow(filterSwitch: easyPrivacySwitch, title: "EasyPrivacy (trackers)"),
            makeFilterRow(filterSwitch: easyListCookieSwitch, title: "Cookie notices"),
            makeFilterRow(filterSwitch: malwareFilterSwitch, title: "Malicious URLs"),
        ])
        filterStack.orientation = .vertical
        filterStack.alignment = .leading
        filterStack.spacing = 6
        filterStack.translatesAutoresizingMaskIntoConstraints = false

        if let contentView = filterListBox.contentView {
            contentView.addSubview(filterStack)
            NSLayoutConstraint.activate([
                filterStack.topAnchor.constraint(equalTo: contentView.topAnchor),
                filterStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                filterStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                filterStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        userAgentPopUp = NSPopUpButton()
        userAgentPopUp.addItems(withTitles: ["Detour", "Safari", "Custom"])
        userAgentPopUp.target = self
        userAgentPopUp.action = #selector(userAgentModeChanged)

        customUserAgentField = NSTextField()
        customUserAgentField.placeholderString = "Enter custom user agent"
        customUserAgentField.font = .systemFont(ofSize: 13)
        customUserAgentField.translatesAutoresizingMaskIntoConstraints = false
        customUserAgentField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        customUserAgentField.target = self
        customUserAgentField.action = #selector(customUserAgentChanged)

        uaPreviewLabel = NSTextField(wrappingLabelWithString: "")
        uaPreviewLabel.font = .systemFont(ofSize: 11)
        uaPreviewLabel.textColor = .secondaryLabelColor
        uaPreviewLabel.isSelectable = true
        uaPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
        uaPreviewLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true

        // Extension per-profile toggles
        extensionTogglesBox = NSBox()
        extensionTogglesBox.boxType = .custom
        extensionTogglesBox.borderColor = .separatorColor
        extensionTogglesBox.borderWidth = 1
        extensionTogglesBox.cornerRadius = 6
        extensionTogglesBox.fillColor = .clear
        extensionTogglesBox.contentViewMargins = NSSize(width: 10, height: 8)
        extensionTogglesBox.translatesAutoresizingMaskIntoConstraints = false

        extensionTogglesStack = NSStackView()
        extensionTogglesStack.orientation = .vertical
        extensionTogglesStack.alignment = .leading
        extensionTogglesStack.spacing = 6
        extensionTogglesStack.translatesAutoresizingMaskIntoConstraints = false

        if let contentView = extensionTogglesBox.contentView {
            contentView.addSubview(extensionTogglesStack)
            NSLayoutConstraint.activate([
                extensionTogglesStack.topAnchor.constraint(equalTo: contentView.topAnchor),
                extensionTogglesStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                extensionTogglesStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                extensionTogglesStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        gridView = NSGridView(views: [
            [makeLabel("Name"), profileNameField],                   // row 0
            [NSGridCell.emptyContentView, privateNoteLabel],         // row 1
            [makeLabel("Search engine"), searchEnginePopUp],         // row 2
            [makeLabel("Search suggestions"), suggestionsSwitch],    // row 3
            [makeLabel("Archive tabs after"), archivePopUp],         // row 4
            [makeLabel("Sleep tabs after"), sleepPopUp],             // row 5
            [NSGridCell.emptyContentView, isolationWarningLabel],    // row 6
            [makeLabel("Per-tab isolation"), perTabIsolationSwitch], // row 7
            [makeLabel("Content blocking"), adBlockSwitch],          // row 8
            [NSGridCell.emptyContentView, filterListBox],            // row 9
            [makeLabel("User agent"), userAgentPopUp],               // row 10
            [makeLabel("Custom string"), customUserAgentField],      // row 11
            [NSGridCell.emptyContentView, uaPreviewLabel],           // row 12
            [makeLabel("Extensions"), extensionTogglesBox],          // row 13
        ])
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.rowSpacing = spacing
        gridView.columnSpacing = 8
        gridView.column(at: 0).xPlacement = .trailing
        gridView.column(at: 1).xPlacement = .leading
        gridView.row(at: 1).isHidden = true   // private note row
        gridView.row(at: 6).isHidden = true   // isolation warning row
        gridView.row(at: 11).isHidden = true  // custom string row

        // Wrap the grid in a flipped clip view + scroll view so the right pane scrolls
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

        NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                                name: ExtensionManager.extensionsDidChangeNotification, object: nil)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self, name: ExtensionManager.extensionsDidChangeNotification, object: nil)
    }

    @objc private func extensionsDidChange() {
        updateExtensionToggles()
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        return label
    }

    private func makeFilterRow(filterSwitch: NSSwitch, title: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [filterSwitch, label])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
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

    private func sleepThresholdTitle(_ t: SleepThreshold) -> String {
        switch t {
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .never: return "Never"
        }
    }

    private func spaceCount(for profile: Profile) -> Int {
        TabStore.shared.spaces.filter { $0.profileID == profile.id && !$0.isIncognito }.count
    }

    private func updateRightPane() {
        guard let profile = selectedProfile else { return }
        profileNameField.stringValue = profile.name
        profileNameField.isEditable = !profile.isIncognito
        gridView.row(at: 1).isHidden = !profile.isIncognito
        if let index = ArchiveThreshold.allCases.firstIndex(of: profile.archiveThreshold) {
            archivePopUp.selectItem(at: index)
        }
        if let index = SleepThreshold.allCases.firstIndex(of: profile.sleepThreshold) {
            sleepPopUp.selectItem(at: index)
        }
        searchEnginePopUp.selectItem(at: profile.searchEngine.rawValue)
        suggestionsSwitch.state = profile.searchSuggestionsEnabled ? .on : .off
        perTabIsolationSwitch.state = profile.isPerTabIsolation ? .on : .off
        userAgentPopUp.selectItem(at: profile.userAgentMode.rawValue)
        customUserAgentField.stringValue = profile.customUserAgent ?? ""
        // Row 4 = archive (hidden for incognito)
        gridView.row(at: 4).isHidden = profile.isIncognito
        // Row 6 = isolation warning (shown when both per-tab isolation and sleep are active)
        gridView.row(at: 6).isHidden = !(profile.isPerTabIsolation && profile.sleepThreshold != .never)
        // Ad blocking
        adBlockSwitch.state = profile.isAdBlockingEnabled ? .on : .off
        easyListSwitch.state = profile.isEasyListEnabled ? .on : .off
        easyPrivacySwitch.state = profile.isEasyPrivacyEnabled ? .on : .off
        easyListCookieSwitch.state = profile.isEasyListCookieEnabled ? .on : .off
        easyListSwitch.isEnabled = profile.isAdBlockingEnabled
        easyPrivacySwitch.isEnabled = profile.isAdBlockingEnabled
        easyListCookieSwitch.isEnabled = profile.isAdBlockingEnabled
        malwareFilterSwitch.state = profile.isMalwareFilterEnabled ? .on : .off
        malwareFilterSwitch.isEnabled = profile.isAdBlockingEnabled
        // Row 11 = custom UA string
        gridView.row(at: 11).isHidden = profile.userAgentMode != .custom
        updateUAPreview()
        updateExtensionToggles()
    }

    private func updateExtensionToggles() {
        guard let profile = selectedProfile else { return }
        let enabledExts = ExtensionManager.shared.enabledExtensions

        // Hide if no extensions installed
        gridView.row(at: 13).isHidden = enabledExts.isEmpty

        // Rebuild toggle rows
        extensionTogglesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for ext in enabledExts {
            let toggle = NSSwitch()
            toggle.controlSize = .small
            let isEnabled = AppDatabase.shared.isExtensionEnabled(
                extensionID: ext.id, profileID: profile.id.uuidString)
            toggle.state = isEnabled ? .on : .off
            toggle.identifier = NSUserInterfaceItemIdentifier(ext.id)
            toggle.target = self
            toggle.action = #selector(extensionToggled(_:))

            let resolvedName = ExtensionI18n.resolve(ext.manifest.name, messages: ext.messages)
            let label = NSTextField(labelWithString: resolvedName)
            label.font = .systemFont(ofSize: 12)

            let row = NSStackView(views: [toggle, label])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            extensionTogglesStack.addArrangedSubview(row)
        }
    }

    @objc private func extensionToggled(_ sender: NSSwitch) {
        guard let profile = selectedProfile,
              let extID = sender.identifier?.rawValue else { return }
        let enabled = sender.state == .on
        ExtensionManager.shared.setEnabled(id: extID, profileID: profile.id, enabled: enabled)
    }

    private func updateUAPreview() {
        uaPreviewLabel.stringValue = selectedProfile?.resolvedUserAgent() ?? ""
    }

    private func updateButtonStates() {
        let canDelete = profiles.count > 1
            && selectedProfile != nil
            && selectedProfile?.id != TabStore.incognitoProfileID
        deleteButton.isEnabled = canDelete
    }

    // MARK: - Actions

    @objc private func profileNameChanged() {
        guard let profile = selectedProfile else { return }
        guard !profile.isIncognito else { return }
        let newName = profileNameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else {
            profileNameField.stringValue = profile.name
            return
        }
        profile.name = newName
        TabStore.shared.updateProfile(profile)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

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

    @objc private func sleepThresholdChanged() {
        guard let profile = selectedProfile,
              let threshold = sleepPopUp.selectedItem?.representedObject as? SleepThreshold else { return }
        profile.sleepThreshold = threshold
        gridView.row(at: 6).isHidden = !(profile.isPerTabIsolation && threshold != .never)
        TabStore.shared.updateProfile(profile)
    }

    @objc private func perTabIsolationToggled() {
        guard let profile = selectedProfile else { return }
        profile.isPerTabIsolation = (perTabIsolationSwitch.state == .on)
        gridView.row(at: 6).isHidden = !(profile.isPerTabIsolation && profile.sleepThreshold != .never)
        TabStore.shared.updateProfile(profile)
    }

    @objc private func adBlockToggled() {
        guard let profile = selectedProfile else { return }
        profile.isAdBlockingEnabled = (adBlockSwitch.state == .on)
        easyListSwitch.isEnabled = profile.isAdBlockingEnabled
        easyPrivacySwitch.isEnabled = profile.isAdBlockingEnabled
        easyListCookieSwitch.isEnabled = profile.isAdBlockingEnabled
        malwareFilterSwitch.isEnabled = profile.isAdBlockingEnabled
        TabStore.shared.updateProfile(profile)
        ContentBlockerManager.shared.reapplyRuleLists()
    }

    @objc private func easyListToggled() {
        guard let profile = selectedProfile else { return }
        profile.isEasyListEnabled = (easyListSwitch.state == .on)
        TabStore.shared.updateProfile(profile)
        ContentBlockerManager.shared.reapplyRuleLists()
    }

    @objc private func easyPrivacyToggled() {
        guard let profile = selectedProfile else { return }
        profile.isEasyPrivacyEnabled = (easyPrivacySwitch.state == .on)
        TabStore.shared.updateProfile(profile)
        ContentBlockerManager.shared.reapplyRuleLists()
    }

    @objc private func easyListCookieToggled() {
        guard let profile = selectedProfile else { return }
        profile.isEasyListCookieEnabled = (easyListCookieSwitch.state == .on)
        TabStore.shared.updateProfile(profile)
        ContentBlockerManager.shared.reapplyRuleLists()
    }

    @objc private func malwareFilterToggled() {
        guard let profile = selectedProfile else { return }
        profile.isMalwareFilterEnabled = (malwareFilterSwitch.state == .on)
        TabStore.shared.updateProfile(profile)
        ContentBlockerManager.shared.reapplyRuleLists()
    }

    @objc private func userAgentModeChanged() {
        guard let profile = selectedProfile,
              let mode = UserAgentMode(rawValue: userAgentPopUp.indexOfSelectedItem) else { return }
        profile.userAgentMode = mode
        gridView.row(at: 11).isHidden = mode != .custom
        TabStore.shared.updateProfile(profile)
        updateUAPreview()
    }

    @objc private func customUserAgentChanged() {
        guard let profile = selectedProfile else { return }
        profile.customUserAgent = customUserAgentField.stringValue
        TabStore.shared.updateProfile(profile)
        updateUAPreview()
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
        guard profile.id != TabStore.incognitoProfileID else { return }
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
            if profile.isIncognito {
                countLabel.stringValue = "Private Windows"
            } else {
                let count = spaceCount(for: profile)
                countLabel.stringValue = "\(count) Space\(count == 1 ? "" : "s")"
            }
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
