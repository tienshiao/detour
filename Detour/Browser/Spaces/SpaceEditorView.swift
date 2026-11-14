import AppKit

/// The space editor that takes the sidebar's page area (TASK-289, design
/// direction A): an emoji tile and a name field where the space header goes,
/// then the colours, the emoji, the profile, and Cancel / Create Space (Done
/// when editing).
///
/// It only edits a `SpaceDraft`. Every change goes out through `onChange` so
/// the sidebar can preview it on the real tint and switcher; nothing touches
/// `TabStore` until `onCommit`.
final class SpaceEditorView: NSView, NSTextFieldDelegate {
    enum Mode: Equatable {
        case create
        case edit(originalProfileID: UUID)
    }

    struct ProfileChoice: Equatable {
        let id: UUID
        let name: String
    }

    private(set) var draft: SpaceDraft
    private let mode: Mode
    private let profiles: [ProfileChoice]
    /// The user picked an emoji, so the name stops suggesting one.
    private var emojiPickedByUser: Bool

    var onChange: ((SpaceDraft) -> Void)?
    /// The pointer is over a colour (its hex), or left the colours (nil).
    var onHoverColor: ((String?) -> Void)?
    var onCommit: ((SpaceDraft) -> Void)?
    var onCancel: (() -> Void)?

    private let scrollView = NSScrollView()
    private let tileButton = SpaceEmojiTileButton()
    private let nameField = NSTextField()
    private let colorGrid = SpaceChoiceGridView(columns: 6, rowHeight: 30, spacing: 4, accessibilityLabel: "Color")
    private let emojiGrid = SpaceChoiceGridView(columns: 6, rowHeight: 34, spacing: 2, accessibilityLabel: "Icon")
    private let allEmojiButton = NSButton(title: "All Emoji…", target: nil, action: nil)
    private let profilePopUp = NSPopUpButton()
    private let profileNote = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let commitButton = NSButton(title: "", target: nil, action: nil)

    static let profileNoteForNewSpace = "Logins, history and extensions come from the profile."
    static let profileNoteForChange = "This space’s tabs reload with the new profile’s logins and history."

    init(mode: Mode, draft: SpaceDraft, profiles: [ProfileChoice]) {
        self.mode = mode
        self.draft = draft
        self.profiles = profiles
        // Editing keeps the space's emoji unless the user picks another: a
        // rename must not swap it.
        self.emojiPickedByUser = mode != .create
        super.init(frame: .zero)
        build()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Building

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(mode == .create ? "New Space" : "Edit Space")

        let document = FlippedView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        // Header: the emoji tile and the name, where the space header goes.
        tileButton.target = self
        tileButton.action = #selector(showAllEmoji(_:))
        tileButton.setAccessibilityLabel("Choose any emoji")
        tileButton.toolTip = "Choose any emoji"

        nameField.placeholderString = "Name your space"
        nameField.font = .systemFont(ofSize: 15, weight: .semibold)
        nameField.bezelStyle = .roundedBezel
        nameField.isBezeled = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.usesSingleLineMode = true
        nameField.cell?.isScrollable = true
        nameField.delegate = self
        nameField.stringValue = draft.name
        nameField.setAccessibilityLabel("Space name")
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [tileButton, nameField])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        addFullWidth(header, to: stack)

        // Colour.
        colorGrid.onSelect = { [weak self] choice in self?.colorChosen(choice) }
        colorGrid.onHover = { [weak self] choice in
            guard let self else { return }
            if case .color(let hex) = choice?.look {
                self.onHoverColor?(hex)
            } else {
                self.onHoverColor?(nil)
            }
        }
        colorGrid.toolTip = nil
        addSection(title: "Color", accessory: nil, content: colorGrid, to: stack)

