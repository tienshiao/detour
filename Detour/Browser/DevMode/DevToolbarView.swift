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

    private static let buttonSize: CGFloat = 22
    private static let stripeColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.035) : NSColor.black.withAlphaComponent(0.03)
    }
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
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.fixedHoverSize = Self.buttonSize
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
    }

    /// Adds a group of buttons at the right end, after a hairline separator.
    /// Each button should carry its own accessibility label.
    func addTrailingGroup(_ buttons: [NSButton]) {
        guard !buttons.isEmpty else { return }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 14).isActive = true
        trailingStack.addArrangedSubview(separator)
        trailingStack.setCustomSpacing(8, after: trailingStack.arrangedSubviews[trailingStack.arrangedSubviews.count - 2])
        trailingStack.setCustomSpacing(8, after: separator)
        for button in buttons {
            trailingStack.addArrangedSubview(button)
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
        Self.stripeColor.setFill()
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
