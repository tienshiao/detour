import Foundation
import AppKit
import WebKit

/// Presents an extension's popup.html in an NSPopover with a WKWebView.
class ExtensionPopoverController: NSObject {
    private let ext: WebExtension
    private var popover: NSPopover?
    private(set) var webView: WKWebView?

    /// Chrome's maximum popup dimensions.
    private static let maxWidth: CGFloat = 800
    private static let maxHeight: CGFloat = 600
    /// Default size used if content measurement fails.
    private static let defaultSize = NSSize(width: 360, height: 480)

    // Positioning info saved from show() for deferred popover presentation
    private weak var positioningView: NSView?
    private var positioningRect: NSRect = .zero
    private var preferredEdge: NSRectEdge = .maxY

    init(extension ext: WebExtension) {
        self.ext = ext
        super.init()
    }

    /// Show the extension popup relative to the given toolbar item view.
    /// Creates the WKWebView and starts loading immediately, but defers showing
    /// the popover until the content has loaded and been measured.
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge = .maxY) {
        guard let popupURL = ext.popupURL else { return }

        // Save positioning for when we're ready to present
        self.positioningView = positioningView
        self.positioningRect = positioningRect
        self.preferredEdge = preferredEdge

        let config = ext.makePageConfiguration()

        let wv = WKWebView(frame: NSRect(origin: .zero, size: Self.defaultSize), configuration: config)
        wv.isInspectable = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.load(URLRequest(url: popupURL))
        self.webView = wv

        // Register the popup webView so the message bridge can dispatch messages
        // to it even before the popover is shown (background may send during load)
        ExtensionManager.shared.registerPopupWebView(wv, for: ext.id)
    }

    func close() {
        popover?.close()
    }

    /// JavaScript to measure popup content size.
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

    /// Parse a measurement JSON string into a clamped NSSize, or nil if invalid.
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

    /// Measure the content and present the popover at the correct size.
    private func measureAndPresent() {
        guard let wv = webView, positioningView != nil else {
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

    /// Install a ResizeObserver on the document body so the popover resizes
    /// dynamically when the extension's content changes (e.g. after a translation).
    private func installResizeObserver() {
        guard let wv = webView else { return }

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

        // Register the message handler for resize notifications
        let contentController = wv.configuration.userContentController
        contentController.add(self, name: "extensionPopupResize")

        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Create and show the NSPopover at the given size.
    private func presentPopover(size: NSSize) {
        guard let wv = webView, let posView = positioningView, popover == nil else { return }

        wv.frame.size = size

        let viewController = NSViewController()
        viewController.view = wv

        let pop = NSPopover()
        pop.contentViewController = viewController
        pop.contentSize = size
        pop.behavior = .transient
        pop.delegate = self
        self.popover = pop

        pop.show(relativeTo: positioningRect, of: posView, preferredEdge: preferredEdge)
    }
}

extension ExtensionPopoverController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "extensionPopupResize")
        ExtensionManager.shared.unregisterPopupWebView(for: ext.id)
        webView = nil
        popover = nil
    }
}

extension ExtensionPopoverController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // After the page loads, wait briefly for the extension's JS to render the DOM,
        // then measure the content and show the popover at the correct size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.measureAndPresent()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow initial loads and chrome-extension:// navigations
        if navigationAction.navigationType == .other || navigationAction.request.url?.scheme == ExtensionPageSchemeHandler.scheme {
            decisionHandler(.allow)
            return
        }

        // Open external links (target=_blank or regular clicks to http(s) URLs) in the browser
        if let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "http" {
            decisionHandler(.cancel)
            NotificationCenter.default.post(
                name: ExtensionManager.popupOpenURLNotification,
                object: nil,
                userInfo: ["url": url]
            )
            return
        }

        decisionHandler(.allow)
    }
}

extension ExtensionPopoverController: WKScriptMessageHandler {
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
        webView?.frame.size = size
    }
}

extension ExtensionPopoverController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Handle target=_blank links by opening them in the browser
        if let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "http" {
            NotificationCenter.default.post(
                name: ExtensionManager.popupOpenURLNotification,
                object: nil,
                userInfo: ["url": url]
            )
        }
        return nil
    }
}
