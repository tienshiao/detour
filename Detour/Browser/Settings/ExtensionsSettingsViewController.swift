import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extensions")

class ExtensionsSettingsViewController: SettingsPaneViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var tableView: NSTableView!
    /// The detail column's document, inside `detailScroll`.
    private var detailContainer: NSView!
    private var detailScroll: NSScrollView!
    /// Below the scrolling details, always in view (user request, TASK-211).
    private var uninstallButton: NSButton!
    private var emptyStateView: NSView!
    private var listContainer: NSView!
    private var addButton: NSButton!
    private var removeButton: NSButton!

    private var extensions: [WebExtension] {
        ExtensionManager.shared.extensions
    }

    private var selectedIndex: Int = 0
    /// The selected extension by id. An update or reload replaces the extension
    /// and `install` appends the replacement, so the index alone would jump to
    /// another extension; `reloadList` reselects by this id first.
    private var selectedExtensionID: String?
    /// The extension the detail column last showed: another one scrolls it to the top.
    private var shownExtensionID: String?

    /// Per-extension result of the last "Check for Updates" / "Reload" click,
    /// kept here because the detail view is rebuilt on every
    /// `extensionsDidChangeNotification` (which an update itself posts).
    private var updateStatusByID: [String: String] = [:]
    /// Extensions whose "Check for Updates" is still running.
    private var checkingIDs: Set<String> = []

    private var selectedExtension: WebExtension? {
        let list = extensions
        guard selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    override var minimumContentHeight: CGFloat? { SettingsMetrics.listPaneMinimumHeight }
    override var scrollsBodyAsWhole: Bool { false }
    override var guidePage: GuidePage? { .webExtensions }

    /// Tall enough to show every extension without scrolling the list.
    override func idealBodyHeight(fittingHeight: CGFloat) -> CGFloat {
        guard !listContainer.isHidden else { return fittingHeight }
        let rows = tableView.allRowsHeight
        return max(fittingHeight, rows + SettingsMetrics.listBarHeight)
    }

    // The detail column is one stack in a column scroll view of its own
    // (TASK-211; TASK-189 made it one stack): the window takes its natural
    // height, and a column taller than the window scrolls by itself, leaving
    // the list in place. Nothing inside the column scrolls on its own.
    override func makeBody() -> NSView {
        let container = NSView()

        // Left side: list container
        let listContainer = SettingsListContainerView()
        self.listContainer = listContainer
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
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extension"))
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

        let buttonSize = SettingsMetrics.listButtonSize

        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
                             target: self, action: #selector(addExtensionClicked))
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true

        removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
                                target: self, action: #selector(removeExtensionClicked))
        removeButton.bezelStyle = .recessed
        removeButton.isBordered = false
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        removeButton.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true

        let buttonStack = NSStackView(views: [addButton, removeButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 0
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(buttonStack)

        // Right side: detail area
        detailContainer = NSView()
        detailScroll = makeColumnScrollView(document: detailContainer,
                                            estimatedWidth: SettingsMetrics.detailColumnWidth)
        container.addSubview(detailScroll)

        // Uninstall sits under the details, outside their scroll view, so it
        // stays in view however far the details scroll.
        uninstallButton = NSButton(title: "Uninstall Extension", target: self, action: #selector(uninstallClicked))
        uninstallButton.controlSize = .regular
        uninstallButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(uninstallButton)

        // Empty state
        emptyStateView = NSView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyStateView)

        let emptyLabel = NSTextField(labelWithString: "No Extensions Installed")
        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyLabel)

        let loadButton = NSButton(title: "Add Extension…", target: self, action: #selector(addExtensionClicked))
        loadButton.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(loadButton)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -16),
            loadButton.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            loadButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 12),
        ])

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
            detailScroll.bottomAnchor.constraint(equalTo: uninstallButton.topAnchor, constant: -SettingsMetrics.sectionGap),

            uninstallButton.leadingAnchor.constraint(equalTo: detailScroll.leadingAnchor),
            uninstallButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyStateView.topAnchor.constraint(equalTo: container.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                                name: ExtensionManager.extensionsDidChangeNotification, object: nil)
        // "Last checked" and any update a background check installed.
        NotificationCenter.default.addObserver(self, selector: #selector(extensionsDidChange),
                                                name: ExtensionUpdater.didFinishCheckNotification, object: nil)
        // A permission row that changes while the pane is open: a prompt's
        // answer, the extension's own `permissions.remove` (TASK-259).
        NotificationCenter.default.addObserver(self, selector: #selector(permissionDecisionsDidChange(_:)),
                                                name: ExtensionManager.permissionDecisionsDidChangeNotification,
                                                object: nil)
        return container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadList()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func extensionsDidChange() {
        reloadList()
    }

    /// Rebuild the detail when the shown extension's saved decisions changed,
    /// so every switch reads the row as it is now. A toggle made here ends in
    /// the same rebuild, which reads back what it saved. The rebuild replaces
    /// every switch, so a focused one (a toggle made from the keyboard) hands
    /// its focus to the switch rebuilt for the same row.
    @objc private func permissionDecisionsDidChange(_ notification: Notification) {
        guard let id = notification.userInfo?[ExtensionManager.extensionIDUserInfoKey] as? String,
              id == selectedExtension?.id else { return }
        let window = view.window
        let focusedRow = (window?.firstResponder as? NSView)
            .flatMap { $0.isDescendant(of: detailContainer) ? $0 as? NSSwitch : nil }?.identifier
        updateDetail()
        if let focusedRow, let window,
           let toggle = Self.firstSwitch(withIdentifier: focusedRow, in: detailContainer) {
            window.makeFirstResponder(toggle)
        }
    }

    private static func firstSwitch(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                                    in view: NSView) -> NSSwitch? {
        if let toggle = view as? NSSwitch, toggle.identifier == identifier { return toggle }
        for subview in view.subviews {
            if let hit = firstSwitch(withIdentifier: identifier, in: subview) { return hit }
        }
        return nil
    }

    private func reloadList() {
        // Captured first: `reloadData` can post a selection change of its own
        // when rows go away, which would overwrite the id with whatever row the
        // table landed on.
        let wantedID = selectedExtensionID
        tableView.reloadData()
        let exts = extensions
        if exts.isEmpty {
            emptyStateView.isHidden = false
            listContainer.isHidden = true
            detailScroll.isHidden = true
            uninstallButton.isHidden = true
            // A hidden view still takes part in layout: the last extension's
            // detail column would keep the empty state at its height.
            detailContainer.subviews.forEach { $0.removeFromSuperview() }
        } else {
            emptyStateView.isHidden = true
            listContainer.isHidden = false
            detailScroll.isHidden = false
            uninstallButton.isHidden = false
            if let id = wantedID, let index = exts.firstIndex(where: { $0.id == id }) {
                selectedIndex = index
            } else {
                selectedIndex = max(0, min(selectedIndex, exts.count - 1))
            }
            selectedExtensionID = exts[selectedIndex].id
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            updateDetail()
        }
        removeButton.isEnabled = !exts.isEmpty
        contentHeightDidChange()  // also covers the empty state, which has no detail
    }

    /// The selected extension's details, a grouped form (TASK-338) rebuilt
    /// from scratch: the header and where the extension came from; the
    /// permissions an update added, while they wait; Enabled, the profiles
    /// it is on in and Allow in Private; its permissions.
    private func updateDetail() {
        // Remove old detail subviews
        detailContainer.subviews.forEach { $0.removeFromSuperview() }

        guard let ext = selectedExtension else { return }
        // Another extension (picked, or after an uninstall) shows its details
        // from the top; the same one rebuilt keeps its offset.
        if ext.id != shownExtensionID {
            shownExtensionID = ext.id
            scrollColumnsToTop()
        }
        let resolvedName = ExtensionManager.shared.displayName(for: ext.id)
        let resolvedDesc = ExtensionManager.shared.displayDescription(for: ext.id)

        // The header and where the extension came from, and how it moves to
        // a newer version (TASK-113), as System Settings' top group.
        var sections = [SettingsFormSection(rows: [makeHeaderRow(for: ext, name: resolvedName, description: resolvedDesc)]
                                            + makeSourceRows(for: ext))]
        // An update or reload that added permissions installed it disabled.
        if let pending = ext.pendingPermissionApproval {
            sections.append(SettingsFormSection(rows: [makePendingPermissionsRow(pending)]))
        }
        sections.append(SettingsFormSection(rows: makeEnablingRows(for: ext, name: resolvedName)))
        sections += makePermissionSections(for: ext)

        let form = SettingsForm(sections: sections, estimatedWidth: SettingsMetrics.detailColumnWidth)
        detailContainer.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            form.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            // The column's document is as tall as the form; it scrolls in
            // its own scroll view, so this does not cap the window.
            form.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        // Another extension's detail column has another natural height.
        contentHeightDidChange()
    }

    /// The header row: the icon; the name (wrapping to two lines, then
    /// truncated) and version beside it, and the description under them;
    /// "Settings…" on the row's right edge when the extension has an options
    /// page, level with the icon.
    private func makeHeaderRow(for ext: WebExtension, name: String, description: String?) -> SettingsFormRow {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = ext.icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        header.addSubview(iconView)

        // "Settings…" opens the extension's options page (TASK-103). Hidden when
        // it declares none; disabled when no profile with an open window has
        // it on (see `ExtensionOptionsPageEntry.resolveProfile`).
        var optionsButton: NSButton?
        if ExtensionOptionsPageEntry.hasOptionsPage(ext.manifest) {
            let button = NSButton(title: "Settings…", target: self, action: #selector(openOptionsClicked))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            if Self.optionsProfile(for: ext.id) == nil {
                button.isEnabled = false
                button.toolTip = "Turn the extension on in a profile with an open window to open its settings."
            }
            optionsButton = button
        }

        // The window never widens for a long name (TASK-189): it wraps to a
        // second line, then truncates. The text wraps at the row's width
        // less the icon (and the button beside the name) until laid out.
        let iconSize: CGFloat = 32, iconGap: CGFloat = 10
        let textWidth = SettingsMetrics.detailColumnWidth - 2 * SettingsMetrics.formRowInsetX - iconSize - iconGap
        let nameWidth = textWidth
            - (optionsButton.map { $0.intrinsicContentSize.width + SettingsMetrics.formLabelToControl } ?? 0)
        let nameLabel = SettingsWrappingLabel(wrapping: name, estimatedWidth: nameWidth,
                                              fontSize: SettingsMetrics.formTitleFontSize, weight: .bold,
                                              color: .labelColor)
        nameLabel.maximumNumberOfLines = 2
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.isSelectable = false
        nameLabel.toolTip = name
        header.addSubview(nameLabel)

        let versionLabel = NSTextField(labelWithString: "Version \(ext.manifest.version)")
        versionLabel.font = .systemFont(ofSize: SettingsMetrics.formHelpFontSize)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.lineBreakMode = .byTruncatingTail
        versionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(versionLabel)

        let descLabel = SettingsWrappingLabel(wrapping: description ?? "No description provided.",
                                              estimatedWidth: textWidth, fontSize: SettingsMetrics.formHelpFontSize)
        descLabel.isSelectable = false
        header.addSubview(descLabel)
        // After the text, so VoiceOver reads the name before the button.
        if let optionsButton { header.addSubview(optionsButton) }

        let nameTrailing = optionsButton?.leadingAnchor ?? header.trailingAnchor
        var constraints: [NSLayoutConstraint] = [
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: header.topAnchor),
            header.bottomAnchor.constraint(greaterThanOrEqualTo: iconView.bottomAnchor),

            nameLabel.topAnchor.constraint(equalTo: header.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: iconGap),
            nameLabel.trailingAnchor.constraint(equalTo: nameTrailing,
                                                constant: optionsButton == nil ? 0 : -SettingsMetrics.formLabelToControl),
            versionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: SettingsMetrics.formTitleToHelp),
            versionLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            versionLabel.trailingAnchor.constraint(lessThanOrEqualTo: nameTrailing),
            // Under the name and version, the full width of the text: below
            // the button, which sits level with the icon.
            descLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: SettingsMetrics.formTitleToHelp),
            descLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            descLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            header.bottomAnchor.constraint(greaterThanOrEqualTo: descLabel.bottomAnchor),
        ]
        // As short as the icon and the text allow.
        let hug = header.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        constraints.append(hug)
        if let optionsButton {
            constraints += [
                optionsButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                optionsButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return SettingsFormRow(content: header)
    }

    /// The permission sections: one switch row per API permission and host
    /// pattern, the optional ones in a section of their own, then the sites
    /// the extension asked for and the site-access decisions, each section
    /// as tall as its rows; or one line when the extension asks for none
    /// (TASK-189 defect 15: a one-row list sat in a 287 pt box).
    private func makePermissionSections(for ext: WebExtension) -> [SettingsFormSection] {
        // One read, partitioned by type: a `.url` row's key can be the same
        // string as a manifest match pattern, so the sections must not share a
        // dictionary.
        let savedPermissions = AppDatabase.shared.loadPermissions(extensionID: ext.id)
        let savedAPI = savedPermissions.statusByKey(type: .apiPermission)
        let savedPatterns = savedPermissions.statusByKey(type: .matchPattern)
        // Only rows the restore would actually re-apply: `loadExtensionContext`
        // skips a `.url` decision for an origin the manifest no longer asks
        // about, so listing one here would offer a switch that takes effect for
        // the session and is silently dropped on the next launch while still
        // reading ON.
        let savedURLs = savedPermissions
            .filter { $0.permissionType == ExtensionPermissionType.url.rawValue }
            .filter { record in
                guard let url = URL(string: record.permissionKey) else { return false }
                return ext.canAskForAccess(to: url)
            }
            .sorted { $0.permissionKey < $1.permissionKey }

        let requiredPerms = ext.manifest.permissions ?? []
        let hostPerms = ext.manifest.hostPermissions ?? []
        let optionalPerms = ext.manifest.optionalPermissions ?? []
        let optionalHostPerms = ext.manifest.optionalHostPermissions ?? []
        // Decisions saved for patterns the manifest does not list itself — the
        // sub-patterns a `permissions.request({origins})` prompt was answered
        // for — gated exactly as the restore gates them (TASK-19), so every row
        // listed here is one the next launch re-applies.
        let savedSubPatterns = ext.savedSubPatternDecisionKeys(in: savedPatterns)

        if requiredPerms.isEmpty && hostPerms.isEmpty && optionalPerms.isEmpty
            && optionalHostPerms.isEmpty && savedSubPatterns.isEmpty && savedURLs.isEmpty {
            return [SettingsFormSection(title: "Permissions", rows: [],
                                        footnote: SettingsFormRow(footnote: "No special permissions requested."))]
        }

        func apiRow(_ permission: String) -> SettingsFormRow {
            makePermissionRow(extensionID: ext.id, key: permission, type: .apiPermission,
                              isGranted: Self.apiPermissionIsOn(permission, saved: savedAPI[permission]),
                              label: ExtensionPermissionDescriptions.describe(permission))
        }
        func patternRow(_ pattern: String) -> SettingsFormRow {
            makePermissionRow(extensionID: ext.id, key: pattern, type: .matchPattern,
                              isGranted: savedPatterns[pattern] == .granted,
                              label: Self.displayName(forPattern: pattern))
        }

        var sections: [SettingsFormSection] = []
        // Required API permissions, then host permissions.
        if !requiredPerms.isEmpty || !hostPerms.isEmpty {
            sections.append(SettingsFormSection(title: "Permissions",
                                                rows: requiredPerms.map(apiRow) + hostPerms.map(patternRow)))
        }
        // Optional permissions: API permissions, then host patterns. An
        // optional host pattern reads OFF until the user grants it (at a
        // `permissions.request` prompt or here), and a Deny is reversible.
        if !optionalPerms.isEmpty || !optionalHostPerms.isEmpty {
            sections.append(SettingsFormSection(title: "Optional Permissions",
                                                rows: optionalPerms.map(apiRow) + optionalHostPerms.map(patternRow)))
        }
        // Requested sites: decisions taken when the extension asked for a
        // specific pattern under one of its optional host permissions. Like the
        // site-access rows below, they live outside the manifest lists, so
        // without a row here such a Deny could never be reversed.
        if !savedSubPatterns.isEmpty {
            sections.append(SettingsFormSection(
                title: "Requested Sites", rows: savedSubPatterns.map(patternRow),
                footnote: SettingsFormRow(footnote: "Decisions made when the extension asked for access to specific sites.")))
        }
        // Site access: the per-URL decisions taken at the site-access prompt
        // while browsing. They live outside the manifest lists, so without a row
        // here a one-click Deny would be permanent and unreversible.
        if !savedURLs.isEmpty {
            let rows = savedURLs.map { record in
                makePermissionRow(extensionID: ext.id, key: record.permissionKey, type: .url,
                                  isGranted: ExtensionPermissionStatus(rawValue: record.status) == .granted,
                                  label: record.permissionKey)
            }
            sections.append(SettingsFormSection(
                title: "Site Access", rows: rows,
                footnote: SettingsFormRow(footnote: "Decisions made at site-access prompts while browsing.")))
        }
        return sections
    }

    // MARK: - Updates (TASK-113)

    /// The source row (where the extension came from; its folder or when
    /// updates were last checked under it, and the result of the last click)
    /// with the button that moves it to a newer version, where it can; and a
    /// row for an update held back while the extension was busy.
    private func makeSourceRows(for ext: WebExtension) -> [SettingsFormRow] {
        // While the pending-permissions row is showing, the status line does
        // not repeat what that row says.
        var statusText = updateStatusByID[ext.id] ?? ""
        if ext.pendingPermissionApproval != nil, let range = statusText.range(of: " — new permissions need your approval") {
            statusText.removeSubrange(range)
        }

        var button: NSButton?
        switch ext.source {
        case .webStore, .crx:
            if ext.updateURL != nil {
                let checking = checkingIDs.contains(ext.id)
                let check = NSButton(title: checking ? "Checking…" : "Check for Updates",
                                     target: self, action: #selector(checkForUpdatesClicked(_:)))
                check.isEnabled = !checking
                button = check
            }
        case .unpacked:
            let reload = NSButton(title: "Reload", target: self, action: #selector(reloadUnpackedClicked(_:)))
            if let unavailableReason = ext.unpackedReloadUnavailableReason {
                reload.isEnabled = false
                reload.toolTip = unavailableReason
            }
            button = reload
        }

        // An update held back because the extension was busy (TASK-123): say so
        // and offer to install it regardless.
        let staged = ExtensionManager.shared.stagedUpdate(for: ext.id)
        if let staged, statusText == Self.statusText(for: .deferred(version: staged.version)) {
            statusText = ""
        }

        let source = Self.sourceDescription(for: ext)
        let sourceRow = SettingsFormRow(title: source.title, accessory: button.map { .button($0) } ?? .none)
        // One line: a long unpacked folder path is truncated in the middle and
        // shown whole in the tooltip, rather than wrapped mid-word.
        sourceRow.addDetail(Self.detailLine(source.detail, lineBreakMode: .byTruncatingMiddle,
                                            toolTip: ext.sourcePath?.path ?? ext.updateURL?.absoluteString))
        if !statusText.isEmpty {
            sourceRow.addDetail(Self.detailLine(statusText, lineBreakMode: .byTruncatingTail, toolTip: statusText))
        }
        var rows = [sourceRow]

        if let staged {
            let installButton = NSButton(title: "Install Now", target: self, action: #selector(installStagedUpdateClicked(_:)))
            rows.append(SettingsFormRow(title: "Version \(staged.version) is downloaded",
                                        help: "It installs when the extension is idle.",
                                        accessory: .button(installButton)))
        }
        return rows
    }

    /// A line of secondary text under a row's name that truncates rather
    /// than wraps.
    private static func detailLine(_ text: String, lineBreakMode: NSLineBreakMode, toolTip: String?) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: SettingsMetrics.formHelpFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = lineBreakMode
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.toolTip = toolTip
        return label
    }

    /// Where the extension came from (the source row's name), and under it
    /// its folder or when updates were last checked: "Installed from the
    /// Chrome Web Store" / "Last checked 2 hours ago", "Loaded unpacked" /
    /// "~/Extensions/foo".
    static func sourceDescription(for ext: WebExtension, lastCheckAt: Date? = nil,
                                  now: Date = Date()) -> (title: String, detail: String) {
        switch ext.source {
        case .webStore, .crx:
            let origin = ext.source == .webStore ? "Installed from the Chrome Web Store" : "Installed from a CRX file"
            guard ext.updateURL != nil else {
                return (origin, "It declares no update URL, so it is not updated")
            }
            let last = lastCheckAt ?? ExtensionUpdater.shared.lastCheckAt
            let when: String
            if let last {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                when = now.timeIntervalSince(last) < 60 ? "just now" : formatter.localizedString(for: last, relativeTo: now)
            } else {
                when = "never"
            }
            return (origin, "Last checked \(when)")
        case .unpacked:
            guard let path = ext.sourcePath else { return ("Loaded unpacked", "Folder not recorded") }
            return ("Loaded unpacked", (path.path as NSString).abbreviatingWithTildeInPath)
        }
    }

    /// The permissions an update or reload added, waiting for the one button
    /// that accepts them (and turns the extension on), in a group of its own
    /// between the source and the Enabled switch.
    private func makePendingPermissionsRow(_ pending: ExtensionUpdatePolicy.PendingApproval) -> SettingsFormRow {
        let accept = NSButton(title: "Accept and Enable", target: self, action: #selector(acceptPendingPermissionsClicked))
        let row = SettingsFormRow(title: "Version \(pending.version) needs new permissions",
                                  help: Self.pendingPermissionsText(pending), accessory: .button(accept))
        row.setWarning(Self.pendingPermissionsWarning)
        return row
    }

    static let pendingPermissionsWarning = "Turned off until you accept them."

    private static func pendingPermissionsText(_ pending: ExtensionUpdatePolicy.PendingApproval) -> String {
        ExtensionPermissionDescriptions.formatForAlert(permissions: pending.delta.permissions,
                                                       hostPermissions: pending.delta.hostPermissions)
    }

    @objc private func checkForUpdatesClicked(_ sender: NSButton) {
        guard let ext = selectedExtension else { return }
        let id = ext.id
        checkingIDs.insert(id)
        updateStatusByID[id] = nil
        sender.isEnabled = false
        sender.title = "Checking…"
        Task { @MainActor [weak self] in
            let outcome = await ExtensionUpdater.shared.checkForUpdate(extensionID: id)
            guard let self else { return }
            self.checkingIDs.remove(id)
            self.updateStatusByID[id] = Self.statusText(for: outcome)
            self.reloadList()
        }
    }

    static func statusText(for outcome: ExtensionUpdateOutcome) -> String {
        switch outcome {
        case .upToDate: return "Up to date"
        case .updated(let version): return "Updated to \(version)"
        case .updatedPendingPermissions(let version, _):
            return "Updated to \(version) — new permissions need your approval"
        case .deferred(let version): return "Version \(version) is downloaded and installs when the extension is idle"
        case .notUpdatable(let reason): return "Not updatable: \(reason)"
        case .throttled: return "Checked too recently; try again later"
        case .failed(let message): return "Update failed: \(message)"
        }
    }

    @objc private func reloadUnpackedClicked(_ sender: NSButton) {
        guard let ext = selectedExtension else { return }
        do {
            let result = try ExtensionManager.shared.reloadUnpacked(id: ext.id)
            switch result {
            case .installed:
                updateStatusByID[ext.id] = "Reloaded"
            case .installedPendingPermissions:
                updateStatusByID[ext.id] = "Reloaded — new permissions need your approval"
            }
        } catch {
            updateStatusByID[ext.id] = "Reload failed: \(error.localizedDescription)"
        }
        reloadList()
    }

    /// Install the update `ExtensionUpdater` staged while the extension was busy,
    /// without waiting for it to go idle.
    @objc private func installStagedUpdateClicked(_ sender: NSButton) {
        guard let ext = selectedExtension else { return }
        do {
            switch try ExtensionManager.shared.applyStagedUpdate(for: ext.id) {
            case .installed(let version):
                updateStatusByID[ext.id] = Self.statusText(for: .updated(version: version))
            case .installedPendingPermissions(let version, let delta):
                updateStatusByID[ext.id] = Self.statusText(for: .updatedPendingPermissions(version: version, delta: delta))
            case nil:
                // Nothing staged any more, or the staged copy no longer applies.
                updateStatusByID[ext.id] = nil
            }
        } catch {
            updateStatusByID[ext.id] = "Update failed: \(error.localizedDescription)"
        }
        reloadList()
    }

    @objc private func acceptPendingPermissionsClicked() {
        guard let ext = selectedExtension else { return }
        ExtensionManager.shared.approvePendingPermissions(id: ext.id)
        // `setEnabled` posts extensionsDidChange; reload anyway in case it was
        // already on globally and nothing changed.
        reloadList()
    }

    /// The label a host match pattern is shown under.
    private static func displayName(forPattern pattern: String) -> String {
        pattern == "<all_urls>" ? "All websites" : pattern
    }

    /// Whether an API permission's switch reads ON. A saved grant, as for every
    /// row — except nativeMessaging, whose switch mirrors what is enforced
    /// (`ExtensionManager.nativeHostAccess`): only a saved denial blocks native
    /// hosts, so no row at all reads ON rather than claiming a block that is not
    /// in force.
    private static func apiPermissionIsOn(_ permission: String, saved: ExtensionPermissionStatus?) -> Bool {
        if permission == ExtensionPermissionRecord.nativeMessagingKey {
            return saved != .denied
        }
        return saved == .granted
    }

    // MARK: - Enabled, profiles, Private

    /// Enabled; the profiles it is on in, with Turn On in All Profiles
    /// (TASK-312); Allow in Private with its note (TASK-74).
    private func makeEnablingRows(for ext: WebExtension, name: String) -> [SettingsFormRow] {
        let enabledSwitch = NSSwitch()
        enabledSwitch.state = ext.isEnabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledToggled(_:))
        let enabledRow = SettingsFormRow(title: "Enabled", accessory: .toggle(enabledSwitch))

        // Where it is on (TASK-312): an install turns it on in one profile, and
        // a new profile starts with none, so the pane says which normal
        // profiles have it on and offers to turn it on in all of them. Private
        // is the switch below, never part of "all".
        let normalProfiles = ExtensionInstallTarget.normalProfileIDs()
        let onIn = ExtensionManager.shared.normalProfilesTurnedOn(extensionID: ext.id)
        let allProfilesButton = NSButton(title: "Turn On in All Profiles", target: self,
                                         action: #selector(turnOnInAllProfilesClicked))
        allProfilesButton.isEnabled = onIn.count < normalProfiles.count
        allProfilesButton.identifier = NSUserInterfaceItemIdentifier("turnOnInAllProfiles")
        let profilesRow = SettingsFormRow(
            title: "Profiles",
            help: Self.profilesSummary(onIn: onIn.map(\.name), normalProfileCount: normalProfiles.count),
            accessory: .button(allProfilesButton))
        profilesRow.helpLabel.identifier = NSUserInterfaceItemIdentifier("extensionProfilesSummary")

        // Allow in Private (TASK-74). Extensions are off in the built-in Private
        // profile until the user opts in per extension, so this switch shows and
        // writes only that profile's own row. Like the per-profile switches in
        // Profiles settings, it shows the saved choice but is disabled (its name
        // dimmed) while the extension is off globally: the choice is kept, it
        // just has no effect.
        let privateSwitch = NSSwitch()
        privateSwitch.state = AppDatabase.shared.isExtensionEnabledByProfile(
            extensionID: ext.id, profileID: TabStore.incognitoProfileID.uuidString) ? .on : .off
        privateSwitch.target = self
        privateSwitch.action = #selector(allowInPrivateToggled(_:))
        let privateRow = SettingsFormRow(
            title: "Allow in Private",
            help: "Extensions allowed in Private windows keep their data (storage, caches, cookies) in memory only. It is never written to disk and is cleared when the last Private window closes.",
            accessory: .toggle(privateSwitch))
        privateRow.isEnabled = ext.isEnabled
        if !ext.isEnabled {
            let note = "\(name) is turned off for all profiles"
            privateSwitch.toolTip = note
            privateRow.titleLabel?.toolTip = note
        }
        return [enabledRow, profilesRow, privateRow]
    }

    // MARK: - Actions

    @objc private func enabledToggled(_ sender: NSSwitch) {
        guard let ext = selectedExtension else { return }
        let enabled = sender.state == .on
        // Turning on an extension an update left off for added permissions is
        // accepting them: say which, and only then clear the hold (TASK-113).
        if enabled, let pending = ext.pendingPermissionApproval {
            let alert = NSAlert()
            alert.messageText = "Allow \"\(ExtensionManager.shared.displayName(for: ext.id))\" \(pending.version) New Permissions?"
            alert.informativeText = Self.pendingPermissionsText(pending)
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Accept and Enable")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                ExtensionManager.shared.approvePendingPermissions(id: ext.id)
                reloadList()
            } else {
                sender.state = .off
            }
            return
        }
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: enabled)
    }

    /// The line under Turn On in All Profiles: which normal profiles have the
    /// extension on by their own choice (TASK-312).
    static func profilesSummary(onIn names: [String], normalProfileCount: Int) -> String {
        let perProfile = "Turn it on or off per profile in Settings › Profiles."
        if names.isEmpty { return "Off in every profile. \(perProfile)" }
        if names.count >= normalProfileCount, normalProfileCount > 1 { return "On in all profiles. \(perProfile)" }
        let list = ListFormatter.localizedString(byJoining: names.map { "\u{201C}\($0)\u{201D}" })
        return "On in \(list). \(perProfile)"
    }

    /// Turn On in All Profiles: the per-profile switch of Settings › Profiles,
    /// turned on in every normal profile in one go — loading the context in
    /// each — and never in Private (TASK-312). `extensionsDidChange` rebuilds
    /// this detail view, so the button and the summary read back the result.
    @objc private func turnOnInAllProfilesClicked() {
        guard let ext = selectedExtension else { return }
        ExtensionManager.shared.turnOnInAllProfiles(id: ext.id)
    }

    /// "Allow in Private": writes only the built-in Private profile's row
    /// (TASK-74). `setEnabled(id:profileID:enabled:)` loads or unloads the
    /// context in that profile right away when it exists, closes its extension
    /// pages on a disable, and posts `extensionsDidChange`, which rebuilds this
    /// detail view — so the switch always reads back the saved state.
    @objc private func allowInPrivateToggled(_ sender: NSSwitch) {
        guard let ext = selectedExtension else { return }
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: TabStore.incognitoProfileID,
                                           enabled: sender.state == .on)
    }

    /// A permission's switch row, named by the permission. The switch's
    /// identifier carries the extension, the key and the type for
    /// `permissionToggled`.
    private func makePermissionRow(
        extensionID: String, key: String, type: ExtensionPermissionType,
        isGranted: Bool, label: String
    ) -> SettingsFormRow {
        let toggle = NSSwitch()
        toggle.state = isGranted ? .on : .off
        toggle.target = self
        toggle.action = #selector(permissionToggled(_:))
        // Encode extension ID, permission key, and type into the identifier
        toggle.identifier = NSUserInterfaceItemIdentifier("\(extensionID)\t\(key)\t\(type.rawValue)")
        return SettingsFormRow(title: label, accessory: .toggle(toggle))
    }

    @objc private func permissionToggled(_ sender: NSSwitch) {
        guard let parts = sender.identifier?.rawValue.split(separator: "\t", maxSplits: 2),
              parts.count == 3,
              let typeRaw = Int(parts[2]),
              let type = ExtensionPermissionType(rawValue: typeRaw) else { return }

        let extensionID = String(parts[0])
        let key = String(parts[1])
        let isGranted = sender.state == .on

        if !isGranted {
            // Warn when revoking a required permission
            let ext = extensions.first { $0.id == extensionID }
            let isRequired: Bool = {
                let required = (ext?.manifest.permissions ?? []) + (ext?.manifest.hostPermissions ?? [])
                return required.contains(key)
            }()
            if isRequired {
                let alert = NSAlert()
                alert.messageText = "Revoke Permission?"
                alert.informativeText = key == ExtensionPermissionRecord.nativeMessagingKey
                    ? "The extension will no longer be able to communicate with native applications, and any it is connected to now are disconnected. Extensions that rely on a desktop app, such as password managers, stop working."
                    : "Revoking this permission may cause the extension to stop working."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Revoke")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn {
                    sender.state = .on
                    return
                }
            }
        }

        // Saves the row and applies it to every loaded context in every profile
        // (nativeMessaging to native-host enforcement instead), without a relaunch.
        ExtensionManager.shared.setPermissionDecision(
            extensionID: extensionID, key: key, type: type, granted: isGranted)
    }

    @objc private func addExtensionClicked(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Load Unpacked Extension…", action: #selector(loadUnpackedExtension), keyEquivalent: "")
        menu.addItem(withTitle: "Install from Chrome Web Store…", action: #selector(openChromeWebStore), keyEquivalent: "")
        for item in menu.items { item.target = self }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func loadUnpackedExtension() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an unpacked extension directory containing manifest.json"
        panel.prompt = "Load Extension"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let manifestURL = url.appendingPathComponent("manifest.json")
                let manifest = try ExtensionManifest.parse(at: manifestURL)
                let displayName = WebExtension.resolveI18nName(manifest.name, basePath: url, defaultLocale: manifest.defaultLocale)

                let permissionSummary = ExtensionPermissionDescriptions.formatForAlert(
                    permissions: manifest.permissions ?? [],
                    hostPermissions: manifest.hostPermissions ?? [],
                    optionalPermissions: manifest.optionalPermissions
                )

                // On in the profile of the browser window behind Settings only
                // (TASK-312), and the alerts say which.
                let target = ExtensionInstallTarget.profileForFrontWindow()
                let targetName = ExtensionInstallTarget.profileName(target)

                let confirmAlert = NSAlert()
                confirmAlert.messageText = "Install \"\(displayName)\"?"
                confirmAlert.informativeText = ExtensionInstallTarget.confirmationLine(profileName: targetName)
                    + permissionSummary
                confirmAlert.alertStyle = .warning
                confirmAlert.addButton(withTitle: "Install")
                confirmAlert.addButton(withTitle: "Cancel")

                guard confirmAlert.runModal() == .alertFirstButtonReturn else { return }

                // Record the folder so the extension can be reloaded from it (TASK-113).
                var options = ExtensionInstaller.Options()
                options.source = .unpacked
                options.sourcePath = url
                let installed = try ExtensionManager.shared.install(from: url, options: options, turningOnIn: target)

                let alert = NSAlert()
                alert.messageText = "Extension Installed"
                alert.informativeText = ExtensionInstallTarget.installedMessage(displayName: displayName,
                                                                                profileName: targetName)
                alert.alertStyle = .informational
                alert.runModal()

                // The list already reloaded via notification; select the new one.
                self?.selectedExtensionID = installed.id
                self?.reloadList()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to Load Extension"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    @objc private func openChromeWebStore() {
        (NSApp.delegate as? AppDelegate)?.openChromeWebStore()
        view.window?.close()
    }

    @objc private func removeExtensionClicked() {
        uninstallClicked()
    }

    @objc private func openOptionsClicked() {
        guard let ext = selectedExtension else { return }
        guard let profile = Self.optionsProfile(for: ext.id),
              ExtensionManager.shared.openOptionsPage(for: ext.id, in: profile) else {
            log.error("Could not open the options page of \(ext.id, privacy: .public)")
            return
        }
    }

    /// The profile whose options page "Settings…" opens: the frontmost browser
    /// window's profile, then the last-active space's, then any profile with an
    /// open space — the first with the extension on (a loaded context). Private
    /// only when it is the frontmost browser window's own
    /// (`ExtensionOptionsPageEntry.resolveProfile`).
    private static func optionsProfile(for extensionID: String) -> Profile? {
        let store = TabStore.shared
        var candidates: [UUID] = []
        // Settings is key — and, being a titled window, main — while its button
        // is clicked, so the browser window is found by z-order: the one right
        // behind Settings.
        if let id = NSApp.frontmostBrowserWindowController?.activeSpace?.profileID {
            candidates.append(id)
        }
        if let lastID = store.lastActiveSpaceID, let id = store.space(withID: lastID)?.profileID {
            candidates.append(id)
        }
        candidates += store.spaces.map(\.profileID)
        let resolved = ExtensionOptionsPageEntry.resolveProfile(
            candidates: candidates,
            isEnabled: { store.profile(withID: $0)?.extensionContext(for: extensionID) != nil },
            isPrivate: { $0 == TabStore.incognitoProfileID }
        )
        return resolved.flatMap { store.profile(withID: $0) }
    }

    @objc private func uninstallClicked() {
        guard let ext = selectedExtension else { return }

        let alert = NSAlert()
        let uninstallName = ExtensionManager.shared.displayName(for: ext.id)
        alert.messageText = "Uninstall \"\(uninstallName)\"?"
        alert.informativeText = "This will remove the extension and all its data."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        selectedExtensionID = nil
        selectedIndex = max(0, selectedIndex - 1)
        ExtensionManager.shared.uninstall(id: ext.id)
        // List reloads via notification
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        extensions.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let ext = extensions[row]
        let cellID = NSUserInterfaceItemIdentifier("ExtensionCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.tag = 10
            cell.addSubview(iconView)

            let nameLabel = NSTextField(labelWithString: "")
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.tag = 1
            cell.addSubview(nameLabel)

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),
                nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            ])
        }

        if let iconView = cell.viewWithTag(10) as? NSImageView {
            if let icon = ext.icon {
                let size = NSSize(width: 16, height: 16)
                iconView.image = NSImage(size: size, flipped: false) { rect in
                    icon.draw(in: rect)
                    return true
                }
            } else {
                iconView.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            }
        }
        if let nameLabel = cell.viewWithTag(1) as? NSTextField {
            nameLabel.stringValue = ExtensionManager.shared.displayName(for: ext.id)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        selectedIndex = row
        selectedExtensionID = row < extensions.count ? extensions[row].id : nil
        updateDetail()
    }
}
