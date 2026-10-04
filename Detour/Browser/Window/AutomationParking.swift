import AppKit
import WebKit

// TASK-132.3: keeping a tab drivable while it is not selected.
//
// An extension that is driving a tab (a debugger attachment, a command in
// flight) needs two things from the tab's web view when the tab is not on
// screen: fresh snapshots, and synthesized input that produces trusted events.
// Measured on the shipped WebKit (`.claude/scratch/task132.3-covered-webview-spike.m`):
// snapshots work anywhere, but a web view in NO window loses mouseup/click.
// What input needs is a window, not visibility — a web view that is in a
// window but `isHidden` takes mouse, key and insertText input sent straight to
// the view, while its page stays `visibilityState: hidden` and its WebContent
// process holds no foreground assertion.
//
// So an automation-attached tab that no window displays is *parked*: its
// container sits in a browser window's `AutomationParkingView`, hidden, at the
// content area's size. Nothing is elevated — not this tab's process priority,
// and nothing at all for any other hidden tab.
//
// The pieces:
//   - `BrowserTab.attachAutomation` / `detachAutomation` — the owner set.
//   - `AutomationParking` — settles every attached tab into "displayed" or
//     "parked" after anything that could have changed where it is hosted.
//   - `AutomationParkingView` — the per-window host, which also isolates a
//     parked page from the window's responder chain.
//   - `BrowserWindow` — refuses first responder for a parked view.
//   - `AutomationInput` — sends key events without a declined one coming
//     back into the user's window.

/// Who holds an automation attachment on a tab: opaque to the tab and to the
/// parking machinery, compared by value. One extension can hold several, each
/// for its own reason, and the tab stays attached until all are dropped.
struct TabAutomationOwner: Hashable {
    /// The extension the attachment belongs to.
    let extensionID: String
    /// What it is for — e.g. "debugger", or a command's identifier.
    let reason: String
}

/// Where an automation-attached tab's web view is.
enum TabAutomationHosting: Equatable {
    /// No owner: an ordinary tab.
    case notAttached
    /// A window shows it — as its selected tab, a split pane, or a presented peek.
    case displayed
    /// Hidden in a window's `AutomationParkingView`.
    case parked
    /// Attached, but there is no browser window to keep it in (or the tab has
    /// no web view). Parked as soon as a window can take it.
    case unhosted
}

// MARK: - The parking host

/// Holds the containers of the automation-attached tabs this window is keeping
/// in its view hierarchy without showing them. It fills the content area, at
/// the bottom of its z-order, so a parked container laid out to its bounds has
/// the size the page would have on screen.
///
/// A parked container is hidden. If `AutomationParking.revealsParkedWebViews`
/// is ever switched on the container is not, and this view is what keeps the
/// page off the screen and away from the pointer: it is fully transparent and
/// answers no hit test.
///
/// It is also where a parked page's responder chain ends. A key WebKit's page
/// declines is passed up the chain, where the window controller acts on it
/// (Esc closes the peek) and `BrowserWebView`/the menu act on key
/// equivalents — all of which belong to the page the user is looking at, not
/// to one an extension is typing into behind it.
final class AutomationParkingView: NSView {
    weak var controller: BrowserWindowController?
    /// Edits typed into a parked page register here instead of the window's
    /// undo manager — `TabStore`'s, which Cmd+Z in the browser drives.
    private let parkedUndoManager = UndoManager()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alphaValue = 0
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var undoManager: UndoManager? { parkedUndoManager }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Key equivalents travel down the view tree, and `BrowserWebView` acts on
    // Cmd+Z whether or not it has focus: never offer one to a parked page.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    // The end of the chain: an event a parked page passed up is dropped.
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func doCommand(by selector: Selector) {}
    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool { false }
    override func noResponder(for eventSelector: Selector) {}
}

extension NSView {
    /// Whether this view is, or sits inside, a window's automation parking host.
    var isInAutomationParking: Bool {
        var view: NSView? = self
        while let current = view {
            if current is AutomationParkingView { return true }
            view = current.superview
        }
        return false
    }
}

// MARK: - The window

/// The browser window. Its one job beyond `NSWindow`'s: a parked web view never
/// becomes first responder. WebKit calls `makeFirstResponder(webView)` on every
/// mouse press a web view receives, hidden or not, which would take keyboard
/// focus away from the page the user is typing in every time an extension
/// clicked in a parked tab. Refusing costs the parked page nothing: it takes
/// mouse, key and text input sent straight to its view regardless.
final class BrowserWindow: NSWindow {
    /// How many times a parked view was refused — for tests.
    private(set) var refusedParkedFirstResponderCount = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, view.isInAutomationParking {
            refusedParkedFirstResponderCount += 1
            return false
        }
        return super.makeFirstResponder(responder)
    }
}

