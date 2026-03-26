import AppKit

/// A clip view that draws content from the top down (flipped coordinate system).
class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
