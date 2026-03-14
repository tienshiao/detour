import AppKit

/// Transparent view that sits atop the content area to enable window dragging.
/// Initiates a window drag on mouse-down; forwards clicks if no drag occurred.
class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startLocation = event.locationInWindow

        // Enter a local event loop to detect drag vs click
        var didDrag = false

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .default) { trackedEvent, stop in
            guard let trackedEvent else { stop.pointee = true; return }

            if trackedEvent.type == .leftMouseUp {
                stop.pointee = true
                return
            }

            // leftMouseDragged
            let delta = NSPoint(
                x: trackedEvent.locationInWindow.x - startLocation.x,
                y: trackedEvent.locationInWindow.y - startLocation.y
            )
            var newOrigin = window.frame.origin
            newOrigin.x += delta.x
            newOrigin.y += delta.y
            window.setFrameOrigin(newOrigin)
            didDrag = true
        }

        if !didDrag {
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
}