// MARK: - Which window parks a tab

/// What `automationParkingWindowIndex` needs to know about a browser window.
struct AutomationParkingCandidate: Equatable {
    let activeSpaceID: UUID?
    let profileID: UUID?
}

/// Which of `candidates` parks a tab that is hosted nowhere, or nil when there
/// is no window. In order of preference:
///
///  1. `preferred` — the window that just stopped displaying the tab, so a
///     parked container follows web view ownership from window to window;
///  2. the first window showing the tab's space — the one that would display it;
///  3. the first window on the tab's profile;
///  4. the first window.
///
/// "First" is the order the caller lists them in (`extensionBrowserWindows()`,
/// i.e. `NSApp.windows`). Which window it is has no visible effect — the
/// container is hidden, and any window that selects the tab claims it — so the
/// rule only has to be stable.
func automationParkingWindowIndex(tabSpaceID: UUID?, tabProfileID: UUID?, preferred: Int?,
                                  candidates: [AutomationParkingCandidate]) -> Int? {
    if let preferred, candidates.indices.contains(preferred) { return preferred }
    if let tabSpaceID, let index = candidates.firstIndex(where: { $0.activeSpaceID == tabSpaceID }) {
        return index
    }
    if let tabProfileID, let index = candidates.firstIndex(where: { $0.profileID == tabProfileID }) {
        return index
    }
    return candidates.isEmpty ? nil : 0
}

// MARK: - The coordinator

/// Keeps every automation-attached tab either displayed or parked.
///
/// `reconcile` is the single place that decides: it is run after an attach,
/// and by every window after anything that could have taken a container out of
/// its content area — a selection change, a claim, an ownership hand-off, a
/// close. It is cheap with nothing attached (one empty-array check), and
/// idempotent.
enum AutomationParking {

    /// The one switch that would raise an attached tab's priority: leave a
    /// parked container un-hidden. WebKit then counts the page as visible — it
    /// runs timers and rendering at full rate and its WebContent process holds
    /// a foreground assertion while the window is on screen — for that tab
    /// only. Off by default and not exposed in the UI: parked pages stay
    /// hidden, at the background priority of any other hidden tab.
    static var revealsParkedWebViews = false {
        didSet {
            guard revealsParkedWebViews != oldValue else { return }
            for tab in attachedTabs() {
                tab.automationParkingHost?.controller?.parkForAutomation(tab)
            }
        }
    }

    private struct WeakTab { weak var tab: BrowserTab? }
    /// Attached tabs, in attach order. Weak: an attachment must not keep a
    /// closed tab alive (`teardown()` drops the owners anyway).
    private static var attached: [WeakTab] = []
    private static var isReconciling = false
    private static var reconcileAgain = false
    private static var reconcileScheduled = false

    private static func attachedTabs() -> [BrowserTab] {
        attached.compactMap(\.tab).filter(\.isAutomationAttached)
    }

    static func tabDidAttach(_ tab: BrowserTab) {
        if !attached.contains(where: { $0.tab === tab }) {
            attached.append(WeakTab(tab: tab))
        }
        reconcile()
    }

    /// The tab's last owner is gone: take it out of parking. A displayed tab is
    /// left exactly where it is.
    static func tabDidDetach(_ tab: BrowserTab) {
        attached.removeAll { $0.tab == nil || $0.tab === tab }
        unpark(tab)
    }

