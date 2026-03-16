import AppKit

class FolderCellView: NSTableCellView {
    private let disclosureButton = NSButton()
    private let folderIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let hoverBackground = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var leadingConstraint: NSLayoutConstraint!
    var onToggleCollapse: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = UIConstants.defaultCornerRadius
        hoverBackground.isHidden = true
        addSubview(hoverBackground, positioned: .below, relativeTo: nil)

        disclosureButton.bezelStyle = .inline
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureTapped)
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        folderIcon.imageScaling = .scaleProportionallyUpOrDown
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")

        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(disclosureButton)
        addSubview(folderIcon)
        addSubview(nameLabel)

        leadingConstraint = disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)

        NSLayoutConstraint.activate([
            leadingConstraint,
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 16),
            disclosureButton.heightAnchor.constraint(equalToConstant: 16),

            folderIcon.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 2),
            folderIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            folderIcon.widthAnchor.constraint(equalToConstant: 16),
            folderIcon.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: folderIcon.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, isCollapsed: Bool, depth: Int, color: NSColor?) {
        nameLabel.stringValue = name
        leadingConstraint.constant = 4 + CGFloat(depth) * 16
        folderIcon.contentTintColor = color ?? .secondaryLabelColor

        let chevron = isCollapsed ? "chevron.right" : "chevron.down"
        disclosureButton.image = NSImage(systemSymbolName: chevron, accessibilityDescription: isCollapsed ? "Expand" : "Collapse")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        hoverBackground.isHidden = true
    }

    override func layout() {
        super.layout()
        hoverBackground.frame = bounds.insetBy(dx: -6, dy: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
        hoverBackground.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverBackground.isHidden = true
    }

    @objc private func disclosureTapped() {
        onToggleCollapse?()
    }
}
