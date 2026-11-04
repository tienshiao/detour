import Foundation
import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "ext-popup")

/// Presents an extension's popup in an NSPopover.
///
/// For user-initiated clicks: `show()` calls `userGesturePerformed(in:)` to register the
/// user gesture (needed for `activeTab`), then presents the popup directly.
/// The delegate `presentActionPopup` handles extension-initiated opens (`browser.action.openPopup()`).
///
/// Sizing (TASK-220): WebKit lays an action popup out at its own content size
/// (size-to-content autosizing, capped at 800×600) whatever the web view's
/// frame, and reports that size as the web view's `intrinsicContentSize` — the
/// size WebKit's own popup popover uses. The popover follows it through Auto
/// Layout: the web view is sized by its intrinsic size within the popover's
/// limits, and `PopupContentView` hands each new size to the popover. Nothing
/// is injected into the page, so the size survives the reload `show` does and
/// any navigation inside the popup.
///
/// Scrolling (TASK-150): in that size-to-content mode WebKit never scrolls
/// the page, so content taller than the popover could not be reached. A popup
/// whose content reaches the popover's maximum height has the mode switched
/// off while it is presented: the web view is held at the popover's size and
/// the page scrolls inside it (`updatePageScrolling`).
class ExtensionPopoverController: NSObject, NSPopoverDelegate, WKUIDelegate {
    let extensionID: String
    private var popover: NSPopover?
    private(set) weak var popupWebView: WKWebView?

    /// The popups on screen, however they were opened — a toolbar click, the
    /// Extensions menu or `action.openPopup()` — for `runtime.getContexts`
    /// (TASK-132.9). Weak; main thread only.
    private static let presented = NSHashTable<ExtensionPopoverController>.weakObjects()

    /// The controllers whose popover is showing.
    static var presentedPopups: [ExtensionPopoverController] {
        presented.allObjects.filter { $0.popover != nil && $0.popupWebView != nil }
    }

    /// The browser window the popover is attached to.
    var hostWindow: NSWindow? { positioningView?.window }

    static let minSize = NSSize(width: 100, height: 100)
    static let maxSize = NSSize(width: 800, height: 600)
    /// For a web view that reports no content size yet: a page that has not
    /// laid out by the timeout.
    static let fallbackSize = NSSize(width: 360, height: 480)

    /// How long a popup page may take to finish loading before the popover is
    /// shown anyway; it then follows the page's size as it lays out.
    private static let presentTimeout: TimeInterval = 0.5

    private weak var positioningView: NSView?
    private var positioningRect: NSRect = .zero
    private var preferredEdge: NSRectEdge = .maxY

    private var loadingObservation: NSKeyValueObservation?
    private var presentTimeoutWork: DispatchWorkItem?
    /// The size constraints put on the popup web view while it is presented;
    /// removed on close, since WebKit keeps the web view for the next open.
    private var webViewConstraints: [NSLayoutConstraint] = []
    /// The size the web view is held at while its page scrolls (TASK-150):
    /// WebKit no longer sizes it then.
    private var scrollingConstraints: [NSLayoutConstraint] = []
    /// The view this controller put the popup web view in. Another controller
    /// may take the web view while this popover is still closing (the Quick
    /// Detour closes the previous popup as it opens the next, and an
    /// `action.openPopup()` can arrive while a toolbar popup is up), so the
    /// close detaches the web view only from here.
    private weak var hostView: NSView?

    /// Called when the popover closes. Used by ExtensionManager to clean up retention and call completion handlers.
    var onClose: (() -> Void)?

    /// The profile whose context the button belongs to, and the tab it acts
    /// on. Nil: the key window's — a Quick Detour window passes its own
    /// (TASK-193.1), whose profile need not be the last active space's.
    private let profile: Profile?
    private let explicitTab: BrowserTab?

    init(extensionID: String, profile: Profile? = nil, tab: BrowserTab? = nil) {
        self.extensionID = extensionID
        self.profile = profile
        self.explicitTab = tab
        super.init()
    }

