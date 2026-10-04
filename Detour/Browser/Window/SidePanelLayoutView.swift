import AppKit

// TASK-132.8: the window's content area with an extension side panel beside
// the tab content.
//
// The panel is a trailing pane of the content area. It reuses the split tabs'
// hosting approach — frames, never Auto Layout (constraints around a web view
// break the docked Web Inspector), a divider that drags, a minimum width, a
// remembered width — but none of the split-tab model: the tab content area
// (`BrowserWindowController.contentContainerView`) is simply made narrower, and
// everything that lives in it (the page or the split panes, the peek, the find
// bar, the link status bar, the empty state, the PiP hold, automation parking)
// keeps laying itself out against its bounds exactly as before.

/// Where the user last left the panel's width. One width for every panel and
/// window: it is how wide the user likes a side panel, not a property of one.
enum SidePanelWidthStore {
    /// Scoped to the data directory, like the window's autosave names, so a
    /// test host or an isolated run never moves the production app's panel.
    static let defaultsKey = UserDefaultsScope.autosaveName("ExtensionSidePanelWidth")
    /// Tests point this at a throwaway suite.
    static var defaults: UserDefaults = .standard

    static var width: CGFloat {
        get {
            let stored = defaults.double(forKey: defaultsKey)
            return stored > 0 ? CGFloat(stored) : SidePanelLayout.defaultPanelWidth
        }
        set { defaults.set(Double(newValue), forKey: defaultsKey) }
    }
}

/// The strip between the tab content and the panel: a hairline to look at and
/// `SidePanelLayout.dividerHitWidth` points to grab.
final class SidePanelDividerView: NSView {
    /// The pointer's x in the layout view while the divider is dragged.
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let scale = window?.backingScaleFactor ?? 2
        let line = 1 / scale
        NSRect(x: bounds.midX - line / 2, y: bounds.minY, width: line, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        // Nothing to do until it moves; taking the event is what keeps the
        // click from reaching the page under the strip.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}

/// The content split item's view: the tab content area and, while a side panel
/// shows, the panel at the trailing edge with a draggable divider between.
final class SidePanelLayoutView: NSView {
    /// The tab content area. Fills this view when no panel shows.
    let contentView: NSView
    /// The panel on screen, if any (`ExtensionSidePanelView`).
    private(set) var panelView: NSView?
    let divider = SidePanelDividerView()

    /// The width the user wants the panel to have. The panel is narrower only
    /// while the window is too small for it, and comes back when it grows.
    private(set) var wantedPanelWidth: CGFloat = SidePanelWidthStore.width

    init(contentView: NSView) {
        self.contentView = contentView
        super.init(frame: .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = []
        addSubview(contentView)
        divider.isHidden = true
        divider.onDrag = { [weak self] x in self?.dividerDragged(to: x) }
        divider.onDragEnded = { [weak self] in self?.dividerDragEnded() }
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `view` as the panel, or no panel for nil. The same view again is
    /// only laid out again; a view that moved to another window meanwhile is
    /// forgotten here without being touched.
    func setPanel(_ view: NSView?) {
        if let current = panelView, current !== view {
            if current.superview === self { current.removeFromSuperview() }
            panelView = nil
        }
        if let view {
            if panelView == nil {
                // Every panel starts from the width the user last chose.
                wantedPanelWidth = SidePanelWidthStore.width
            }
            panelView = view
            if view.superview !== self {
                view.translatesAutoresizingMaskIntoConstraints = true
                view.autoresizingMask = []
                addSubview(view, positioned: .below, relativeTo: divider)
            }
        }
        divider.isHidden = panelView == nil
        tile()
    }

    /// The frames in force now.
    var frames: SidePanelLayout.Frames {
        SidePanelLayout.frames(in: bounds, wantedPanelWidth: panelView == nil ? nil : wantedPanelWidth)
    }

    func tile() {
        let frames = frames
        if contentView.frame != frames.content { contentView.frame = frames.content }
        if let panelView, panelView.frame != frames.panel { panelView.frame = frames.panel }
        if !divider.isHidden {
            divider.frame = frames.divider
            window?.invalidateCursorRects(for: divider)
        }
    }

    // Frames, not autoresizing masks: the panel keeps its width and the
    // content takes the rest.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        tile()
    }

    /// Sets the panel's width as a divider drag would, without saving it.
    func setWantedPanelWidth(_ width: CGFloat) {
        wantedPanelWidth = SidePanelLayout.clampedPanelWidth(width, totalWidth: bounds.width)
        tile()
    }

    private func dividerDragged(to x: CGFloat) {
        guard panelView != nil else { return }
        wantedPanelWidth = SidePanelLayout.panelWidth(forBoundaryAt: x, in: bounds)
        tile()
    }

    /// The width is remembered when the drag ends, not on every step of it.
    func dividerDragEnded() {
        guard panelView != nil else { return }
        SidePanelWidthStore.width = wantedPanelWidth
    }
}
