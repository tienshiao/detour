import AppKit

class ProfilesSettingsViewController: SettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate {
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
    private var addButton: NSButton!
    private var deleteButton: NSButton!
    private var extensionTogglesGroup: SettingsGroupBoxView!
    private var externalAppsLabel: NSTextField!
    private var externalAppsClearButton: NSButton!

    /// Each section's view and each row's grid row, so rows and sections are
    /// shown and hidden by name (`ProfileSettingsLayout`), never by row number.
    private var sectionViews: [ProfileSettingsSection: NSView] = [:]
    private var gridRows: [ProfileSettingsRow: NSGridRow] = [:]

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

    override var minimumContentHeight: CGFloat? { SettingsMetrics.listPaneMinimumHeight }
    override var scrollsBodyAsWhole: Bool { false }

    /// Tall enough to show every profile without scrolling the list.
    override func idealBodyHeight(fittingHeight: CGFloat) -> CGFloat {
        let rows = tableView.allRowsHeight
        return max(fittingHeight, rows + SettingsMetrics.listBarHeight)
    }

    /// The width of a section's control column: the detail column less the
    /// label column. Help text and groups fill it.
    private static let controlColumnInset = SettingsMetrics.labelColumnWidth + SettingsMetrics.labelToControl
    private static let estimatedControlColumnWidth = SettingsMetrics.detailColumnWidth - controlColumnInset

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

        // Right side: the selected profile's settings, in titled sections.
        profileNameField = NSTextField()
        profileNameField.placeholderString = "Profile name"
        profileNameField.font = .systemFont(ofSize: 13)
        profileNameField.translatesAutoresizingMaskIntoConstraints = false
        profileNameField.widthAnchor.constraint(equalToConstant: SettingsMetrics.fieldWidth).isActive = true
        profileNameField.target = self
        profileNameField.action = #selector(profileNameChanged)

        privateNoteLabel = SettingsWrappingLabel(wrapping: "This profile is used for Private Windows.",
                                                 estimatedWidth: Self.estimatedControlColumnWidth)

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

        isolationWarningLabel = SettingsWrappingLabel(
            wrapping: "Sleeping tabs will lose session data when per-tab isolation is enabled.",
            estimatedWidth: Self.estimatedControlColumnWidth)

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

        let filterListGroup = SettingsGroupBoxView(rows: [
            SettingsGroupBoxView.switchRow(easyListSwitch, title: "EasyList (ads)").row,
            SettingsGroupBoxView.switchRow(easyPrivacySwitch, title: "EasyPrivacy (trackers)").row,
            SettingsGroupBoxView.switchRow(easyListCookieSwitch, title: "Cookie notices").row,
            SettingsGroupBoxView.switchRow(malwareFilterSwitch, title: "Malicious URLs").row,
        ])

        userAgentPopUp = NSPopUpButton()
        userAgentPopUp.addItems(withTitles: ["Detour", "Safari", "Custom"])
        userAgentPopUp.target = self
        userAgentPopUp.action = #selector(userAgentModeChanged)

        customUserAgentField = NSTextField()
        customUserAgentField.placeholderString = "Enter custom user agent"
        customUserAgentField.font = .systemFont(ofSize: 13)
        customUserAgentField.translatesAutoresizingMaskIntoConstraints = false
        customUserAgentField.lineBreakMode = .byTruncatingTail
        customUserAgentField.target = self
        customUserAgentField.action = #selector(customUserAgentChanged)

        uaPreviewLabel = SettingsWrappingLabel(wrapping: "", estimatedWidth: Self.estimatedControlColumnWidth)
        uaPreviewLabel.isSelectable = true

        // Extension per-profile toggles
        extensionTogglesGroup = SettingsGroupBoxView()

