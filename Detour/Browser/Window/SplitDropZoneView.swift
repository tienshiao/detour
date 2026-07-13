import AppKit

/// Maps a pointer x within the content area to a split-edge drop zone:
/// outer 30% bands target an edge, the middle band rejects.
func splitContentDropEdge(forX x: CGFloat, width: CGFloat) -> SplitEdge? {
    guard width > 0, x >= 0, x <= width else { return nil }
    if x < width * 0.3 { return .left }
    if x > width * 0.7 { return .right }
    return nil
}

/// Whether a content-area edge drop may form a split. Mirrors the sidebar's
/// `localDragPayload` rules: only a lone normal tab from THIS window's sidebar
/// and the active space qualifies, and never onto itself.
func validateContentSplitDrop(payload: SidebarDragPayload, sidebarID: UUID,
                              activeSpaceID: UUID?, targetTabID: UUID?) -> Bool {
    guard let activeSpaceID, let targetTabID else { return false }
    return payload.kind == .normalTab
        && payload.sidebarID == sidebarID
        && payload.spaceID == activeSpaceID
        && payload.itemID != targetTabID
}

/// Transparent overlay covering the window's content area during a local sidebar
/// tab drag. Dragging a normal tab over the left/right 30% band previews a split
/// over that half; dropping there forms a split with the window's selected tab.
/// The overlay exists ONLY while our own drag session is live (installed on
/// session start, removed on end), so it never intercepts WKWebView's native
/// drop handling.
final class SplitDropZoneView: NSView {
    var payloadValidator: ((SidebarDragPayload) -> Bool)?
    var onDrop: ((SidebarDragPayload, SplitEdge) -> Bool)?

    /// The payload decoded once on entry and cleared when the drag leaves/ends,
    /// so we don't re-parse the pasteboard on every `draggingUpdated`.
    private var cachedPayload: SidebarDragPayload?
    /// Lazily created accent preview drawn over the targeted half.
    private var previewView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([tabReorderPasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // No hitTest override: the overlay exists only while the mouse is captured
    // by a live drag session, so there are no clicks to pass through — and a
    // nil-returning hitTest could exclude the view from AppKit's (undocumented)
    // drag-destination discovery. Do not add one.

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        cachedPayload = sender.draggingPasteboard.string(forType: tabReorderPasteboardType)
            .flatMap { SidebarDragPayload(pasteboardString: $0) }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let payload = cachedPayload, payloadValidator?(payload) == true else {
            hidePreview()
            return []
        }
        let x = convert(sender.draggingLocation, from: nil).x
        guard let edge = splitContentDropEdge(forX: x, width: bounds.width) else {
            hidePreview()
            return []
        }
        showPreview(for: edge)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        hidePreview()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        hidePreview()
        cachedPayload = nil
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { hidePreview() }
        guard let payload = cachedPayload, payloadValidator?(payload) == true else { return false }
        let x = convert(sender.draggingLocation, from: nil).x
        guard let edge = splitContentDropEdge(forX: x, width: bounds.width) else { return false }
        return onDrop?(payload, edge) ?? false
    }

    // MARK: - Preview

    /// The targeted half of `bounds`, inset 8pt from the outer edges and stopping
    /// 4pt short of the midline (matches the sidebar's split drop overlay).
    private func previewFrame(for edge: SplitEdge) -> NSRect {
        let mid = bounds.midX
        let y = bounds.minY + 8
        let height = bounds.height - 16
        switch edge {
        case .left:
            return NSRect(x: 8, y: y, width: mid - 4 - 8, height: height)
        case .right:
            return NSRect(x: mid + 4, y: y, width: bounds.maxX - 8 - (mid + 4), height: height)
        }
    }

    private func showPreview(for edge: SplitEdge) {
        let preview: NSView
        if let existing = previewView {
            preview = existing
        } else {
            preview = NSView()
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 8
            preview.layer?.borderWidth = UIConstants.splitDropAccentBorderWidth
            preview.layer?.backgroundColor = UIConstants.splitDropAccentFillColor.cgColor
            preview.layer?.borderColor = UIConstants.splitDropAccentBorderColor.cgColor
            addSubview(preview)
            previewView = preview
        }
        preview.isHidden = false
        preview.frame = previewFrame(for: edge)
    }

    private func hidePreview() {
        previewView?.isHidden = true
    }
}
