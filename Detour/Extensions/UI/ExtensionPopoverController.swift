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
class ExtensionPopoverController: NSObject, NSPopoverDelegate, WKScriptMessageHandler, WKUIDelegate {
    private let extensionID: String
    private var popover: NSPopover?
    private weak var popupWebView: WKWebView?

    static let maxWidth: CGFloat = 800
    static let maxHeight: CGFloat = 600
    private static let defaultSize = NSSize(width: 360, height: 480)

    private weak var positioningView: NSView?
    private var positioningRect: NSRect = .zero
    private var preferredEdge: NSRectEdge = .maxY

    /// Called when the popover closes. Used by ExtensionManager to clean up retention and call completion handlers.
    var onClose: (() -> Void)?

    init(extensionID: String) {
        self.extensionID = extensionID
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
        guard let context = ExtensionManager.shared.context(for: extensionID) else { return }

        self.positioningView = positioningView
        self.positioningRect = positioningRect
        self.preferredEdge = preferredEdge

        // The page the user is looking at, which is a presented Peek when one
        // is up — so an activeTab grant and the popup's own tab both name the
        // peek, not the host behind it (TASK-51).
        let tab = (NSApp.keyWindow?.windowController as? BrowserWindowController)?.extensionActiveTab

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

        // Measure and present once the page has loaded (TASK-150).
        waitForLoad(of: webView, since: Date())
    }

    /// How long the popup's page gets to finish loading before the popover is
    /// shown regardless, and how often that is checked.
    static let loadWait: TimeInterval = 1.5
    private static let loadPollInterval: TimeInterval = 0.05

    /// Whether to measure now: the page has loaded, or it has had its time.
    static func shouldMeasure(isLoading: Bool, waited: TimeInterval) -> Bool {
        !isLoading || waited >= loadWait
    }

