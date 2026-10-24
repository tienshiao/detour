import AppKit

/// What the hover card needs from its window.
protocol TabHoverCardHost: AnyObject {
    /// The browser window the card's panel is a child of.
    var hoverCardParentWindow: NSWindow? { get }
    /// The visible part of the sidebar in window coordinates; nil while it is
    /// hidden. The card goes just outside its trailing edge.
    var hoverCardSidebarRectInWindow: NSRect? { get }
    /// Whether `tab` is on screen in this window (the selected tab or a pane
    /// of the selected split): its card shows no thumbnail.
    func hoverCardIsOnScreen(_ tab: BrowserTab) -> Bool
    /// `TabStore.thumbnailKey(for:)`.
    func hoverCardThumbnailKey(for tab: BrowserTab) -> UUID?
}

/// Shows the sidebar's tab hover card (TASK-190), one per browser window.
///
/// The sidebar reports hovers (`hoverBegan` / `hoverEnded`) with the row's
/// target already resolved. A fresh hover shows the card after
/// `HoverCardTiming.showDelay`; moving to another row while one is up, or
/// just after, swaps it at once. A mouse down, scroll or key down in the
/// window (a local event monitor, installed only while a card is pending or
/// up), the window resigning key, or the sidebar hiding dismisses the card
/// and keeps it away until the pointer leaves that row. Nothing shows while
/// a mouse button is down. Thumbnails come from the tab's in-memory switcher
/// preview, else from `TabThumbnailCache` on disk; no tab is ever woken,
/// hosted or snapshotted for one.
final class TabHoverCardController {
    weak var host: TabHoverCardHost?
    var now: () -> Date = Date.init
    /// `NSEvent.pressedMouseButtons`, injectable so tests do not read the
    /// real mouse.
    var pressedMouseButtons: () -> Int = { NSEvent.pressedMouseButtons }
    var thumbnailCache: TabThumbnailCache = .shared

    private struct Hover {
        let target: HoverCardTarget
        let rowRectInWindow: NSRect
    }

    private var hover: Hover?
    private var shownTarget: HoverCardTarget?
    /// Dismissed by an event: not shown again until the pointer leaves it.
    private var suppressed: HoverCardTarget?
    private var lastHiddenAt: Date?
    private var showTimer: Timer?
    private var eventMonitor: Any?
    private var panel: TabHoverCardPanel?
    /// The last thumbnail read from disk, so the card shown for it has it.
    private var diskThumbnail: (key: UUID, image: NSImage?)?
    private var loadGeneration = 0
    /// The shown card's row top in screen coordinates, kept for re-placing
    /// the panel when a thumbnail arrives after it is up.
    private var shownRowTop: CGFloat?

    var isShowing: Bool { shownTarget != nil }

    deinit {
        showTimer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    // MARK: - Entry points

    /// The pointer is over `target`'s row (or split half).
    func hoverBegan(_ target: HoverCardTarget, rowRectInWindow: NSRect) {
        if let current = hover, current.target.isSame(as: target) {
            hover = Hover(target: target, rowRectInWindow: rowRectInWindow)
            return
        }
        if let suppressed, !suppressed.isSame(as: target) { self.suppressed = nil }
        hover = Hover(target: target, rowRectInWindow: rowRectInWindow)
        showTimer?.invalidate()
        showTimer = nil
        guard suppressed == nil else { return }
        // A drag over the rows, or a press that has not been released.
        guard pressedMouseButtons() == 0 else {
            dismiss()
            return
        }
        loadDiskThumbnailIfNeeded(for: target)
        let delay = HoverCardTiming.delay(isShowing: isShowing, lastHiddenAt: lastHiddenAt, now: now())
        if delay <= 0 {
            show()
        } else {
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                self?.showTimer = nil
                self?.show()
            }
            RunLoop.main.add(timer, forMode: .common)
            showTimer = timer
        }
        updateEventMonitor()
    }

    /// The pointer left `target`'s row.
    func hoverEnded(_ target: HoverCardTarget) {
        if let suppressed, suppressed.isSame(as: target) { self.suppressed = nil }
        guard let current = hover, current.target.isSame(as: target) else { return }
        hover = nil
        showTimer?.invalidate()
        showTimer = nil
        if isShowing {
            hideCard()
            lastHiddenAt = now()
        }
        updateEventMonitor()
    }

    /// Hides the card, pending or up, and keeps it away from the hovered row
    /// until the pointer leaves it.
    func dismiss() {
        suppressAndHide()
        updateEventMonitor()
    }

    private func suppressAndHide() {
        showTimer?.invalidate()
        showTimer = nil
        if let hover { suppressed = hover.target }
        hideCard()
        // An event hid it, not the pointer moving on: the next row waits.
        lastHiddenAt = nil
    }

    // MARK: - Showing