        // Emoji.
        allEmojiButton.isBordered = false
        allEmojiButton.font = .systemFont(ofSize: 11)
        allEmojiButton.contentTintColor = .linkColor
        allEmojiButton.target = self
        allEmojiButton.action = #selector(showAllEmoji(_:))
        allEmojiButton.attributedTitle = NSAttributedString(string: "All Emoji…", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.linkColor,
        ])
        emojiGrid.choices = SpaceEmojiPreset.all.map {
            SpaceChoiceGridView.Choice(id: $0.emoji, label: $0.name, look: .emoji($0.emoji))
        }
        emojiGrid.onSelect = { [weak self] choice in self?.emojiChosen(choice.id) }
        addSection(title: "Icon", accessory: allEmojiButton, content: emojiGrid, to: stack)

        // Profile.
        for profile in profiles {
            profilePopUp.addItem(withTitle: profile.name)
            profilePopUp.lastItem?.representedObject = profile.id
        }
        profilePopUp.target = self
        profilePopUp.action = #selector(profileChanged(_:))
        profilePopUp.setAccessibilityLabel("Profile")
        profileNote.font = .systemFont(ofSize: 11)
        profileNote.textColor = .secondaryLabelColor
        profileNote.preferredMaxLayoutWidth = 200
        let profileStack = NSStackView(views: [profilePopUp, profileNote])
        profileStack.orientation = .vertical
        profileStack.alignment = .leading
        profileStack.spacing = 6
        profilePopUp.translatesAutoresizingMaskIntoConstraints = false
        profileNote.translatesAutoresizingMaskIntoConstraints = false
        profileStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            profilePopUp.widthAnchor.constraint(equalTo: profileStack.widthAnchor),
            profileNote.widthAnchor.constraint(equalTo: profileStack.widthAnchor),
        ])
        addSection(title: "Profile", accessory: nil, content: profileStack, to: stack)

        // Buttons.
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        commitButton.bezelStyle = .rounded
        commitButton.title = mode == .create ? "Create Space" : "Done"
        commitButton.target = self
        commitButton.action = #selector(commitClicked(_:))
        let buttons = NSStackView(views: [cancelButton, commitButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8
        addFullWidth(buttons, to: stack)

        // One pass through the editor with Tab, then back to the name.
        nameField.nextKeyView = colorGrid
        colorGrid.nextKeyView = emojiGrid
        emojiGrid.nextKeyView = allEmojiButton
        allEmojiButton.nextKeyView = profilePopUp
        profilePopUp.nextKeyView = cancelButton
        cancelButton.nextKeyView = commitButton
        commitButton.nextKeyView = nameField
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    private func addSection(title: String, accessory: NSView?, content: NSView, to stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityElement(false)
        let titleRow = NSStackView(views: accessory.map { [label, NSView(), $0] } ?? [label])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 4
        let section = NSStackView(views: [titleRow, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        for view in [titleRow, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        addFullWidth(section, to: stack)
    }

    // MARK: - State → views

    private func refresh() {
        tileButton.emoji = draft.emoji
        tileButton.tint = NSColor(hex: draft.colorHex) ?? .controlAccentColor

        let colors = SpaceChoiceGridView.spaceColorChoices(currentHex: draft.colorHex)
        colorGrid.choices = colors.choices
        colorGrid.selectedID = colors.selectedID

        emojiGrid.selectedID = draft.emoji
        emojiGrid.selectionTint = NSColor(hex: draft.colorHex) ?? .controlAccentColor

        if let index = profiles.firstIndex(where: { $0.id == draft.profileID }) {
            profilePopUp.selectItem(at: index)
        }
        switch mode {
        case .create:
            profileNote.stringValue = Self.profileNoteForNewSpace
        case .edit(let original):
            profileNote.stringValue = draft.profileID == original ? Self.profileNoteForNewSpace : Self.profileNoteForChange
        }

        commitButton.isEnabled = draft.canCommit
        let color = NSColor(hex: draft.colorHex) ?? .controlAccentColor
        commitButton.bezelColor = color.blended(withFraction: 0.3, of: .black) ?? color
    }

    private func update(_ change: (inout SpaceDraft) -> Void) {
        let before = draft
        change(&draft)
        guard draft != before else { return }
        if draft.emoji != before.emoji { tileButton.bounce() }
        refresh()
        onChange?(draft)
    }

    // MARK: - Actions

    /// Where the emoji tile is, in window coordinates: the celebration's
    /// emoji takes off from here (TASK-289).
    var emojiTileFrameInWindow: NSRect {
        tileButton.convert(tileButton.bounds, to: nil)
    }

    func focusNameField() {
        window?.makeFirstResponder(nameField)
    }

    func controlTextDidChange(_ notification: Notification) {
        let typed = nameField.stringValue
        let picked = emojiPickedByUser
        update { $0.setName(typed, emojiPickedByUser: picked) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    private func colorChosen(_ choice: SpaceChoiceGridView.Choice) {
        switch choice.look {
        case .color(let hex):
            update { $0.colorHex = hex }
        case .customColor:
            showColorPanel()
        case .emoji:
            break
        }
    }

    private func emojiChosen(_ emoji: String) {
        emojiPickedByUser = true
        update { $0.emoji = emoji }
    }

    @objc private func showAllEmoji(_ sender: NSButton) {
        EmojiPickerViewController.showPicker(relativeTo: sender) { [weak self] emoji in
            self?.emojiChosen(emoji)
        }
    }

    private func showColorPanel() {
        SpaceColorPanel.show(for: self, color: NSColor(hex: draft.colorHex) ?? .controlAccentColor,
                             continuous: true, action: #selector(colorPanelChanged(_:)))
    }

    @objc private func colorPanelChanged(_ panel: NSColorPanel) {
        let hex = panel.color.toHex()
        update { $0.colorHex = hex }
    }

    /// Lets go of the colour panel if this editor still has it.
    func releaseColorPanel() {
        SpaceColorPanel.release(self, close: true)
    }

    /// An editor leaving its window (the window closed with the editor open)
    /// must not stay the colour panel's target.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { releaseColorPanel() }
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? UUID else { return }
        update { $0.profileID = id }
    }

    @objc private func cancelClicked(_ sender: Any?) { cancel() }
    @objc private func commitClicked(_ sender: Any?) { commit() }

    private func commit() {
        guard draft.canCommit else {
            NSSound.beep()
            focusNameField()
            return
        }
        onCommit?(draft)
    }

    private func cancel() {
        onCancel?()
    }

    override func cancelOperation(_ sender: Any?) { cancel() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: commit()   // Return, Enter
        case 53: cancel()       // Escape
        default: super.keyDown(with: event)
        }
    }
}

/// The large emoji in the space's colour at the head of the editor; clicking
/// it opens the full emoji picker.
final class SpaceEmojiTileButton: NSButton {
    var emoji = "" { didSet { needsDisplay = true } }
    var tint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    private static let side: CGFloat = 44

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        title = ""
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.side).isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        tint.withAlphaComponent(dark ? 0.34 : 0.22).setFill()
        path.fill()
        tint.withAlphaComponent(0.4).setStroke()
        path.lineWidth = 1
        path.stroke()
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 26)])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    /// A short spring when the emoji changes; nothing with Reduce Motion.
    func bounce() {
        guard let layer, !MotionPreference.reduceMotion else { return }
        layer.removeAnimation(forKey: "bounce")
        let animation = CAKeyframeAnimation(keyPath: "transform")
        let center = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        func scaled(_ s: CGFloat) -> NSValue {
            NSValue(caTransform3D: CATransform3DTranslate(CATransform3DScale(center, s, s, 1), -bounds.midX, -bounds.midY, 0))
        }
        animation.values = [scaled(0.7), scaled(1.12), scaled(0.97), scaled(1)]
        animation.keyTimes = [0, 0.45, 0.75, 1]
        animation.duration = 0.38
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "bounce")
    }
}

/// A flipped document view, so the editor scrolls from its top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
