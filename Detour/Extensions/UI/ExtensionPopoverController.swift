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
class ExtensionPopoverController: NSObject, NSPopoverDelegate, WKUIDelegate {
    private let extensionID: String
    private var popover: NSPopover?
    private weak var popupWebView: WKWebView?

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
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge = .maxY) {
        let context = profile.map { $0.extensionContext(for: extensionID) }
            ?? ExtensionManager.shared.context(for: extensionID)
        guard let context else { return }

        self.positioningView = positioningView
        self.positioningRect = positioningRect
        self.preferredEdge = preferredEdge

        // The page the user is looking at, which is a presented Peek when one
        // is up — so an activeTab grant and the popup's own tab both name the
        // peek, not the host behind it (TASK-51).
        let tab = explicitTab
            ?? (NSApp.keyWindow?.windowController as? (any ExtensionListedWindow))?.extensionActiveTab

        // Record the user gesture so activeTab permission grants work.
        if let tab {
            context.userGesturePerformed(in: tab)
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

        // Until the page has loaded, the web view's content size is the
        // previous document's — about:blank's 16×8 right after `show`'s
        // reload. Present once it has, or after a timeout.
        guard webView.isLoading else {
            presentPopover()
            return
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            guard !webView.isLoading else { return }
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
    /// bookkeeping) is not left waiting.
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

        pop.show(relativeTo: positioningRect, of: posView, preferredEdge: preferredEdge)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        NSLayoutConstraint.deactivate(webViewConstraints)
        webViewConstraints = []
        if let wv = popupWebView, let hostView, wv.superview === hostView {
            wv.removeFromSuperview()
            wv.translatesAutoresizingMaskIntoConstraints = true
        }
        hostView = nil
        popupWebView = nil
        popover = nil
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

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let webView = subviews.first else { return }
        let size = webView.frame.size
        guard size.width > 0, size.height > 0, size != bounds.size else { return }
        // Not from inside the layout pass: resizing the popover lays it out again.
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, let webView, webView.superview === self else { return }
            self.onWebViewSizeChange?(webView.frame.size)
        }
    }
}
