import AppKit

/// Dev mode's in-page toolbar (TASK-186.2): a bar across the top of a dev-mode
/// tab's web content, in the "under construction" motif of the sidebar's
/// hazard border (Arc: faint diagonal stripes on a light bar). Left: the site
/// settings button, then the page's URL, which opens the command palette to
/// navigate the tab. Right: the copy-link button, and room for more groups
/// (`addTrailingGroup`: the capture buttons of TASK-186.3, the inspector
/// buttons of TASK-186.4).
///
/// It lives inside the tab's `WebViewContainerView`, which frames it (see
/// `DevToolbarLayout`); only its own subviews use Auto Layout.
final class DevToolbarView: NSView {
    var url: URL? {
        didSet {
            let text = url?.absoluteString ?? ""
            urlButton.title = text
            urlButton.toolTip = text.isEmpty ? nil : text
            urlButton.setAccessibilityLabel(text.isEmpty ? "Address" : "Address, \(text)")
        }
    }

    /// The control's own view comes with each callback, to anchor a popover
    /// or the palette.
    var onInfoClick: ((NSView) -> Void)?
    var onURLClick: ((NSView) -> Void)?
    var onCopyClick: (() -> Void)?

    let infoButton = HoverButton()
    let urlButton = NSButton(title: "", target: nil, action: nil)
    let copyButton = HoverButton()
    /// The right-hand controls, in groups separated by a hairline.
    let trailingStack = NSStackView()
    /// The capture buttons, once installed (TASK-186.3).
    var captureGroup: DevToolbarCaptureGroup?
    /// The Web Inspector buttons, once installed (TASK-186.4).
    var inspectorGroup: DevToolbarInspectorGroup?

    private static let buttonSize: CGFloat = 22
    static let backgroundColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.975, alpha: 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Dev Mode Toolbar")

        configure(infoButton, symbol: "info.circle", label: "Site Settings", action: #selector(infoClicked))
        configure(copyButton, symbol: "link", label: "Copy URL", action: #selector(copyClicked))

        urlButton.isBordered = false
        urlButton.bezelStyle = .inline
        urlButton.alignment = .left
        urlButton.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlButton.contentTintColor = .labelColor
        urlButton.lineBreakMode = .byTruncatingMiddle
        urlButton.cell?.lineBreakMode = .byTruncatingMiddle
        urlButton.target = self
        urlButton.action = #selector(urlClicked)
        urlButton.setAccessibilityLabel("Address")
        urlButton.setAccessibilityHelp("Opens the command palette to navigate this tab")
        urlButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        urlButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlButton.translatesAutoresizingMaskIntoConstraints = false

        trailingStack.orientation = .horizontal
        trailingStack.spacing = 4
        trailingStack.alignment = .centerY
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingStack.addArrangedSubview(copyButton)

        for view in [infoButton, urlButton, trailingStack] as [NSView] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            infoButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            infoButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            urlButton.leadingAnchor.constraint(equalTo: infoButton.trailingAnchor, constant: 6),
            urlButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            urlButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -12),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func configure(_ button: HoverButton, symbol: String, label: String, action: Selector) {
        Self.styleIconButton(button, symbol: symbol, label: label)
        button.target = self
        button.action = action
    }

    /// A toolbar icon button: borderless, a 12 pt SF Symbol, 22 pt square,
    /// labelled for accessibility and with a tooltip. For the groups other
    /// files add (`addTrailingGroup`).
    static func makeIconButton(symbol: String, label: String) -> HoverButton {
        let button = HoverButton()
        styleIconButton(button, symbol: symbol, label: label)
        return button
    }

    private static func styleIconButton(_ button: HoverButton, symbol: String, label: String) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.fixedHoverSize = buttonSize
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: buttonSize),
            button.heightAnchor.constraint(equalToConstant: buttonSize),
        ])
    }

    /// Where a trailing group sits: groups are kept in ascending order after
    /// the copy button, whichever is added first (Arc: link | capture |
    /// inspector).
    enum TrailingGroupOrder: Int, Comparable {
        case capture = 100
        case inspector = 200
        case last = 1000

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct TrailingGroup {
        let order: TrailingGroupOrder
        let separator: NSView
        let buttons: [NSButton]
    }

    private var trailingGroups: [TrailingGroup] = []

    /// Adds a group of buttons at the right end, after a hairline separator,
    /// in `order` among the groups already added (equal orders keep the order
    /// they were added in). Each button should carry its own accessibility
    /// label.
    func addTrailingGroup(_ buttons: [NSButton], order: TrailingGroupOrder = .last) {
        guard !buttons.isEmpty else { return }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        // Both dimensions fixed: a separator box has no intrinsic width, and
        // with two groups the stack stretched one across the bar (TASK-186.3).
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 14),
        ])
        let group = TrailingGroup(order: order, separator: separator, buttons: buttons)
        let index = trailingGroups.firstIndex { $0.order > order } ?? trailingGroups.count
        trailingGroups.insert(group, at: index)

        // The stack's views: the copy button, then each group's separator and
        // buttons, in group order.
        var position = 1 + trailingGroups[..<index].reduce(0) { $0 + 1 + $1.buttons.count }
        let before = trailingStack.arrangedSubviews[position - 1]
        for view in [separator] + buttons {
            trailingStack.insertArrangedSubview(view, at: position)
            position += 1
        }
        trailingStack.setCustomSpacing(8, after: before)
        trailingStack.setCustomSpacing(8, after: separator)
        if let last = buttons.last, position < trailingStack.arrangedSubviews.count {
            trailingStack.setCustomSpacing(8, after: last)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Self.backgroundColor.setFill()
        bounds.fill()

        // Faint 45° bands, rising to the right, anchored at the view's origin
        // so they do not crawl as the bar resizes.
        let period: CGFloat = 14
        let band: CGFloat = 6
        let path = NSBezierPath()
        let height = bounds.height
        var x = -height
        while x < bounds.width {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + band, y: 0))
            path.line(to: NSPoint(x: x + band + height, y: height))
            path.line(to: NSPoint(x: x + height, y: height))
            path.close()
            x += period
        }
        DevModePalette.current.toolbarStripe.setFill()
        path.fill()

        // Hairline between the bar and the page.
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1 / max(1, window?.backingScaleFactor ?? 2)).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// The bar sits in the window's drag strip (the content area's top 38 pt),
    /// which passes its clicks through to it (`WindowDragPassThrough`); a drag
    /// on the bar's background still moves the window, as a title bar would.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    // MARK: - Actions

    @objc private func infoClicked() { onInfoClick?(infoButton) }
    @objc private func urlClicked() { onURLClick?(urlButton) }
    @objc private func copyClicked() { onCopyClick?() }
}

extension DevToolbarView: WindowDragPassThrough {}
