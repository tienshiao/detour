import AppKit

class DraggableTableView: NSTableView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func dragImageForRows(with dragRows: IndexSet, tableColumns: [NSTableColumn], event: NSEvent, offset dragImageOffset: NSPointPointer) -> NSImage {
        let image = super.dragImageForRows(with: dragRows, tableColumns: tableColumns, event: event, offset: dragImageOffset)
        guard let row = dragRows.first else { return image }
        let rowRect = rect(ofRow: row)
        let mouseInTable = convert(event.locationInWindow, from: nil)
        dragImageOffset.pointee = NSPoint(
            x: mouseInTable.x - rowRect.origin.x,
            y: mouseInTable.y - rowRect.origin.y
        )
        return image
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 {
            super.mouseDown(with: event)
        } else {
            window?.performDrag(with: event)
        }
    }
}

class DraggableScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { true }

    /// Return `true` to consume the event (suppress vertical scrolling).
    var onScrollWheel: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if onScrollWheel?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

class DraggableClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool { true }
}

class DraggableBarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

class FadeShadowView: NSView {
    init(flipped: Bool) {
        super.init(frame: .zero)
        let gradient = CAGradientLayer()
        if flipped {
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        wantsLayer = true
        layer?.addSublayer(gradient)
        updateGradientColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGradientColors()
    }

    private func updateGradientColors() {
        guard let gradient = layer?.sublayers?.first as? CAGradientLayer else { return }
        let isDark = effectiveAppearance.isDark
        let alpha: CGFloat = isDark ? 0.25 : 0.05
        gradient.colors = [
            NSColor.black.withAlphaComponent(alpha).cgColor,
            CGColor.clear
        ]
    }
}
