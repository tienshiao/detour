import Foundation
import AppKit
import WebKit

/// Presents an extension's popup.html in an NSPopover with a WKWebView.
class ExtensionPopoverController: NSObject {
    private let ext: WebExtension
    private var popover: NSPopover?
    private(set) var webView: WKWebView?

    init(extension ext: WebExtension) {
        self.ext = ext
        super.init()
    }

    /// Show the extension popup relative to the given toolbar item view.
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge = .minY) {
        guard let popupURL = ext.popupURL else { return }

        let config = ext.makePageConfiguration()

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 480), configuration: config)
        wv.isInspectable = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.load(URLRequest(url: popupURL))
        self.webView = wv

        let viewController = NSViewController()
        viewController.view = wv

        let pop = NSPopover()
        pop.contentViewController = viewController
        pop.contentSize = NSSize(width: 360, height: 480)
        pop.behavior = .transient
        pop.delegate = self
        self.popover = pop

        pop.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
    }

    func close() {
        popover?.close()
    }
}

extension ExtensionPopoverController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        webView = nil
        popover = nil
    }
}

extension ExtensionPopoverController: WKNavigationDelegate {
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
