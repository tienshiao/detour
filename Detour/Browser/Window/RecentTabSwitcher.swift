import AppKit
import Carbon.HIToolbox

/// Control+Tab most-recently-used tab switching for one window (TASK-108),
/// Cmd+Tab style: Control+Tab (Shift to reverse) moves a highlight through
/// the space's recently used tabs, releasing Control switches to it, Escape
/// cancels. The overlay only appears once Control has been held briefly, so a
/// quick tap flips straight to the previous tab without flashing it.
///
/// Keys are taken with a local event monitor, ahead of the responder chain,
/// so neither web content nor a focused text field ever sees them.
@MainActor
final class RecentTabSwitcher {

    struct Entry {
        /// The item's tabs in visual order (a split's left pane first).
        let tabs: [BrowserTab]
        /// The tab to select when this entry is chosen.
        let focusTabID: UUID
        /// Whether this is the window's current item (always the first entry
        /// when present; absent when the window has no selection).
        var isCurrent = false
        /// The tab whose Peek comes back over this item when it is chosen:
        /// the pane that gets focus, if it has one (TASK-173).
        var peekHost: BrowserTab?
    }

    /// The switchable items, current first (see `recentTabOrder`).
    var entries: () -> [Entry] = { [] }
    /// Refreshes the visible tab's preview before the overlay shows it.
    var willBegin: () -> Void = {}
    var didChoose: (Entry) -> Void = { _ in }

    /// How long Control+Tab must be held before the overlay appears.
    static let revealDelay: TimeInterval = 0.15

    private weak var window: NSWindow?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var state: RecentTabSwitcherState?
    private var list: [Entry] = []
    private var overlay: RecentTabSwitcherView?
    private var revealWork: DispatchWorkItem?

    var isActive: Bool { state != nil }

    init(window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { RecentTabSwitcher.monitorResult(for: event, switcher: self) }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    /// Removes the event monitor; call when the window closes.
    func invalidate() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    // MARK: - Events

    /// What the local monitor returns for `event`: nil swallows it, the event
    /// lets it continue to the key window. A switcher that is gone passes
    /// everything through. Not `switcher?.handle(event) ?? event`: optional
    /// chaining flattens `handle`'s nil ("swallow") into the same nil as a
    /// missing switcher, and `??` then hands the swallowed key back (TASK-133).
    static func monitorResult(for event: NSEvent, switcher: RecentTabSwitcher?) -> NSEvent? {
        guard let switcher else { return event }
        return switcher.handle(event)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        // A key an extension sent to a page, declined and handed back by
        // WebKit, is not the user's: `AutomationInput`'s monitor drops it
        // (TASK-132.3), whichever of the two runs first.
        guard !AutomationInput.isDrivenKeyDown(event) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if event.type == .flagsChanged {
            if isActive, !modifiers.contains(.control) { commit() }
            return event
        }

        if Int(event.keyCode) == kVK_Tab, modifiers.subtracting(.shift) == .control {
            let backward = modifiers.contains(.shift)
            if state == nil {
                begin(backward: backward)
            } else {
                move(backward: backward)
            }
            // Ours even when there is nothing to switch to.
            return nil
        }

        guard isActive else { return event }
        switch Int(event.keyCode) {
        case kVK_Escape: cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter: commit()
        case kVK_LeftArrow: move(backward: true)
        case kVK_RightArrow: move(backward: false)
        default: break
        }
        // Nothing typed while switching reaches the page.
        return nil
    }

    // MARK: - Switching

    private func begin(backward: Bool) {
        willBegin()
        list = entries()
        guard let initial = RecentTabSwitcherState(count: list.count, backward: backward,
                                                   hasCurrent: list.first?.isCurrent == true) else {
            list = []
            return
        }
        state = initial
        let work = DispatchWorkItem { [weak self] in self?.showOverlay() }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay, execute: work)
    }

    private func move(backward: Bool) {
        state?.advance(backward: backward)
        overlay?.highlightedIndex = state?.index ?? 0
    }

    private func highlight(_ index: Int) {
        state?.highlight(index)
        overlay?.highlightedIndex = state?.index ?? 0
    }

    private func commit() {
        guard let index = state?.index, index < list.count else { return cancel() }
        let entry = list[index]
        end()
        didChoose(entry)
    }

    /// A preview arrived (captures are asynchronous): refresh the open overlay.
    func previewDidChange() {
        overlay?.reloadPreviews()
    }

