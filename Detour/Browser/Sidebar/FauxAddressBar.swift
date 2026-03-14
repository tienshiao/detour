import AppKit

class FauxAddressBar: NSView {
    var displayText: String = "" {
        didSet { label.stringValue = displayText }
    }

    var isSecure: Bool = true {
        didSet {
            lockIcon.isHidden = isSecure
            labelLeadingDefault.isActive = isSecure
            labelLeadingAfterIcon.isActive = !isSecure
        }
    }

    var onClick: (() -> Void)?
    var onCopyURL: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let lockIcon = NSImageView()
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
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        lockIcon.image = NSImage(systemSymbolName: "lock.trianglebadge.exclamationmark", accessibilityDescription: "Insecure connection")
        lockIcon.contentTintColor = .systemRed
        lockIcon.toolTip = "This connection is not secure"
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.isHidden = true
        lockIcon.setContentHuggingPriority(.required, for: .horizontal)
        lockIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(lockIcon)

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
        labelLeadingAfterIcon = label.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 4)

        NSLayoutConstraint.activate([
            lockIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            lockIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelLeadingDefault,
            label.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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
        if !lockIcon.isHidden {
            addCursorRect(lockIcon.frame, cursor: .arrow)
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