        // Remembered "Always allow" decisions for external application links (TASK-84)
        externalAppsLabel = NSTextField(labelWithString: "")
        externalAppsLabel.font = .systemFont(ofSize: 13)
        externalAppsLabel.textColor = .secondaryLabelColor
        externalAppsClearButton = NSButton(title: "Clear", target: self, action: #selector(clearExternalAppPermissionsClicked))
        externalAppsClearButton.controlSize = .small
        let externalAppsRow = NSStackView(views: [externalAppsLabel, externalAppsClearButton])
        externalAppsRow.orientation = .horizontal
        externalAppsRow.alignment = .centerY
        externalAppsRow.spacing = SettingsMetrics.labelToControl

        // Each row's label (nil for none) and control.
        func cells(for row: ProfileSettingsRow) -> (label: String?, control: NSView) {
            switch row {
            case .name: return ("Name", profileNameField)
            case .privateNote: return (nil, privateNoteLabel)
            case .searchEngine: return ("Search engine", searchEnginePopUp)
            case .searchSuggestions: return ("Search suggestions", suggestionsSwitch)
            case .archiveTabs: return ("Archive tabs after", archivePopUp)
            case .sleepTabs: return ("Sleep tabs after", sleepPopUp)
            case .perTabIsolation: return ("Per-tab isolation", perTabIsolationSwitch)
            case .isolationWarning: return (nil, isolationWarningLabel)
            case .contentBlocking: return ("Block content", adBlockSwitch)
            case .filterLists: return (nil, filterListGroup)
            case .extensionSwitches: return (nil, extensionTogglesGroup)
            case .userAgentMode: return ("Identify as", userAgentPopUp)
            case .customUserAgent: return ("Custom string", customUserAgentField)
            case .userAgentPreview: return (nil, uaPreviewLabel)
            case .externalAppPermissions: return ("Saved permissions", externalAppsRow)
            }
        }

        let sectionsStack = NSStackView()
        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = SettingsMetrics.sectionGap
        sectionsStack.translatesAutoresizingMaskIntoConstraints = false
        for section in ProfileSettingsSection.allCases {
            let view = makeSection(section, cells: cells)
            sectionsStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true
            sectionViews[section] = view
        }

        // The sections scroll in a column of their own, so scrolling them
        // leaves the profile list in place (TASK-211).
        let detailDocument = NSView()
        detailDocument.addSubview(sectionsStack)
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

            sectionsStack.topAnchor.constraint(equalTo: detailDocument.topAnchor),
            sectionsStack.leadingAnchor.constraint(equalTo: detailDocument.leadingAnchor),
            sectionsStack.trailingAnchor.constraint(equalTo: detailDocument.trailingAnchor),
            sectionsStack.bottomAnchor.constraint(equalTo: detailDocument.bottomAnchor),
        ])
        return container
    }

    /// A section: its title (if any), then a two-column grid of right-aligned
    /// labels and controls. Rows are spaced by their top padding
    /// (`applyRowLayout`), so a hidden row leaves no gap.
    private func makeSection(_ section: ProfileSettingsSection,
                             cells: (ProfileSettingsRow) -> (label: String?, control: NSView)) -> NSView {
        let rows = section.rows.map(cells)
        let grid = NSGridView(views: rows.map { [$0.label.map(makeLabel) ?? NSGridCell.emptyContentView, $0.control] })
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 0
        grid.columnSpacing = SettingsMetrics.labelToControl
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = SettingsMetrics.labelColumnWidth
        grid.column(at: 1).xPlacement = .leading
        // Labels sit on their control's first baseline; a switch has no text
        // to share a baseline with, so its label is centred on it instead.
        grid.rowAlignment = .firstBaseline

        let sectionView = NSStackView()
        sectionView.orientation = .vertical
        sectionView.alignment = .leading
        sectionView.spacing = SettingsMetrics.sectionTitleToRows
        sectionView.translatesAutoresizingMaskIntoConstraints = false
        if let title = section.title {
            sectionView.addArrangedSubview(NSTextField.settingsSectionTitle(title))
        }
        sectionView.addArrangedSubview(grid)
        grid.widthAnchor.constraint(lessThanOrEqualTo: sectionView.widthAnchor).isActive = true

        for (index, row) in section.rows.enumerated() {
            let gridRow = grid.row(at: index)
            gridRows[row] = gridRow
            let control = rows[index].control
            if control is NSSwitch || control is NSStackView {
                gridRow.rowAlignment = .none
                gridRow.yPlacement = .center
            }
            // Help text and groups take the control column's whole width: help
            // text wraps at it, and a long extension name truncates inside it.
            if control is SettingsWrappingLabel || control is SettingsGroupBoxView || control === customUserAgentField {
                control.widthAnchor.constraint(equalTo: sectionView.widthAnchor, constant: -Self.controlColumnInset).isActive = true
            }
            if control is SettingsGroupBoxView {
                gridRow.rowAlignment = .none
                gridRow.yPlacement = .top
            }
        }
        return sectionView
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

    /// Shows the rows and sections `ProfileSettingsLayout` gives for the
    /// selected profile, spaces the rows, and reports the height change.
    private func applyRowLayout() {
        let state = layoutState
        for row in ProfileSettingsRow.allCases {
            guard let gridRow = gridRows[row] else { continue }
            let spacing = ProfileSettingsLayout.spacing(above: row, in: state)
            gridRow.isHidden = spacing == nil
            gridRow.topPadding = spacing ?? 0
        }
        let visible = ProfileSettingsLayout.visibleSections(in: state)
        for (section, view) in sectionViews {
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

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        // The label column is a fixed width ("Search suggestions" fills it
        // exactly): a longer label truncates rather than being clipped.
        label.lineBreakMode = .byTruncatingTail
        return label
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
        customUserAgentField.stringValue = profile.customUserAgent ?? ""
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
        updateExternalAppPermissions()
        updateUAPreview()
        updateExtensionToggles()  // also applies the row layout
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

    private func updateExtensionToggles() {
        guard let profile = selectedProfile else { return }
        let installedExts = ExtensionManager.shared.extensions

        // Rebuild toggle rows; the section hides when none are installed.
        var rows: [NSView] = []
        for ext in installedExts {
            let toggle = NSSwitch()
            toggle.controlSize = .small
            // The switch shows the profile's own saved choice. While the extension
            // is turned off globally that choice is kept but has no effect, so the
            // switch is shown disabled (and the name dimmed) rather than hidden:
            // it tells the user what turning the extension back on will restore.
            let isEnabledByProfile = AppDatabase.shared.isExtensionEnabledByProfile(
                extensionID: ext.id, profileID: profile.id.uuidString)
            toggle.state = isEnabledByProfile ? .on : .off
            toggle.isEnabled = ext.isEnabled
            toggle.identifier = NSUserInterfaceItemIdentifier(ext.id)
            toggle.target = self
            toggle.action = #selector(extensionToggled(_:))

            let resolvedName = ExtensionManager.shared.displayName(for: ext.id)
            // The name truncates inside the group (TASK-189): the window keeps
            // its width and the label column beside it keeps its own.
            let (row, label) = SettingsGroupBoxView.switchRow(toggle, title: resolvedName)
            label.textColor = ext.isEnabled ? .labelColor : .disabledControlTextColor
            if !ext.isEnabled {
                let note = "\(resolvedName) is turned off for all profiles in Extensions settings"
                toggle.toolTip = note
                label.toolTip = note
            } else if profile.isIncognito {
                // The same opt-in as "Allow in Private" in Extensions settings,
                // so it carries the same warning (TASK-74).
                let note = "Extensions allowed in Private windows keep their data (storage, caches, cookies) in memory only. It is never written to disk and is discarded when Detour quits."
                toggle.toolTip = note
                label.toolTip = note
            }
            rows.append(row)
        }
        extensionTogglesGroup.setRows(rows)
        applyRowLayout()
    }

    @objc private func extensionToggled(_ sender: NSSwitch) {
        guard let profile = selectedProfile,
              let extID = sender.identifier?.rawValue else { return }
        let enabled = sender.state == .on
        ExtensionManager.shared.setEnabled(id: extID, profileID: profile.id, enabled: enabled)
    }

    private func updateUAPreview() {
        uaPreviewLabel.stringValue = selectedProfile?.resolvedUserAgent() ?? ""
        contentHeightDidChange()
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
        TabStore.shared.updateProfile(profile)
        updateUAPreview()
        applyRowLayout()
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
