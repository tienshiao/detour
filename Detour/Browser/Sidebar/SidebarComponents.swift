import AppKit

/// The Archived Tabs page's list, whose keyboard focus the page switches off
/// while it is off screen (`ArchivePageView.acceptsKeyboardFocus`).
/// `becomeFirstResponder` too: `makeFirstResponder` does not ask
/// `acceptsFirstResponder`.
class FocusGatedTableView: NSTableView {
    var allowsKeyboardFocus = true
    override var acceptsFirstResponder: Bool { allowsKeyboardFocus && super.acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool { allowsKeyboardFocus && super.becomeFirstResponder() }
}

/// A space's tab list. It never takes keyboard focus (TASK-174): choosing a
/// tab is not a reason to type at the list, so the keyboard stays with — or
/// goes to — the page. Only a row being renamed holds it inside the list.
class DraggableTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }

    /// `makeFirstResponder` does not ask `acceptsFirstResponder`.
    override func becomeFirstResponder() -> Bool { false }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Last mouse-down location in table coordinates. `pasteboardWriterForRow`
    /// reads it to decide which part of a split row a drag grabbed (the drag
    /// APIs don't hand the originating event to the data source).
    private(set) var lastMouseDownPoint: NSPoint?

    /// Fired from `draggingExited`/`draggingEnded` so the sidebar can clear
    /// drop affordances the table-view delegate is never told about.
    var onDragTargetingEnded: (() -> Void)?

    /// The list has no use for the keyboard: the window decides who takes
    /// it — the page, unless something the click opened already has it.
    var onReleaseKeyboardFocus: (() -> Void)?

    /// Opt-Cmd-click on a row (TASK-193.5), with the table point: true when
    /// the sidebar opened a Quick Detour copy of the row's tab, so the click
    /// selects nothing.
    var onQuickDetourClick: ((_ row: Int, _ point: NSPoint) -> Bool)?

    /// Ends a rename in one of the rows (committing it, as any loss of focus
    /// does) and gives the keyboard up.
    func releaseKeyboardFocus() {
        endRename()
        onReleaseKeyboardFocus?()
    }

    private func endRename() {
        guard let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) else { return }
        window.makeFirstResponder(nil)
    }

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

    /// A drag-source table delays window ordering on every mouse-down — rows or
    /// not — so a row can be dragged out of a background window without raising
    /// it. Off the rows our mouse-down moves the window instead, so order it
    /// front first; otherwise a background window is dragged around underneath
    /// the others and only comes forward on mouse-up.
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        guard row(at: convert(event.locationInWindow, from: nil)) >= 0 else { return false }
        return super.shouldDelayWindowOrdering(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMouseDownPoint = point
        // The list used to end a rename by taking the focus the click gave it.
        endRename()
        let clickedRow = row(at: point)
        if clickedRow >= 0,
           QuickDetour.isQuickDetourClick(event.modifierFlags,
                                          enabled: QuickDetourSettings.shared.isOptionCommandClickEnabled),
           onQuickDetourClick?(clickedRow, point) == true {
            // The tab stays as it was: not selected, not toggled.
        } else if clickedRow >= 0 {
            super.mouseDown(with: event)
        } else {
            window?.performDrag(with: event)
        }
        // A click on the list leaves the keyboard wherever it was. It chose
        // a page (or nothing), so the page gets it.
        onReleaseKeyboardFocus?()
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
