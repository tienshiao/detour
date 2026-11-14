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

    private let overlay: CelebrationOverlayView

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
        overlay = CelebrationOverlayView(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = true
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        // Keeps itself alive until the overlay is gone.
        overlay.owner = self
    }

    private var hostLayer: CALayer? { overlay.layer }

    private func point(_ p: NSPoint) -> CGPoint {
        // The overlay matches the host's flippedness, so view and layer
        // coordinates agree.
        overlay.convert(p, from: overlay.superview)
    }

    // MARK: - The flight

    private func fly(from origin: NSRect, to target: NSRect, emoji: String, landed: @escaping () -> Void) {
        guard let hostLayer, let image = Self.emojiImage(emoji, pointSize: 26) else {
            landed()
            return
        }
        let start = point(NSPoint(x: origin.midX, y: origin.midY))
        let end = point(NSPoint(x: target.midX, y: target.midY))

        let proxy = CALayer()
        proxy.contents = image
        proxy.contentsScale = overlay.window?.backingScaleFactor ?? 2
        proxy.bounds = CGRect(origin: .zero, size: image.size)
        proxy.position = end
        hostLayer.addSublayer(proxy)

        // A real toss (SpaceFlightPath): a hop off the tile, then gravity.
        // Positions are sampled at even times and played linearly, so the
        // emoji slows into the top of its hop and speeds up as it falls.
        let toss = SpaceFlightPath.toss(from: start, to: end, in: hostLayer.bounds, flipped: overlay.isFlipped,
                                        hop: Self.tunedHop, gravity: Self.tunedGravity)
        let duration = toss.duration
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = toss.points.map { NSValue(point: $0) }
        move.calculationMode = .linear

        // A little bigger at the top of the hop, the switcher's size on
        // landing.
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        if toss.apexTime > 0.02 {
            scale.values = [1, 1.1, 0.55]
            scale.keyTimes = [0, NSNumber(value: toss.apexTime / duration), 1]
        } else {
            // No hop: it shrinks on the way down only.
            scale.values = [1, 0.55]
            scale.keyTimes = [0, 1]
        }

        // It turns the way it travels, a little.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = toss.points.last!.x < toss.points.first!.x ? 0.5 : -0.5

        let group = CAAnimationGroup()
        group.animations = [move, scale, spin]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        // The group's completion waits for the flight added inside it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            proxy.add(group, forKey: "fly")
        } onMain: {
            proxy.removeFromSuperlayer()
            landed()
        }
    }

    /// The toss's hop and gravity. A Debug build reads overrides from the data
    /// directory's defaults (`SpaceTossHop`, `SpaceTossGravity`), so the feel
    /// can be tuned without a rebuild; a release build always uses the
    /// defaults.
    private static var tunedHop: Double {
        #if DEBUG
        if let value = UserDefaultsScope.defaults.object(forKey: "SpaceTossHop") as? Double { return max(0, value) }
        #endif
        return SpaceFlightPath.defaultHop
    }

    private static var tunedGravity: Double {
        #if DEBUG
        if let value = UserDefaultsScope.defaults.object(forKey: "SpaceTossGravity") as? Double, value > 0 { return value }
        #endif
        return SpaceFlightPath.defaultGravity
    }

    // MARK: - The landing

    private func burst(at landing: NSPoint, color: NSColor, style: Style) {
        guard let hostLayer else { return }
        let center = point(landing)
        ripple(at: center, color: color, in: hostLayer)
        sparkle(at: center, color: color, style: style, in: hostLayer)
        // The overlay outlives the longest particle, then goes.
        let overlay = self.overlay
        Timer.scheduledMainTimer(withTimeInterval: 1.2, repeats: false) { _ in
            overlay.owner = nil
            overlay.removeFromSuperview()
        }
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

/// The celebration's flight (TASK-289): the emoji is tossed from the
/// editor's tile into the space's switcher button under constant gravity.
///
/// It hops `hop` points up, then falls; its sideways speed is constant, so
/// the path is a true parabola and its timing is the physics', not an easing
/// curve. Two earlier versions were a quadratic and then a cubic Bézier,
/// eased out into the button: a falling thing that slows down as it lands
/// reads as floaty. In a tall sidebar a fall lands nearly vertically; it
/// arrives fast and the button catches it with a spring.
nonisolated enum SpaceFlightPath {
    struct Toss: Equatable {
        /// Positions at even time steps, `start` first and `end` last.
        var points: [CGPoint]
        var duration: Double
        /// When the hop peaks, from the start.
        var apexTime: Double
    }

    /// Points per second squared: a sidebar-tall fall takes about 0.6 s.
    static let defaultGravity: Double = 6000
    /// How high it hops above the tile, at most: a small lift, so it reads as
    /// let go rather than thrown up (50 pt read as a throw; the user asked for
    /// less).
    static let defaultHop: Double = 8
    static let margin: Double = 14
    static let framesPerSecond: Double = 60

    /// `flipped`: y grows downwards in `bounds` (up is then -y).
    static func toss(from start: CGPoint, to end: CGPoint, in bounds: CGRect, flipped: Bool,
                     hop: Double = defaultHop, gravity: Double = defaultGravity) -> Toss {
        let up: Double = flipped ? -1 : 1
        // Heights measured upwards, whatever the space's orientation.
        let startHeight = Double(start.y) * up
        let endHeight = Double(end.y) * up
        let ceiling = flipped ? -(Double(bounds.minY) + margin) : Double(bounds.maxY) - margin
        let hopHeight = max(0, min(hop, ceiling - startHeight))

        let g = max(1, gravity)
        let vy = (2 * g * hopHeight).squareRoot()
        // Height h(t) = startHeight + vy t - g t² / 2 meets endHeight.
        let drop = startHeight - endHeight
        let discriminant = max(0, vy * vy + 2 * g * drop)
        let duration = max(0.25, (vy + discriminant.squareRoot()) / g)
        let vx = Double(end.x - start.x) / duration
        // The shortest flight, or a target above the hop, does not land at
        // `duration` with `vy`: launch at the speed that does, so the last
        // step meets the button instead of jumping to it.
        let fallEnd = startHeight + vy * duration - g * duration * duration / 2
        let launch = abs(endHeight - fallEnd) < 0.01 ? vy : vy + (endHeight - fallEnd) / duration

        let steps = max(2, Int((duration * framesPerSecond).rounded(.up)))
        var points: [CGPoint] = []
        points.reserveCapacity(steps + 1)
        for step in 0...steps {
            let t = duration * Double(step) / Double(steps)
            let height = startHeight + launch * t - g * t * t / 2
            points.append(CGPoint(x: Double(start.x) + vx * t, y: height * up))
        }
        points[points.count - 1] = end
        return Toss(points: points, duration: duration, apexTime: min(duration, max(0, launch / g)))
    }
}

/// The celebration's canvas: on top of the sidebar, never in the way of a
/// click.
private final class CelebrationOverlayView: NSView {
    /// The celebration that draws here, kept alive while it runs.
    var owner: SpaceCelebration?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
