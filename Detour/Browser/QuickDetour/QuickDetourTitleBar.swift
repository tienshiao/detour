import AppKit

/// The title bar of a Quick Detour window (TASK-193.1), after Arc's Little
/// Arc (docs/little-window/arc-little-arc.png): past the traffic lights an
/// address capsule holding the profile pill, the page's host in the centre
/// (click: the palette, navigating in place), the extension buttons and the
/// copy-link button; then Open in <Space> at the trailing edge: a capsule
/// like the address one, whose main part moves the page (TASK-193.3, Cmd+O)
/// and whose chevron lists the spaces to move it to.
///
/// Placeholder until its subtask: the pill shows the profile and has no menu
/// (TASK-193.4).
final class QuickDetourTitleBar: NSView {
    var onHostClick: (() -> Void)?
    var onCopyLink: (() -> Void)?
    /// Open in's main part was clicked: the default target.
    var onOpenIn: (() -> Void)?
    /// Open in's chevron was clicked: the dropdown, anchored on the capsule.
    var onOpenInMenu: ((NSView) -> Void)?
    /// An extension's button was clicked: its id and the button to anchor on.
    var onExtensionClick: ((String, NSView) -> Void)?
    /// The extensions button (all of the profile's extensions) was clicked.
    var onExtensionsMenuClick: ((NSView) -> Void)?

    /// Where the capsule starts: clear of the traffic lights.
    static let leadingInset: CGFloat = 78

