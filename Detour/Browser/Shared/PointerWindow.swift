import AppKit

/// Which window the pointer is over, for hover that is worked out from the
/// pointer's position rather than from a tracking area's enter and exit
/// events (TASK-383).
///
/// `mouseLocationOutsideOfEventStream` gives the pointer in a window's
/// coordinates whether or not anything covers the window there, so a view
/// that asks `bounds.contains` of it alone takes a hover through another
/// window on top: a sidebar row of a window behind, re-checked after its tab
/// list changed, counted as hovered under the front window's page and
/// showed its hover card. Tracking areas have no such gap: the window server
/// sends enter and exit events to the window it finds under the pointer.
enum PointerWindow {

    /// Whether the topmost window at the pointer, `topmostWindowNumber`
    /// (any app's), is `windowNumber` or one of its child windows (the hover
    /// card, the automation endpoint's pointer overlay), which sit over it
    /// and belong to it.
    static func isOwn(topmostWindowNumber: Int, windowNumber: Int, childWindowNumbers: [Int]) -> Bool {
        topmostWindowNumber == windowNumber || childWindowNumbers.contains(topmostWindowNumber)
    }

    /// Whether the pointer is over `window` with no other window on top of
    /// it at that point.
    static func isOver(_ window: NSWindow) -> Bool {
        let topmost = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return isOwn(topmostWindowNumber: topmost, windowNumber: window.windowNumber,
                     childWindowNumbers: (window.childWindows ?? []).map(\.windowNumber))
    }
}