    func cancel() {
        guard isActive else { return }
        end()
    }

    private func end() {
        state = nil
        list = []
        revealWork?.cancel()
        revealWork = nil
        overlay?.removeFromSuperview()
        overlay = nil
    }

    private func showOverlay() {
        revealWork = nil
        guard let state, overlay == nil, let host = window?.contentView else { return }
        let view = RecentTabSwitcherView(entries: list)
        view.highlightedIndex = state.index
        view.onHover = { [weak self] index in self?.highlight(index) }
        view.onClick = { [weak self] index in
            self?.highlight(index)
            self?.commit()
        }
        view.onClickOutside = { [weak self] in self?.cancel() }
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        overlay = view
    }
}

// MARK: - Overlay

/// The switcher's panel: a centred row of cards (page preview, favicon,
/// title). Cards shrink to fit the window, then the row scrolls to keep the
/// highlight in view.
@MainActor
final class RecentTabSwitcherView: NSView {

    var onHover: (Int) -> Void = { _ in }
    var onClick: (Int) -> Void = { _ in }
    var onClickOutside: () -> Void = {}

    var highlightedIndex: Int = 0 {
        didSet { updateHighlight() }
    }

    private let panel = GlassContainerView(cornerRadius: 18)
    private let scrollView = NSScrollView()
    private let row = FlippedRowView()
    private var cards: [RecentTabCardView] = []
    private var panelWidth: NSLayoutConstraint!
    private var rowHeight: NSLayoutConstraint!

    private static let padding: CGFloat = 16
    private static let spacing: CGFloat = 12
    private static let maxCardWidth: CGFloat = 200
    private static let minCardWidth: CGFloat = 120

    init(entries: [RecentTabSwitcher.Entry]) {
        super.init(frame: .zero)
        cards = entries.enumerated().map { index, entry in
            let card = RecentTabCardView(tabs: entry.tabs, peekHost: entry.peekHost)
            card.onHover = { [weak self] in self?.onHover(index) }
            card.onClick = { [weak self] in self?.onClick(index) }
            return card
        }
        cards.forEach(row.addSubview)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = row
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(panel)
        panel.contentView.addSubview(scrollView)
        panelWidth = panel.widthAnchor.constraint(equalToConstant: 0)
        rowHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelWidth,
            rowHeight,
            scrollView.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: Self.padding),
            scrollView.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -Self.padding),
            scrollView.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: Self.padding),
            scrollView.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -Self.padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        let count = CGFloat(max(cards.count, 1))
        let available = max(bounds.width - 80 - 2 * Self.padding, Self.minCardWidth)
        let fitted = (available - (count - 1) * Self.spacing) / count
        let cardWidth = min(Self.maxCardWidth, max(Self.minCardWidth, fitted))
        let cardSize = RecentTabCardView.size(forWidth: cardWidth)
        let rowWidth = count * cardWidth + (count - 1) * Self.spacing

        for (index, card) in cards.enumerated() {
            card.frame = NSRect(x: CGFloat(index) * (cardWidth + Self.spacing), y: 0,
                                width: cardSize.width, height: cardSize.height)
        }
        row.frame = NSRect(x: 0, y: 0, width: rowWidth, height: cardSize.height)
        panelWidth.constant = min(rowWidth, available) + 2 * Self.padding
        rowHeight.constant = cardSize.height
        super.layout()
        scrollHighlightIntoView()
    }

    func reloadPreviews() {
        cards.forEach { $0.reloadPreviews() }
    }

    private func updateHighlight() {
        for (index, card) in cards.enumerated() {
            card.isHighlighted = index == highlightedIndex
        }
        scrollHighlightIntoView()
    }

    private func scrollHighlightIntoView() {
        guard highlightedIndex < cards.count else { return }
        row.scrollToVisible(cards[highlightedIndex].frame.insetBy(dx: -Self.spacing, dy: 0))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point) { onClickOutside() }
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }

    // The overlay owns the pointer while it is up.
    override func scrollWheel(with event: NSEvent) {}
}

private final class FlippedRowView: NSView {
    override var isFlipped: Bool { true }
}

/// One switcher card. A split shows both panes side by side. A tab that comes
/// back with a Peek shows it as on screen: the page dimmed, the Peek in a
/// panel over it (TASK-173).
@MainActor
private final class RecentTabCardView: NSView {

    var onHover: () -> Void = {}
    var onClick: () -> Void = {}