    /// `show` reloads the popup, and the page has to be measured — and its
    /// resize observer installed — in the document that reload ends with.
    /// Measuring a fixed 50 ms after `reload()` instead (as this did) depends
    /// on timing, and both outcomes were seen with one popup (TASK-150):
    ///  - the measurement lands in the document the reload then replaces: the
    ///    resize observer is lost with it, and a popup measured while still
    ///    empty stays 100 x 100;
    ///  - it lands in the old, complete document: the view is held to 600 pt
    ///    before the page loads into it, and WebKit then never scrolls it.
    /// A page still loading after `loadWait` is presented anyway and measured
    /// again when it has loaded.
    private func waitForLoad(of webView: WKWebView, since start: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadPollInterval) { [weak self, weak webView] in
            guard let self, let webView, self.popupWebView === webView else { return }
            let loading = webView.isLoading
            guard Self.shouldMeasure(isLoading: loading, waited: Date().timeIntervalSince(start)) else {
                self.waitForLoad(of: webView, since: start)
                return
            }
            self.measureAndPresent()
            if loading { self.remeasureWhenLoaded(webView, since: Date()) }
        }
    }

    /// For a page that was presented before it finished loading: once it has,
    /// size the popover to it and install the resize observer in its document.
    private func remeasureWhenLoaded(_ webView: WKWebView, since start: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadPollInterval * 4) { [weak self, weak webView] in
            guard let self, let webView, self.popupWebView === webView else { return }
            if webView.isLoading {
                // Give up on a page that never finishes; it keeps what it has.
                if Date().timeIntervalSince(start) < 30 { self.remeasureWhenLoaded(webView, since: start) }
                return
            }
            webView.evaluateJavaScript(Self.measureFnJS) { _, _ in
                webView.evaluateJavaScript(Self.measureJS) { [weak self] result, _ in
                    guard let self, self.popupWebView === webView else { return }
                    if let sizing = (result as? String).flatMap({
                        Self.parseSizing(from: $0, pageScrollsNow: self.pageScrolls)
                    }) {
                        self.apply(sizing)
                    }
                    self.installResizeObserver()
                }
            }
        }
    }

    func close() {
        popover?.close()
    }

    // MARK: - Content Measurement

    /// Shared measurement function injected once, called by both initial measure and resize observer.
    static let measureFnJS = """
    window.__detourMeasureBody = function() {
        const body = document.body;
        if (!body) return {width: 0, height: 0};
        const doc = document.documentElement;
        const style = window.getComputedStyle(body);
        const marginV = parseFloat(style.marginTop) + parseFloat(style.marginBottom);
        const height = Math.ceil(Math.max(body.offsetHeight, body.scrollHeight, doc.scrollHeight) + marginV);
        return {
            width: Math.ceil(Math.max(body.scrollWidth, doc.scrollWidth)),
            height: height,
            // How tall the content is while the page scrolls in a 600 pt view
            // (TASK-150). A document taller than the viewport is as tall as
            // its content, so `height` holds — and has to be used: content
            // outside the body (padding on <html>, an absolutely positioned
            // footer) would otherwise read as "fits" and be cut off again.
            // A document no taller than the viewport is stretched to it; then
            // the body's own height says how tall the content is.
            contentHeight: doc.scrollHeight > window.innerHeight
                ? height
                : Math.ceil(Math.max(body.offsetHeight, body.scrollHeight) + marginV)
        };
    };
    """

    private static let measureJS = """
    JSON.stringify(window.__detourMeasureBody ? window.__detourMeasureBody() : {width: 0, height: 0});
    """

    /// What a measurement of the popup's page asks of the popover (TASK-150):
    /// its size, clamped to 100...800 x 100...600, and whether the page has to
    /// scroll inside it because its content is taller than the popover can be.
    struct PopupSizing: Equatable {
        let popoverSize: NSSize
        let pageScrolls: Bool
    }

    /// The sizing for one measurement (`__detourMeasureBody`).
    ///
    /// - Parameters:
    ///   - width, height: the document's size as the page reports it.
    ///   - contentHeight: the body's own height, when the page reported it.
    ///   - pageScrollsNow: whether the page is already scrolling in the popover.
    ///     Then the document is at least as tall as the 600 pt view whatever
    ///     its content, so `height` cannot say that the content shrank back:
    ///     `contentHeight` decides instead (falling back to `height`, which
    ///     keeps the page scrolling). Content of exactly the maximum keeps
    ///     scrolling: a body sized to the viewport (`height: 100vh`) reports
    ///     the view's own 600 pt, and handing such a page back to WebKit would
    ///     grow it again — and switch back and forth for ever.
    static func sizing(width: CGFloat, height: CGFloat, contentHeight: CGFloat?,
                       pageScrollsNow: Bool) -> PopupSizing? {
        guard width > 0, height > 0 else { return nil }
        let content = pageScrollsNow ? max(contentHeight ?? height, 1) : height
        return PopupSizing(
            popoverSize: NSSize(width: min(max(width, 100), maxWidth), height: min(max(content, 100), maxHeight)),
            pageScrolls: pageScrollsNow ? content >= maxHeight : content > maxHeight)
    }

    static func sizing(fromMeasurement measured: [String: Any], pageScrollsNow: Bool) -> PopupSizing? {
        func number(_ key: String) -> CGFloat? { (measured[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let width = number("width"), let height = number("height") else { return nil }
        return sizing(width: width, height: height, contentHeight: number("contentHeight"), pageScrollsNow: pageScrollsNow)
    }

    private static func parseSizing(from jsonString: String, pageScrollsNow: Bool) -> PopupSizing? {
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return sizing(fromMeasurement: parsed, pageScrollsNow: pageScrollsNow)
    }

    // MARK: - Page scrolling (TASK-150)

    /// WebKit's private setter for the popup web view's size-to-content mode,
    /// and the KVC key that reaches it.
    static let sizeToContentSetter = NSSelectorFromString("_setSizeToContentAutoSizeMaximumSize:")
    static let sizeToContentKey = "sizeToContentAutoSizeMaximumSize"

    /// The popup web views whose size-to-content mode Detour has switched off.
    /// Kept per web view, not per controller: WebKit hands the same web view
    /// out for every presentation and each presentation gets a new controller,
    /// so a controller that takes over a view its predecessor left scrolling
    /// (re-clicking the toolbar button while the popup is open) has to start
    /// from the view's real mode. Main thread only.
    private static let scrollingPopups = NSHashTable<WKWebView>.weakObjects()

    /// Whether Detour has switched the popup's size-to-content mode off, i.e.
    /// the page scrolls inside the popover.
    private var pageScrolls: Bool {
        popupWebView.map(Self.isPageScrolling) ?? false
    }

    static func isPageScrolling(_ webView: WKWebView) -> Bool {
        scrollingPopups.contains(webView)
    }

    /// The maximum WebKit builds an action popup's web view with
    /// (`maximumPopoverWidth` x `maximumPopoverHeight` in WebKit's
    /// WebExtensionActionCocoa.mm) — the popover's own limits — and what the
    /// mode is given back with. The getter is not used for it: on macOS 26.7
    /// it answers 0 x 0 for a popup WebKit is plainly sizing to its content.
    static let webKitSizeToContentMaximum = NSSize(width: maxWidth, height: maxHeight)

    /// Switch a popup web view's size-to-content mode off (`maximum` zero) or
    /// back on. False — and nothing touched — when this WebKit has no setter.
    @discardableResult
    static func setSizeToContentMaximum(_ maximum: NSValue, on webView: NSObject) -> Bool {
        guard webView.responds(to: sizeToContentSetter) else { return false }
        webView.setValue(maximum, forKey: sizeToContentKey)
        return true
    }

    /// Make the popup's page scroll inside the popover, or hand its layout back
    /// to WebKit.
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
    /// other page, as Chrome's popup does at its own 800 x 600 limit.
    ///
    /// The mode stays on for a popup that fits, and comes back when a popup
    /// shrinks to fit again: WebKit's shrink-to-fit layout is what gives a
    /// popup without an explicit width its width, and what lets a popup get
    /// smaller. On a WebKit without the setter the popup is left as it was
    /// (cut off at 600 pt), and the log says so.
    func setPageScrolls(_ scrolls: Bool, in webView: WKWebView) {
        guard scrolls != Self.scrollingPopups.contains(webView) else { return }
        let maximum = scrolls ? NSSize.zero : Self.webKitSizeToContentMaximum
        guard Self.setSizeToContentMaximum(NSValue(size: maximum), on: webView) else {
            log.notice("The popup of \(self.extensionID, privacy: .public) is taller than the popover and cannot be made to scroll: this WebKit has no _setSizeToContentAutoSizeMaximumSize:")
            return
        }
        if scrolls {
            Self.scrollingPopups.add(webView)
        } else {
            Self.scrollingPopups.remove(webView)
        }
    }

    private func measureAndPresent() {
        guard let wv = popupWebView, positioningView != nil else {
            presentPopover(size: Self.defaultSize)
            return
        }

        // Inject shared measure function, then call it
        wv.evaluateJavaScript(Self.measureFnJS) { _, _ in
            wv.evaluateJavaScript(Self.measureJS) { [weak self] result, _ in
                guard let self else { return }
                let sizing = (result as? String).flatMap {
                    Self.parseSizing(from: $0, pageScrollsNow: self.pageScrolls)
                }
                self.presentPopover(size: sizing?.popoverSize ?? Self.defaultSize)
                if let sizing { self.setPageScrolls(sizing.pageScrolls, in: wv) }
                self.installResizeObserver()
            }
        }
    }

    // MARK: - Resize Observer

    private func installResizeObserver() {
        guard let wv = popupWebView else { return }

        let js = """
        (function() {
            if (window.__detourResizeObserver) return;
            const handler = window.webkit.messageHandlers.extensionPopupResize;
            if (!handler || !window.__detourMeasureBody) return;
            window.__detourResizeObserver = new ResizeObserver(() => {
                const size = window.__detourMeasureBody();
                handler.postMessage(size);
            });
            window.__detourResizeObserver.observe(document.body);
        })();
        """

        wv.configuration.userContentController.removeScriptMessageHandler(forName: "extensionPopupResize")
        wv.configuration.userContentController.add(self, name: "extensionPopupResize")
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Popover Presentation

    private func presentPopover(size: NSSize) {
        guard let wv = popupWebView, let posView = positioningView, popover == nil else { return }

        wv.frame.size = size

        let viewController = NSViewController()
        viewController.view = wv

        let pop = NSPopover()
        pop.contentViewController = viewController
        pop.contentSize = size
        pop.behavior = .semitransient
        pop.delegate = self
        self.popover = pop

        pop.show(relativeTo: positioningRect, of: posView, preferredEdge: preferredEdge)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // WebKit hands the same web view out for the next presentation, so give
        // its layout back — unless that presentation has already begun: a
        // popover's close animation outlasts a quick reload, and by then the
        // view (and its mode) belongs to the controller that took it over.
        if let popupWebView, popupWebView.uiDelegate === self { setPageScrolls(false, in: popupWebView) }
        popupWebView = nil
        popover = nil
        onClose?()
        onClose = nil
    }

    // MARK: - WKUIDelegate

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    // MARK: - WKScriptMessageHandler (resize)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "extensionPopupResize",
              let body = message.body as? [String: Any],
              let sizing = Self.sizing(fromMeasurement: body, pageScrollsNow: pageScrolls),
              popover != nil else { return }

        apply(sizing)
    }

    /// Resize the presented popover for a new measurement. A popup that grows
    /// past the popover after it opened scrolls too, and one that shrinks back
    /// is WebKit's to size again (TASK-150).
    private func apply(_ sizing: PopupSizing) {
        guard let popover, let popupWebView else { return }
        popover.contentSize = sizing.popoverSize
        popupWebView.frame.size = sizing.popoverSize
        setPageScrolls(sizing.pageScrolls, in: popupWebView)
    }
}