    private let capsule = NSView()
    private let pill = NSView()
    private let pillIcon = NSImageView()
    private let pillLabel = NSTextField(labelWithString: "")
    let hostButton = NSButton(title: "", target: nil, action: nil)
    private let lockIcon = NSImageView()
    let extensionStack = NSStackView()
    let extensionsMenuButton = HoverButton()
    let copyButton = HoverButton()
    /// Open in's capsule: `openInButton`, a divider, `openInMenuButton`.
    let openInControl = NSView()
    let openInButton = NSButton(title: "", target: nil, action: nil)
    let openInMenuButton = HoverButton()
    private let openInDivider = NSView()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks on the bar's background drag the window, as a title bar does.
    override var mouseDownCanMoveWindow: Bool { true }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = 8
        capsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule)

        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.toolTip = "Profile"
        capsule.addSubview(pill)
        pillIcon.translatesAutoresizingMaskIntoConstraints = false
        pillIcon.contentTintColor = .secondaryLabelColor
        pill.addSubview(pillIcon)
        pillLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pillLabel.textColor = .labelColor
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(pillLabel)

        hostButton.isBordered = false
        hostButton.bezelStyle = .inline
        hostButton.font = .systemFont(ofSize: 13)
        hostButton.contentTintColor = .labelColor
        hostButton.lineBreakMode = .byTruncatingMiddle
        hostButton.target = self
        hostButton.action = #selector(hostClicked)
        hostButton.translatesAutoresizingMaskIntoConstraints = false
        hostButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostButton.toolTip = "Go somewhere else"
        capsule.addSubview(hostButton)

        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.contentTintColor = .tertiaryLabelColor
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        capsule.addSubview(lockIcon)

        extensionStack.orientation = .horizontal
        extensionStack.spacing = 2
        extensionStack.translatesAutoresizingMaskIntoConstraints = false
        extensionStack.setContentHuggingPriority(.required, for: .horizontal)
        extensionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        capsule.addSubview(extensionStack)

        configureIconButton(extensionsMenuButton, symbol: "puzzlepiece.extension", label: "Extensions",
                            action: #selector(extensionsMenuClicked))
        capsule.addSubview(extensionsMenuButton)
        configureIconButton(copyButton, symbol: "link", label: "Copy Link", action: #selector(copyClicked))
        capsule.addSubview(copyButton)

        openInControl.wantsLayer = true
        openInControl.layer?.cornerRadius = 8
        openInControl.translatesAutoresizingMaskIntoConstraints = false
        openInControl.setContentHuggingPriority(.required, for: .horizontal)
        openInControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(openInControl)

        openInButton.isBordered = false
        openInButton.bezelStyle = .inline
        openInButton.font = .systemFont(ofSize: 12)
        openInButton.target = self
        openInButton.action = #selector(openInClicked)
        openInButton.translatesAutoresizingMaskIntoConstraints = false
        openInButton.setContentHuggingPriority(.required, for: .horizontal)
        openInButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        openInControl.addSubview(openInButton)

        openInDivider.wantsLayer = true
        openInDivider.translatesAutoresizingMaskIntoConstraints = false
        openInControl.addSubview(openInDivider)

        configureIconButton(openInMenuButton, symbol: "chevron.down", label: "Open in Another Space",
                            action: #selector(openInMenuClicked))
        openInMenuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Open in Another Space")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        openInMenuButton.fixedHoverSize = 20
        openInControl.addSubview(openInMenuButton)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // The host sits in the capsule's centre while there is room, and gives
        // way to the pill and the buttons when there is not.
        let hostCentred = hostButton.centerXAnchor.constraint(equalTo: capsule.centerXAnchor)
        hostCentred.priority = .defaultHigh

        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            capsule.trailingAnchor.constraint(equalTo: openInControl.leadingAnchor, constant: -8),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: 28),

            pill.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 4),
            pill.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 20),
            pillIcon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            pillIcon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pillIcon.widthAnchor.constraint(equalToConstant: 12),
            pillIcon.heightAnchor.constraint(equalToConstant: 12),
            pillLabel.leadingAnchor.constraint(equalTo: pillIcon.trailingAnchor, constant: 4),
            pillLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            pillLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            hostCentred,
            hostButton.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            hostButton.leadingAnchor.constraint(greaterThanOrEqualTo: pill.trailingAnchor, constant: 22),
            hostButton.trailingAnchor.constraint(lessThanOrEqualTo: extensionStack.leadingAnchor, constant: -8),
            lockIcon.trailingAnchor.constraint(equalTo: hostButton.leadingAnchor, constant: -3),
            lockIcon.centerYAnchor.constraint(equalTo: hostButton.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -6),
            copyButton.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            extensionsMenuButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -2),
            extensionsMenuButton.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            extensionStack.trailingAnchor.constraint(equalTo: extensionsMenuButton.leadingAnchor, constant: -2),
            extensionStack.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),

            openInControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            openInControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            openInControl.heightAnchor.constraint(equalToConstant: 28),
            openInButton.leadingAnchor.constraint(equalTo: openInControl.leadingAnchor, constant: 10),
            openInButton.centerYAnchor.constraint(equalTo: openInControl.centerYAnchor),
            openInDivider.leadingAnchor.constraint(equalTo: openInButton.trailingAnchor, constant: 8),
            openInDivider.centerYAnchor.constraint(equalTo: openInControl.centerYAnchor),
            openInDivider.widthAnchor.constraint(equalToConstant: 1),
            openInDivider.heightAnchor.constraint(equalToConstant: 16),
            openInMenuButton.leadingAnchor.constraint(equalTo: openInDivider.trailingAnchor, constant: 2),
            openInMenuButton.centerYAnchor.constraint(equalTo: openInControl.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        openInMenuButtonTrailing.isActive = true
        updateColors()
    }

    private func configureIconButton(_ button: HoverButton, symbol: String, label: String, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.fixedHoverSize = 22
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    // MARK: - Content

    /// The profile pill: its name, and a symbol saying whether it is Private.
    func setProfile(name: String, isPrivate: Bool) {
        pillLabel.stringValue = name
        pillIcon.image = NSImage(systemSymbolName: isPrivate ? "eyeglasses" : "person.crop.circle",
                                 accessibilityDescription: nil)
        pill.setAccessibilityLabel("Profile: \(name)")
    }

    /// The page's host, or the prompt when nothing is loaded.
    func setHost(_ host: String?, isSecure: Bool) {
        let text = host ?? ""
        hostButton.title = text.isEmpty ? "Where to?" : text
        hostButton.contentTintColor = text.isEmpty ? .tertiaryLabelColor : .labelColor
        lockIcon.isHidden = text.isEmpty || !isSecure
        copyButton.isEnabled = !text.isEmpty
    }

    /// The Open in capsule: what its main part names after "Open in" (a
    /// space's emoji and name, or "Private Window"), whether that reloads the
    /// page (another profile's space), and whether there is a dropdown (none
    /// for a Private Quick Detour). A nil destination hides it: there is no
    /// normal space to open in.
    func setOpenIn(destination: String?, reloads: Bool, hasDropdown: Bool) {
        guard let destination else {
            openInControl.isHidden = true
            return
        }
        openInControl.isHidden = false
        let title = NSMutableAttributedString(string: "Open in ", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        title.append(NSAttributedString(string: destination, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        title.append(NSAttributedString(string: "  ⌘O", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        openInButton.attributedTitle = title
        openInButton.toolTip = reloads
            ? "Open this address in \(destination) (another profile: the page reloads there)"
            : "Move this page into a new tab in \(destination)"
        openInButton.setAccessibilityLabel("Open in \(destination)")
        openInMenuButton.isHidden = !hasDropdown
        openInDivider.isHidden = !hasDropdown
        // Without the chevron the capsule closes after the title. The one
        // going inactive goes first, so the two never conflict.
        if hasDropdown {
            openInButtonTrailing.isActive = false
            openInMenuButtonTrailing.isActive = true
        } else {
            openInMenuButtonTrailing.isActive = false
            openInButtonTrailing.isActive = true
        }
    }

    private lazy var openInButtonTrailing = openInButton.trailingAnchor.constraint(
        equalTo: openInControl.trailingAnchor, constant: -10)
    private lazy var openInMenuButtonTrailing = openInMenuButton.trailingAnchor.constraint(
        equalTo: openInControl.trailingAnchor, constant: -3)

    /// The pinned extensions' buttons, in order.
    func setExtensions(_ items: [(id: String, image: NSImage)]) {
        extensionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let button = HoverButton()
            configureIconButton(button, symbol: "puzzlepiece", label: item.id, action: #selector(extensionClicked(_:)))
            button.image = item.image
            button.imageScaling = .scaleProportionallyDown
            button.identifier = NSUserInterfaceItemIdentifier(item.id)
            button.toolTip = ExtensionManager.shared.displayName(for: item.id)
            extensionStack.addArrangedSubview(button)
        }
    }

    /// Replaces one extension's icon after its action changed.
    func updateExtensionIcon(extensionID: String, image: NSImage) {
        for case let button as NSButton in extensionStack.arrangedSubviews
        where button.identifier?.rawValue == extensionID {
            button.image = image
        }
    }

    func extensionButton(for extensionID: String) -> NSView? {
        extensionStack.arrangedSubviews.first { $0.identifier?.rawValue == extensionID }
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            capsule.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            openInControl.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            openInDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - Actions

    @objc private func hostClicked() { onHostClick?() }
    @objc private func copyClicked() { onCopyLink?() }
    @objc private func extensionsMenuClicked() { onExtensionsMenuClick?(extensionsMenuButton) }
    @objc private func openInClicked() { onOpenIn?() }
    @objc private func openInMenuClicked() { onOpenInMenu?(openInControl) }

    @objc private func extensionClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onExtensionClick?(id, sender)
    }
}
