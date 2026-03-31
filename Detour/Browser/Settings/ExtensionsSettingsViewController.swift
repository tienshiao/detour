import AppKit
import WebKit

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
            selectedIndex = min(selectedIndex, exts.count - 1)
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

        let headerStack = NSStackView(views: [iconView, nameStack])
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

        // Permissions section — interactive toggles
        let permsHeader = NSTextField(labelWithString: "Permissions")
        permsHeader.font = .systemFont(ofSize: 13, weight: .medium)

        let savedByKey = AppDatabase.shared.loadPermissionsByKey(extensionID: ext.id)

        let requiredPerms = ext.manifest.permissions ?? []
        let hostPerms = ext.manifest.hostPermissions ?? []
        let optionalPerms = ext.manifest.optionalPermissions ?? []

        var permContentViews: [NSView] = []

        if requiredPerms.isEmpty && hostPerms.isEmpty && optionalPerms.isEmpty {
            let noneLabel = NSTextField(labelWithString: "No special permissions requested.")
            noneLabel.font = .systemFont(ofSize: 12)
            noneLabel.textColor = .secondaryLabelColor
            permContentViews.append(noneLabel)
        } else {
            // Required API permissions
            for perm in requiredPerms {
                let row = makePermissionRow(
                    extensionID: ext.id, key: perm,
                    type: .apiPermission, isGranted: savedByKey[perm] == .granted,
                    label: ExtensionPermissionDescriptions.describe(perm),
                    isRequired: true
                )
                permContentViews.append(row)
            }
            // Host permissions
            for pattern in hostPerms {
                let display = pattern == "<all_urls>" ? "All websites" : pattern
                let row = makePermissionRow(
                    extensionID: ext.id, key: pattern,
                    type: .matchPattern, isGranted: savedByKey[pattern] == .granted,
                    label: display,
                    isRequired: true
                )
                permContentViews.append(row)
            }
            // Optional permissions
            if !optionalPerms.isEmpty {
                let optHeader = NSTextField(labelWithString: "Optional:")
                optHeader.font = .systemFont(ofSize: 11, weight: .medium)
                optHeader.textColor = .secondaryLabelColor
                permContentViews.append(optHeader)
                for perm in optionalPerms {
                    let row = makePermissionRow(
                        extensionID: ext.id, key: perm,
                        type: .apiPermission, isGranted: savedByKey[perm] == .granted,
                        label: ExtensionPermissionDescriptions.describe(perm),
                        isRequired: false
                    )
                    permContentViews.append(row)
                }
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
        let mainStack = NSStackView(views: [headerStack, descLabel, sep, enabledRow, permsStack])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 8),
            mainStack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            scrollView.widthAnchor.constraint(equalTo: detailContainer.widthAnchor),
            flippedDocView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            uninstallButton.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            uninstallButton.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            mainStack.bottomAnchor.constraint(equalTo: uninstallButton.topAnchor, constant: -12),
        ])
    }

    // MARK: - Actions

    @objc private func enabledToggled(_ sender: NSSwitch) {
        guard let ext = selectedExtension else { return }
        let enabled = sender.state == .on
        ExtensionManager.shared.setEnabled(id: ext.id, enabled: enabled)
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
                alert.informativeText = "Revoking this permission may cause the extension to stop working."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Revoke")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn {
                    sender.state = .on
                    return
                }
            }
        }

        AppDatabase.shared.savePermission(ExtensionPermissionRecord(
            extensionID: extensionID, key: key, type: type,
            status: isGranted ? .granted : .denied
        ))

        // Update the WKWebExtensionContext permission status in all loaded profiles
        let wkStatus: WKWebExtensionContext.PermissionStatus = isGranted ? .grantedExplicitly : .deniedExplicitly
        for profile in TabStore.shared.profiles {
            guard let context = profile.extensionContext(for: extensionID) else { continue }
            switch type {
            case .apiPermission:
                let permission = WKWebExtension.Permission(rawValue: key)
                context.setPermissionStatus(wkStatus, for: permission)
            case .matchPattern:
                if let pattern = try? WKWebExtension.MatchPattern(string: key) {
                    context.setPermissionStatus(wkStatus, for: pattern)
                }
            }
        }
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

                try ExtensionManager.shared.install(from: url)

                let alert = NSAlert()
                alert.messageText = "Extension Installed"
                alert.informativeText = "\"\(displayName)\" has been installed and enabled."
                alert.alertStyle = .informational
                alert.runModal()

                // List reloads via notification
                self?.selectedIndex = (self?.extensions.count ?? 1) - 1
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

        ExtensionManager.shared.uninstall(id: ext.id)
        selectedIndex = max(0, selectedIndex - 1)
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
        updateDetail()
    }
}

/// An NSView subclass with flipped coordinates so content starts at the top.
/// Used as an NSScrollView document view for top-aligned content.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
