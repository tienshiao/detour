import AppKit
import WebKit

// MARK: - BrowserTab + WKWebExtensionTab

extension BrowserTab: WKWebExtensionTab {
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        // Per the docs: the webView's controller must match the context's controller
        guard webView?.configuration.webExtensionController === context.webExtensionController else {
            return nil
        }
        return webView
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        // Find the window controller that currently owns this tab
        for window in NSApp.windows {
            if let wc = window.windowController as? BrowserWindowController,
               wc.selectedTabID == id {
                return wc
            }
        }
        // Fallback: find the window for this tab's space
        guard let spaceID else { return nil }
        for window in NSApp.windows {
            if let wc = window.windowController as? BrowserWindowController,
               wc.activeSpaceID == spaceID {
                return wc
            }
        }
        return nil
    }

    func title(for context: WKWebExtensionContext) -> String? {
        title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !isLoading
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        isPlayingAudio
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        isMuted
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let spaceID else {
            completionHandler(nil)
            return
        }
        NotificationCenter.default.post(
            name: ExtensionManager.tabShouldSelectNotification,
            object: nil,
            userInfo: ["tabID": id, "spaceID": spaceID]
        )
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.load(URLRequest(url: url))
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin {
            webView?.reloadFromOrigin()
        } else {
            webView?.reload()
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let spaceID, let space = TabStore.shared.space(withID: spaceID) else {
            completionHandler(nil)
            return
        }
        TabStore.shared.closeTab(id: id, in: space)
        completionHandler(nil)
    }
}
