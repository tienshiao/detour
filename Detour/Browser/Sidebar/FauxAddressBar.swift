import AppKit

class FauxAddressBar: NSView {
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

    private let label = NSTextField(labelWithString: "")
    private let leadingIcon = NSImageView()
    private let copyButton = NSButton()
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
            string: "Where do you want to go?",
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
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
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

    @objc private func copyClicked() {
        onCopyURL?()
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
        onClick?()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if copyButton.frame.insetBy(dx: -6, dy: -6).contains(point) {
            copyButton.contentTintColor = .secondaryLabelColor
            onCopyURL?()
        }
    }
}