    /// `reconcile()` on the next main-queue turn, coalesced — for callers in
    /// the middle of something (a forced sleep) that must finish first.
    static func setNeedsReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async {
            reconcileScheduled = false
            reconcile()
        }
    }

    /// Wakes every attached tab that is asleep and parks every attached tab
    /// that no window displays. `preferred` is the window asking — the one that
    /// may have just stopped displaying a tab, and so parks it.
    static func reconcile(preferring preferred: BrowserWindowController? = nil) {
        attached.removeAll { $0.tab?.isAutomationAttached != true }
        guard !attached.isEmpty else { return }
        // Waking a tab reports it to the extension contexts, which can come
        // back here; fold that into this pass instead of nesting.
        guard !isReconciling else { reconcileAgain = true; return }
        isReconciling = true
        defer { isReconciling = false }
        var passes = 0
        repeat {
            reconcileAgain = false
            passes += 1
            for tab in attachedTabs() { settle(tab, preferring: preferred) }
        } while reconcileAgain && passes < 4
    }

    /// A window is closing: nothing may stay in it. Its attached tabs — parked
    /// there, or displayed by it — are parked in another window, or left
    /// unhosted until there is one.
    static func windowWillClose(_ controller: BrowserWindowController) {
        for tab in attachedTabs() {
            guard let view = tab.automationHostedView,
                  view.isDescendant(of: controller.contentContainerView) else { continue }
            view.removeFromSuperview()
            view.isHidden = false
        }
        reconcile()
    }

    private static func settle(_ tab: BrowserTab, preferring preferred: BrowserWindowController?) {
        if tab.webView == nil { tab.wake() }
        guard let webView = tab.webView else { return }

        if tab.isHostedForDisplay, !isInClosedBrowserWindow(tab) {
            // A parked peek that was presented again leaves its (now empty)
            // container behind in the host.
            if let container = tab.webViewContainer, container.superview is AutomationParkingView,
               webView.superview !== container {
                container.removeFromSuperview()
                container.isHidden = false
            }
            return
        }
        if let controller = tab.automationParkingHost?.controller, controller.canParkAutomationTabs {
            controller.parkForAutomation(tab)
            return
        }
        guard let controller = parkingWindow(for: tab, preferring: preferred) else {
            unpark(tab)
            return
        }
        controller.parkForAutomation(tab)
    }

    /// The container is still parented in the content area of a window that
    /// has closed (a closed window keeps its views until it is released).
    private static func isInClosedBrowserWindow(_ tab: BrowserTab) -> Bool {
        guard let controller = tab.automationHostedView?.window?.windowController as? BrowserWindowController else {
            return false
        }
        return !controller.canParkAutomationTabs
    }

    private static func parkingWindow(for tab: BrowserTab,
                                      preferring preferred: BrowserWindowController?) -> BrowserWindowController? {
        let windows = extensionBrowserWindows().filter(\.canParkAutomationTabs)
        let index = automationParkingWindowIndex(
            tabSpaceID: tab.spaceID,
            tabProfileID: tab.owningProfile?.id,
            preferred: preferred.flatMap { preferred in windows.firstIndex { $0 === preferred } },
            candidates: windows.map {
                AutomationParkingCandidate(activeSpaceID: $0.activeSpaceID, profileID: $0.activeSpace?.profileID)
            })
        return index.map { windows[$0] }
    }

    private static func unpark(_ tab: BrowserTab) {
        guard let container = tab.webViewContainer, container.superview is AutomationParkingView else { return }
        container.removeFromSuperview()
        container.isHidden = false
    }
}

// MARK: - BrowserTab: where the web view is

extension BrowserTab {
    /// The outermost view a window parents for this tab: its container, or the
    /// bare web view while that is hosted by itself (a presented peek; a page
    /// WebKit has moved into its full-screen window).
    fileprivate var automationHostedView: NSView? {
        guard let webView else { return nil }
        if let container = webViewContainer, webView.superview === container { return container }
        return webView
    }

    /// The parking host holding this tab's container, if it is parked.
    var automationParkingHost: AutomationParkingView? {
        automationHostedView?.superview as? AutomationParkingView
    }

    /// Whether the tab's web view is in a window only to stay drivable.
    var isAutomationParked: Bool { automationParkingHost != nil }

    /// Whether some window is hosting this tab's web view in order to show it —
    /// "has a superview" for every tab that is not parked. What "hosted
    /// somewhere" means to the selection and ownership paths: a parked
    /// container is in a window, but no window is showing it.
    var isHostedForDisplay: Bool {
        guard let superview = automationHostedView?.superview else { return false }
        return !(superview is AutomationParkingView)
    }

    var automationHosting: TabAutomationHosting {
        guard isAutomationAttached else { return .notAttached }
        if isAutomationParked { return .parked }
        if isHostedForDisplay, webView?.window != nil { return .displayed }
        return .unhosted
    }

