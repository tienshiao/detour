import AppKit

class SettingsPopoverViewController: NSViewController {

    struct ExtensionItem {
        let id: String
        let name: String
        let icon: NSImage
        let isPinned: Bool
    }

    var host: String = ""
    var isBlockingEnabled: Bool = true
    /// The site's picture in picture switch (TASK-188): whether switching away
    /// from its playing tab enters picture in picture.
    var isPictureInPictureEnabled: Bool = true
    /// The site's dev mode switch (TASK-186.5): the effective state, and
    /// whether the page has a site key to store a choice under.
    var isDevModeEnabled: Bool = false
    var isDevModeAvailable: Bool = false
    var blockedCount: Int = 0
    var extensions: [ExtensionItem] = []

    var onBlockingToggle: (() -> Void)?
    var onPictureInPictureToggle: ((Bool) -> Void)?
    var onDevModeToggle: ((Bool) -> Void)?
    var onPinToggle: ((String) -> Void)?
    var onExtensionClick: ((String) -> Void)?
    var onOpenExtensionSettings: (() -> Void)?

    private let toggleSwitch = NSSwitch()
    private let pictureInPictureSwitch = NSSwitch()
    private let devModeSwitch = NSSwitch()

    override func loadView() {
        let margin: CGFloat = 16
        let spacing: CGFloat = 8
        let width: CGFloat = 280

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container

        // MARK: - Content Blocking Section

        let contentBlockingTitle = NSTextField(labelWithString: "Content Blocking")
        contentBlockingTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        contentBlockingTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentBlockingTitle)

        // Shield icon with badge (top-right of section)
        let shieldContainer = NSView()
        shieldContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(shieldContainer)

        let shieldIcon = NSImageView()
        shieldIcon.translatesAutoresizingMaskIntoConstraints = false
        if isBlockingEnabled {
            shieldIcon.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Content blocking active")
            shieldIcon.contentTintColor = .controlAccentColor
        } else {
            shieldIcon.image = NSImage(systemSymbolName: "shield.slash", accessibilityDescription: "Content blocking disabled")
            shieldIcon.contentTintColor = .secondaryLabelColor
        }
        shieldContainer.addSubview(shieldIcon)

        let badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.font = .systemFont(ofSize: 7, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = .controlAccentColor
        badgeLabel.drawsBackground = true
        badgeLabel.isBezeled = false
        badgeLabel.isEditable = false
        badgeLabel.alignment = .center
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 4.5
        badgeLabel.layer?.masksToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        if blockedCount > 0 {
            badgeLabel.stringValue = blockedCount > 99 ? "99+" : "\(blockedCount)"
        } else {
            badgeLabel.isHidden = true
        }
        shieldContainer.addSubview(badgeLabel)

        let hostLabel = NSTextField(labelWithString: host.isEmpty ? "No site loaded" : host)
        hostLabel.font = .systemFont(ofSize: 11)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostLabel)

