import AppKit

class DraggableTableView: NSTableView {
    override var mouseDownCanMoveWindow: Bool { false }

    /// Last mouse-down location in table coordinates. `pasteboardWriterForRow`
    /// reads it to decide which part of a split row a drag grabbed (the drag
    /// APIs don't hand the originating event to the data source).
    private(set) var lastMouseDownPoint: NSPoint?

    /// Fired from `draggingExited`/`draggingEnded` so the sidebar can clear
    /// drop affordances the table-view delegate is never told about.
    var onDragTargetingEnded: (() -> Void)?

    // NSDraggingDestination methods are declared on NSView's interface (so the
    // overrides compile) but not necessarily implemented — an unguarded super
    // call raises unrecognized-selector mid-drag-teardown, which aborts the
    // session before the source's endedAt callback. Only call super when the
    // superclass really implements the method.
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragTargetingEnded?()
        if NSTableView.instancesRespond(to: #selector(NSView.draggingExited(_:))) {
            super.draggingExited(sender)
        }
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragTargetingEnded?()
        if NSTableView.instancesRespond(to: #selector(NSView.draggingEnded(_:))) {
            super.draggingEnded(sender)
        }
    }

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
        lastMouseDownPoint = point
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
