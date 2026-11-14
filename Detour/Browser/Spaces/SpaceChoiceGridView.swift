import AppKit

/// A grid of choices with one selected (TASK-289): the curated space colours
/// or the curated space emoji, in the sidebar's space editor and in
/// Settings › Spaces.
///
/// It takes the keyboard as one stop: the arrow keys move the selection
/// (selection follows focus, as in a radio group) and Space activates the
/// focused choice, which for the custom-colour choice opens the colour panel.
/// VoiceOver sees a radio group of named radio buttons. Hovering reports the
/// choice under the pointer so the sidebar can preview a colour before it is
/// picked.
final class SpaceChoiceGridView: NSView {
    struct Choice: Equatable {
        enum Look: Equatable {
            case color(hex: String)
            case emoji(String)
            /// The way to any colour: a colour wheel, with the colour in use
            /// in its middle when that colour is not one of the presets.
            case customColor(currentHex: String?)
        }

        let id: String
        let label: String
        let look: Look
    }

    /// The id of the custom-colour choice in `spaceColorChoices`.
    static let customColorID = "custom"

    /// The curated colours, then the way to any colour, showing `colorHex`
    /// in its middle when that colour is not a preset. The space editor and
    /// Settings › Spaces show the same row.
    static func spaceColorChoices(currentHex colorHex: String) -> (choices: [Choice], selectedID: String) {
        let preset = SpaceColorPreset.matching(hex: colorHex)
        let choices = SpaceColorPreset.all.map {
            Choice(id: $0.hex, label: $0.name, look: .color(hex: $0.hex))
        } + [Choice(id: customColorID, label: "Custom Color…",
                    look: .customColor(currentHex: preset == nil ? colorHex : nil))]
        return (choices, preset?.hex ?? customColorID)
    }

    var choices: [Choice] = [] {
        didSet {
            guard choices != oldValue else { return }
            if choices.count == cells.count {
                // The same grid with a choice's look changed (the custom
                // colour following the colour panel): redraw, don't rebuild.
                for (cell, choice) in zip(cells, choices) { cell.choice = choice }
                updateCells()
            } else {
                rebuildCells()
            }
        }
    }

    var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            updateCells()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// The selection background behind a selected emoji.
    var selectionTint: NSColor = .controlAccentColor {
        didSet { updateCells() }
    }

    /// A choice was picked: clicked, chosen with the arrow keys, pressed by
    /// VoiceOver, or activated with Space.
    var onSelect: ((Choice) -> Void)?
    /// The pointer moved onto a choice, or off the grid (nil).
    var onHover: ((Choice?) -> Void)?

    private let columns: Int
    private let rowHeight: CGFloat
    private let spacing: CGFloat
    private var cells: [SpaceChoiceCell] = []
    private var focusIndex: Int?
    private var hoverIndex: Int?
    private var trackingArea: NSTrackingArea?

    init(columns: Int, rowHeight: CGFloat, spacing: CGFloat, accessibilityLabel: String) {
        self.columns = columns
        self.rowHeight = rowHeight
        self.spacing = spacing
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private var rowCount: Int { max(1, (choices.count + columns - 1) / columns) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * spacing)
    }

    // MARK: - Cells

    private func rebuildCells() {
        for cell in cells { cell.removeFromSuperview() }
        cells = choices.enumerated().map { index, choice in
            let cell = SpaceChoiceCell(choice: choice)
            cell.onPress = { [weak self] in self?.activate(index: index) }
            addSubview(cell)
            return cell
        }
        if let focus = focusIndex, focus >= cells.count { focusIndex = cells.isEmpty ? nil : cells.count - 1 }
        hoverIndex = nil
        invalidateIntrinsicContentSize()
        needsLayout = true
        updateCells()
    }

    private func updateCells() {
        let showsFocus = window?.firstResponder === self
        for (index, cell) in cells.enumerated() {
            cell.isSelected = cell.choice.id == selectedID
            cell.isFocused = showsFocus && index == focusIndex
            cell.isHovered = index == hoverIndex
            cell.selectionTint = selectionTint
        }
    }

    override func layout() {
        super.layout()
        guard !cells.isEmpty else { return }
        let cellWidth = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        for (index, cell) in cells.enumerated() {
            let row = index / columns
            let column = index % columns
            cell.frame = NSRect(x: CGFloat(column) * (cellWidth + spacing),
                                y: CGFloat(row) * (rowHeight + spacing),
                                width: cellWidth, height: rowHeight)
        }
    }

    private func index(at point: NSPoint) -> Int? {
        cells.firstIndex { $0.frame.contains(point) }
    }