    private func content(for target: HoverCardTarget) -> HoverCardContent? {
        guard let host else { return nil }
        return HoverCardContent.make(for: target,
                                     isOnScreen: { host.hoverCardIsOnScreen($0) },
                                     thumbnailKey: { host.hoverCardThumbnailKey(for: $0) })
    }

    private func show() {
        guard let hover, suppressed == nil, let host,
              let window = host.hoverCardParentWindow, window.isVisible,
              let sidebarRect = host.hoverCardSidebarRectInWindow,
              let content = content(for: hover.target) else {
            hideCard()
            updateEventMonitor()
            return
        }
        guard pressedMouseButtons() == 0 else {
            dismiss()
            return
        }
        let thumbnail = content.preview
            ?? content.thumbnailKey.flatMap { key in diskThumbnail?.key == key ? diskThumbnail?.image : nil }
        let panel = self.panel ?? TabHoverCardPanel()
        self.panel = panel
        panel.appearance = window.effectiveAppearance
        panel.cardView.configure(text: content.text, thumbnail: thumbnail)

        let sidebarOnScreen = window.convertToScreen(sidebarRect)
        let rowOnScreen = window.convertToScreen(hover.rowRectInWindow)
        shownRowTop = rowOnScreen.maxY
        place(panel, sidebarMaxX: sidebarOnScreen.maxX, rowTop: rowOnScreen.maxY, on: window)

        // A card hidden a moment ago (the pointer moved to the next row) is
        // swapped in place, not faded in again.
        let fadesIn = !isShowing && HoverCardTiming.delay(isShowing: false, lastHiddenAt: lastHiddenAt, now: now()) > 0
        shownTarget = hover.target
        // Transparent before `addChildWindow` orders it in, so a fresh card
        // never flashes at full opacity before its fade.
        if fadesIn { panel.alphaValue = 0 }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if fadesIn {
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFront(nil)
        }
        panel.invalidateShadow()
        updateEventMonitor()
    }

    private var sidebarMaxXOnScreen: CGFloat? {
        guard let window = host?.hoverCardParentWindow, let rect = host?.hoverCardSidebarRectInWindow else { return nil }
        return window.convertToScreen(rect).maxX
    }

    private func place(_ panel: TabHoverCardPanel, sidebarMaxX: CGFloat, rowTop: CGFloat, on window: NSWindow) {
        let size = panel.fittingCardSize
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)
        let frame = HoverCardPlacement.frame(cardSize: size, sidebarMaxX: sidebarMaxX,
                                             rowTop: rowTop, visibleFrame: visible)
        panel.setFrame(frame, display: true)
    }

    private func hideCard() {
        guard let panel else {
            shownTarget = nil
            return
        }
        if shownTarget != nil || panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        shownTarget = nil
        shownRowTop = nil
    }

    // MARK: - Disk thumbnails

    /// Starts reading the target's thumbnail from disk while the show delay
    /// runs, when the tab has no in-memory preview. Read afresh on every new
    /// hover: the file may have been written since the last read (a pinned
    /// entry woken, pictured and made dormant again).
    private func loadDiskThumbnailIfNeeded(for target: HoverCardTarget) {
        guard let content = content(for: target), content.preview == nil,
              let key = content.thumbnailKey else { return }
        diskThumbnail = nil
        loadGeneration += 1
        let generation = loadGeneration
        thumbnailCache.image(for: key) { [weak self] image in
            guard let self, generation == self.loadGeneration else { return }
            self.diskThumbnail = (key, image)
            self.diskThumbnailDidLoad(image, for: key)
        }
    }

    /// Puts a late thumbnail on the card if it is still up for that key.
    private func diskThumbnailDidLoad(_ image: NSImage?, for key: UUID) {
        guard let image, let shownTarget, let panel, let window = host?.hoverCardParentWindow,
              let rowTop = shownRowTop, let sidebarMaxX = sidebarMaxXOnScreen,
              let content = content(for: shownTarget), content.preview == nil,
              content.thumbnailKey == key, !panel.cardView.hasThumbnail else { return }
        panel.cardView.setThumbnail(image)
        place(panel, sidebarMaxX: sidebarMaxX, rowTop: rowTop, on: window)
        panel.invalidateShadow()
    }

    // MARK: - Dismissal

    /// The monitor runs only while a card is pending or up.
    private func updateEventMonitor() {
        let needed = showTimer != nil || isShowing
        if needed, eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
            ) { [weak self] event in
                guard let self, let window = self.host?.hoverCardParentWindow,
                      event.window === window else { return event }
                // Removing a monitor from inside its own handler is avoided:
                // hide now, retire the monitor on the next turn.
                self.suppressAndHide()
                DispatchQueue.main.async { [weak self] in self?.updateEventMonitor() }
                return event
            }
        } else if !needed, let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Testing

    var isPendingForTesting: Bool { showTimer != nil }
    var hasEventMonitorForTesting: Bool { eventMonitor != nil }
    var panelForTesting: NSPanel? { panel }
}
