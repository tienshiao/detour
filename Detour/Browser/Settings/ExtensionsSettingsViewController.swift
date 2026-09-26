import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "extensions")

class ExtensionsSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var tableView: NSTableView!
    private var detailContainer: NSView!
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

    override func loadView() {
        preferredContentSize = NSSize(width: 740, height: 480)
        let container = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        self.view = container

        let margin: CGFloat = 20
        let spacing: CGFloat = 12

        // Left side: list container
        listContainer = NSView()
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
        tableView.rowHeight = 32
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

        let buttonSize: CGFloat = 24

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
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detailContainer)

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
            listContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
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

            detailContainer.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            detailContainer.leadingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: margin),
            detailContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            detailContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),

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
            detailContainer.isHidden = true
        } else {
            emptyStateView.isHidden = true
            listContainer.isHidden = false
            detailContainer.isHidden = false
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
    }

    private func updateDetail() {
        // Remove old detail subviews
        detailContainer.subviews.forEach { $0.removeFromSuperview() }

        guard let ext = selectedExtension else { return }

        // Icon + name + version header
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 32).isActive = true
        if let icon = ext.icon {
            iconView.image = icon
        } else {
            iconView.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        }

        let resolvedName = ExtensionManager.shared.displayName(for: ext.id)
        let resolvedDesc = ExtensionManager.shared.displayDescription(for: ext.id)

        let nameLabel = NSTextField(labelWithString: resolvedName)
        nameLabel.font = .systemFont(ofSize: 15, weight: .bold)

        let versionLabel = NSTextField(labelWithString: "Version \(ext.manifest.version)")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let nameStack = NSStackView(views: [nameLabel, versionLabel])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 2

        var headerViews: [NSView] = [iconView, nameStack]

        // "Settings…" opens the extension's options page (TASK-103). Hidden when
        // it declares none; disabled when no profile with an open window has
        // it on (see `ExtensionOptionsPageEntry.resolveProfile`).
        if ExtensionOptionsPageEntry.hasOptionsPage(ext.manifest) {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            let optionsButton = NSButton(title: "Settings…", target: self, action: #selector(openOptionsClicked))
            optionsButton.controlSize = .regular
            optionsButton.setContentHuggingPriority(.required, for: .horizontal)
            if Self.optionsProfile(for: ext.id) == nil {
                optionsButton.isEnabled = false
                optionsButton.toolTip = "Turn the extension on in a profile with an open window to open its settings."
            }
            headerViews += [spacer, optionsButton]
        }

        let headerStack = NSStackView(views: headerViews)
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10

        // Description
        let descLabel = NSTextField(wrappingLabelWithString: resolvedDesc ?? "No description provided.")
        descLabel.font = .systemFont(ofSize: 12)
        descLabel.textColor = .secondaryLabelColor

        // Separator
        let sep = NSBox()
        sep.boxType = .separator

        // Where the extension came from, and how it moves to a newer version (TASK-113).
        let updateSection = makeUpdateSection(for: ext)

        // An update or reload that added permissions installed it disabled.
        let pendingBanner = ext.pendingPermissionApproval.map { makePendingPermissionsBanner(for: ext, pending: $0) }

        // Enabled switch
        let enabledSwitch = NSSwitch()
        enabledSwitch.state = ext.isEnabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledToggled(_:))

        let enabledLabel = NSTextField(labelWithString: "Enabled")
        enabledLabel.font = .systemFont(ofSize: 13)

        let enabledRow = NSStackView(views: [enabledLabel, enabledSwitch])
        enabledRow.orientation = .horizontal
        enabledRow.spacing = 8

        // Allow in Private (TASK-74). Extensions are off in the built-in Private
        // profile until the user opts in per extension, so this switch shows and
        // writes only that profile's own row. Like the per-profile toggles in
        // Profiles settings, it shows the saved choice but is disabled while the
        // extension is off globally: the choice is kept, it just has no effect.
        let privateSwitch = NSSwitch()
        privateSwitch.state = AppDatabase.shared.isExtensionEnabledByProfile(
            extensionID: ext.id, profileID: TabStore.incognitoProfileID.uuidString) ? .on : .off
        privateSwitch.isEnabled = ext.isEnabled
        privateSwitch.target = self
        privateSwitch.action = #selector(allowInPrivateToggled(_:))

        let privateLabel = NSTextField(labelWithString: "Allow in Private")
        privateLabel.font = .systemFont(ofSize: 13)
        privateLabel.textColor = ext.isEnabled ? .labelColor : .disabledControlTextColor

        let privateRow = NSStackView(views: [privateLabel, privateSwitch])
        privateRow.orientation = .horizontal
        privateRow.spacing = 8
        if !ext.isEnabled {
            let note = "\(resolvedName) is turned off for all profiles"
            privateSwitch.toolTip = note
            privateLabel.toolTip = note
        }

        let privateNote = NSTextField(wrappingLabelWithString: "Extensions allowed in Private windows keep their data (storage, caches, cookies) in memory only. It is never written to disk and is discarded when Detour quits.")
        privateNote.font = .systemFont(ofSize: 11)
        privateNote.textColor = .secondaryLabelColor

        // Permissions section — interactive toggles
        let permsHeader = NSTextField(labelWithString: "Permissions")
        permsHeader.font = .systemFont(ofSize: 13, weight: .medium)

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

        var permContentViews: [NSView] = []

        if requiredPerms.isEmpty && hostPerms.isEmpty && optionalPerms.isEmpty
            && optionalHostPerms.isEmpty && savedSubPatterns.isEmpty && savedURLs.isEmpty {
            let noneLabel = NSTextField(labelWithString: "No special permissions requested.")
            noneLabel.font = .systemFont(ofSize: 12)
            noneLabel.textColor = .secondaryLabelColor
            permContentViews.append(noneLabel)
        } else {
            // Required API permissions
            for perm in requiredPerms {
                let row = makePermissionRow(
                    extensionID: ext.id, key: perm,
                    type: .apiPermission, isGranted: Self.apiPermissionIsOn(perm, saved: savedAPI[perm]),
                    label: ExtensionPermissionDescriptions.describe(perm),
                    isRequired: true
                )
                permContentViews.append(row)
            }
            // Host permissions
            for pattern in hostPerms {
                let row = makePermissionRow(
                    extensionID: ext.id, key: pattern,
                    type: .matchPattern, isGranted: savedPatterns[pattern] == .granted,
                    label: Self.displayName(forPattern: pattern),
                    isRequired: true
                )
                permContentViews.append(row)
            }
            // Optional permissions: API permissions, then host patterns. An
            // optional host pattern reads OFF until the user grants it (at a
            // `permissions.request` prompt or here), and a Deny is reversible.
            if !optionalPerms.isEmpty || !optionalHostPerms.isEmpty {
                let optHeader = NSTextField(labelWithString: "Optional:")
                optHeader.font = .systemFont(ofSize: 11, weight: .medium)
                optHeader.textColor = .secondaryLabelColor
                permContentViews.append(optHeader)
                for perm in optionalPerms {
                    let row = makePermissionRow(
                        extensionID: ext.id, key: perm,
                        type: .apiPermission, isGranted: Self.apiPermissionIsOn(perm, saved: savedAPI[perm]),
                        label: ExtensionPermissionDescriptions.describe(perm),
                        isRequired: false
                    )
                    permContentViews.append(row)
                }
                for pattern in optionalHostPerms {
                    let row = makePermissionRow(
                        extensionID: ext.id, key: pattern,
                        type: .matchPattern, isGranted: savedPatterns[pattern] == .granted,
                        label: Self.displayName(forPattern: pattern),
                        isRequired: false
                    )
                    permContentViews.append(row)
                }
            }
        }

        // Requested sites: decisions taken when the extension asked for a
        // specific pattern under one of its optional host permissions. Like the
        // site-access rows below, they live outside the manifest lists, so
        // without a row here such a Deny could never be reversed.
        if !savedSubPatterns.isEmpty {
            let requestedHeader = NSTextField(labelWithString: "Requested sites:")
            requestedHeader.font = .systemFont(ofSize: 11, weight: .medium)
            requestedHeader.textColor = .secondaryLabelColor
            permContentViews.append(requestedHeader)

            let requestedCaption = NSTextField(labelWithString: "Decisions made when the extension asked for access to specific sites.")
            requestedCaption.font = .systemFont(ofSize: 11)
            requestedCaption.textColor = .tertiaryLabelColor
            permContentViews.append(requestedCaption)

            for pattern in savedSubPatterns {
                let row = makePermissionRow(
                    extensionID: ext.id, key: pattern,
                    type: .matchPattern, isGranted: savedPatterns[pattern] == .granted,
                    label: Self.displayName(forPattern: pattern),
                    isRequired: false
                )
                permContentViews.append(row)
            }
        }

        // Site access: the per-URL decisions taken at the site-access prompt
        // while browsing. They live outside the manifest lists, so without a row
        // here a one-click Deny would be permanent and unreversible.
        if !savedURLs.isEmpty {
            let siteHeader = NSTextField(labelWithString: "Site access:")
            siteHeader.font = .systemFont(ofSize: 11, weight: .medium)
            siteHeader.textColor = .secondaryLabelColor
            permContentViews.append(siteHeader)

            let siteCaption = NSTextField(labelWithString: "Decisions made at site-access prompts while browsing.")
            siteCaption.font = .systemFont(ofSize: 11)
            siteCaption.textColor = .tertiaryLabelColor
            permContentViews.append(siteCaption)

            for record in savedURLs {
                let row = makePermissionRow(
                    extensionID: ext.id, key: record.permissionKey,
                    type: .url,
                    isGranted: ExtensionPermissionStatus(rawValue: record.status) == .granted,
                    label: record.permissionKey,
                    isRequired: false
                )
                permContentViews.append(row)
            }
        }

        let permContentStack = NSStackView(views: permContentViews)
        permContentStack.orientation = .vertical
        permContentStack.alignment = .leading
        permContentStack.spacing = 4
        permContentStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        // Use a flipped NSView as the document view so content starts at the top
        let flippedDocView = FlippedView()
        flippedDocView.translatesAutoresizingMaskIntoConstraints = false
        flippedDocView.addSubview(permContentStack)
        permContentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            permContentStack.topAnchor.constraint(equalTo: flippedDocView.topAnchor),
            permContentStack.leadingAnchor.constraint(equalTo: flippedDocView.leadingAnchor),
            permContentStack.trailingAnchor.constraint(equalTo: flippedDocView.trailingAnchor),
            permContentStack.bottomAnchor.constraint(equalTo: flippedDocView.bottomAnchor),
        ])

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = flippedDocView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.drawsBackground = true

        scrollView.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let permsStack = NSStackView(views: [permsHeader, scrollView])
        permsStack.orientation = .vertical
        permsStack.alignment = .leading
        permsStack.spacing = 4
        permsStack.setHuggingPriority(.defaultLow - 1, for: .vertical)

        // Uninstall button
        let uninstallButton = NSButton(title: "Uninstall Extension", target: self, action: #selector(uninstallClicked))
        uninstallButton.controlSize = .regular
        uninstallButton.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(uninstallButton)

        // Main stack (everything above uninstall)
        var mainViews: [NSView] = [headerStack, descLabel, sep, updateSection]
        if let pendingBanner { mainViews.append(pendingBanner) }
        mainViews += [enabledRow, privateRow, privateNote, permsStack]
        let mainStack = NSStackView(views: mainViews)
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.setCustomSpacing(4, after: privateRow)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 8),
            mainStack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            // The note wraps rather than stretching the leading-aligned stack.
            privateNote.widthAnchor.constraint(equalTo: detailContainer.widthAnchor),
            updateSection.widthAnchor.constraint(equalTo: detailContainer.widthAnchor),
            // Full width, so the header's spacer pushes "Settings…" to the trailing edge.
            headerStack.widthAnchor.constraint(equalTo: detailContainer.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: detailContainer.widthAnchor),
            flippedDocView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            uninstallButton.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            uninstallButton.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            mainStack.bottomAnchor.constraint(equalTo: uninstallButton.topAnchor, constant: -12),
        ])
        pendingBanner?.widthAnchor.constraint(equalTo: detailContainer.widthAnchor).isActive = true
    }

    // MARK: - Updates (TASK-113)

    /// The source line ("Installed from…", "Loaded unpacked from…") and, where
    /// the extension can move to a newer version, the button that does it with
    /// the result of its last click next to it.
    private func makeUpdateSection(for ext: WebExtension) -> NSView {
        let sourceLabel = NSTextField(wrappingLabelWithString: Self.sourceDescription(for: ext))
        sourceLabel.font = .systemFont(ofSize: 12)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byCharWrapping

        var views: [NSView] = [sourceLabel]
        let statusLabel = NSTextField(labelWithString: updateStatusByID[ext.id] ?? "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        switch ext.source {
        case .webStore, .crx:
            if ext.updateURL != nil {
                let checking = checkingIDs.contains(ext.id)
                let button = NSButton(title: checking ? "Checking…" : "Check for Updates",
                                      target: self, action: #selector(checkForUpdatesClicked(_:)))
                button.isEnabled = !checking
                button.setContentHuggingPriority(.required, for: .horizontal)
                views.append(Self.buttonRow(button, statusLabel))
            }
        case .unpacked:
            let button = NSButton(title: "Reload", target: self, action: #selector(reloadUnpackedClicked(_:)))
            button.setContentHuggingPriority(.required, for: .horizontal)
            if let unavailableReason = ext.unpackedReloadUnavailableReason {
                button.isEnabled = false
                button.toolTip = unavailableReason
            }
            views.append(Self.buttonRow(button, statusLabel))
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        sourceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private static func buttonRow(_ button: NSButton, _ statusLabel: NSTextField) -> NSView {
        let row = NSStackView(views: [button, statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// "Installed from the Chrome Web Store · Last checked 2 hours ago", etc.
    static func sourceDescription(for ext: WebExtension, lastCheckAt: Date? = nil, now: Date = Date()) -> String {
        switch ext.source {
        case .webStore, .crx:
            let origin = ext.source == .webStore ? "Installed from the Chrome Web Store" : "Installed from a CRX file"
            guard ext.updateURL != nil else {
                return origin + " · It declares no update URL, so it is not updated"
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
            return origin + " · Last checked \(when)"
        case .unpacked:
            guard let path = ext.sourcePath else { return "Loaded unpacked (folder not recorded)" }
            return "Loaded unpacked from \((path.path as NSString).abbreviatingWithTildeInPath)"
        }
    }

    /// The highlighted box an update's added permissions put above the Enabled
    /// switch, with the one button that accepts them.
    private func makePendingPermissionsBanner(for ext: WebExtension,
                                              pending: ExtensionUpdatePolicy.PendingApproval) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                              accessibilityDescription: "Warning") ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(wrappingLabelWithString: "Version \(pending.version) needs new permissions:")
        title.font = .systemFont(ofSize: 12, weight: .semibold)

        let details = NSTextField(wrappingLabelWithString: Self.pendingPermissionsText(pending))
        details.font = .systemFont(ofSize: 12)
        details.textColor = .secondaryLabelColor

        let accept = NSButton(title: "Accept and Enable", target: self, action: #selector(acceptPendingPermissionsClicked))
        accept.bezelStyle = .rounded

        let textStack = NSStackView(views: [title, details, accept])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 6
        box.borderWidth = 1
        box.borderColor = NSColor.systemOrange.withAlphaComponent(0.6)
        box.fillColor = NSColor.systemOrange.withAlphaComponent(0.12)
        box.contentViewMargins = .zero
        box.contentView?.addSubview(row)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: content.topAnchor),
                row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        return box
    }

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

    private func makePermissionRow(
        extensionID: String, key: String, type: ExtensionPermissionType,
        isGranted: Bool, label: String, isRequired: Bool
    ) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        toggle.state = isGranted ? .on : .off
        toggle.target = self
        toggle.action = #selector(permissionToggled(_:))
        // Encode extension ID, permission key, and type into the identifier
        toggle.identifier = NSUserInterfaceItemIdentifier("\(extensionID)\t\(key)\t\(type.rawValue)")

        let permLabel = NSTextField(labelWithString: label)
        permLabel.font = .systemFont(ofSize: 12)
        permLabel.textColor = .secondaryLabelColor

        let row = NSStackView(views: [toggle, permLabel])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
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

                let confirmAlert = NSAlert()
                confirmAlert.messageText = "Install \"\(displayName)\"?"
                confirmAlert.informativeText = permissionSummary
                confirmAlert.alertStyle = .warning
                confirmAlert.addButton(withTitle: "Install")
                confirmAlert.addButton(withTitle: "Cancel")

                guard confirmAlert.runModal() == .alertFirstButtonReturn else { return }

                // Record the folder so the extension can be reloaded from it (TASK-113).
                var options = ExtensionInstaller.Options()
                options.source = .unpacked
                options.sourcePath = url
                let installed = try ExtensionManager.shared.install(from: url, options: options)

                let alert = NSAlert()
                alert.messageText = "Extension Installed"
                alert.informativeText = "\"\(displayName)\" has been installed and enabled."
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

/// An NSView subclass with flipped coordinates so content starts at the top.
/// Used as an NSScrollView document view for top-aligned content.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