        let blockedLabel = NSTextField(labelWithString: blockedCount > 0 ? "\(blockedCount) resource\(blockedCount == 1 ? "" : "s") blocked on this page" : "No resources blocked yet")
        blockedLabel.font = .systemFont(ofSize: 11)
        blockedLabel.textColor = .tertiaryLabelColor
        blockedLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blockedLabel)

        let toggleLabel = NSTextField(labelWithString: "Block content on this site")
        toggleLabel.font = .systemFont(ofSize: 13)
        toggleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggleLabel)

        toggleSwitch.state = isBlockingEnabled ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(toggleClicked)
        toggleSwitch.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggleSwitch)

        let pictureInPictureLabel = NSTextField(labelWithString: "Picture in picture on tab switch")
        pictureInPictureLabel.font = .systemFont(ofSize: 13)
        pictureInPictureLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pictureInPictureLabel)

        pictureInPictureSwitch.state = isPictureInPictureEnabled ? .on : .off
        pictureInPictureSwitch.isEnabled = !host.isEmpty
        pictureInPictureSwitch.target = self
        pictureInPictureSwitch.action = #selector(pictureInPictureToggleClicked)
        pictureInPictureSwitch.setAccessibilityLabel("Picture in picture on tab switch")
        pictureInPictureSwitch.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pictureInPictureSwitch)

        let devModeLabel = NSTextField(labelWithString: "Dev mode for this site")
        devModeLabel.font = .systemFont(ofSize: 13)
        devModeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(devModeLabel)

        devModeSwitch.state = isDevModeEnabled ? .on : .off
        devModeSwitch.isEnabled = isDevModeAvailable
        devModeSwitch.target = self
        devModeSwitch.action = #selector(devModeToggleClicked)
        devModeSwitch.setAccessibilityLabel("Dev mode for this site")
        devModeSwitch.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(devModeSwitch)

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        // MARK: - Extensions Section

        let extensionsTitle = NSTextField(labelWithString: "Extensions")
        extensionsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        extensionsTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(extensionsTitle)

        // Build extension rows in a vertical stack
        let extensionStack = NSStackView()
        extensionStack.orientation = .vertical
        extensionStack.spacing = 0
        extensionStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(extensionStack)

        if extensions.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No extensions installed")
            emptyLabel.font = .systemFont(ofSize: 11)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            extensionStack.addArrangedSubview(emptyLabel)
        } else {
            for ext in extensions {
                let row = makeExtensionRow(ext)
                extensionStack.addArrangedSubview(row)
            }
        }

        // Extension Settings button
        let settingsButton = NSButton(title: "Extension Settings…", target: self, action: #selector(openExtensionSettings))
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .controlAccentColor
        settingsButton.font = .systemFont(ofSize: 12)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(settingsButton)

        // MARK: - Layout

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),

            contentBlockingTitle.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            contentBlockingTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            shieldContainer.centerYAnchor.constraint(equalTo: contentBlockingTitle.centerYAnchor),
            shieldContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            shieldContainer.widthAnchor.constraint(equalToConstant: 22),
            shieldContainer.heightAnchor.constraint(equalToConstant: 18),

            shieldIcon.centerXAnchor.constraint(equalTo: shieldContainer.centerXAnchor),
            shieldIcon.centerYAnchor.constraint(equalTo: shieldContainer.centerYAnchor),
            shieldIcon.widthAnchor.constraint(equalToConstant: 16),
            shieldIcon.heightAnchor.constraint(equalToConstant: 16),

            badgeLabel.bottomAnchor.constraint(equalTo: shieldIcon.bottomAnchor, constant: 4),
            badgeLabel.centerXAnchor.constraint(equalTo: shieldIcon.centerXAnchor),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
            badgeLabel.heightAnchor.constraint(equalToConstant: 10),

            hostLabel.topAnchor.constraint(equalTo: contentBlockingTitle.bottomAnchor, constant: 2),
            hostLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            blockedLabel.topAnchor.constraint(equalTo: hostLabel.bottomAnchor, constant: spacing),
            blockedLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            toggleLabel.topAnchor.constraint(equalTo: blockedLabel.bottomAnchor, constant: spacing),
            toggleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            toggleSwitch.centerYAnchor.constraint(equalTo: toggleLabel.centerYAnchor),
            toggleSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            pictureInPictureLabel.topAnchor.constraint(equalTo: toggleLabel.bottomAnchor, constant: spacing + 6),
            pictureInPictureLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            pictureInPictureSwitch.centerYAnchor.constraint(equalTo: pictureInPictureLabel.centerYAnchor),
            pictureInPictureSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            devModeLabel.topAnchor.constraint(equalTo: pictureInPictureLabel.bottomAnchor, constant: spacing + 6),
            devModeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            devModeSwitch.centerYAnchor.constraint(equalTo: devModeLabel.centerYAnchor),
            devModeSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            separator.topAnchor.constraint(equalTo: devModeLabel.bottomAnchor, constant: margin),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            extensionsTitle.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: margin - 4),
            extensionsTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            extensionStack.topAnchor.constraint(equalTo: extensionsTitle.bottomAnchor, constant: spacing),
            extensionStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            extensionStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            settingsButton.topAnchor.constraint(equalTo: extensionStack.bottomAnchor, constant: spacing),
            settingsButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),

            container.bottomAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: margin),
        ])
    }

    private func makeExtensionRow(_ ext: ExtensionItem) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let iconView = NSImageView(image: ext.icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(iconView)

        let nameButton = NSButton(title: ext.name, target: self, action: #selector(extensionNameClicked(_:)))
        nameButton.bezelStyle = .inline
        nameButton.isBordered = false
        nameButton.font = .systemFont(ofSize: 12)
        nameButton.contentTintColor = .labelColor
        nameButton.alignment = .left
        nameButton.identifier = NSUserInterfaceItemIdentifier(ext.id)
        nameButton.translatesAutoresizingMaskIntoConstraints = false
        nameButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameButton.lineBreakMode = .byTruncatingTail
        row.addSubview(nameButton)

        let pinButton = HoverButton()
        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.tag = ext.isPinned ? 1 : 0
        pinButton.image = NSImage(systemSymbolName: ext.isPinned ? "pin" : "pin.slash", accessibilityDescription: ext.isPinned ? "Unpin" : "Pin")
        pinButton.contentTintColor = .secondaryLabelColor
        pinButton.toolTip = ext.isPinned ? "Unpin from address bar" : "Pin to address bar"
        pinButton.identifier = NSUserInterfaceItemIdentifier(ext.id)
        pinButton.target = self
        pinButton.action = #selector(pinToggleClicked(_:))
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.fixedHoverSize = 22
        row.addSubview(pinButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            nameButton.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameButton.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -4),

            pinButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            pinButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    // MARK: - Actions

    @objc private func toggleClicked() {
        onBlockingToggle?()
    }

    @objc private func pictureInPictureToggleClicked() {
        onPictureInPictureToggle?(pictureInPictureSwitch.state == .on)
    }

    @objc private func devModeToggleClicked() {
        onDevModeToggle?(devModeSwitch.state == .on)
    }

    @objc private func extensionNameClicked(_ sender: NSButton) {
        guard let extID = sender.identifier?.rawValue else { return }
        onExtensionClick?(extID)
    }

    @objc private func pinToggleClicked(_ sender: NSButton) {
        guard let extID = sender.identifier?.rawValue else { return }
        // Toggle visual state: tag 1 = pinned, tag 0 = unpinned
        let nowPinned = sender.tag == 0
        sender.tag = nowPinned ? 1 : 0
        sender.image = NSImage(systemSymbolName: nowPinned ? "pin" : "pin.slash", accessibilityDescription: nowPinned ? "Unpin" : "Pin")
        sender.toolTip = nowPinned ? "Unpin from address bar" : "Pin to address bar"
        onPinToggle?(extID)
    }

    @objc private func openExtensionSettings() {
        onOpenExtensionSettings?()
    }
}

extension SettingsPopoverViewController {
    /// The page settings for a page at `url` in the profile `profileID`: the
    /// main window's address bar and a Quick Detour's bar build the same one
    /// (TASK-210). Every switch acts on the profile the popover was built for,
    /// not on whatever the window shows when it is clicked.
    ///
    /// - Parameters:
    ///   - pages: what the window has on screen; toggling content blocking
    ///     reloads the ones on the switched site.
    ///   - openExtension: an extension's name was clicked: its action.
    static func forPage(url: URL?, blockedCount: Int, profileID: UUID?,
                        pages: @escaping () -> [BrowserTab],
                        openExtension: @escaping (String) -> Void) -> SettingsPopoverViewController {
        let host = url?.host ?? ""
        let vc = SettingsPopoverViewController()
        vc.host = host
        if let profileID {
            vc.isBlockingEnabled = host.isEmpty
                || !ContentBlockerManager.shared.whitelist.isWhitelisted(host: host, profileID: profileID)
            vc.isPictureInPictureEnabled = host.isEmpty ? true
                : SiteSettingsStore.shared.override(.pictureInPicture, forSite: host, profileID: profileID) ?? true
        }
        // With no profile there is no override, but the local-development
        // default still applies.
        vc.isDevModeEnabled = DevMode.isActive(for: url, profileID: profileID)
        vc.isDevModeAvailable = devModeSiteKey(for: url) != nil
        vc.blockedCount = blockedCount

        // The pinned IDs are fetched once, not per extension.
        if let profileID {
            let pinnedIDs = Set(AppDatabase.shared.pinnedExtensionIDs(for: profileID.uuidString))
            vc.extensions = ExtensionManager.shared.enabledExtensions(for: profileID)
                .filter { $0.manifest.action != nil }
                .map { ext in
                    ExtensionItem(id: ext.id, name: ExtensionManager.shared.displayName(for: ext.id),
                                  icon: ExtensionManager.iconImage(for: ext.id, ext: ext),
                                  isPinned: pinnedIDs.contains(ext.id))
                }
        }

        vc.onBlockingToggle = {
            guard let profileID, !host.isEmpty else { return }
            ContentBlockerManager.shared.whitelist.toggleHost(host, profileID: profileID)
            // The switch takes effect per navigation (the page's
            // `WKWebpagePreferences`), so the page has to load again — the way
            // Safari's per-site switch reloads the tab (TASK-69).
            for page in pages()
            where page.url?.host.map({ ContentBlockerWhitelist.covers(host: $0, whitelistedHosts: [host]) }) == true {
                page.reload()
            }
        }

        vc.onPictureInPictureToggle = { isOn in
            guard let profileID, !host.isEmpty else { return }
            // Off stores this host; on clears every row covering it, since a
            // parent site's row would keep it off. Takes effect at the next
            // tab switch, so nothing reloads.
            if isOn {
                SiteSettingsStore.shared.resetToDefault(.pictureInPicture, forSite: host, profileID: profileID)
            } else {
                SiteSettingsStore.shared.set(.pictureInPicture, site: host, to: false, profileID: profileID)
            }
        }

        vc.onDevModeToggle = { isOn in
            guard let profileID else { return }
            // The store's change notification re-marks every sidebar row on
            // this site in every window; nothing reloads.
            DevMode.setEnabled(isOn, for: url, profileID: profileID)
        }

        vc.onPinToggle = { extensionID in
            guard let profileID else { return }
            ExtensionManager.shared.toggleExtensionPinned(extensionID, profileID: profileID)
        }

        vc.onExtensionClick = openExtension

        vc.onOpenExtensionSettings = {
            SettingsWindowController.shared.showExtensionsPane()
        }
        return vc
    }
}
