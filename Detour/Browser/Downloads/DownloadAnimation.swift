import AppKit
import QuartzCore

enum DownloadAnimation {
    static func animate(in window: NSWindow, from sourcePoint: NSPoint, to destPoint: NSPoint, iconName: String = "doc.fill") {
        guard let contentView = window.contentView, contentView.wantsLayer else { return }
        guard let rootLayer = contentView.layer else { return }
        guard sourcePoint.x.isFinite, sourcePoint.y.isFinite,
              destPoint.x.isFinite, destPoint.y.isFinite else { return }

        let iconLayer = CALayer()
        let iconSize: CGFloat = 36
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            let configured = image.withSymbolConfiguration(config) ?? image
            iconLayer.contents = configured.layerContents(forContentsScale: window.backingScaleFactor)
            iconLayer.contentsGravity = .resizeAspect
        }
        iconLayer.frame = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        iconLayer.position = sourcePoint
        rootLayer.addSublayer(iconLayer)

        // Build arc path
        let path = CGMutablePath()
        path.move(to: sourcePoint)
        let midX = (sourcePoint.x + destPoint.x) / 2
        let midY = (sourcePoint.y + destPoint.y) / 2
        let controlPoint = CGPoint(x: midX, y: midY + 250)
        path.addQuadCurve(to: destPoint, control: controlPoint)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            iconLayer.removeFromSuperlayer()
        }

        let positionAnim = CAKeyframeAnimation(keyPath: "position")
        positionAnim.path = path
        positionAnim.duration = 0.6
        positionAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 0.4
        scaleAnim.duration = 0.6

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 1.0
        opacityAnim.toValue = 0.6
        opacityAnim.duration = 0.6

        let group = CAAnimationGroup()
        group.animations = [positionAnim, scaleAnim, opacityAnim]
        group.duration = 0.6
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        iconLayer.add(group, forKey: "downloadArc")

        CATransaction.commit()
    }
}