    var isHighlighted = false {
        didSet { layer?.backgroundColor = isHighlighted ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.55).cgColor : nil }
    }

    private static let inset: CGFloat = 6
    private static let titleHeight: CGFloat = 22

    static func size(forWidth width: CGFloat) -> NSSize {
        let previewHeight = (width - 2 * inset) * 0.625
        return NSSize(width: width, height: previewHeight + titleHeight + 2 * inset)
    }

    private let tabs: [BrowserTab]
    private let peekHost: BrowserTab?
    private let previews: [CALayer]
    private let previewFrame = CALayer()
    private let peekDim = CALayer()
    private let peekPanel = CALayer()
    private let fallbackIcon = NSImageView()
    private let peekFallbackIcon = NSImageView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")

    init(tabs: [BrowserTab], peekHost: BrowserTab?) {
        self.tabs = tabs
        self.peekHost = peekHost
        previews = tabs.map { _ in
            let layer = CALayer()
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            return layer
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12

        previewFrame.cornerRadius = 8
        previewFrame.masksToBounds = true
        previewFrame.backgroundColor = NSColor.textBackgroundColor.cgColor
        previews.forEach(previewFrame.addSublayer)
        if peekHost != nil {
            peekDim.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            peekPanel.cornerRadius = 4
            peekPanel.masksToBounds = true
            peekPanel.contentsGravity = .resizeAspectFill
            peekPanel.backgroundColor = NSColor.textBackgroundColor.cgColor
            previewFrame.addSublayer(peekDim)
            previewFrame.addSublayer(peekPanel)
        }
        layer?.addSublayer(previewFrame)

        let lead = tabs.first
        // Shown while a card has no preview at all (a failed capture).
        fallbackIcon.image = lead?.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        fallbackIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(fallbackIcon)
        if let peekHost {
            // Shown while the Peek has no picture (parked before it was ever
            // left on screen, or a failed capture).
            peekFallbackIcon.image = peekHost.displayPeekFavicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            peekFallbackIcon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(peekFallbackIcon)
        }
        reloadPreviews()

        icon.image = lead?.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        title.stringValue = tabs.map(\.title).joined(separator: " | ")
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    func reloadPreviews() {
        for (layer, tab) in zip(previews, tabs) {
            layer.contents = tab.switcherPreview
        }
        let peekPreview = peekHost?.peekTab?.switcherPreview
        peekPanel.contents = peekPreview
        peekFallbackIcon.isHidden = peekPreview != nil
        // The panel covers the middle of the card, where this icon sits.
        fallbackIcon.isHidden = peekHost != nil || tabs.contains { $0.switcherPreview != nil }
    }

    /// The Peek's panel within the card's preview. The real one is inset 64 pt
    /// at the sides and 12 pt above and below, which at card size would be a
    /// hairline; these proportions keep it reading as a panel over the page.
    static func peekPanelFrame(in preview: NSRect) -> NSRect {
        preview.insetBy(dx: (preview.width * 0.1).rounded(), dy: (preview.height * 0.07).rounded())
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let previewRect = NSRect(x: inset, y: inset, width: bounds.width - 2 * inset,
                                 height: bounds.height - 2 * inset - Self.titleHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewFrame.frame = previewRect
        let paneWidth = previewRect.width / CGFloat(max(previews.count, 1))
        for (index, pane) in previews.enumerated() {
            // One point of gutter between split panes.
            pane.frame = NSRect(x: CGFloat(index) * paneWidth, y: 0,
                                width: paneWidth - (index < previews.count - 1 ? 1 : 0), height: previewRect.height)
        }
        // Over both panes of a split, as the overlay is.
        peekDim.frame = previewFrame.bounds
        peekPanel.frame = Self.peekPanelFrame(in: previewFrame.bounds)
        CATransaction.commit()
        fallbackIcon.frame = NSRect(x: previewRect.midX - 16, y: previewRect.midY - 16, width: 32, height: 32)
        peekFallbackIcon.frame = fallbackIcon.frame

        let titleY = previewRect.maxY + 4
        icon.frame = NSRect(x: inset, y: titleY + 1, width: 16, height: 16)
        title.frame = NSRect(x: inset + 20, y: titleY, width: bounds.width - 2 * inset - 20, height: 18)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Moves only: a card that appears under a resting pointer must not
        // steal the keyboard's highlight.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onHover() }
    override func mouseDown(with event: NSEvent) { onClick() }
    // Control is held while switching, so a click arrives as a secondary click.
    override func rightMouseDown(with event: NSEvent) { onClick() }
}
