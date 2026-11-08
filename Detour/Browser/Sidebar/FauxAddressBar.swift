import AppKit

/// The sidebar's address bar: the host, then (on hover) the trailing icons in
/// the same order as a Quick Detour's bar (TASK-299): the pinned extensions,
/// Copy Link and Site Settings. Copy and Site Settings sit together at the
/// trailing edge, so they never move; extensions grow leftward from Copy.
class FauxAddressBar: NSView {
    /// The copy button's tooltip and accessibility label, shared with a Quick
    /// Detour's title bar (TASK-299).
    static let copyLinkLabel = "Copy Link"
    /// The site settings button's tooltip and accessibility label, shared
    /// with a Quick Detour's title bar.
    static let siteSettingsLabel = "Site Settings"

    var displayText: String = "" {
        didSet {
            label.stringValue = displayText
            updateLeadingIcon()
        }
    }

    var isSecure: Bool = true {
        didSet { updateLeadingIcon() }
    }

    var onClick: (() -> Void)?
    var onCopyURL: (() -> Void)?
    var onSettingsClick: (() -> Void)?
    var onPinnedExtensionClick: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let leadingIcon = NSImageView()
    let settingsButton = HoverButton()
    let copyButton = HoverButton()
    let pinnedExtensionStack = NSStackView()
    private var labelLeadingDefault: NSLayoutConstraint!
    private var labelLeadingAfterIcon: NSLayoutConstraint!
    private var labelTrailingToButtons: NSLayoutConstraint!
    private var labelTrailingToStack: NSLayoutConstraint!
    private var labelTrailingToEdge: NSLayoutConstraint!
    private var hasPinnedExtensions = false
    private var isHovering = false
    var keepButtonsVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = UIConstants.defaultCornerRadius
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.placeholderAttributedString = NSAttributedString(
            string: "Where to?",
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            ]
        )
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        leadingIcon.translatesAutoresizingMaskIntoConstraints = false
        leadingIcon.setContentHuggingPriority(.required, for: .horizontal)
        leadingIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(leadingIcon)

        // Settings button
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: Self.siteSettingsLabel)
        settingsButton.toolTip = Self.siteSettingsLabel
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsButton.alphaValue = 0
        settingsButton.fixedHoverSize = 22
        addSubview(settingsButton)

        // Pinned extension icons stack
        pinnedExtensionStack.orientation = .horizontal
        pinnedExtensionStack.spacing = 2
        pinnedExtensionStack.distribution = .fill
        pinnedExtensionStack.translatesAutoresizingMaskIntoConstraints = false
        pinnedExtensionStack.setContentHuggingPriority(.required, for: .horizontal)
        pinnedExtensionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        pinnedExtensionStack.alphaValue = 0
        addSubview(pinnedExtensionStack)

        copyButton.bezelStyle = .inline
        copyButton.isBordered = false
        copyButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: Self.copyLinkLabel)
        copyButton.toolTip = Self.copyLinkLabel
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyButton.alphaValue = 0
        copyButton.fixedHoverSize = 22
        addSubview(copyButton)

        labelLeadingDefault = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        labelLeadingAfterIcon = label.leadingAnchor.constraint(equalTo: leadingIcon.trailingAnchor, constant: 6)
        // On hover the label ends before the leftmost trailing icon: the
        // extensions when there are any, Copy otherwise.
        labelTrailingToButtons = label.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -4)
        labelTrailingToStack = label.trailingAnchor.constraint(equalTo: pinnedExtensionStack.leadingAnchor, constant: -4)
        labelTrailingToEdge = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)

        // Start with buttons hidden — label extends to trailing edge
        pinnedExtensionStack.isHidden = true
        labelTrailingToEdge.isActive = true

        NSLayoutConstraint.activate([
            leadingIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            leadingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingIcon.widthAnchor.constraint(equalToConstant: 14),
            leadingIcon.heightAnchor.constraint(equalToConstant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -2),
            pinnedExtensionStack.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -2),
            pinnedExtensionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateLeadingIcon()
    }

    // MARK: - Pinned Extensions

    func setPinnedExtensions(_ items: [(id: String, image: NSImage)]) {
        pinnedExtensionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        hasPinnedExtensions = !items.isEmpty
        pinnedExtensionStack.isHidden = !hasPinnedExtensions
        updateLabelTrailing()

        for item in items {
            let button = HoverButton()
            button.bezelStyle = .inline
            button.isBordered = false
            // Resize to 14x14 to match SF Symbol visual weight of copy/settings buttons
            let iconSize = NSSize(width: 14, height: 14)
            let resized = NSImage(size: iconSize, flipped: false) { rect in
                item.image.draw(in: rect)
                return true
            }
            button.image = resized
            button.imageScaling = .scaleNone
            button.identifier = NSUserInterfaceItemIdentifier(item.id)
            button.toolTip = ExtensionManager.shared.displayName(for: item.id)
            button.setAccessibilityLabel(button.toolTip)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.fixedHoverSize = 22
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.target = self
            button.action = #selector(pinnedExtensionClicked(_:))
            pinnedExtensionStack.addArrangedSubview(button)
        }

        // Update alpha to match current hover state
        let alpha: CGFloat = isHovering && !displayText.isEmpty ? 1 : 0
        pinnedExtensionStack.alphaValue = alpha

        window?.invalidateCursorRects(for: self)
    }

    func updatePinnedExtensionIcon(extensionID: String, image: NSImage) {
        for view in pinnedExtensionStack.arrangedSubviews {
            if let button = view as? HoverButton, button.identifier?.rawValue == extensionID {
                button.image = image
                break
            }
        }
    }

    // MARK: - State Updates

    private func updateLeadingIcon() {
        if displayText.isEmpty {
            leadingIcon.isHidden = false
            leadingIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            leadingIcon.contentTintColor = .tertiaryLabelColor
            leadingIcon.toolTip = nil
            labelLeadingDefault.isActive = false
            labelLeadingAfterIcon.isActive = true
        } else if !isSecure {
            leadingIcon.isHidden = false
            leadingIcon.image = NSImage(systemSymbolName: "lock.trianglebadge.exclamationmark", accessibilityDescription: "Insecure connection")
            leadingIcon.contentTintColor = .systemRed
            leadingIcon.toolTip = "This connection is not secure"
            labelLeadingDefault.isActive = false
            labelLeadingAfterIcon.isActive = true
        } else {
            leadingIcon.isHidden = true
            leadingIcon.toolTip = nil
            labelLeadingAfterIcon.isActive = false
            labelLeadingDefault.isActive = true
        }
    }

    // MARK: - Actions

    @objc private func copyClicked() {
        onCopyURL?()
    }

    @objc private func settingsClicked() {
        onSettingsClick?()
    }

    @objc private func pinnedExtensionClicked(_ sender: HoverButton) {
        guard let extID = sender.identifier?.rawValue else { return }
        onPinnedExtensionClick?(extID)
    }

    // MARK: - Mouse Tracking

    /// The label's trailing edge: the bar's edge while the icons are hidden,
    /// else the leftmost icon. The one going inactive goes first, so the
    /// constraints never conflict.
    private func updateLabelTrailing() {
        let target: NSLayoutConstraint = !isHovering ? labelTrailingToEdge
            : hasPinnedExtensions ? labelTrailingToStack : labelTrailingToButtons
        for constraint in [labelTrailingToEdge!, labelTrailingToStack!, labelTrailingToButtons!] where constraint !== target {
            constraint.isActive = false
        }
        target.isActive = true
    }

    private func showButtons() {
        isHovering = true
        updateLabelTrailing()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyButton.animator().alphaValue = 1
            settingsButton.animator().alphaValue = 1
            if hasPinnedExtensions {
                pinnedExtensionStack.animator().alphaValue = 1
            }
        }
    }

    private func hideButtons() {
        isHovering = false
        updateLabelTrailing()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyButton.animator().alphaValue = 0
            settingsButton.animator().alphaValue = 0
            pinnedExtensionStack.animator().alphaValue = 0
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !displayText.isEmpty else { return }
        showButtons()
    }

    override func mouseExited(with event: NSEvent) {
        guard !keepButtonsVisible else { return }
        hideButtons()
    }

    /// Called when a popover anchored to this bar closes, to hide buttons if the mouse is no longer inside.
    func dismissPopoverKeep() {
        keepButtonsVisible = false
        // Check if mouse is still inside
        guard let window else { hideButtons(); return }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let mouseInSelf = convert(mouseInWindow, from: nil)
        if !bounds.contains(mouseInSelf) {
            hideButtons()
        }
    }

    override func resetCursorRects() {
        addCursorRect(label.frame, cursor: .iBeam)
        addCursorRect(copyButton.frame, cursor: .arrow)
        addCursorRect(settingsButton.frame, cursor: .arrow)
        for view in pinnedExtensionStack.arrangedSubviews {
            addCursorRect(convert(view.bounds, from: view), cursor: .arrow)
        }
        if !leadingIcon.isHidden {
            addCursorRect(leadingIcon.frame, cursor: .arrow)
        }
    }

    private enum TrailingHit {
        case copy
        case settings
        case pinnedExtension(NSView)
    }

    /// The trailing button under `point`. The buttons sit 2 pt apart and each
    /// has a padded hit area, so an exact hit on any button wins before the
    /// padding is considered; otherwise Copy's padding would take clicks on
    /// the edge of its neighbours.
    private func trailingHit(at point: NSPoint) -> TrailingHit? {
        let extensions = pinnedExtensionStack.arrangedSubviews.map { ($0, convert($0.bounds, from: $0)) }
        for padding: CGFloat in [0, 4] {
            if settingsButton.frame.insetBy(dx: -padding, dy: -padding).contains(point) { return .settings }
            for (view, frame) in extensions where frame.insetBy(dx: -padding, dy: -padding).contains(point) {
                return .pinnedExtension(view)
            }
            if copyButton.frame.insetBy(dx: -padding, dy: -padding).contains(point) { return .copy }
        }
        if copyButton.frame.insetBy(dx: -6, dy: -6).contains(point) { return .copy }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isHovering, let hit = trailingHit(at: point) {
            if case .copy = hit { copyButton.contentTintColor = .labelColor }
            return
        }
        onClick?()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isHovering, let hit = trailingHit(at: point) else { return }
        switch hit {
        case .copy:
            copyButton.contentTintColor = .secondaryLabelColor
            onCopyURL?()
        case .settings:
            onSettingsClick?()
        case .pinnedExtension(let view):
            if let button = view as? HoverButton {
                pinnedExtensionClicked(button)
            }
        }
    }
}
