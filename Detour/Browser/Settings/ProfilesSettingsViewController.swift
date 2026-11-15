import AppKit

class ProfilesSettingsViewController: SettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var tableView: NSTableView!
    private var archivePopUp: NSPopUpButton!
    private var sleepPopUp: NSPopUpButton!
    private var searchEnginePopUp: NSPopUpButton!
    private var suggestionsSwitch: NSSwitch!
    private var perTabIsolationSwitch: NSSwitch!
    private var userAgentPopUp: NSPopUpButton!
    private var customUserAgentField: NSTextField!
    private var profileNameField: NSTextField!
    private var adBlockSwitch: NSSwitch!
    private var easyListSwitch: NSSwitch!
    private var easyPrivacySwitch: NSSwitch!
    private var easyListCookieSwitch: NSSwitch!
    private var malwareFilterSwitch: NSSwitch!
    private var addButton: NSButton!
    private var deleteButton: NSButton!
    private var externalAppsLabel: NSTextField!
    private var externalAppsClearButton: NSButton!

    /// The detail column's grouped form (TASK-338): each section, and the
    /// form rows of each `ProfileSettingsRow`, by name, so they are shown and
    /// hidden by `ProfileSettingsLayout`, never by position. A row that is a
    /// line of another row (the isolation warning, the user agent preview)
    /// has no form rows of its own.
    private(set) var formSections: [ProfileSettingsSection: SettingsFormSection] = [:]
    private(set) var formRows: [ProfileSettingsRow: [SettingsFormRow]] = [:]
    /// Per-tab isolation's row; its warning line is `isolationWarning`.
    private(set) var isolationRow: SettingsFormRow!
    /// Identify as's row; its help text is `userAgentPreview`.
    private(set) var userAgentRow: SettingsFormRow!

    /// All profiles including the built-in incognito profile.
    private var profiles: [Profile] {
        TabStore.shared.profiles.filter { !$0.isIncognito || $0.id == TabStore.incognitoProfileID }
    }
    private var selectedIndex: Int = 0
    /// The profile the detail column last showed: another one scrolls it to the top.
    private var shownProfileID: UUID?

    private var selectedProfile: Profile? {
        let list = profiles
        guard selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    override var paneDescription: String? {
        "Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. You can use any Profile across one or more Spaces."
    }

    override var guidePage: GuidePage? { .profiles }

    override var minimumContentHeight: CGFloat? { SettingsMetrics.listPaneMinimumHeight }
    override var scrollsBodyAsWhole: Bool { false }

    /// Tall enough to show every profile without scrolling the list.
    override func idealBodyHeight(fittingHeight: CGFloat) -> CGFloat {
        let rows = tableView.allRowsHeight
        return max(fittingHeight, rows + SettingsMetrics.listBarHeight)
    }

    override func makeBody() -> NSView {
        let container = NSView()

        // Left side: list container (table + segmented control in a bordered box)
        let listContainer = SettingsListContainerView()
        container.addSubview(listContainer)

        let scrollView = SettingsColumnScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = SettingsMetrics.listRowHeight
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
        let buttonSize = SettingsMetrics.listButtonSize

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

        // Right side: the selected profile's settings, a grouped form
        // (TASK-338) in a column of its own, so scrolling it leaves the
        // profile list in place (TASK-211).
        let form = SettingsForm(sections: ProfileSettingsSection.allCases.map(makeSection),
                                estimatedWidth: SettingsMetrics.detailColumnWidth)
        let detailDocument = NSView()
        detailDocument.addSubview(form)
        let detailScroll = makeColumnScrollView(document: detailDocument,
                                                estimatedWidth: SettingsMetrics.detailColumnWidth)
        container.addSubview(detailScroll)

        // Layout
        NSLayoutConstraint.activate([
            listContainer.topAnchor.constraint(equalTo: container.topAnchor),
            listContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            listContainer.widthAnchor.constraint(equalToConstant: SettingsMetrics.listWidth),
            listContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -2),

            buttonStack.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 4),
            buttonStack.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor, constant: -2),

            detailScroll.topAnchor.constraint(equalTo: container.topAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: SettingsMetrics.sectionGap),
            detailScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // The column's document is as tall as the form; it scrolls in
            // its own scroll view, so this does not cap the window.
            form.topAnchor.constraint(equalTo: detailDocument.topAnchor),
            form.leadingAnchor.constraint(equalTo: detailDocument.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: detailDocument.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: detailDocument.bottomAnchor),
        ])
        return container
    }

    /// A section of the form: its title with the Learn more link to its
    /// guide (TASK-292.11), and the rows of its `ProfileSettingsRow`s; the
    /// private note closes the first section as its footnote.
    private func makeSection(_ section: ProfileSettingsSection) -> SettingsFormSection {
        var rows: [SettingsFormRow] = []
        var footnote: SettingsFormRow?
        for row in section.rows {
            let made = makeRows(row)
            formRows[row] = made
            if row == .privateNote {
                footnote = made.first
            } else {
                rows += made
            }
        }
        let formSection = SettingsFormSection(
            title: section.title,
            headerAccessory: section.guidePage.map { SettingsGuideLink($0, title: "Learn more") },
            rows: rows, footnote: footnote)
        formSections[section] = formSection
        return formSection
    }

    /// The form rows of one `ProfileSettingsRow`, with their controls. Every
    /// control writes its property of the selected profile and saves it with
    /// `TabStore.shared.updateProfile`; the row names it (TASK-336).
    private func makeRows(_ row: ProfileSettingsRow) -> [SettingsFormRow] {
        switch row {
        case .name:
            profileNameField = NSTextField()
            profileNameField.placeholderString = "Profile name"
            profileNameField.font = .systemFont(ofSize: 13)
            profileNameField.translatesAutoresizingMaskIntoConstraints = false
            // Before the row reads the field's size.
            profileNameField.widthAnchor.constraint(equalToConstant: SettingsMetrics.fieldWidth).isActive = true
            profileNameField.target = self
            profileNameField.action = #selector(profileNameChanged)
            return [SettingsFormRow(title: "Name", accessory: .custom(profileNameField))]

        case .privateNote:
            // TASK-292.11: the Private profile is Private Browsing's settings.
            let note = SettingsFormRow(footnote: "This profile is used for Private Windows.")
            note.addLink(SettingsGuideLink(.privateBrowsing))
            return [note]

        case .searchEngine:
            searchEnginePopUp = NSPopUpButton()
            for engine in SearchEngine.allCases {
                searchEnginePopUp.addItem(withTitle: engine.name)
            }
            searchEnginePopUp.target = self
            searchEnginePopUp.action = #selector(searchEngineChanged)
            return [SettingsFormRow(title: "Search engine", accessory: .popUp(searchEnginePopUp))]

        case .searchSuggestions:
            suggestionsSwitch = NSSwitch()
            suggestionsSwitch.target = self
            suggestionsSwitch.action = #selector(suggestionsToggled)
            return [SettingsFormRow(title: "Search suggestions", accessory: .toggle(suggestionsSwitch))]

        case .archiveTabs:
            archivePopUp = NSPopUpButton()
            for threshold in ArchiveThreshold.allCases {
                archivePopUp.addItem(withTitle: thresholdTitle(threshold))
                archivePopUp.lastItem?.representedObject = threshold
            }
            archivePopUp.target = self
            archivePopUp.action = #selector(archiveThresholdChanged)
            return [SettingsFormRow(title: "Archive tabs after", accessory: .popUp(archivePopUp))]

        case .sleepTabs:
            sleepPopUp = NSPopUpButton()
            for threshold in SleepThreshold.allCases {
                sleepPopUp.addItem(withTitle: sleepThresholdTitle(threshold))
                sleepPopUp.lastItem?.representedObject = threshold
            }
            sleepPopUp.target = self
            sleepPopUp.action = #selector(sleepThresholdChanged)
            return [SettingsFormRow(title: "Sleep tabs after", accessory: .popUp(sleepPopUp))]

        case .perTabIsolation:
            perTabIsolationSwitch = NSSwitch()
            perTabIsolationSwitch.target = self
            perTabIsolationSwitch.action = #selector(perTabIsolationToggled)
            isolationRow = SettingsFormRow(title: "Per-tab isolation", accessory: .toggle(perTabIsolationSwitch))
            return [isolationRow]

        case .isolationWarning, .userAgentPreview:
            // Lines of the isolation and Identify as rows.
            return []

        case .contentBlocking:
            adBlockSwitch = NSSwitch()
            adBlockSwitch.target = self
            adBlockSwitch.action = #selector(adBlockToggled)
            return [SettingsFormRow(title: "Block content", accessory: .toggle(adBlockSwitch))]

        case .filterLists:
            // A row per list, off while blocking is off.
            func filterList(_ title: String, _ action: Selector) -> (NSSwitch, SettingsFormRow) {
                let toggle = NSSwitch()
                toggle.target = self
                toggle.action = action
                return (toggle, SettingsFormRow(title: title, accessory: .toggle(toggle)))
            }
            let easyList = filterList("EasyList (ads)", #selector(easyListToggled))
            let easyPrivacy = filterList("EasyPrivacy (trackers)", #selector(easyPrivacyToggled))
            let cookies = filterList("Cookie notices", #selector(easyListCookieToggled))
            let malware = filterList("Malicious URLs", #selector(malwareFilterToggled))
            easyListSwitch = easyList.0
            easyPrivacySwitch = easyPrivacy.0
            easyListCookieSwitch = cookies.0
            malwareFilterSwitch = malware.0
            return [easyList.1, easyPrivacy.1, cookies.1, malware.1]

        case .extensionSwitches:
            // A row per installed extension, made for the selected profile
            // (`updateExtensionToggles`).
            return []

        case .userAgentMode:
            userAgentPopUp = NSPopUpButton()
            userAgentPopUp.addItems(withTitles: ["Detour", "Safari", "Custom"])
            userAgentPopUp.target = self
            userAgentPopUp.action = #selector(userAgentModeChanged)
            userAgentRow = SettingsFormRow(title: "Identify as", accessory: .popUp(userAgentPopUp))
            // The preview under it can be selected and copied, as before.
            userAgentRow.helpLabel.isSelectable = true
            return [userAgentRow]

        case .customUserAgent:
            customUserAgentField = NSTextField()
            customUserAgentField.placeholderString = "Enter custom user agent"
            customUserAgentField.font = .systemFont(ofSize: 13)
            customUserAgentField.translatesAutoresizingMaskIntoConstraints = false
            customUserAgentField.lineBreakMode = .byTruncatingTail
            // As wide as the name's field, on the right; the whole string is
            // the preview under Identify as.
            customUserAgentField.widthAnchor.constraint(equalToConstant: SettingsMetrics.fieldWidth).isActive = true
            customUserAgentField.target = self
            customUserAgentField.action = #selector(customUserAgentChanged)
            return [SettingsFormRow(title: "Custom string", accessory: .custom(customUserAgentField))]

        case .externalAppPermissions:
            // Remembered "Always allow" decisions for external application
            // links (TASK-84).
            externalAppsLabel = NSTextField(labelWithString: "None")
            externalAppsLabel.font = .systemFont(ofSize: SettingsMetrics.formTitleFontSize)
            externalAppsLabel.textColor = .secondaryLabelColor
            externalAppsClearButton = NSButton(title: "Clear", target: self,
                                               action: #selector(clearExternalAppPermissionsClicked))
            return [SettingsFormRow(title: "Saved permissions",
                                    accessory: .value(externalAppsLabel, button: externalAppsClearButton))]
        }
    }

    /// The selected profile, as far as it decides which rows show.
    private var layoutState: ProfileSettingsState {
        guard let profile = selectedProfile else { return ProfileSettingsState() }
        return ProfileSettingsState(
            isPrivate: profile.isIncognito,
            isPerTabIsolation: profile.isPerTabIsolation,
            sleepsTabs: profile.sleepThreshold != .never,
            usesCustomUserAgent: profile.userAgentMode == .custom,
            hasExtensions: !ExtensionManager.shared.extensions.isEmpty)
    }

    static let isolationWarningText = "Sleeping tabs will lose session data when per-tab isolation is enabled."

    /// Shows the rows and sections `ProfileSettingsLayout` gives for the
    /// selected profile, and the isolation warning, and reports the height
    /// change.
    private func applyRowLayout() {
        let state = layoutState
        for (row, rows) in formRows {
            let isVisible = ProfileSettingsLayout.isVisible(row, in: state)
            for formRow in rows { formRow.isHidden = !isVisible }
        }
        isolationRow.setWarning(ProfileSettingsLayout.isVisible(.isolationWarning, in: state) ? Self.isolationWarningText : nil)
        let visible = ProfileSettingsLayout.visibleSections(in: state)
        for (section, view) in formSections {
            view.isHidden = !visible.contains(section)
        }
        contentHeightDidChange()
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
        NotificationCenter.default.addObserver(self, selector: #selector(externalAppPermissionsDidChange),
                                                name: ExternalAppPermissionStore.didChangeNotification, object: nil)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self, name: ExtensionManager.extensionsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: ExternalAppPermissionStore.didChangeNotification, object: nil)
    }

    @objc private func externalAppPermissionsDidChange() {
        updateExternalAppPermissions()
    }

    @objc private func extensionsDidChange() {
        updateExtensionToggles()
    }

    // MARK: - Helpers

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
        // Another profile (picked, added or deleted) shows its details from the top.
        if profile.id != shownProfileID {
            shownProfileID = profile.id
            scrollColumnsToTop()
        }
        profileNameField.stringValue = profile.name
        profileNameField.isEditable = !profile.isIncognito
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
        customUserAgentField.stringValue = profile.validCustomUserAgent
            ?? (profile.userAgentMode == .custom ? profile.resolvedUserAgent() : "")
        // Ad blocking
        adBlockSwitch.state = profile.isAdBlockingEnabled ? .on : .off
        easyListSwitch.state = profile.isEasyListEnabled ? .on : .off
        easyPrivacySwitch.state = profile.isEasyPrivacyEnabled ? .on : .off
        easyListCookieSwitch.state = profile.isEasyListCookieEnabled ? .on : .off
        malwareFilterSwitch.state = profile.isMalwareFilterEnabled ? .on : .off
        enableFilterLists(profile.isAdBlockingEnabled)
        updateExternalAppPermissions()
        updateUAPreview()
        updateExtensionToggles()  // also applies the row layout
    }

    /// The filter lists' rows are off (switch disabled, name dimmed) while
    /// blocking is off.
    private func enableFilterLists(_ isEnabled: Bool) {
        for row in formRows[.filterLists] ?? [] { row.isEnabled = isEnabled }
    }

    private func updateExternalAppPermissions() {
        guard let profile = selectedProfile else { return }
        let count = ExternalAppPermissionStore.shared.count(for: profile.id)
        externalAppsLabel.stringValue = count == 0 ? "None" : "\(count)"
        externalAppsClearButton.isEnabled = count > 0
    }

    @objc private func clearExternalAppPermissionsClicked() {
        guard let profile = selectedProfile else { return }
        ExternalAppPermissionStore.shared.clearAll(for: profile.id)
        updateExternalAppPermissions()
    }

    /// A row per installed extension in the Extensions section, rebuilt for
    /// the selected profile; the section hides when none are installed.
    private func updateExtensionToggles() {
        guard let profile = selectedProfile else { return }
        var rows: [SettingsFormRow] = []
        for ext in ExtensionManager.shared.extensions {
            let toggle = NSSwitch()
            // The switch shows the profile's own saved choice. While the extension
            // is turned off globally that choice is kept but has no effect, so the
            // row is shown disabled (the name dimmed) rather than hidden: it
            // tells the user what turning the extension back on will restore.
            let isEnabledByProfile = AppDatabase.shared.isExtensionEnabledByProfile(
                extensionID: ext.id, profileID: profile.id.uuidString)
            toggle.state = isEnabledByProfile ? .on : .off
            toggle.identifier = NSUserInterfaceItemIdentifier(ext.id)
            toggle.target = self
            toggle.action = #selector(extensionToggled(_:))

            let resolvedName = ExtensionManager.shared.displayName(for: ext.id)
            let row = SettingsFormRow(title: resolvedName,
                                      help: ext.isEnabled ? nil : Self.extensionOffEverywhereHelp,
                                      accessory: .toggle(toggle))
            row.isEnabled = ext.isEnabled
            var note: String?
            if !ext.isEnabled {
                note = "\(resolvedName) is turned off for all profiles in Extensions settings"
            } else if profile.isIncognito {
                // The same opt-in as "Allow in Private" in Extensions settings,
                // so it carries the same warning (TASK-74).
                note = "Extensions allowed in Private windows keep their data (storage, caches, cookies) in memory only. It is never written to disk and is cleared when the last Private window closes."
            }
            toggle.toolTip = note
            row.titleLabel?.toolTip = note
            rows.append(row)
        }
        formSections[.extensions]?.setRows(rows)
        formRows[.extensionSwitches] = rows
        applyRowLayout()
    }

    /// The help under an extension turned off for all profiles: why its
    /// switch is off here.
    static let extensionOffEverywhereHelp = "Turned off for all profiles in Extensions settings."

    @objc private func extensionToggled(_ sender: NSSwitch) {
        guard let profile = selectedProfile,
              let extID = sender.identifier?.rawValue else { return }
        let enabled = sender.state == .on
        ExtensionManager.shared.setEnabled(id: extID, profileID: profile.id, enabled: enabled)
    }

    /// The user agent the profile sends, under Identify as; the row tells
    /// the pane when its height changes.
    private func updateUAPreview() {
        let isVisible = ProfileSettingsLayout.isVisible(.userAgentPreview, in: layoutState)
        userAgentRow.setHelp(isVisible ? selectedProfile?.resolvedUserAgent() : nil)
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
        let isDuplicate = profiles.contains { $0.id != profile.id && $0.name.caseInsensitiveCompare(newName) == .orderedSame }
        guard !isDuplicate else {
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
        TabStore.shared.updateProfile(profile)
        applyRowLayout()
    }

    @objc private func perTabIsolationToggled() {
        guard let profile = selectedProfile else { return }
        profile.isPerTabIsolation = (perTabIsolationSwitch.state == .on)
        TabStore.shared.updateProfile(profile)
        applyRowLayout()
    }

    @objc private func adBlockToggled() {
        guard let profile = selectedProfile else { return }
        profile.isAdBlockingEnabled = (adBlockSwitch.state == .on)
        enableFilterLists(profile.isAdBlockingEnabled)
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
        // Custom never starts blank (TASK-216): see `selectUserAgentMode`.
        profile.selectUserAgentMode(mode)
        customUserAgentField.stringValue = profile.customUserAgent ?? ""
        TabStore.shared.updateProfile(profile)
        updateUAPreview()
        applyRowLayout()
    }

    @objc private func customUserAgentChanged() {
        guard let profile = selectedProfile else { return }
        // A blank (or multi-line) string is refused: the field goes back to
        // the saved one and the profile keeps sending it (TASK-216).
        // With no valid saved string (one saved before the refusal), the field
        // shows what the profile sends instead.
        guard let text = UserAgentMode.validatedCustomUserAgent(customUserAgentField.stringValue) else {
            customUserAgentField.stringValue = profile.validCustomUserAgent ?? profile.resolvedUserAgent()
            NSSound.beep()
            updateUAPreview()
            return
        }
        customUserAgentField.stringValue = text
        profile.customUserAgent = text
        TabStore.shared.updateProfile(profile)
        updateUAPreview()
    }

    @objc private func addProfileClicked() {
        let addVC = AddProfileViewController()
        addVC.onCreate = { [weak self] name in
            guard let self else { return }
            self.dismiss(addVC)
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

            // The name gives way first and truncates; "N Spaces" keeps its width
            // (TASK-189 defect 8: the name was cut without an ellipsis and ran
            // into the count).
            let nameLabel = NSTextField(labelWithString: "")
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.tag = 1
            cell.addSubview(nameLabel)

            let countLabel = NSTextField(labelWithString: "")
            countLabel.font = .systemFont(ofSize: 11)
            countLabel.textColor = .secondaryLabelColor
            countLabel.translatesAutoresizingMaskIntoConstraints = false
            countLabel.tag = 2
            countLabel.setContentHuggingPriority(.required, for: .horizontal)
            countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            nameLabel.toolTip = profile.name
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
