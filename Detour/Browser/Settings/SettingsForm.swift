import AppKit

/// A System Settings–style grouped form (TASK-338): sections one under the
/// other, each a header, an inset rounded group of rows (the setting's name
/// on the left, its control on the right, every control on one right edge)
/// and, optionally, buttons under the group on the right.
///
/// The metrics (`SettingsMetrics.form…`) were measured on macOS 26 from a
/// SwiftUI `Form` with `.formStyle(.grouped)`, which is what System Settings
/// is built with, and from a System Settings screenshot. A pane puts a form in
/// its body with `SettingsPaneViewController.formBody(_:)`.
final class SettingsForm: NSView {
    private let stack = NSStackView()
    private(set) var sections: [SettingsFormSection] = []

    /// - Parameter estimatedWidth: the form's width before its first layout
    ///   (the pane's body by default); its rows wrap their text at it, so
    ///   the pane's first natural-height measurement is already right.
    init(sections: [SettingsFormSection], estimatedWidth: CGFloat = SettingsMetrics.formWidth) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = SettingsMetrics.formSectionGap
        // A hidden section leaves no gap.
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .vertical)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for section in sections {
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            section.estimateWidth(estimatedWidth)
        }
        self.sections = sections
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One section of a `SettingsForm`: an optional header (13 pt semibold, on
/// the rows' text edge) with an optional accessory after it (a "Learn more"
/// link), the group of rows with an optional footnote row at its end, and
/// optional buttons under the group, on its right edge, that act on the
/// whole group.
final class SettingsFormSection: NSView {
    let titleLabel: NSTextField?
    /// What follows the header on its baseline, nil for none.
    let headerAccessory: NSView?
    let group: SettingsFormGroupView
    /// The buttons under the group, nil for none.
    let buttonRow: NSStackView?

    init(title: String? = nil, headerAccessory: NSView? = nil, rows: [SettingsFormRow],
         footnote: SettingsFormRow? = nil, buttons: [NSButton] = []) {
        self.headerAccessory = title == nil ? nil : headerAccessory
        group = SettingsFormGroupView(rows: rows + (footnote.map { [$0] } ?? []))
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: SettingsMetrics.formTitleFontSize, weight: .semibold)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            titleLabel = label
        } else {
            titleLabel = nil
        }
        if buttons.isEmpty {
            buttonRow = nil
        } else {
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = SettingsMetrics.formButtonGap
            row.translatesAutoresizingMaskIntoConstraints = false
            buttonRow = row
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let insetX = SettingsMetrics.formRowInsetX
        var constraints: [NSLayoutConstraint] = []
        var above = topAnchor
        var gap: CGFloat = 0
        if let titleLabel {
            addSubview(titleLabel)
            constraints += [
                titleLabel.topAnchor.constraint(equalTo: topAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -insetX),
            ]
            above = titleLabel.bottomAnchor
            gap = SettingsMetrics.formHeaderToGroup
            if let headerAccessory {
                headerAccessory.translatesAutoresizingMaskIntoConstraints = false
                addSubview(headerAccessory)
                constraints += [
                    headerAccessory.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor,
                                                             constant: SettingsMetrics.labelToControl),
                    headerAccessory.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
                    headerAccessory.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -insetX),
                ]
            }
        }
        addSubview(group)
        constraints += [
            group.topAnchor.constraint(equalTo: above, constant: gap),
            group.leadingAnchor.constraint(equalTo: leadingAnchor),
            group.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        endsAtGroup = bottomAnchor.constraint(equalTo: group.bottomAnchor)
        if let buttonRow {
            addSubview(buttonRow)
            constraints += [
                buttonRow.topAnchor.constraint(equalTo: group.bottomAnchor, constant: SettingsMetrics.formGroupToButtons),
                // On the group's edge, as System Settings puts them.
                buttonRow.trailingAnchor.constraint(equalTo: trailingAnchor),
                buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            ]
            endsAtButtons = bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor)
        }
        constraints.append(endsAtButtons ?? endsAtGroup)
        NSLayoutConstraint.activate(constraints)
    }

    private var endsAtGroup: NSLayoutConstraint!
    private var endsAtButtons: NSLayoutConstraint?

    /// Hides the buttons under the group and the room they take (General's
    /// copy buttons while automation is off). Hiding a button alone keeps
    /// the row; hide the row when none is left.
    var isButtonRowHidden: Bool {
        get { buttonRow?.isHidden ?? true }
        set {
            guard let buttonRow, let endsAtButtons, newValue != buttonRow.isHidden else { return }
            buttonRow.isHidden = newValue
            // Off first, so the two are never on together.
            if newValue {
                endsAtButtons.isActive = false
                endsAtGroup.isActive = true
            } else {
                endsAtGroup.isActive = false
                endsAtButtons.isActive = true
            }
            enclosingSettingsPane?.contentHeightDidChange()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The rows, the footnote included.
    var rows: [SettingsFormRow] { group.rows }

    /// The width the rows wrap at until the group is laid out.
    private var estimatedWidth = SettingsMetrics.formWidth

    /// The section's width before its first layout.
    func estimateWidth(_ width: CGFloat) {
        estimatedWidth = width
        for row in rows { row.estimateWidth(groupWidth: width) }
    }

    /// Replaces the rows, a footnote included (Profiles' per-extension
    /// switches, which come and go with the installed extensions). The new
    /// rows wrap at the group's width, or the estimate before its first
    /// layout, so the pane's next measurement is already right.
    func setRows(_ rows: [SettingsFormRow]) {
        let width = group.bounds.width > 0 ? group.bounds.width : estimatedWidth
        for row in rows { row.estimateWidth(groupWidth: width) }
        group.setRows(rows)
        // Rows came, went or changed: the pane refits, as a row's own help
        // or warning change does.
        enclosingSettingsPane?.contentHeightDidChange()
    }
}

/// The inset group of a form section: a rounded fill of about 3% of the
/// label colour (247 on white, 37 on the dark window's 30), hairline
/// separators between its visible rows inset to the rows' text, and under
/// Increase Contrast a separator-coloured border. Drawn in `draw(_:)`, so
/// the colours follow the appearance. Rows carry their own insets; a hidden
/// row leaves no gap and no separator.
final class SettingsFormGroupView: NSView {
    private let stack = NSStackView()

    init(rows: [SettingsFormRow]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Rows are clipped to the rounded shape (a highlighted first or last row).
        wantsLayer = true
        layer?.cornerRadius = SettingsMetrics.formGroupCornerRadius
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .vertical)
        addSubview(stack)
        // Required: a stack's own edge insets are soft on the cross axis.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setRows(rows)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var rows: [SettingsFormRow] { stack.arrangedSubviews.compactMap { $0 as? SettingsFormRow } }

    /// Replaces the rows; the separators follow (Profiles' extension
    /// switches, General's allowed clients). A section's `setRows` also wraps
    /// the new rows at the group's width.
    func setRows(_ rows: [SettingsFormRow]) {
        for row in stack.arrangedSubviews { row.removeFromSuperview() }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // Rows came, went or changed height: the separators move.
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = SettingsMetrics.formGroupCornerRadius
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        SettingsGroupStyle.fillColor.setFill()
        shape.fill()
        if SettingsGroupStyle.increasesContrast(effectiveAppearance) {
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5,
                                      yRadius: radius - 0.5)
            border.lineWidth = 1
            NSColor.separatorColor.setStroke()
            border.stroke()
        }
        // A hairline: one device pixel, as dark as half a point of the
        // separator colour (System Settings draws half a point, so on a 1x
        // screen its line is a pixel at half strength).
        let scale = window?.backingScaleFactor ?? 2
        let hairline = 1 / scale
        let separator = NSColor.separatorColor.usingColorSpace(.sRGB) ?? .separatorColor
        separator.withAlphaComponent(separator.alphaComponent * min(1, scale / 2)).setFill()
        let insetX = SettingsMetrics.formRowInsetX
        let visible = stack.arrangedSubviews.filter { !$0.isHidden }
        for row in visible.dropFirst() {
            let top = convert(row.bounds, from: row).minY
            let line = backingAlignedRect(NSRect(x: insetX, y: top, width: bounds.width - 2 * insetX, height: hairline),
                                          options: .alignAllEdgesNearest)
            NSBezierPath(rect: line).fill()
        }
    }
}

