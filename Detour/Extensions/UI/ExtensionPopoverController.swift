import Foundation
import AppKit
import WebKit

/// Presents an extension's popup.html in an NSPopover with a WKWebView.
class ExtensionPopoverController: NSObject {
    private let ext: WebExtension
    private var popover: NSPopover?
    private var webView: WKWebView?

    init(extension ext: WebExtension) {
        self.ext = ext
        super.init()
    }

    /// Show the extension popup relative to the given toolbar item view.
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge = .minY) {
        guard let popupURL = ext.popupURL else { return }

        // Create a WKWebView with chrome API polyfills
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let apiBundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: false)
        let apiScript = WKUserScript(
            source: apiBundle,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(apiScript)
        ExtensionMessageBridge.shared.register(on: config.userContentController)

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 480), configuration: config)
        wv.loadFileURL(popupURL, allowingReadAccessTo: ext.basePath)
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
