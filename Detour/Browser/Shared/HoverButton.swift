import AppKit

class HoverButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private let hoverBackground = NSView()
    var circular: Bool = false { didSet { needsLayout = true } }
    var circularPadding: CGFloat = 3 { didSet { needsLayout = true } }
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
            let side = min(bounds.width, bounds.height) + circularPadding
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hoverBackground.layer?.backgroundColor = UIConstants.hoverBackgroundColor.cgColor
        }
        hoverBackground.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverBackground.isHidden = true
    }
}
