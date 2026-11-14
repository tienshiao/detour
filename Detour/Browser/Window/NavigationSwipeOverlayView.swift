import AppKit

/// What shows during Detour's own swipe (TASK-325): a cosmetic veneer over the
/// pane that received it. Live views are never moved (see the split hosting
/// wiki page): any interruption just removes the veneer over correct content.
///
/// - Back: a picture of the page slides right, off an underlay — the opener's
///   picture where there is one, else a plain page background.
/// - Forward: a plain card slides in from the right over the live page, and
///   the forward page loads under it (PROVISIONAL: WebKit's own picture of the
///   forward page is not readable, so nothing better is shown).
final class NavigationSwipeOverlayView: NSView {

    /// An image drawn into the underlay at `frame` (the overlay's coordinates).
    struct Picture {
        let image: NSImage
        let frame: CGRect
    }

    let direction: NavigationSwipeDirection
    private(set) var progress: CGFloat = 0

    private let underlayLayer = CALayer()
    private let dimmingLayer = CALayer()
    private let slidingLayer = CALayer()

    /// WebKit's swipe dims the page underneath by this much at the start.
    private static let maximumDimming: Float = 0.12
    private static let shadowOpacity: Float = 0.25

    init(frame: NSRect, direction: NavigationSwipeDirection, page: NSImage?, underlay: [Picture],
         cornerRadius: CGFloat) {
        self.direction = direction
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = []
        guard let layer else { return }
        layer.masksToBounds = true
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous

        var pageBackground: CGColor = NSColor.white.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pageBackground = NSColor.textBackgroundColor.cgColor
        }

        let bounds = CGRect(origin: .zero, size: frame.size)
        // Frames set below must not animate implicitly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if direction == .back {
            underlayLayer.frame = bounds
            underlayLayer.backgroundColor = pageBackground
            for picture in underlay {
                let pictureLayer = CALayer()
                pictureLayer.frame = picture.frame
                pictureLayer.contents = picture.image
                pictureLayer.contentsGravity = .resize
                underlayLayer.addSublayer(pictureLayer)
            }
            layer.addSublayer(underlayLayer)

            dimmingLayer.frame = bounds
            dimmingLayer.backgroundColor = NSColor.black.cgColor
            dimmingLayer.opacity = Self.maximumDimming
            layer.addSublayer(dimmingLayer)

            slidingLayer.contents = page
            slidingLayer.contentsGravity = .resize
            slidingLayer.backgroundColor = pageBackground
        } else {
            slidingLayer.backgroundColor = pageBackground
        }
        slidingLayer.frame = bounds
        slidingLayer.shadowColor = NSColor.black.cgColor
        slidingLayer.shadowOpacity = Self.shadowOpacity
        slidingLayer.shadowRadius = 8
        slidingLayer.shadowOffset = .zero
        slidingLayer.shadowPath = CGPath(rect: bounds, transform: nil)
        layer.addSublayer(slidingLayer)
        applyProgress()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Cosmetic only: clicks go to whatever is under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The swipe's progress, clamped as `NavigationSwipeRules.clampedProgress`:
    /// 0…1 going back, -1…0 going forward.
    func setProgress(_ progress: CGFloat) {
        self.progress = NavigationSwipeRules.clampedProgress(progress, direction: direction)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyProgress()
        CATransaction.commit()
    }

    private func applyProgress() {
        let width = bounds.width
        let offset = (width * progress).rounded(.down)
        var frame = slidingLayer.frame
        switch direction {
        case .back:
            // The page follows the fingers to the right.
            frame.origin.x = offset
            dimmingLayer.opacity = Self.maximumDimming * Float(1 - progress)
        case .forward:
            // The card comes in from the right edge.
            frame.origin.x = width + offset
        }
        slidingLayer.frame = frame
        // The shadow fades out as the card's edge reaches the far side.
        let remaining = width - abs(offset)
        let fadeDistance: CGFloat = 20
        slidingLayer.shadowOpacity = remaining < fadeDistance
            ? Self.shadowOpacity * Float(max(remaining, 0) / fadeDistance) : Self.shadowOpacity
    }
}
