import AppKit
import QuartzCore
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "downloads")

/// A click in a window's web content (TASK-324): where, in window
/// coordinates, and when, on the `ProcessInfo.systemUptime` clock (read when
/// the click is noted, as the download side reads it).
nonisolated struct WebContentClick: Equatable, Sendable {
    var point: CGPoint
    var time: TimeInterval
}

/// Where a download's icon takes off (TASK-324). WebKit does not say where a
/// download came from, and it reports one only once the server has answered,
/// possibly seconds after the click, when the pointer may have moved. So the
/// window remembers the last click in any of its web views (the opener's,
/// for a link that opens a new tab first), and a download soon after it flies
/// from there. Anything else (the keyboard, a script, a click long ago)
/// flies from the middle of the page, as before.
nonisolated enum DownloadFlightStart {
    /// A click older than this did not start the download.
    static let maxClickAge: TimeInterval = 5
    /// Download Linked File: the click is the right click that opened the
    /// context menu, which may have stayed open a while before the choice.
    static let contextMenuMaxClickAge: TimeInterval = 60

    static func point(click: WebContentClick?, now: TimeInterval, contentRect: CGRect,
                      maxAge: TimeInterval = maxClickAge) -> CGPoint {
        let middle = CGPoint(x: contentRect.midX, y: contentRect.midY)
        guard let click else { return middle }
        let age = now - click.time
        guard age >= 0, age <= maxAge, contentRect.contains(click.point) else { return middle }
        return click.point
    }
}

/// The download's icon tossed from where the download started into the
/// sidebar's Downloads button, which catches it with a spring: the same toss
/// as the space editor's (`TossPath`, TASK-289), with a bigger hop since a
/// download is thrown up and out of the page.
enum DownloadAnimation {
    /// The icon is thrown up and out of the page; a short or level throw
    /// still takes this long, so it arcs instead of darting sideways.
    static let hop: Double = 40
    static let minimumDuration: Double = 0.5

    /// `sourcePoint` and `destPoint` are in window coordinates. `catcher`
    /// (the Downloads button, nil when the sidebar is hidden) catches the
    /// icon; with Reduce Motion nothing flies and the catcher brightens back
    /// in instead.
    static func animate(in window: NSWindow, from sourcePoint: NSPoint, to destPoint: NSPoint,
                        catcher: NSView?, iconName: String = "doc.fill") {
        guard let contentView = window.contentView else { return }
        guard sourcePoint.x.isFinite, sourcePoint.y.isFinite,
              destPoint.x.isFinite, destPoint.y.isFinite else { return }

        // What a runtime check reads (TASK-228.1's re-run of TASK-324's checks):
        // where the flight starts and ends, in window points, and how.
        let style = MotionPreference.reduceMotion ? "reduced (no flight)" : "toss"
        let caught = catcher == nil ? "none" : "downloads button"
        log.info("Download flight from \(Int(sourcePoint.x), privacy: .public),\(Int(sourcePoint.y), privacy: .public) to \(Int(destPoint.x), privacy: .public),\(Int(destPoint.y), privacy: .public); catcher \(caught, privacy: .public); motion \(style, privacy: .public)")
        if MotionPreference.reduceMotion {
            if let layer = catcher?.layer { SpringCatch.fadeIn(on: layer) }
            return
        }
        guard let image = iconImage(iconName) else { return }

        let overlay = TossOverlayView.add(over: contentView)
        TossFlight.play(image, in: overlay,
                        from: overlay.convert(sourcePoint, from: nil),
                        to: overlay.convert(destPoint, from: nil),
                        hop: hop, minimumDuration: minimumDuration,
                        look: TossFlight.Look(apexScale: 1.05, endScale: 0.45, turn: 0.35)) {
            if let catcher, let layer = catcher.layer {
                SpringCatch.play(on: layer, size: catcher.bounds.size)
            }
            overlay.removeFromSuperview()
        }
    }

    private static func iconImage(_ name: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        return symbol.withSymbolConfiguration(config) ?? symbol
    }
}
