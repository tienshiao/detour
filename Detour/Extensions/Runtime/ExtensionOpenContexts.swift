import AppKit
import WebKit

// TASK-132.9: what `chrome.runtime.getContexts` lists — the native half of
// `ExtensionAPIPolyfill.runtimeGetContextsJS`.
//
// WebKit has no such API and tells the host nothing about an extension's live
// documents, so the list is made of what Detour itself hosts or presents: the
// extension's pages in tabs, its action popup, its offscreen document and its
// side panels — plus its background, which Detour knows from the manifest.

/// A stable id for one extension context, kept on the object that *is* the
/// context for Detour (a web view, or the `WKWebExtensionContext` for the
/// background), so it lives exactly as long as the context does.
enum ExtensionContextIdentity {
    private static var key: UInt8 = 0

    static func id(for object: NSObject) -> String {
        if let existing = objc_getAssociatedObject(object, &key) as? String { return existing }
        let minted = UUID().uuidString.lowercased()
        objc_setAssociatedObject(object, &key, minted, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        return minted
    }
}

extension ExtensionPolyfillHandler {

    /// The open contexts of `extensionID` in this handler's profile, each as
    /// the bridge sends it: `contextType`, `contextId`, `frameId`, `incognito`,
    /// `documentUrl` and `documentOrigin` where there is a document, and the
    /// tab handles the polyfill turns into WebKit's ids — `tabHandle` (the tab
    /// the context is a page of) and `windowTabHandle` (a tab of the window
    /// the context is in).
    ///
    /// Only this extension, only this profile: everything is read from this
    /// profile's own context, tabs, popups, offscreen host and side panels.
    /// Empty when the extension is not loaded here.
    ///
    /// Limits, all WebKit's: no `documentId` (the host is not told one); an
    /// extension frame inside a web page is not listed (frames are not
    /// enumerated); and the background is listed whenever the manifest
    /// declares one, because WebKit does not say whether a worker is running
    /// right now — it starts one on demand.
    func openContexts(extensionID: String) -> [[String: Any]] {
        guard let profile, let context = profile.extensionContext(for: extensionID),
              let host = context.baseURL.host, !host.isEmpty else { return [] }
        let origin = "\(ExtensionPageURL.scheme)://\(host)"
        let incognito = profile.isIncognito
        let handles = ExtensionTabHandleRegistry.shared

        func entry(_ type: String, id: String, url: URL?, frameID: Int,
                   tab: BrowserTab? = nil, windowTab: BrowserTab? = nil) -> [String: Any] {
            var entry: [String: Any] = [
                "contextType": type, "contextId": id, "frameId": frameID, "incognito": incognito,
            ]
            if let url {
                entry["documentUrl"] = url.absoluteString
                entry["documentOrigin"] = origin
            }
            if let tab { entry["tabHandle"] = handles.handle(for: tab) }
            if let windowTab { entry["windowTabHandle"] = handles.handle(for: windowTab) }
            return entry
        }

        var contexts: [[String: Any]] = []

        // The background. A worker has no document and no frame; a background
        // page is a document at the manifest's (or WebKit's generated) path.
        if let background = ExtensionManager.shared.extension(withID: extensionID)?.manifest.background,
           background.hasBackgroundContent {
            let id = ExtensionContextIdentity.id(for: context)
            if background.mayRunAsServiceWorker {
                contexts.append(entry("BACKGROUND", id: id, url: nil, frameID: -1))
            } else {
                let url = Self.backgroundDocumentPath(background).flatMap { URL(string: $0, relativeTo: context.baseURL)?.absoluteURL }
                contexts.append(entry("BACKGROUND", id: id, url: url, frameID: url == nil ? -1 : 0))
            }
        }

        // Pages in tabs: a space's tabs, pinned entries, favourites and their
        // peeks. A sleeping tab has no document, so it is not a context.
        for location in profile.extensionPageLocations(forOriginHost: host) {
            let tab = location.tab
            guard let webView = tab.webView else { continue }
            contexts.append(entry("TAB", id: ExtensionContextIdentity.id(for: webView),
                                  url: webView.url ?? tab.url, frameID: 0, tab: tab, windowTab: tab))
        }

        // The action popup, while it is on screen.
        for popup in ExtensionPopoverController.presentedPopups where popup.extensionID == extensionID {
            guard let webView = popup.popupWebView,
                  let controller = webView.configuration.webExtensionController,
                  Profile.profile(owning: controller) === profile else { continue }
            let window = popup.hostWindow?.windowController as? BrowserWindowController
            contexts.append(entry("POPUP", id: ExtensionContextIdentity.id(for: webView),
                                  url: webView.url, frameID: 0, windowTab: window?.extensionActiveTab))
        }

        // The offscreen document, once it has loaded.
        if let offscreen = offscreenHosts[extensionID], !offscreen.isLoading, let webView = offscreen.webView {
            contexts.append(entry("OFFSCREEN_DOCUMENT", id: ExtensionContextIdentity.id(for: webView),
                                  url: webView.url, frameID: 0))
        }

        // Side panels (TASK-132.8), open ones only, on screen or hidden with
        // their tab. A panel is not a tab; its window is its tab's, or the
        // window it belongs to.
        for panel in profile.sidePanels.panels(for: extensionID) {
            guard let webView = panel.webView else { continue }
            let windowTab = panel.tab ?? (panel.hostingWindow ?? panel.windowController)?.extensionActiveTab
            contexts.append(entry("SIDE_PANEL", id: ExtensionContextIdentity.id(for: webView),
                                  url: panel.documentURL, frameID: 0, windowTab: windowTab))
        }

        return contexts
    }
}
