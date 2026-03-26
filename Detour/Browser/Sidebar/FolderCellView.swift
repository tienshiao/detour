import AppKit

class FolderCellView: NSTableCellView, NSTextFieldDelegate {
    private let disclosureButton = NSButton()
    private let nameLabel = NSTextField(labelWithString: "")
    private let hoverBackground = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var leadingConstraint: NSLayoutConstraint!
    var onToggleCollapse: (() -> Void)?
    var onRename: ((String) -> Void)?
    private var isEditing = false
    private var originalEditingValue: String?

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
        disclosureButton.imageScaling = .scaleProportionallyUpOrDown
        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureTapped)
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(disclosureButton)
        addSubview(nameLabel)

        leadingConstraint = disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)

        NSLayoutConstraint.activate([
            leadingConstraint,
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 20),
            disclosureButton.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, isCollapsed: Bool, depth: Int, color: NSColor?) {
        nameLabel.stringValue = name
        leadingConstraint.constant = 2 + CGFloat(depth) * 16
        let symbolName = isCollapsed ? "font-awesome-folder.fill" : "font-awesome-folder-open.fill"
        disclosureButton.image = NSImage(named: symbolName)
        updateColor(color)
    }

    func updateColor(_ color: NSColor?) {
        disclosureButton.contentTintColor = (color ?? .secondaryLabelColor).withAlphaComponent(0.7)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        hoverBackground.isHidden = true
        if isEditing { endEditing(commit: false) }
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

    func beginEditing() {
        isEditing = true
        originalEditingValue = nameLabel.stringValue
        nameLabel.isEditable = true
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.focusRingType = .none
        nameLabel.delegate = self
        nameLabel.selectText(nil)
    }

    private func endEditing(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        nameLabel.isEditable = false
        if !commit, let original = originalEditingValue {
            nameLabel.stringValue = original
        }
        originalEditingValue = nil
        if commit {
            let newName = nameLabel.stringValue.trimmingCharacters(in: .whitespaces)
            if !newName.isEmpty {
                onRename?(newName)
                pulseCommit()
            }
        }
    }

    private func pulseCommit() {
        hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
        hoverBackground.isHidden = false
        hoverBackground.alphaValue = 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverBackground.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !self.isHovered {
                self.hoverBackground.isHidden = true
            }
            self.hoverBackground.alphaValue = 1
        })
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        endEditing(commit: true)
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            endEditing(commit: false)
            window?.makeFirstResponder(enclosingScrollView?.documentView)
            return true
        }
        return false
    }
}
