import Foundation
import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "ext-popup")

/// Presents an extension's popup in an NSPopover.
///
/// For user-initiated clicks: get `action.popupWebView` directly and present it.
/// `performAction()` is only for the no-popup case (fires `browser.action.onClicked`).
/// The delegate `presentActionPopup` is for extension-initiated opens (`browser.action.openPopup()`).
class ExtensionPopoverController: NSObject, NSPopoverDelegate, WKScriptMessageHandler {
    private let extensionID: String
    private var popover: NSPopover?
    private weak var popupWebView: WKWebView?

    private static let maxWidth: CGFloat = 800
    private static let maxHeight: CGFloat = 600
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

        let activeTab = (NSApp.keyWindow?.windowController as? BrowserWindowController)?.selectedTab
        let tab: (any WKWebExtensionTab)? = activeTab?.webView(for: context) != nil ? activeTab : nil
        let action = context.action(for: tab)

        if let action, action.presentsPopup, let webView = action.popupWebView {
            // User click with popup — reload to match Chrome behavior (popups are recreated each open)
            webView.reload()
            presentPopupWebView(webView)
        } else if let action, !action.presentsPopup {
            // No popup — fire browser.action.onClicked in the background script
            context.performAction(for: tab)
        }
    }

    /// Called by ExtensionManager's delegate for extension-initiated popup opens
    /// (e.g. `browser.action.openPopup()` from background script).
    func presentPopupWebView(_ webView: WKWebView) {
        self.popupWebView = webView

        // Wait briefly for the extension's JS to render, then measure and present
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.measureAndPresent()
        }
    }

    func close() {
        popover?.close()
    }

    // MARK: - Content Measurement

    private static let measureJS = """
    (function() {
        const body = document.body;
        if (!body) return JSON.stringify({width: 0, height: 0});
        const style = window.getComputedStyle(body);
        const marginH = parseFloat(style.marginLeft) + parseFloat(style.marginRight);
        const marginV = parseFloat(style.marginTop) + parseFloat(style.marginBottom);
        const width = Math.ceil(body.offsetWidth + marginH);
        const height = Math.ceil(body.offsetHeight + marginV);
        return JSON.stringify({width: width, height: height});
    })();
    """

    private static func parseSize(from jsonString: String) -> NSSize? {
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
              let w = parsed["width"], let h = parsed["height"],
              w > 0, h > 0 else { return nil }
        return NSSize(
            width: min(max(w, 100), maxWidth),
            height: min(max(h, 100), maxHeight)
        )
    }

    private func measureAndPresent() {
        guard let wv = popupWebView, positioningView != nil else {
            presentPopover(size: Self.defaultSize)
            return
        }

        wv.evaluateJavaScript(Self.measureJS) { [weak self] result, _ in
            guard let self else { return }
            let size = (result as? String).flatMap(Self.parseSize) ?? Self.defaultSize
            self.presentPopover(size: size)
            self.installResizeObserver()
        }
    }

    // MARK: - Resize Observer

    private func installResizeObserver() {
        guard let wv = popupWebView else { return }

        let js = """
        (function() {
            if (window.__detourResizeObserver) return;
            const handler = window.webkit.messageHandlers.extensionPopupResize;
            if (!handler) return;
            window.__detourResizeObserver = new ResizeObserver(() => {
                const body = document.body;
                if (!body) return;
                const style = window.getComputedStyle(body);
                const marginH = parseFloat(style.marginLeft) + parseFloat(style.marginRight);
                const marginV = parseFloat(style.marginTop) + parseFloat(style.marginBottom);
                const width = Math.ceil(body.offsetWidth + marginH);
                const height = Math.ceil(body.offsetHeight + marginV);
                handler.postMessage({width: width, height: height});
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
        popupWebView = nil
        popover = nil
        onClose?()
        onClose = nil
    }

    // MARK: - WKScriptMessageHandler (resize)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "extensionPopupResize",
              let body = message.body as? [String: Any],
              let w = (body["width"] as? NSNumber)?.doubleValue,
              let h = (body["height"] as? NSNumber)?.doubleValue,
              w > 0, h > 0,
              let pop = popover else { return }

        let size = NSSize(
            width: min(max(CGFloat(w), 100), Self.maxWidth),
            height: min(max(CGFloat(h), 100), Self.maxHeight)
        )
        pop.contentSize = size
        popupWebView?.frame.size = size
    }
}
