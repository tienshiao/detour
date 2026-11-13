import AppKit

/// A borderless button that shows a rounded background under the pointer.
/// A disabled one shows none, as AppKit's own controls do (TASK-323): the
/// background follows the pointer and `isEnabled` together, so a button
/// enabled or disabled under a resting pointer gains or loses it at once.
class HoverButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private let hoverBackground = NSView()
    /// The pointer is over the button, enabled or not.
    private var isPointerInside = false
    /// Whether the hover background is showing.
    var isShowingHover: Bool { !hoverBackground.isHidden }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { updateHoverBackground() } }
    }
    var circular: Bool = false { didSet { needsLayout = true } }
    var circularPadding: CGFloat = 3 { didSet { needsLayout = true } }
    /// The hover background's side — a circle's diameter when `circular`,
    /// instead of one derived from the bounds and `circularPadding`.
    var fixedHoverSize: CGFloat? { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = UIConstants.defaultCornerRadius
        hoverBackground.isHidden = true
        addSubview(hoverBackground, positioned: .below, relativeTo: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if circular {
            let side = fixedHoverSize ?? (min(bounds.width, bounds.height) + circularPadding)
            hoverBackground.frame = CGRect(
                x: (bounds.width - side) / 2,
                y: (bounds.height - side) / 2,
                width: side,
                height: side
            )
            hoverBackground.layer?.cornerRadius = side / 2
        } else if let size = fixedHoverSize {
            hoverBackground.frame = CGRect(
                x: (bounds.width - size) / 2,
                y: (bounds.height - size) / 2,
                width: size,
                height: size
            )
            hoverBackground.layer?.cornerRadius = UIConstants.defaultCornerRadius
        } else {
            hoverBackground.frame = bounds.insetBy(dx: 10, dy: 1)
            hoverBackground.layer?.cornerRadius = UIConstants.defaultCornerRadius
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
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
        isPointerInside = true
        updateHoverBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateHoverBackground()
    }

    /// A view hidden or moved out of its window under the pointer gets no
    /// `mouseExited`; forget the pointer so a later `isEnabled` change or
    /// unhide does not bring back a background nobody is pointing at.
    override func viewDidHide() {
        super.viewDidHide()
        isPointerInside = false
        updateHoverBackground()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPointerInside = false
        updateHoverBackground()
    }

    /// The background's color is resolved once when it shows; re-resolve it
    /// when the appearance flips (light/dark) while it is showing.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverBackground()
    }

    private func updateHoverBackground() {
        let shows = isPointerInside && isEnabled
        if shows {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
            }
        }
        hoverBackground.isHidden = !shows
    }
}
