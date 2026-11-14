import AppKit

/// Something tossed across a window under gravity and caught by the control
/// it lands on (TASK-289, shared with downloads in TASK-324): a space's emoji
/// into its switcher button, a download's icon into the Downloads button.
///
/// - `TossPath`: the pure path, a true parabola.
/// - `TossOverlayView`: a click-through canvas over a view for the flight.
/// - `TossFlight`: plays an image along a `TossPath` in an overlay.
/// - `SpringCatch`: the catching control's squash and spring back.

/// The path of a toss: it hops `hop` points up, then falls under constant
/// gravity at a constant sideways speed, so it is a true parabola and its
/// timing is the physics', not an easing curve.
///
/// History (TASK-289): a quadratic and then a cubic Bézier, eased out into
/// the target, came first; a falling thing that slows as it lands reads as
/// floaty. In a tall sidebar a fall lands nearly vertically; it arrives fast
/// and the target catches it with a spring.
nonisolated enum TossPath {
    struct Toss: Equatable {
        /// Positions at even time steps, `start` first and `end` last.
        var points: [CGPoint]
        var duration: Double
        /// When the hop peaks, from the start (0 when it never rises).
        var apexTime: Double
    }

    /// Points per second squared: a sidebar-tall fall takes about 0.6 s.
    static let defaultGravity: Double = 6000
    static let defaultMinimumDuration: Double = 0.25
    static let margin: Double = 14
    static let framesPerSecond: Double = 60

    /// `flipped`: y grows downwards in `bounds` (up is then -y). A toss
    /// shorter than `minimumDuration` (a short drop, a level or upward throw)
    /// is launched faster upward so it takes that long and still lands on
    /// `end`: it arcs instead of darting.
    static func toss(from start: CGPoint, to end: CGPoint, in bounds: CGRect, flipped: Bool,
                     hop: Double, gravity: Double = defaultGravity,
                     minimumDuration: Double = defaultMinimumDuration) -> Toss {
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
        let duration = max(minimumDuration, (vy + discriminant.squareRoot()) / g)
        let vx = Double(end.x - start.x) / duration
        // The clamped flight, or a target above the hop, does not land at
        // `duration` with `vy`: launch at the speed that does, so the last
        // step meets the target instead of jumping to it.
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

/// A canvas for a toss over `host`: on top, never in the way of a click,
/// and gone once `finish(after:)` has run.
final class TossOverlayView: NSView {
    /// What draws here, kept alive while it runs.
    var owner: AnyObject?

    static func add(over host: NSView) -> TossOverlayView {
        let overlay = TossOverlayView(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = true
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        return overlay
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Removes the overlay after `delay` seconds.
    func finish(after delay: TimeInterval) {
        Timer.scheduledMainTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.owner = nil
            self?.removeFromSuperview()
        }
    }
}

/// Plays an image along a `TossPath` in a `TossOverlayView`.
enum TossFlight {
    struct Look {
        /// The image's scale at the top of the hop, and on landing.
        var apexScale: CGFloat
        var endScale: CGFloat
        /// How far it turns, in radians, the way it travels.
        var turn: CGFloat
    }

    /// `start` and `end` are in the overlay's coordinates. `landed` runs
    /// when the image reaches `end`; the image is gone by then.
    static func play(_ image: NSImage, in overlay: TossOverlayView, from start: CGPoint, to end: CGPoint,
                     hop: Double, gravity: Double = TossPath.defaultGravity,
                     minimumDuration: Double = TossPath.defaultMinimumDuration,
                     look: Look, landed: @escaping () -> Void) {
        guard let host = overlay.layer else {
            landed()
            return
        }
        let proxy = CALayer()
        proxy.contents = image
        proxy.contentsScale = overlay.window?.backingScaleFactor ?? 2
        proxy.contentsGravity = .resizeAspect
        proxy.bounds = CGRect(origin: .zero, size: image.size)
        proxy.position = end
        host.addSublayer(proxy)

        // Positions sampled at even times and played linearly: the image
        // slows into the top of its hop and speeds up as it falls.
        let toss = TossPath.toss(from: start, to: end, in: host.bounds, flipped: overlay.isFlipped,
                                 hop: hop, gravity: gravity, minimumDuration: minimumDuration)
        let duration = toss.duration
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = toss.points.map { NSValue(point: $0) }
        move.calculationMode = .linear

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        if toss.apexTime > 0.02 {
            scale.values = [1, look.apexScale, look.endScale]
            scale.keyTimes = [0, NSNumber(value: toss.apexTime / duration), 1]
        } else {
            // No hop: it shrinks on the way down only.
            scale.values = [1, look.endScale]
            scale.keyTimes = [0, 1]
        }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = end.x < start.x ? look.turn : -look.turn

        let group = CAAnimationGroup()
        group.animations = [move, scale, spin]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        // The group's completion waits for the flight added inside it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            proxy.add(group, forKey: "toss")
        } onMain: {
            proxy.removeFromSuperlayer()
            landed()
        }
    }
}

/// The catching control's response: squashed by the landing, springing back
/// through a small overshoot to rest. `layer` is the control's own layer;
/// its current transform is the rest state.
enum SpringCatch {
    static func play(on layer: CALayer, size: CGSize) {
        let base = layer.transform
        let midX = size.width / 2
        let midY = size.height / 2
        var squash = CATransform3DTranslate(base, midX, midY, 0)
        squash = CATransform3DScale(squash, 1.35, 0.65, 1)
        squash = CATransform3DTranslate(squash, -midX, -midY, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: squash)
        spring.toValue = NSValue(caTransform3D: base)
        spring.mass = 1
        spring.stiffness = 420
        spring.damping = 11
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "catch")
    }

    /// With Reduce Motion: no squash, the control brightens back in.
    static func fadeIn(on layer: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.25
        fade.toValue = 1
        fade.duration = 0.4
        layer.add(fade, forKey: "catch")
    }
}
