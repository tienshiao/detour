import AppKit

class HoverButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private let hoverBackground = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 6
        hoverBackground.isHidden = true
        addSubview(hoverBackground, positioned: .below, relativeTo: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Match the source list selection inset: 10pt from each side of the full sidebar width
        hoverBackground.frame = bounds.insetBy(dx: 10, dy: 1)
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
        hoverBackground.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        hoverBackground.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverBackground.isHidden = true
    }
}