/// The look every group shares: a form's groups and the lists drawn as
/// groups (`SettingsListContainerView`).
enum SettingsGroupStyle {
    /// Black on light, white on dark, at about 3%, as System Settings' groups
    /// measure (`quaternarySystemFill`, 2.7%, came out a level lighter).
    static let fillColor = NSColor(name: "SettingsFormGroupFill") { appearance in
        NSColor(white: appearance.isDark ? 1 : 0, alpha: 0.031)
    }

    /// Replaces the system's Increase Contrast for a test or a capture
    /// harness: a process cannot turn it on for itself (an
    /// `accessibilityHighContrast…` appearance resolves to the plain one
    /// while the setting is off). Nil follows the system.
    static var increaseContrastOverride: Bool?

    /// Increase Contrast: the high-contrast appearance AppKit swaps in when
    /// it is on (and redraws), or the workspace's flag.
    static func increasesContrast(_ appearance: NSAppearance) -> Bool {
        if let increaseContrastOverride { return increaseContrastOverride }
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        return match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

/// One row of a form group: the setting's name (13 pt) on the left, with its
/// help text (11 pt, secondary), status lines, a warning and Learn more links
/// under it, all wrapping in a column that ends before the control; the
/// control on the right, on the row's right edge, level with the name's first
/// line. Text sits 10 pt from the row's top and bottom and a control at least
/// 7 pt, so a one-line switch row is 36 pt and a pop-up row 38, as in System
/// Settings.
///
/// The control is named by the row (TASK-336, built in): a switch, pop-up,
/// shortcut recorder or custom control takes the title (or
/// `accessibilityName`) as its accessible name and the title leaves the
/// Accessibility tree, so VoiceOver reads the setting once. A button keeps
/// its own title, a value is text of its own and a custom container is not
/// an element, so with those the title stays.
final class SettingsFormRow: NSView {
    enum Accessory {
        case none
        /// A switch, made mini as System Settings' are, centred on the name's first line.
        case toggle(NSSwitch)
        /// On the name's baseline, as are the button, value and recorder.
        case popUp(NSPopUpButton)
        /// An action on the setting ("Clear…"); it keeps its own title.
        case button(NSButton)
        /// A value in secondary text, with an optional button after it.
        case value(NSTextField, button: NSButton?)
        case shortcut(ShortcutRecorderView)
        /// Any other view, centred on the name's first line; named by the
        /// row when it is a control.
        case custom(NSView)
    }

    /// The setting's name; nil in a footnote row.
    let titleLabel: SettingsWrappingLabel?
    /// The help text under the name (the text of a footnote row), hidden while empty.
    let helpLabel: SettingsWrappingLabel
    /// What sits on the right, nil for none.
    let accessoryView: NSView?

    /// Title, help, details, warning and links, top to bottom.
    private let column = NSStackView()
    private var details: [NSView] = []
    private var warningLine: NSView?
    private var warningLabel: SettingsWrappingLabel?
    /// The accessory's width and height as laid out (a mini switch's real
    /// size, which NSSwitch only reports inside a window).
    private let accessorySize: NSSize

    /// A setting: its name, help text and control.
    convenience init(title: String, help: String? = nil, accessory: Accessory = .none,
                     accessibilityName: String? = nil) {
        self.init(title: title, footnote: nil, help: help, accessory: accessory, accessibilityName: accessibilityName)
    }

    /// A footnote row: secondary text across the group, at its end.
    convenience init(footnote: String) {
        self.init(title: nil, footnote: footnote, help: nil, accessory: .none, accessibilityName: nil)
    }

    /// A row that is one view of its own across the row, inside the row's
    /// insets, as tall as its constraints make it (the Extensions pane's
    /// header: icon, name, version, description and Settings…, the top row
    /// of System Settings' Wi-Fi or Bluetooth pane). The view wraps its own
    /// text: the row's width estimate does not reach into it.
    convenience init(content: NSView) {
        self.init(title: nil, footnote: nil, help: nil, accessory: .none, accessibilityName: nil)
        content.translatesAutoresizingMaskIntoConstraints = false
        column.insertArrangedSubview(content, at: 0)
        content.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private init(title: String?, footnote: String?, help: String?, accessory: Accessory, accessibilityName: String?) {
        let width = SettingsMetrics.formWidth
        if let title {
            let label = SettingsWrappingLabel(wrapping: title, estimatedWidth: width,
                                              fontSize: SettingsMetrics.formTitleFontSize, color: .labelColor)
            label.isSelectable = false
            titleLabel = label
        } else {
            titleLabel = nil
        }
        helpLabel = SettingsWrappingLabel(wrapping: footnote ?? help ?? "", estimatedWidth: width,
                                          fontSize: SettingsMetrics.formHelpFontSize)
        helpLabel.isSelectable = false

        // The accessory, and how it lines up with the name.
        var control: NSView?
        var baselineAligned = false
        var nameControl = false
        // A push button keeps 10 pt above and below it, as in System
        // Settings (a 44 pt row); other controls 7.
        var controlInsetY = SettingsMetrics.formControlInsetY
        var size = NSSize.zero
        switch accessory {
        case .none:
            break
        case .toggle(let toggle):
            toggle.controlSize = .mini
            control = toggle
            nameControl = true
            size = Self.switchSize(.mini)
        case .popUp(let popUp):
            control = popUp
            baselineAligned = true
            nameControl = true
        case .button(let button):
            control = button
            baselineAligned = true
            controlInsetY = SettingsMetrics.formButtonInsetY
        case .value(let value, let button):
            value.translatesAutoresizingMaskIntoConstraints = false
            let views: [NSView] = [value] + (button.map { [$0] } ?? [])
            // Their own width: the text column takes the rest of the row.
            for view in views { view.setContentHuggingPriority(.required, for: .horizontal) }
            button?.setContentCompressionResistancePriority(.required, for: .horizontal)
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .firstBaseline
            stack.spacing = SettingsMetrics.labelToControl
            stack.setHuggingPriority(.required, for: .horizontal)
            control = stack
            baselineAligned = true
            if button != nil { controlInsetY = SettingsMetrics.formButtonInsetY }
        case .shortcut(let recorder):
            control = recorder
            baselineAligned = true
            nameControl = true
        case .custom(let view):
            control = view
            // Only a control can carry the name: a container of controls
            // keeps the title as text, or VoiceOver would read neither.
            nameControl = view is NSControl || view.isAccessibilityElement()
        }
        if let control, size == .zero { size = control.fittingSize }
        accessoryView = control
        accessorySize = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = SettingsMetrics.formTitleToHelp
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setHuggingPriority(.required, for: .vertical)
        // The text column takes the width the control leaves.
        column.setHuggingPriority(.init(1), for: .horizontal)
        addSubview(column)
        if let titleLabel { addFullWidth(titleLabel) }
        addFullWidth(helpLabel)
        helpLabel.isHidden = helpLabel.stringValue.isEmpty

        let insetX = SettingsMetrics.formRowInsetX
        let insetY = SettingsMetrics.formRowInsetY
        var constraints: [NSLayoutConstraint] = [
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: insetY),
            bottomAnchor.constraint(greaterThanOrEqualTo: column.bottomAnchor, constant: insetY),
        ]
        // As short as its content allows: above the stretch of a pane's body
        // (`bottomHug`, 250) and of a stack, below every required inset.
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .init(740)
        constraints.append(hug)

        if let control, let titleLabel {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.required, for: .horizontal)
            // Its own compression resistance (750 for a control) beats the
            // text column's (250), and a pop-up capped in width can still
            // truncate its title (Spaces' Profile).
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
                column.trailingAnchor.constraint(equalTo: control.leadingAnchor,
                                                 constant: -SettingsMetrics.formLabelToControl),
                control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: controlInsetY),
                bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor, constant: controlInsetY),
            ]
            if case .toggle = accessory {
                constraints += [
                    control.widthAnchor.constraint(equalToConstant: size.width),
                    control.heightAnchor.constraint(equalToConstant: size.height),
                ]
            }
            let below: CGFloat
            if baselineAligned {
                // On the name's first baseline: the value's text, or the control.
                var aligned = [control]
                if case .value(let value, let button) = accessory { aligned = [value] + (button.map { [$0] } ?? []) }
                constraints.append(aligned[0].firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor))
                // How far the control reaches below the name's first line.
                let descent = aligned.map { $0.fittingSize.height - $0.firstBaselineOffsetFromTop }.max() ?? 0
                below = descent - (Self.titleLineHeight - Self.titleBaselineOffset)
            } else {
                constraints.append(control.centerYAnchor.constraint(
                    equalTo: titleLabel.topAnchor, constant: Self.titleLineHeight / 2))
                below = (size.height - Self.titleLineHeight) / 2
            }
            // Help text starts below a control taller than the name's line
            // (a pop-up), as System Settings' does.
            column.setCustomSpacing(SettingsMetrics.formTitleToHelp + max(0, ceil(below)), after: titleLabel)
            if nameControl {
                SettingsSwitchRow.name(control, by: titleLabel, as: accessibilityName)
            }
        } else {
            constraints.append(column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX))
        }
        NSLayoutConstraint.activate(constraints)
        estimateWidth(groupWidth: SettingsMetrics.formWidth)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Accessibility

    /// The control is read right after the name that names it: first when
    /// the name is hidden (it is the control's name), after the name when
    /// the name is read (a value, a button), and before the help text in
    /// both cases. AppKit lists children in subview order, which put the
    /// whole text column, help included, before the control.
    override func accessibilityChildren() -> [Any]? {
        guard let children = super.accessibilityChildren(), let accessoryView else {
            return super.accessibilityChildren()
        }
        func view(of element: Any) -> NSView? { (element as? NSView) ?? (element as? NSCell)?.controlView }
        let isAccessory = { (element: Any) in view(of: element)?.isDescendant(of: accessoryView) == true }
        let accessory = children.filter(isAccessory)
        let text = children.filter { !isAccessory($0) }
        let afterName = text.firstIndex { view(of: $0) === titleLabel }.map { $0 + 1 } ?? 0
        return Array(text[..<afterName]) + accessory + Array(text[afterName...])
    }

    // MARK: - Highlight

    /// Tints the row with the accent colour: the row a pane points the user
    /// to (Links' Default, from the blocked space deletion).
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        bounds.fill(using: .sourceOver)
    }

    // MARK: - Enabled

    /// Off, the control is disabled and the name dimmed (a filter list while
    /// blocking is off, an extension turned off everywhere). The help stays
    /// as it is: it says why.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            titleLabel?.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
            // Turning the row on again re-enables only what turning it off
            // disabled: a control the pane disabled itself (a Clear with
            // nothing to clear) stays off.
            guard !isEnabled else {
                for control in rowDisabledControls { control.isEnabled = true }
                for recorder in rowDisabledRecorders { recorder.isEnabled = true }
                rowDisabledControls = []
                rowDisabledRecorders = []
                return
            }
            func disable(_ view: NSView) {
                if let control = view as? NSControl, control.isEnabled {
                    control.isEnabled = false
                    rowDisabledControls.append(control)
                }
                if let recorder = view as? ShortcutRecorderView, recorder.isEnabled {
                    recorder.isEnabled = false
                    rowDisabledRecorders.append(recorder)
                }
                view.subviews.forEach(disable)
            }
            if let accessoryView { disable(accessoryView) }
        }
    }

    /// What `isEnabled = false` turned off, for turning it back on.
    private var rowDisabledControls: [NSControl] = []
    private var rowDisabledRecorders: [ShortcutRecorderView] = []

    // MARK: - Content under the name

    /// Sets the help text; nil or empty hides it. A change tells the pane,
    /// since the row's height may change with it.
    func setHelp(_ text: String?) {
        let text = text ?? ""
        guard text != helpLabel.stringValue || helpLabel.isHidden != text.isEmpty else { return }
        helpLabel.stringValue = text
        helpLabel.isHidden = text.isEmpty
        enclosingSettingsPane?.contentHeightDidChange()
    }

    /// Adds a line under the help text (a status line). A text field fills
    /// the column's width, so a long one wraps or truncates instead of
    /// widening the row. Hide it to take it out.
    func addDetail(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        let index = column.arrangedSubviews.firstIndex { $0 === warningLine } ?? column.arrangedSubviews.count
        column.insertArrangedSubview(view, at: min(index, firstLinkIndex))
        if view is NSTextField {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        } else {
            view.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
        }
        details.append(view)
    }

    /// Adds a Learn more link at the end of the row.
    func addLink(_ link: SettingsGuideLink) {
        column.addArrangedSubview(link)
    }

    /// Shows a warning line (an orange triangle and the text) under the help
    /// and details, or hides it for nil. A change tells the pane.
    func setWarning(_ message: String?) {
        guard message != warning else { return }
        if message != nil, warningLine == nil { makeWarningLine() }
        warningLabel?.stringValue = message ?? ""
        warningLine?.isHidden = message == nil
        enclosingSettingsPane?.contentHeightDidChange()
    }

    /// The warning's text while one shows.
    var warning: String? {
        guard let warningLine, !warningLine.isHidden else { return nil }
        return warningLabel?.stringValue
    }

    private var firstLinkIndex: Int {
        column.arrangedSubviews.firstIndex { $0 is SettingsGuideLink } ?? column.arrangedSubviews.count
    }

    private func addFullWidth(_ label: NSTextField) {
        column.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func makeWarningLine() {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = LinkRouteCellView.warningImage()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let iconWidth = LinkRouteCellView.warningIconWidth
        let label = SettingsWrappingLabel(wrapping: "", estimatedWidth: columnWidth - iconWidth - Self.warningIconGap,
                                          fontSize: SettingsMetrics.formHelpFontSize)
        label.isSelectable = false
        line.addSubview(icon)
        line.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconWidth),
            icon.centerYAnchor.constraint(equalTo: label.topAnchor, constant: Self.helpLineHeight / 2),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.warningIconGap),
            label.trailingAnchor.constraint(equalTo: line.trailingAnchor),
            label.topAnchor.constraint(equalTo: line.topAnchor),
            label.bottomAnchor.constraint(equalTo: line.bottomAnchor),
        ])
        column.insertArrangedSubview(line, at: firstLinkIndex)
        line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        warningLine = line
        warningLabel = label
    }

    // MARK: - Widths

    /// The text column's width in a group `groupWidth` wide, before layout.
    private var columnWidth: CGFloat = 0

    /// Wraps the row's text at its width in a group `groupWidth` wide,
    /// until the row is laid out (the labels then take their own width).
    func estimateWidth(groupWidth: CGFloat) {
        var width = groupWidth - 2 * SettingsMetrics.formRowInsetX
        if accessoryView != nil, titleLabel != nil {
            width -= accessorySize.width + SettingsMetrics.formLabelToControl
        }
        columnWidth = max(width, 1)
        for label in [titleLabel, helpLabel].compactMap({ $0 }) + details.compactMap({ $0 as? SettingsWrappingLabel }) {
            label.preferredMaxLayoutWidth = columnWidth
            label.invalidateIntrinsicContentSize()
        }
        if let warningLabel {
            warningLabel.preferredMaxLayoutWidth = columnWidth - LinkRouteCellView.warningIconWidth - Self.warningIconGap
            warningLabel.invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Metrics

    private static var warningIconGap: CGFloat { LinkRouteCellView.warningIconGap }

    /// The height of one line of a title, and its baseline from the top.
    static let titleLineHeight: CGFloat = lineMetrics(SettingsMetrics.formTitleFontSize).height
    static let titleBaselineOffset: CGFloat = lineMetrics(SettingsMetrics.formTitleFontSize).baseline
    private static let helpLineHeight: CGFloat = lineMetrics(SettingsMetrics.formHelpFontSize).height

    private static func lineMetrics(_ size: CGFloat) -> (height: CGFloat, baseline: CGFloat) {
        let label = NSTextField(labelWithString: "X")
        label.font = .systemFont(ofSize: size)
        return (label.intrinsicContentSize.height, label.firstBaselineOffsetFromTop)
    }

    /// The size a switch of `controlSize` lays out at. On macOS 26 NSSwitch
    /// reports its regular size (54 × 24) for every control size until it
    /// is in a window, and keeps the first size it reported; a pane is
    /// built and measured before it is in one. So the size is read once from
    /// a switch in a window that is never shown.
    static func switchSize(_ controlSize: NSControl.ControlSize) -> NSSize {
        if let size = switchSizes[controlSize] { return size }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let probe = NSSwitch()
        probe.controlSize = controlSize
        window.contentView?.addSubview(probe)
        let size = probe.intrinsicContentSize
        switchSizes[controlSize] = size
        return size
    }

    private static var switchSizes: [NSControl.ControlSize: NSSize] = [:]
}

extension SettingsPaneViewController {
    /// A body holding a grouped form (TASK-338): the form at the body's top
    /// and full width, its bottom `<=` the body's with a weak equality, so it
    /// never caps the window's height. Under the pane's description or
    /// Learn more link the form starts `formBelowPaneHeader` lower, so the
    /// link does not read as the first section's.
    func formBody(_ form: SettingsForm) -> NSView {
        let body = NSView()
        body.addSubview(form)
        let top = paneDescription != nil || guidePage != nil ? SettingsMetrics.formBelowPaneHeader : 0
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: body.topAnchor, constant: top),
            form.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            form.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),
            bottomHug(form.bottomAnchor, body.bottomAnchor),
        ])
        return body
    }
}
