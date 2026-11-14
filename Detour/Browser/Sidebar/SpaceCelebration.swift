import AppKit

/// The moment a space is created or saved in the space editor (TASK-289):
/// the editor's emoji lifts off its tile and flies in an arc into the
/// space's switcher button, which pops; a ripple of the space's colour washes
/// over the sidebar from there, and a small ring of dots sparkles around the
/// button (smaller for an edit).
///
/// Everything happens in a click-through overlay over the sidebar that
/// removes itself when done. With Reduce Motion the caller fades the button
/// in instead and never runs this.
final class SpaceCelebration {
    enum Style {
        case created
        case edited
    }

    /// How high the emoji hops off the tile: a small lift, so it reads as
    /// let go rather than thrown up (50 pt read as a throw, 16 pt still a
    /// little much; the user chose 8).
    static let hop: Double = 8

    private let overlay: TossOverlayView

    /// `host` is the view the overlay covers; `origin` (the editor's emoji
    /// tile) and `target` (the switcher button) are in `host`'s coordinates.
    /// `land` runs when the emoji reaches the button: show the button there.
    @discardableResult
    static func run(in host: NSView, from origin: NSRect, to target: NSRect, emoji: String, color: NSColor,
                    style: Style, land: @escaping () -> Void) -> SpaceCelebration {
        let celebration = SpaceCelebration(host: host)
        celebration.fly(from: origin, to: target, emoji: emoji) { [weak celebration] in
            land()
            celebration?.burst(at: NSPoint(x: target.midX, y: target.midY), color: color, style: style)
        }
        return celebration
    }

    private init(host: NSView) {
        overlay = TossOverlayView.add(over: host)
        // Keeps itself alive until the overlay is gone.
        overlay.owner = self
    }

    private var hostLayer: CALayer? { overlay.layer }

    private func point(_ p: NSPoint) -> CGPoint {
        // The overlay is never flipped, whatever the host is; its layer
        // shares its coordinates, and the toss reads `isFlipped`.
        overlay.convert(p, from: overlay.superview)
    }

    // MARK: - The flight

    /// A toss (`TossPath`): a small hop off the tile, then gravity, a little
    /// bigger at the top of the hop and the switcher's size on landing.
    private func fly(from origin: NSRect, to target: NSRect, emoji: String, landed: @escaping () -> Void) {
        guard let image = Self.emojiImage(emoji, pointSize: 26) else {
            landed()
            return
        }
        TossFlight.play(image, in: overlay,
                        from: point(NSPoint(x: origin.midX, y: origin.midY)),
                        to: point(NSPoint(x: target.midX, y: target.midY)),
                        hop: Self.tunedHop, gravity: Self.tunedGravity,
                        look: TossFlight.Look(apexScale: 1.1, endScale: 0.55, turn: 0.5),
                        landed: landed)
    }

    /// The toss's hop and gravity. A Debug build reads overrides from the data
    /// directory's defaults (`SpaceTossHop`, `SpaceTossGravity`), so the feel
    /// can be tuned without a rebuild; a release build always uses the
    /// defaults.
    private static var tunedHop: Double {
        #if DEBUG
        if let value = UserDefaultsScope.defaults.object(forKey: "SpaceTossHop") as? Double { return max(0, value) }
        #endif
        return SpaceCelebration.hop
    }

    private static var tunedGravity: Double {
        #if DEBUG
        if let value = UserDefaultsScope.defaults.object(forKey: "SpaceTossGravity") as? Double, value > 0 { return value }
        #endif
        return TossPath.defaultGravity
    }

    // MARK: - The landing

    private func burst(at landing: NSPoint, color: NSColor, style: Style) {
        // The overlay outlives the longest particle, then goes (and with it
        // this celebration, which it keeps alive), even with nothing to draw.
        overlay.finish(after: 1.2)
        guard let hostLayer else { return }
        let center = point(landing)
        ripple(at: center, color: color, in: hostLayer)
        sparkle(at: center, color: color, style: style, in: hostLayer)
    }

    /// A disc of the space's colour that spreads from the button over the
    /// whole sidebar and fades: the new tint arriving.
    private func ripple(at center: CGPoint, color: NSColor, in layer: CALayer) {
        let bounds = layer.bounds
        let reach = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                     CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
            .map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 400
        let radius: CGFloat = 20
        let disc = CAShapeLayer()
        disc.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        disc.fillColor = color.withAlphaComponent(0.16).cgColor
        disc.position = center
        disc.opacity = 0
        layer.insertSublayer(disc, at: 0)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = reach / radius
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.15, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        disc.add(group, forKey: "ripple")
    }

    /// A small ring of dots in the space's colours that bursts out around
    /// the button and fades: a sparkle, not confetti (the user found confetti
    /// too much). An edit gets a smaller one.
    private func sparkle(at center: CGPoint, color: NSColor, style: Style, in layer: CALayer) {
        let created = style == .created
        let count = created ? 8 : 6
        let reach: CGFloat = created ? 30 : 22
        let paints = [color, color.blended(withFraction: 0.45, of: .white) ?? color]
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi + .pi / CGFloat(count)
            let radius: CGFloat = index.isMultiple(of: 2) ? 2.5 : 1.8
            let dot = CAShapeLayer()
            dot.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
            dot.fillColor = paints[index % paints.count].cgColor
            dot.position = center
            dot.opacity = 0
            layer.addSublayer(dot)

            let distance = reach * (index.isMultiple(of: 2) ? 1 : 0.75)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: NSPoint(x: center.x + cos(angle) * 10, y: center.y + sin(angle) * 10))
            move.toValue = NSValue(point: NSPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance))
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.8, 0.3, 1)
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.2
            shrink.toValue = 0.3
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.1, 0.5, 1]
            let group = CAAnimationGroup()
            group.animations = [move, shrink, fade]
            group.duration = 0.5
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            dot.add(group, forKey: "sparkle")
        }
    }

    // MARK: - Images

    private static func emojiImage(_ emoji: String, pointSize: CGFloat) -> NSImage? {
        guard !emoji.isEmpty else { return nil }
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: pointSize)])
        let size = text.size()
        guard size.width > 0, size.height > 0 else { return nil }
        return NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { _ in
            text.draw(at: .zero)
            return true
        }
    }
}
