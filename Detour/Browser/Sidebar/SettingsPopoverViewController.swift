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
    var blockedCount: Int = 0
    var extensions: [ExtensionItem] = []

    var onBlockingToggle: (() -> Void)?
    var onPinToggle: ((String) -> Void)?
    var onExtensionClick: ((String) -> Void)?
    var onOpenExtensionSettings: (() -> Void)?

    private let toggleSwitch = NSSwitch()

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

            separator.topAnchor.constraint(equalTo: toggleLabel.bottomAnchor, constant: margin),
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
