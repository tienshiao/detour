import Foundation
import AppKit
import WebKit

/// Presents an extension's popup.html in an NSPopover with a WKWebView.
class ExtensionPopoverController: NSObject {
    private let ext: WebExtension
    private var popover: NSPopover?
    private(set) var webView: WKWebView?
    private var contentSizeObservation: NSKeyValueObservation?

    /// Chrome's maximum popup dimensions.
    private static let maxWidth: CGFloat = 800
    private static let maxHeight: CGFloat = 600
    /// Default size used before the content determines its preferred size.
    private static let defaultSize = NSSize(width: 360, height: 480)

    init(extension ext: WebExtension) {
        self.ext = ext
        super.init()
    }

    /// Show the extension popup relative to the given toolbar item view.
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge = .minY) {
        guard let popupURL = ext.popupURL else { return }

        let config = ext.makePageConfiguration()

        let wv = WKWebView(frame: NSRect(origin: .zero, size: Self.defaultSize), configuration: config)
        wv.isInspectable = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.load(URLRequest(url: popupURL))
        self.webView = wv

        // Register the popup webView so the message bridge can dispatch messages to it
        ExtensionManager.shared.registerPopupWebView(wv, for: ext.id)

        let viewController = NSViewController()
        viewController.view = wv

        let pop = NSPopover()
        pop.contentViewController = viewController
        pop.contentSize = Self.defaultSize
        pop.behavior = .transient
        pop.delegate = self
        self.popover = pop

        pop.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
    }

    func close() {
        popover?.close()
    }

    /// Query the popup's content size from the rendered DOM and resize the popover.
    private func resizeToFitContent() {
        guard let wv = webView, let pop = popover else { return }

        let js = """
        (function() {
            const body = document.body;
            const html = document.documentElement;
            if (!body) return JSON.stringify({width: 0, height: 0});
            const style = window.getComputedStyle(body);
            const marginH = parseFloat(style.marginLeft) + parseFloat(style.marginRight);
            const marginV = parseFloat(style.marginTop) + parseFloat(style.marginBottom);
            const width = Math.ceil(body.offsetWidth + marginH);
            const height = Math.ceil(body.offsetHeight + marginV);
            return JSON.stringify({width: width, height: height});
        })();
        """

        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let pop = self.popover,
                  let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let size = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
                  let w = size["width"], let h = size["height"],
                  w > 0, h > 0 else { return }

            let clampedWidth = min(max(w, 100), Self.maxWidth)
            let clampedHeight = min(max(h, 100), Self.maxHeight)
            let newSize = NSSize(width: clampedWidth, height: clampedHeight)

            pop.contentSize = newSize
            wv.frame.size = newSize
        }
    }
}

extension ExtensionPopoverController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        ExtensionManager.shared.unregisterPopupWebView(for: ext.id)
        webView = nil
        popover = nil
    }
}

extension ExtensionPopoverController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // After the page loads, measure the content and resize the popover to fit.
        // Use a short delay to allow the extension's JS to render the DOM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.resizeToFitContent()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow initial loads and extension:// navigations
        if navigationAction.navigationType == .other || navigationAction.request.url?.scheme == ExtensionPageSchemeHandler.scheme {
            decisionHandler(.allow)
            return
        }

        // Open external links (target=_blank or regular clicks to http(s) URLs) in the browser
        if let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "http" {
            decisionHandler(.cancel)
            // Post a notification or open in a new tab
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
