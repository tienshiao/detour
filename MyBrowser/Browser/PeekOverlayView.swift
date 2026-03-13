import AppKit
import WebKit

@available(macOS 26.0, *)
private class GlassCircleButton: NSView {
    var onTap: (() -> Void)?
    private let glassView = NSGlassEffectView()

    init(symbolName: String, accessibilityDescription: String) {
        super.init(frame: .zero)

        glassView.cornerRadius = 16
        glassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassView)

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)!
            .withSymbolConfiguration(config)!
        imageView.contentTintColor = .labelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleNone
        glassView.contentView = imageView

        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.centerXAnchor.constraint(equalTo: glassView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: glassView.centerYAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityDescription)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }
}

class PeekOverlayView: NSView {
    let peekWebView: WKWebView
    var onClose: (() -> Void)?
    var onExpand: (() -> Void)?

    private let shadowContainer = NSView()
    private let panelView = NSView()
    private let closeButton: NSView
    private let expandButton: NSView
    /// Click point in overlay (superview) coordinates.
    private var clickPoint: CGPoint?
    private var isClosing = false

    init(peekWebView: WKWebView, clickPoint: CGPoint? = nil) {
        self.clickPoint = clickPoint
        self.peekWebView = peekWebView
        if #available(macOS 26.0, *) {
            let close = GlassCircleButton(symbolName: "xmark", accessibilityDescription: "Close")
            let expand = GlassCircleButton(symbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Open in New Tab")
            closeButton = close
            expandButton = expand
            super.init(frame: .zero)
            close.onTap = { [weak self] in self?.onClose?() }
            expand.onTap = { [weak self] in self?.onExpand?() }
        } else {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            let close = NSButton(
                image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!.withSymbolConfiguration(symbolConfig)!,
                target: nil, action: nil
            )
            let expand = NSButton(
                image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right.circle.fill", accessibilityDescription: "Open in New Tab")!.withSymbolConfiguration(symbolConfig)!,
                target: nil, action: nil
            )
            for button in [close, expand] {
                button.bezelStyle = .inline
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.contentTintColor = .labelColor
            }
            closeButton = close
            expandButton = expand
            super.init(frame: .zero)
            close.target = self
            close.action = #selector(closeTapped)
            expand.target = self
            expand.action = #selector(expandTapped)
        }
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func expandTapped() {
        onExpand?()
    }

    private func setupViews() {
        wantsLayer = true

        // Shadow container (casts shadow, no clipping)
        shadowContainer.wantsLayer = true
        shadowContainer.shadow = NSShadow()
        shadowContainer.layer?.shadowColor = NSColor.black.cgColor
        shadowContainer.layer?.shadowOpacity = 0.5
        shadowContainer.layer?.shadowRadius = 30
        shadowContainer.layer?.shadowOffset = CGSize(width: 0, height: -5)
        shadowContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shadowContainer)

        // Panel (clips corners)
        panelView.wantsLayer = true
        panelView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panelView.layer?.cornerRadius = 12
        panelView.layer?.masksToBounds = true
        panelView.translatesAutoresizingMaskIntoConstraints = false
        shadowContainer.addSubview(panelView)

        // WebView inside panel
        peekWebView.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(peekWebView)

        // Buttons
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        addSubview(expandButton)

        NSLayoutConstraint.activate([
            // Shadow container: centered with equal insets, reserving space for buttons
            shadowContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            shadowContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -48),
            shadowContainer.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            shadowContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            // Panel fills shadow container
            panelView.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            panelView.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor),
            panelView.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),

            // WebView fills panel
            peekWebView.topAnchor.constraint(equalTo: panelView.topAnchor),
            peekWebView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
            peekWebView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            peekWebView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),

            // Buttons: vertical stack to the right of the panel, aligned to top
            closeButton.leadingAnchor.constraint(equalTo: shadowContainer.trailingAnchor, constant: 4),
            closeButton.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            expandButton.leadingAnchor.constraint(equalTo: shadowContainer.trailingAnchor, constant: 4),
            expandButton.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 4),
            expandButton.widthAnchor.constraint(equalToConstant: 32),
            expandButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// Build a transform that scales the shadowContainer to a point around the click origin.
    private func scaledDownTransform() -> CATransform3D? {
        guard let pt = clickPoint, let layer = shadowContainer.layer else { return nil }
        let s: CGFloat = 0.05
        let anchorInBounds = CGPoint(
            x: layer.bounds.width * layer.anchorPoint.x,
            y: layer.bounds.height * layer.anchorPoint.y
        )
        let clickInLocal = shadowContainer.convert(pt, from: self)
        let dx = clickInLocal.x - anchorInBounds.x
        let dy = clickInLocal.y - anchorInBounds.y
        return CATransform3DConcat(
            CATransform3DMakeScale(s, s, 1),
            CATransform3DMakeTranslation((1 - s) * dx, (1 - s) * dy, 0)
        )
    }

    /// Animate the overlay open. Call after the view is in the hierarchy and layout has been forced.
    func animateOpen() {
        guard clickPoint != nil else { return }
        shadowContainer.alphaValue = 0
        closeButton.alphaValue = 0
        expandButton.alphaValue = 0

        if let fromTransform = scaledDownTransform(), let layer = shadowContainer.layer {
            layer.transform = CATransform3DIdentity
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = NSValue(caTransform3D: fromTransform)
            anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            anim.duration = 0.2
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(anim, forKey: "openScale")
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            shadowContainer.alphaValue = 1
            closeButton.alphaValue = 1
            expandButton.alphaValue = 1
        }
    }

    func animateClose(completion: @escaping () -> Void) {
        isClosing = true
        peekWebView.removeFromSuperview()

        guard let toTransform = scaledDownTransform(), let layer = shadowContainer.layer else {
            completion()
            return
        }

        layer.transform = toTransform

        let scaleAnim = CABasicAnimation(keyPath: "transform")
        scaleAnim.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        scaleAnim.toValue = NSValue(caTransform3D: toTransform)
        scaleAnim.duration = 0.15
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(scaleAnim, forKey: "closeScale")

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            shadowContainer.alphaValue = 0
            closeButton.alphaValue = 0
            expandButton.alphaValue = 0
        }, completionHandler: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isClosing { return nil }
        return super.hitTest(point) ?? self
    }

    override func scrollWheel(with event: NSEvent) {
        // Forward scrolls inside the panel to the peek web view, swallow the rest
        let point = convert(event.locationInWindow, from: nil)
        if shadowContainer.frame.contains(point) {
            peekWebView.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking outside the panel closes the peek
        let point = convert(event.locationInWindow, from: nil)
        if !shadowContainer.frame.contains(point) {
            onClose?()
        }
    }
}
