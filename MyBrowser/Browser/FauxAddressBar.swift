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

    private let label = NSTextField(labelWithString: "")
    private let lockIcon = NSImageView()
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

        labelLeadingDefault = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        labelLeadingAfterIcon = label.leadingAnchor.constraint(equalTo: lockIcon.trailingAnchor, constant: 4)

        NSLayoutConstraint.activate([
            lockIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            lockIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelLeadingDefault,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