    private func activate(index: Int) {
        guard index >= 0, index < choices.count else { return }
        focusIndex = index
        let choice = choices[index]
        if case .customColor = choice.look {
            // The panel decides the colour; the selection follows it.
        } else {
            selectedID = choice.id
        }
        updateCells()
        onSelect?(choice)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHover(index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
    }

    private func setHover(_ index: Int?) {
        guard index != hoverIndex else { return }
        hoverIndex = index
        updateCells()
        onHover?(index.map { choices[$0] })
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { !choices.isEmpty }
    override var canBecomeKeyView: Bool { !choices.isEmpty }

    override func becomeFirstResponder() -> Bool {
        if focusIndex == nil {
            focusIndex = choices.firstIndex { $0.id == selectedID } ?? 0
        }
        defer { updateCells() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.updateCells() } }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let count = choices.count
        guard count > 0 else { return super.keyDown(with: event) }
        let current = focusIndex ?? choices.firstIndex { $0.id == selectedID } ?? 0
        var target: Int?
        switch event.keyCode {
        case 123: target = max(0, current - 1)                                  // ←
        case 124: target = min(count - 1, current + 1)                          // →
        case 126: target = current - columns >= 0 ? current - columns : nil     // ↑
        case 125: target = current + columns < count ? current + columns : nil  // ↓
        case 49:                                                                // Space
            activate(index: current)
            return
        default:
            super.keyDown(with: event)
            return
        }
        guard let target, target != current else { return }
        focusIndex = target
        // Selection follows focus, except onto the way to a custom colour:
        // arriving there must not open a panel.
        if case .customColor = choices[target].look {
            updateCells()
        } else {
            activate(index: target)
        }
    }

    // MARK: - Accessibility

    override func accessibilityValue() -> Any? {
        choices.first { $0.id == selectedID }?.label
    }

    override func accessibilityChildren() -> [Any]? { cells }
}

/// The shared colour panel, lent to one space colour picker at a time (the
/// sidebar's space editor or Settings › Spaces): whoever opened it last gets
/// its changes, and a picker letting go only lets go of a panel it still has.
enum SpaceColorPanel {
    private static weak var owner: AnyObject?

    static func show(for owner: AnyObject, color: NSColor, continuous: Bool, action: Selector) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = continuous
        panel.color = color
        panel.setTarget(owner)
        panel.setAction(action)
        self.owner = owner
        panel.orderFront(nil)
    }

    /// Stops sending the panel's changes to `owner`, if it still has the
    /// panel; `close` also puts the panel away.
    static func release(_ owner: AnyObject, close: Bool) {
        guard self.owner === owner else { return }
        self.owner = nil
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        if close { panel.orderOut(nil) }
    }
}

/// One choice of a `SpaceChoiceGridView`.
private final class SpaceChoiceCell: NSView {
    var choice: SpaceChoiceGridView.Choice {
        didSet {
            guard choice != oldValue else { return }
            toolTip = choice.label
            setAccessibilityLabel(choice.label)
            needsDisplay = true
        }
    }
    var onPress: (() -> Void)?

    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            updateHoverScale()
        }
    }
    var selectionTint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    init(choice: SpaceChoiceGridView.Choice) {
        self.choice = choice
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = choice.label
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(choice.label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func accessibilityValue() -> Any? { NSNumber(value: isSelected) }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    /// A colour swatch grows a little under the pointer; not with Reduce Motion.
    private func updateHoverScale() {
        guard case .color = choice.look, let layer else { return }
        let grow = isHovered && !isSelected && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale: CGFloat = grow ? 1.12 : 1
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, bounds.midX, bounds.midY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            layer.transform = transform
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch choice.look {
        case .color(let hex):
            drawSwatch(fill: NSColor(hex: hex) ?? .gray, ringColor: NSColor(hex: hex) ?? .gray)
        case .customColor(let currentHex):
            drawCustomSwatch(currentHex: currentHex)
        case .emoji(let emoji):
            drawEmoji(emoji)
        }
        if isFocused { drawFocusRing() }
    }

    private var swatchRect: NSRect {
        let diameter = max(10, min(bounds.width, bounds.height) - 8)
        return NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                      width: diameter, height: diameter)
    }

    private func drawSwatch(fill: NSColor, ringColor: NSColor) {
        let rect = swatchRect
        if isSelected {
            // The ring sits outside the fill with a gap, so the swatch's own
            // colour stays readable.
            ringColor.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3))
            ring.lineWidth = 2
            ring.stroke()
        }
        fill.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        edge.stroke()
    }

    private func drawCustomSwatch(currentHex: String?) {
        let rect = swatchRect
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let segments = 48
        for index in 0..<segments {
            let start = CGFloat(index) / CGFloat(segments) * 360
            let end = CGFloat(index + 1) / CGFloat(segments) * 360 + 0.5
            NSColor(calibratedHue: CGFloat(index) / CGFloat(segments), saturation: 0.62, brightness: 0.92, alpha: 1).setFill()
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
            wedge.close()
            wedge.fill()
        }
        if let currentHex, let color = NSColor(hex: currentHex) {
            if isSelected {
                color.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 2
                ring.stroke()
            }
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: radius * 0.38, dy: radius * 0.38)).fill()
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: radius * 0.46, dy: radius * 0.46)).fill()
        }
    }

    private func drawEmoji(_ emoji: String) {
        let background = bounds.insetBy(dx: 1, dy: 1)
        if isSelected {
            let dark = effectiveAppearance.isDark
            selectionTint.withAlphaComponent(dark ? 0.38 : 0.26).setFill()
            NSBezierPath(roundedRect: background, xRadius: 7, yRadius: 7).fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: background, xRadius: 7, yRadius: 7).fill()
        }
        let fontSize = min(19, bounds.height * 0.56)
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    private func drawFocusRing() {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let path: NSBezierPath
        switch choice.look {
        case .color, .customColor:
            path = NSBezierPath(ovalIn: swatchRect.insetBy(dx: -3.5, dy: -3.5))
        case .emoji:
            path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
        }
        path.lineWidth = 2.5
        path.stroke()
    }
}
