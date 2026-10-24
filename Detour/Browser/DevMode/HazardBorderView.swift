import AppKit
import QuartzCore

/// Dev mode's "under construction" border (TASK-186.1): a dashed stroke in
/// hazard yellow and near-black around the view's bounds. A solid yellow
/// stroke sits under a dashed dark one on the same rounded-rect path, so the
/// dashes alternate yellow and black. Sidebar rows are reused and redrawn
/// often, so it is two shape layers whose path changes only on resize, with
/// implicit animations off. Decorative: never the hit view.
final class HazardBorderView: NSView {
    static let lineWidth: CGFloat = 1.5
    static let dashLength: CGFloat = 4

    /// The yellow half of the hazard pair; `systemYellow` is tuned per appearance.
    static let yellowColor = NSColor.systemYellow
    /// The dark half: near-black in both appearances, slightly lifted in dark
    /// mode so the dashes still separate from a dark sidebar.
    static let darkColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.05, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    }

    private let cornerRadius = UIConstants.defaultCornerRadius

    private let yellowLayer = CAShapeLayer()
    private let dashLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let noActions: [String: CAAction] = [
            "path": NSNull(), "bounds": NSNull(), "position": NSNull(),
            "strokeColor": NSNull(), "contentsScale": NSNull(),
        ]
        for shape in [yellowLayer, dashLayer] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.actions = noActions
            layer?.addSublayer(shape)
        }
        dashLayer.lineDashPattern = [NSNumber(value: Double(Self.dashLength)), NSNumber(value: Double(Self.dashLength))]
        updateColors()
        updatePath()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePath()
    }

    private func updatePath() {
        let rect = bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        guard rect.width > 0, rect.height > 0 else {
            yellowLayer.path = nil
            dashLayer.path = nil
            return
        }
        let radius = max(0, min(cornerRadius - Self.lineWidth / 2, rect.width / 2, rect.height / 2))
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for shape in [yellowLayer, dashLayer] {
            shape.frame = bounds
            shape.path = path
        }
    }

    /// CGColor doesn't track appearance changes — re-resolve on theme switches.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            yellowLayer.strokeColor = Self.yellowColor.cgColor
            dashLayer.strokeColor = Self.darkColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Unhosted shape layers rasterise at 1x unless told the screen's scale —
    /// on joining a window (borders are made lazily, often after the cell is
    /// already on screen) and when the window's scale changes.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        guard let scale = window?.backingScaleFactor else { return }
        yellowLayer.contentsScale = scale
        dashLayer.contentsScale = scale
    }
}
