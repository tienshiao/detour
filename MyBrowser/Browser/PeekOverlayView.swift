import AppKit
import WebKit

class PeekOverlayView: NSView {
    let peekWebView: WKWebView
    var onClose: (() -> Void)?
    var onExpand: (() -> Void)?

    private let shadowContainer = NSView()
    private let panelView = NSView()
    private let closeButton: NSButton
    private let expandButton: NSButton
    /// Click point in overlay (superview) coordinates.
    private var clickPoint: CGPoint?
    private var isClosing = false

    init(peekWebView: WKWebView, clickPoint: CGPoint? = nil) {
        self.clickPoint = clickPoint
        self.peekWebView = peekWebView
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!.withSymbolConfiguration(symbolConfig)!,
            target: nil,
            action: nil
        )
        expandButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right.circle.fill", accessibilityDescription: "Open in New Tab")!.withSymbolConfiguration(symbolConfig)!,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

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
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.contentTintColor = .labelColor
        addSubview(closeButton)

        expandButton.bezelStyle = .inline
        expandButton.isBordered = false
        expandButton.target = self
        expandButton.action = #selector(expandTapped)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.contentTintColor = .labelColor
        addSubview(expandButton)

        NSLayoutConstraint.activate([
            // Shadow container: fixed margins from overlay edges
            shadowContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            shadowContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
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

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func expandTapped() {
        onExpand?()
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
