import AppKit

class FauxAddressBar: NSView {
    var displayText: String = "" {
        didSet {
            label.stringValue = displayText
            updateLeadingIcon()
            updateShieldVisibility()
        }
    }

    var isSecure: Bool = true {
        didSet { updateLeadingIcon() }
    }

    var blockedCount: Int = 0 {
        didSet { updateBadge() }
    }

    var isBlockingEnabledForHost: Bool = true {
        didSet { updateShieldIcon() }
    }

    var onClick: (() -> Void)?
    var onCopyURL: (() -> Void)?
    var onShieldClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let leadingIcon = NSImageView()
    let shieldButton = HoverButton()
    private let copyButton = HoverButton()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var labelLeadingDefault: NSLayoutConstraint!
    private var labelLeadingAfterIcon: NSLayoutConstraint!

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

        // Shield button (content blocker indicator)
        shieldButton.bezelStyle = .inline
        shieldButton.isBordered = false
        shieldButton.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Content blocker")
        shieldButton.contentTintColor = .controlAccentColor
        shieldButton.target = self
        shieldButton.action = #selector(shieldClicked)
        shieldButton.translatesAutoresizingMaskIntoConstraints = false
        shieldButton.setContentHuggingPriority(.required, for: .horizontal)
        shieldButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        shieldButton.isHidden = true
        shieldButton.fixedHoverSize = 22
        addSubview(shieldButton)

        // Badge for blocked count
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
        badgeLabel.isHidden = true
        addSubview(badgeLabel)

        copyButton.bezelStyle = .inline
        copyButton.isBordered = false
        copyButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy URL")
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

        NSLayoutConstraint.activate([
            leadingIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            leadingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingIcon.widthAnchor.constraint(equalToConstant: 14),
            leadingIcon.heightAnchor.constraint(equalToConstant: 14),
            label.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: shieldButton.leadingAnchor, constant: -2),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            shieldButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            shieldButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.bottomAnchor.constraint(equalTo: shieldButton.bottomAnchor, constant: 4),
            badgeLabel.centerXAnchor.constraint(equalTo: shieldButton.centerXAnchor),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
            badgeLabel.heightAnchor.constraint(equalToConstant: 10),
        ])

        updateLeadingIcon()
    }

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

    private func updateShieldVisibility() {
        shieldButton.isHidden = displayText.isEmpty
        if displayText.isEmpty {
            badgeLabel.isHidden = true
        }
    }

    private func updateShieldIcon() {
        if isBlockingEnabledForHost {
            shieldButton.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "Content blocking active")
            shieldButton.contentTintColor = .controlAccentColor
            shieldButton.toolTip = "Content blocking is enabled for this site"
        } else {
            shieldButton.image = NSImage(systemSymbolName: "shield.slash", accessibilityDescription: "Content blocking disabled")
            shieldButton.contentTintColor = .secondaryLabelColor
            shieldButton.toolTip = "Content blocking is disabled for this site"
        }
    }

    private func updateBadge() {
        if blockedCount > 0 {
            badgeLabel.stringValue = blockedCount > 99 ? "99+" : "\(blockedCount)"
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
    }

    @objc private func copyClicked() {
        onCopyURL?()
    }

    @objc private func shieldClicked() {
        onShieldClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !displayText.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            copyButton.animator().alphaValue = 0
        }
    }

    override func resetCursorRects() {
        addCursorRect(label.frame, cursor: .iBeam)
        addCursorRect(copyButton.frame, cursor: .arrow)
        addCursorRect(shieldButton.frame, cursor: .arrow)
        if !leadingIcon.isHidden {
            addCursorRect(leadingIcon.frame, cursor: .arrow)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if copyButton.frame.insetBy(dx: -6, dy: -6).contains(point) {
            copyButton.contentTintColor = .labelColor
            return
        }
        if !shieldButton.isHidden && shieldButton.frame.insetBy(dx: -4, dy: -4).contains(point) {
            return
        }
        onClick?()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if copyButton.frame.insetBy(dx: -6, dy: -6).contains(point) {
            copyButton.contentTintColor = .secondaryLabelColor
            onCopyURL?()
            return
        }
        if !shieldButton.isHidden && shieldButton.frame.insetBy(dx: -4, dy: -4).contains(point) {
            onShieldClick?()
        }
    }
}
