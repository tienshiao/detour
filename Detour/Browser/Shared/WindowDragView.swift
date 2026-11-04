import AppKit

/// A view under the drag strip that handles its own clicks, such as the dev
/// toolbar's buttons. The strip forwards a click by synthesizing mouse-down
/// and mouse-up, which an `NSButton` cannot take: its mouse-down tracks the
/// real event stream for a mouse-up the strip has already consumed.
protocol WindowDragPassThrough: NSView {}

/// Transparent view that sits atop the content area to enable window dragging.
/// Initiates a window drag on mouse-down; forwards clicks if no drag occurred.
class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    /// Lets events through to a `WindowDragPassThrough` view (or one inside
    /// it) under the strip; the strip handles everything else.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self, let superview else { return hit }
        for sibling in superview.subviews.reversed() where sibling !== self {
            guard let target = sibling.hitTest(point) else { continue }
            let passesThrough = sequence(first: target, next: \.superview).contains { $0 is WindowDragPassThrough }
            return passesThrough ? nil : self
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startLocation = event.locationInWindow
        let threshold: CGFloat = 3

        // Enter a local event loop to detect drag vs click. We don't move the
        // window here — once movement crosses the threshold we hand off to the
        // native window-drag machinery via performDrag(with:), which is what
        // enables moving the window across Spaces and snapping to screen edges.
        var didDrag = false

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .default) { trackedEvent, stop in
            guard let trackedEvent else { stop.pointee = true; return }

            if trackedEvent.type == .leftMouseUp {
                stop.pointee = true
                return
            }

            // leftMouseDragged
            let dx = trackedEvent.locationInWindow.x - startLocation.x
            let dy = trackedEvent.locationInWindow.y - startLocation.y
            if dx * dx + dy * dy >= threshold * threshold {
                didDrag = true
                stop.pointee = true
            }
        }

        if didDrag {
            // Mouse button is still down — hand the gesture to the OS. Uses the
            // original mouse-down event so the grab point stays under the cursor.
            window.performDrag(with: event)
            return
        }

        // It was a click — forward full click sequence to the view underneath
        guard let superview else { return }
        let superPoint = superview.convert(event.locationInWindow, from: nil)
        for sibling in superview.subviews.reversed() where sibling !== self {
            if let target = sibling.hitTest(superPoint) {
                target.mouseDown(with: event)
                // Synthesize a matching mouseUp
                let mouseUp = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: event.locationInWindow,
                    modifierFlags: event.modifierFlags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: event.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: event.clickCount,
                    pressure: 0
                )
                if let mouseUp {
                    target.mouseUp(with: mouseUp)
                }
                return
            }
        }
    }
}