    /// Set positioning without triggering the action (used by the delegate fallback path).
    func setPositioning(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge = .maxY) {
        self.positioningView = positioningView
        self.positioningRect = positioningRect
        self.preferredEdge = preferredEdge
    }

    /// Show the extension popup for a user-initiated toolbar button click.
    ///
    /// `window` is the browser window the click was in — the key window,
    /// unless a caller (a test) names another. A controller made with a
    /// profile (a Quick Detour window) uses that profile's context; otherwise
    /// the clicked window's profile's, falling back to the manager's.
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge = .maxY,
              in window: BrowserWindowController? = nil) {
        let windowController = window ?? (NSApp.keyWindow?.windowController as? BrowserWindowController)
        let context = profile.map { $0.extensionContext(for: extensionID) }
            ?? windowController?.activeSpace?.profile?.extensionContext(for: extensionID)
            ?? ExtensionManager.shared.context(for: extensionID)
        guard let context else {
            finishWithoutPresenting()
            return
        }

        self.positioningView = positioningView
        self.positioningRect = positioningRect
        self.preferredEdge = preferredEdge

        // The page the user is looking at, which is a presented Peek when one
        // is up — so an activeTab grant and the popup's own tab both name the
        // peek, not the host behind it (TASK-51).
        let tab = explicitTab
            ?? window?.extensionActiveTab
            ?? (NSApp.keyWindow?.windowController as? (any ExtensionListedWindow))?.extensionActiveTab

        // Record the user gesture so activeTab permission grants work.
        if let tab {
            context.userGesturePerformed(in: tab)
        }

        // A side panel the extension opens in answer to this click may take
        // keyboard focus, and with `openPanelOnActionClick` the click is the
        // panel's toggle and nothing else (TASK-132.8). Side panels live in
        // browser windows only.
        if explicitTab == nil, let windowController, let profile = windowController.activeSpace?.profile,
           profile.extensionContext(for: extensionID) === context {
            profile.sidePanels.noteUserGesture(extensionID: extensionID)
            if profile.sidePanels.handleActionClick(extensionID: extensionID, tab: tab, window: windowController) {
                finishWithoutPresenting()
                return
            }
        }

        let action = context.action(for: tab)

        // Explicit present path: the user clicked the toolbar button, so creating
        // and loading the popup web view here is what they asked for (TASK-55).
        if let action, action.presentsPopup, let webView = action.popupWebView {
            webView.reload()
            presentPopupWebView(webView)
        } else {
            // No popup — fire browser.action.onClicked
            context.performAction(for: tab)
            finishWithoutPresenting()
        }
    }

    /// Called by ExtensionManager's delegate for extension-initiated popup opens
    /// (e.g. `browser.action.openPopup()` from background script).
    func presentPopupWebView(_ webView: WKWebView) {
        self.popupWebView = webView
        // WebKit builds the popup view, but Detour is what puts it on screen,
        // so it is a page the user is being shown and never the extension's
        // background page (TASK-66).
        ExtensionPageHostRegistry.register(webView)
        webView.uiDelegate = self
        // A predecessor may have left this web view scrolling (its popover's
        // close outlasted a quick re-click, or never came): the page about to
        // be shown is WebKit's to size first (TASK-150).
        NSLayoutConstraint.deactivate(webView.constraints.filter { $0.identifier == Self.scrollingHoldIdentifier })
        setPageScrolls(false, in: webView)

        // Until the page has loaded, the web view's content size is the
        // previous document's — about:blank's 16×8 right after `show`'s
        // reload. Present once it has, or after a timeout.
        guard webView.isLoading else {
            presentPopover()
            return
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            // The change's value, not `webView.isLoading`: the handler is not
            // main-actor isolated (WebKit changes the property on the main thread).
            guard change.newValue == false else { return }
            DispatchQueue.main.async { self?.presentPopover() }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.presentPopover() }
        presentTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.presentTimeout, execute: timeout)
    }

    func close() {
        if let popover {
            popover.close()
        } else if loadingObservation != nil || presentTimeoutWork != nil {
            // Closed while waiting for the page: it must not appear later
            // (the Quick Detour closes the previous popup when it opens the
            // next), and whoever waits for the close is told now.
            cancelPendingPresentation()
            finishWithoutPresenting()
        }
    }

    /// Reports a popup that will never be presented as closed, so whoever
    /// waits for the close (an `openPopup()` completion handler, an owner's
    /// bookkeeping, the address bar keeping its buttons up for the popover)
    /// is not left waiting. Also for a click that put no popover on screen: a
    /// side panel toggle or an `action.onClicked`.
    private func finishWithoutPresenting() {
        popupWebView = nil
        onClose?()
        onClose = nil
    }

    /// The presented popover's content size; nil until it is shown. For tests.
    var presentedContentSize: NSSize? { popover?.contentSize }

    // MARK: - Sizing

    /// `size` held to the popover's limits.
    static func clampedPopoverSize(_ size: NSSize) -> NSSize {
        NSSize(width: min(max(size.width, minSize.width), maxSize.width),
               height: min(max(size.height, minSize.height), maxSize.height))
    }

    /// The popup web view's content size as WebKit reports it, held to the
    /// popover's limits; `fallbackSize` while it reports none.
    private static func contentSize(of webView: WKWebView) -> NSSize {
        let intrinsic = webView.intrinsicContentSize
        guard intrinsic.width > 0, intrinsic.height > 0 else { return fallbackSize }
        return clampedPopoverSize(intrinsic)
    }

    // MARK: - Popover Presentation

    private func cancelPendingPresentation() {
        loadingObservation = nil
        presentTimeoutWork?.cancel()
        presentTimeoutWork = nil
    }

    private func presentPopover() {
        cancelPendingPresentation()
        guard let wv = popupWebView, popover == nil else { return }
        // The anchor went away while the page loaded (its window closed), or
        // there never was one: nothing to present from.
        guard let posView = positioningView else {
            finishWithoutPresenting()
            return
        }

        let size = Self.contentSize(of: wv)
        let container = PopupContentView(frame: NSRect(origin: .zero, size: size))
        wv.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        hostView = container
        // Pinned at the top leading corner only: the web view's size comes
        // from its intrinsic size within the limits, and the container (the
        // popover's content) follows the web view, never the reverse.
        // The fallback size is the weakest wish: it only decides while the
        // web view reports no intrinsic size, which would leave it ambiguous.
        let fallbackWidth = wv.widthAnchor.constraint(equalToConstant: Self.fallbackSize.width)
        let fallbackHeight = wv.heightAnchor.constraint(equalToConstant: Self.fallbackSize.height)
        fallbackWidth.priority = .fittingSizeCompression
        fallbackHeight.priority = .fittingSizeCompression
        let sizeConstraints = [
            wv.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minSize.width),
            wv.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxSize.width),
            wv.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minSize.height),
            wv.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxSize.height),
            fallbackWidth, fallbackHeight,
        ]
        webViewConstraints = sizeConstraints
        NSLayoutConstraint.activate(sizeConstraints + [
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ])
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            wv.setContentHuggingPriority(.defaultHigh, for: orientation)
            wv.setContentCompressionResistancePriority(.defaultHigh, for: orientation)
        }
        wv.frame = NSRect(origin: .zero, size: size)

        let viewController = NSViewController()
        viewController.view = container

        let pop = NSPopover()
        pop.contentViewController = viewController
        pop.contentSize = size
        pop.behavior = .semitransient
        pop.delegate = self
        self.popover = pop

        container.onWebViewSizeChange = { [weak self, weak pop] newSize in
            guard let self, let pop, self.popover === pop, pop.contentSize != newSize else { return }
            pop.contentSize = newSize
        }
        // Every layout, not only a size change: a web view held at the
        // maximum height can report content that reaches it without its
        // frame changing.
        container.onLayout = { [weak self, weak pop, weak wv] in
            guard let self, let pop, let wv, self.popover === pop else { return }
            self.updatePageScrolling(wv)
        }

        pop.show(relativeTo: positioningRect, of: posView, preferredEdge: preferredEdge)
        Self.presented.add(self)
        updatePageScrolling(wv)
    }

    // MARK: - Page scrolling (TASK-150)

    /// Whether a popup whose content WebKit reports as `contentHeight` tall,
    /// in a size-to-content mode capped at `maximumHeight`, has to scroll.
    /// WebKit caps the reported height at the maximum, so reaching it means
    /// the content may be taller; content of exactly the maximum scrolls too,
    /// which costs nothing (it fits, so there is nothing to scroll).
    static func pageScrolls(contentHeight: CGFloat, maximumHeight: CGFloat) -> Bool {
        contentHeight > 0 && contentHeight >= maximumHeight
    }

    /// Switch the presented popup to scrolling once its content reaches the
    /// size-to-content maximum: hold the web view at its current width and
    /// the maximum height, then turn WebKit's size-to-content mode off. It
    /// stays scrolling until the popover closes — with the mode off WebKit no
    /// longer reports the content's size, so a page that shrinks back keeps
    /// the maximum height.
    private func updatePageScrolling(_ webView: WKWebView) {
        guard popover != nil, webView.uiDelegate === self, !Self.isPageScrolling(webView),
              Self.pageScrolls(contentHeight: webView.intrinsicContentSize.height,
                               maximumHeight: Self.maxSize.height) else { return }
        let size = Self.contentSize(of: webView)
        let held = [
            webView.widthAnchor.constraint(equalToConstant: size.width),
            webView.heightAnchor.constraint(equalToConstant: Self.maxSize.height),
        ]
        for constraint in held { constraint.identifier = Self.scrollingHoldIdentifier }
        NSLayoutConstraint.activate(held)
        guard setPageScrolls(true, in: webView) else {
            NSLayoutConstraint.deactivate(held)
            return
        }
        scrollingConstraints = held
    }

    /// Marks the constraints that hold a scrolling popup's web view, so the
    /// next presentation can find them when the previous popover has not
    /// finished closing.
    private static let scrollingHoldIdentifier = "ExtensionPopoverController.scrollingHold"

    /// WebKit's private setter for the popup web view's size-to-content mode,
    /// and the KVC key that reaches it.
    static let sizeToContentSetter = NSSelectorFromString("_setSizeToContentAutoSizeMaximumSize:")
    static let sizeToContentKey = "sizeToContentAutoSizeMaximumSize"

    /// The popup web views whose size-to-content mode Detour has switched off.
    /// Kept per web view, not per controller: WebKit hands the same web view
    /// out for every presentation and each presentation gets a new controller,
    /// so the mode is the view's. Main thread only.
    private static let scrollingPopups = NSHashTable<WKWebView>.weakObjects()

    static func isPageScrolling(_ webView: WKWebView) -> Bool {
        scrollingPopups.contains(webView)
    }

    /// The maximum WebKit builds an action popup's web view with
    /// (`maximumPopoverWidth` x `maximumPopoverHeight` in WebKit's
    /// WebExtensionActionCocoa.mm) — the popover's own limits. The getter is
    /// not used for it: on macOS 26.7 it answers 0 x 0 for a popup WebKit is
    /// plainly sizing to its content. The mode is given back with it.
    static let webKitSizeToContentMaximum = maxSize

    /// What switches the mode off: a zero height turns size-to-content off
    /// in the web process, and the nonzero width keeps WebKit's UI process
    /// from dropping the web view's intrinsic size, as a zero width does
    /// (`WebPageProxy::setSizeToContentAutoSizeMaximumSize`). Dropped, it
    /// would not come back when the mode is switched on again: the web
    /// process only sends a size that differs from the last one it sent
    /// (`WebPage::m_lastSentIntrinsicContentSize`), so a popup reopened with
    /// the same content would open at `fallbackSize`.
    static let sizeToContentOff = NSSize(width: maxSize.width, height: 0)

    /// Switch a popup web view's size-to-content mode off
    /// (`sizeToContentOff`) or back on. False — and nothing touched — when this WebKit has no setter.
    @discardableResult
    static func setSizeToContentMaximum(_ maximum: NSValue, on webView: NSObject) -> Bool {
        guard webView.responds(to: sizeToContentSetter) else { return false }
        webView.setValue(maximum, forKey: sizeToContentKey)
        return true
    }

    /// Make the popup's page scroll inside the popover, or hand its layout back
    /// to WebKit. True when the view is now in the mode asked for.
    ///
    /// WebKit builds an action's popup web view in a size-to-content mode
    /// (`_sizeToContentAutoSizeMaximumSize`, 800 x 600) in which the page never
    /// scrolls: the host is expected to give the view the content's size.
    /// Measured with a popup of 3456 pt of content in the popover's 600 pt:
    /// `window.scrollTo` is a no-op, a wheel does nothing, and everything below
    /// the fold cannot be reached. Giving the view the full height does not
    /// help either — WebKit keeps a 600 pt viewport and hit-tests nothing
    /// below it. So while the content overflows the mode is switched off: the
    /// view keeps the popover's size and the page scrolls inside it like any
    /// other page, as Chrome's popup does at its own 800 x 600 limit. On a
    /// WebKit without the setter the popup is left as it was (cut off at
    /// 600 pt), and the log says so.
    @discardableResult
    func setPageScrolls(_ scrolls: Bool, in webView: WKWebView) -> Bool {
        guard scrolls != Self.scrollingPopups.contains(webView) else { return true }
        let maximum = scrolls ? Self.sizeToContentOff : Self.webKitSizeToContentMaximum
        guard Self.setSizeToContentMaximum(NSValue(size: maximum), on: webView) else {
            log.notice("The popup of \(self.extensionID, privacy: .public) is taller than the popover and cannot be made to scroll: this WebKit has no _setSizeToContentAutoSizeMaximumSize:")
            return false
        }
        if scrolls {
            Self.scrollingPopups.add(webView)
        } else {
            Self.scrollingPopups.remove(webView)
        }
        return true
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        NSLayoutConstraint.deactivate(webViewConstraints + scrollingConstraints)
        webViewConstraints = []
        scrollingConstraints = []
        // WebKit hands the same web view out for the next presentation, so give
        // its layout back — unless that presentation has already begun: a
        // popover's close animation outlasts a quick reload, and by then the
        // view (and its mode) belongs to the controller that took it over.
        if let popupWebView, popupWebView.uiDelegate === self { setPageScrolls(false, in: popupWebView) }
        if let wv = popupWebView, let hostView, wv.superview === hostView {
            wv.removeFromSuperview()
            wv.translatesAutoresizingMaskIntoConstraints = true
        }
        hostView = nil
        popupWebView = nil
        popover = nil
        Self.presented.remove(self)
        onClose?()
        onClose = nil
    }

    // MARK: - WKUIDelegate

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }
}

/// The popover's content: hosts the popup web view at its top leading corner
/// and reports the web view's size whenever Auto Layout changes it — which it
/// does when WebKit invalidates the web view's intrinsic content size.
private final class PopupContentView: NSView {
    var onWebViewSizeChange: ((NSSize) -> Void)?
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let webView = subviews.first else { return }
        if onLayout != nil {
            DispatchQueue.main.async { [weak self] in self?.onLayout?() }
        }
        let size = webView.frame.size
        guard size.width > 0, size.height > 0, size != bounds.size else { return }
        // Not from inside the layout pass: resizing the popover lays it out again.
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, let webView, webView.superview === self else { return }
            self.onWebViewSizeChange?(webView.frame.size)
        }
    }
}