    /// The web view to snapshot and send synthesized input to: awake, in a
    /// window, laid out at the size the page has (or would have) on screen —
    /// whether a window displays the tab or it is parked. Nil when the tab is
    /// not attached, or when there is no browser window to keep it in.
    ///
    /// Mouse events and text go straight to the view (`webView.mouseDown(with:)`,
    /// `insertText(_:replacementRange:)`) and key events through
    /// `AutomationInput.sendKey(_:to:)`, with events built for
    /// `webView.window`; never through `NSApp.sendEvent` or the window, which
    /// route by first responder and hit testing.
    func automationDrivableWebView() -> WKWebView? {
        guard isAutomationAttached else { return nil }
        AutomationParking.reconcile()
        guard let webView, let window = webView.window else { return nil }
        // A window that has not been laid out yet has no content-area size.
        if webView.bounds.isEmpty { window.layoutIfNeeded() }
        return webView
    }
}

// MARK: - Key input

/// The way to send a synthesized key event to a web view an extension is
/// driving — parked or displayed.
///
/// Why not `webView.keyDown(with:)` directly: a key down the page declines is
/// handed back by WebKit through `NSApp.sendEvent` (`WebViewImpl::doneWithKeyEvent`),
/// as if it had just arrived from the keyboard. AppKit then routes it by the
/// app's key window and its first responder, not by the view it was sent to —
/// so a letter typed at a parked page with nothing focused lands in the field
/// the user is typing in, and a declined Cmd-key fires the main menu's item
/// (measured: `.claude/scratch/task132.3/declined-key-spike.m`). WebKit
/// re-sends the very same `NSEvent`, so key downs sent from here are
/// remembered and a local event monitor — which runs before `sendEvent`
/// dispatches anything — drops them when they come round again. For an
/// extension's key press, "the page declined it" is the end of the story.
///
/// Mouse events and `insertText(_:replacementRange:)` are never re-sent and
/// need no such care: send them straight to the view.
enum AutomationInput {
    /// Key downs in flight, by identity. Weak: WebKit holds the event until
    /// the page has answered, and it is forgotten when it dies.
    private static let drivenKeyDowns = NSHashTable<NSEvent>(options: [.weakMemory, .objectPointerPersonality])
    private static var monitor: Any?
    /// How many declined key downs were dropped — for tests.
    private(set) static var droppedKeyDownCount = 0

    /// Sends a `keyDown`, `keyUp` or `flagsChanged` event to `webView`. Build
    /// the event with `webView.window`'s window number.
    static func sendKey(_ event: NSEvent, to webView: WKWebView) {
        switch event.type {
        case .keyDown:
            installMonitorIfNeeded()
            drivenKeyDowns.add(event)
            webView.keyDown(with: event)
        case .keyUp:
            webView.keyUp(with: event)
        case .flagsChanged:
            webView.flagsChanged(with: event)
        default:
            assertionFailure("AutomationInput.sendKey takes key events, not \(event.type)")
        }
    }

    /// Whether `event` is a key down sent through `sendKey` — which, seen by
    /// an event monitor, means WebKit is handing it back. Other monitors must
    /// leave such an event alone: monitors are not ordered.
    static func isDrivenKeyDown(_ event: NSEvent) -> Bool {
        event.type == .keyDown && drivenKeyDowns.contains(event)
    }

    /// What the monitor does with an event: nil drops it.
    static func filter(_ event: NSEvent) -> NSEvent? {
        guard isDrivenKeyDown(event) else { return event }
        droppedKeyDownCount += 1
        return nil
    }

    private static func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { AutomationInput.filter($0) }
    }
}

// MARK: - BrowserWindowController: parking

extension BrowserWindowController {
    /// Whether this window can keep a parked tab: it has a window, and that
    /// window has not closed.
    var canParkAutomationTabs: Bool { window != nil && !hasClosed }

    /// The tabs parked in this window, bottom to top.
    var automationParkedContainers: [NSView] { automationParkingView.subviews }

    /// Moves `tab`'s container into this window's parking host — hidden, at
    /// the content area's size, following it as it resizes. Idempotent: a
    /// container already parked here is only re-asserted.
    func parkForAutomation(_ tab: BrowserTab) {
        // Also re-wraps a web view that was hosted bare (a peek).
        tab.ensureWebViewContainer()
        guard let container = tab.webViewContainer else { return }
        let host = automationParkingView
        host.frame = contentContainerView.bounds
        let hidden = !AutomationParking.revealsParkedWebViews
        if container.superview !== host {
            // Hidden before it enters the window, so the page is never
            // visible to WebKit on the way in.
            container.isHidden = hidden
            container.removeFromSuperview()
            host.addSubview(container)
        }
        container.isHidden = hidden
        // A pane kept for a PiP capture arrives pinned (`removeContentViews`).
        container.autoresizingMask = [.width, .height]
        container.frame = host.bounds
    }
}
