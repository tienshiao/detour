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
    /// Whether the popover has the picture in picture and dev mode switches:
    /// they act on a window's tab switching and sidebar, which a Quick Detour
    /// doesn't have (TASK-213).
    var showsTabSwitches: Bool = true
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

        var constraints = [container.widthAnchor.constraint(equalToConstant: width)]
        var bottom = container.topAnchor
        /// Adds `view` below the last one, `gap` under it, inset by the margin
        /// on the leading side and, when `fullWidth`, on the trailing one too.
        func stack(_ view: NSView, gap: CGFloat, fullWidth: Bool = false) {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            constraints += [
                view.topAnchor.constraint(equalTo: bottom, constant: gap),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
                fullWidth
                    ? view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin)
                    : view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),
            ]
            bottom = view.bottomAnchor
        }
        func separator() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            return box
        }

        // MARK: - The site

        let hostLabel = NSTextField(labelWithString: host.isEmpty ? "No site loaded" : host)
        hostLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        hostLabel.textColor = host.isEmpty ? .secondaryLabelColor : .labelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack(hostLabel, gap: margin - 2)
        stack(separator(), gap: 10, fullWidth: true)

        // MARK: - Content Blocking Section

        let contentBlockingTitle = NSTextField(labelWithString: "Content Blocking")
        contentBlockingTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        stack(contentBlockingTitle, gap: margin - 4)

        // Shield icon with badge, right of the section's title
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

        constraints += [
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
        ]

        let blockedLabel = NSTextField(labelWithString: blockedCount > 0 ? "\(blockedCount) resource\(blockedCount == 1 ? "" : "s") blocked on this page" : "No resources blocked yet")
        blockedLabel.font = .systemFont(ofSize: 11)
        blockedLabel.textColor = .tertiaryLabelColor
        stack(blockedLabel, gap: 2)

        toggleSwitch.state = isBlockingEnabled ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(toggleClicked)
        stack(makeSwitchRow("Block content on this site", toggleSwitch), gap: spacing, fullWidth: true)

        // MARK: - Tab Switches Section

        if showsTabSwitches {
            stack(separator(), gap: margin - 4, fullWidth: true)

            pictureInPictureSwitch.state = isPictureInPictureEnabled ? .on : .off
            pictureInPictureSwitch.isEnabled = !host.isEmpty
            pictureInPictureSwitch.target = self
            pictureInPictureSwitch.action = #selector(pictureInPictureToggleClicked)
            stack(makeSwitchRow("Picture in picture on tab switch", pictureInPictureSwitch), gap: margin - 4, fullWidth: true)

            devModeSwitch.state = isDevModeEnabled ? .on : .off
            devModeSwitch.isEnabled = isDevModeAvailable
            devModeSwitch.target = self
            devModeSwitch.action = #selector(devModeToggleClicked)
            stack(makeSwitchRow("Dev mode for this site", devModeSwitch), gap: spacing, fullWidth: true)
        }

        stack(separator(), gap: margin - 4, fullWidth: true)

        // MARK: - Extensions Section

        let extensionsTitle = NSTextField(labelWithString: "Extensions")
        extensionsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        stack(extensionsTitle, gap: margin - 4)

        // Build extension rows in a vertical stack
        let extensionStack = NSStackView()
        extensionStack.orientation = .vertical
        extensionStack.spacing = 0

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
        stack(extensionStack, gap: spacing, fullWidth: true)

        // Extension Settings button
        let settingsButton = NSButton(title: "Extension Settings…", target: self, action: #selector(openExtensionSettings))
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .controlAccentColor
        settingsButton.font = .systemFont(ofSize: 12)
        stack(settingsButton, gap: spacing)

        constraints.append(container.bottomAnchor.constraint(equalTo: bottom, constant: margin))
        NSLayoutConstraint.activate(constraints)
    }

    /// A switch with its label on the left, as tall as the switch.
    private func makeSwitchRow(_ title: String, _ control: NSSwitch) -> NSView {
        let row = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        control.setAccessibilityLabel(title)
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // 6, not 8: "Picture in picture on tab switch" (188 pt) and the
            // switch (54 pt) only just fit the 248 pt content width.
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -6),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
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
    ///   - showsTabSwitches: whether to offer picture in picture and dev mode;
    ///     the Quick Detour, with no tabs to switch and no sidebar, doesn't.
    static func forPage(url: URL?, blockedCount: Int, profileID: UUID?,
                        showsTabSwitches: Bool = true,
                        pages: @escaping () -> [BrowserTab],
                        openExtension: @escaping (String) -> Void) -> SettingsPopoverViewController {
        let host = url?.host ?? ""
        let vc = SettingsPopoverViewController()
        vc.host = host
        vc.showsTabSwitches = showsTabSwitches
        if let profileID {
            vc.isBlockingEnabled = host.isEmpty
                || !ContentBlockerManager.shared.whitelist.isWhitelisted(host: host, profileID: profileID)
        }
        if showsTabSwitches {
            if let profileID {
                vc.isPictureInPictureEnabled = host.isEmpty ? true
                    : SiteSettingsStore.shared.override(.pictureInPicture, forSite: host, profileID: profileID) ?? true
            }
            // With no profile there is no override, but the local-development
            // default still applies.
            vc.isDevModeEnabled = DevMode.isActive(for: url, profileID: profileID)
            vc.isDevModeAvailable = devModeSiteKey(for: url) != nil
        }
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

        if showsTabSwitches {
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
