import AppKit
import WebKit

extension BrowserWindowController: WKUIDelegate {

    // MARK: - window.open() and context menu link actions

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Consumed by this request whatever happens below: a menu action left
        // set by an early return would route the next page's own window.open
        // through it, past the `data:` and extension-context checks below.
        let linkAction = contextMenuLinkAction
        contextMenuLinkAction = .none
        guard let url = navigationAction.request.url, let space = activeSpace else { return nil }
        // window.open() never consults decidePolicy; refuse here rather than
        // open a tab whose only navigation the policy would then cancel.
        if InternalPage.isInternal(url) { return nil }

        switch linkAction {
        case .openInNewTab:
            _ = TabStore.shared.addTab(in: space, url: url, parentID: selectedTabID)
        case .openInNewWindow:
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.createNewWindowWithURL(url)
            }
        case .openInSplitView:
            // The tab whose page the menu was opened on, by Option-click's rules.
            if let clickedTab = tab(owning: webView) {
                openLinkInSplit(url, from: clickedTab, in: space)
            }
        case .none:
            // A page's own new-window request (a `target=_blank` link, a
            // script's window.open) for a `data:` URL. A peek below loads the
            // URL itself, and a load the app asks for is one WebKit allows —
            // where it refuses a page's top-level navigation to a `data:` URL.
            // Refused here, before a peek or a tab exists, to keep that rule
            // (TASK-159). The context menu's own actions, above, are the
            // user's choice and still open one.
            if url.scheme?.lowercased() == "data" { return nil }

            // A tab-style window.open from a pinned tab or favourite peeks, like
            // a target=_blank link does in decidePolicy (TASK-85).
            if let host = peekHostTab(firing: webView),
               PeekAnchor.anchorURL(forTabID: host.id, pinnedEntries: space.pinnedEntries,
                                    favorites: space.profile?.favorites ?? []) != nil,
               PeekAnchor.shouldPeekScriptedWindow(to: url, wantsPopup: Self.wantsPopup(windowFeatures)) {
                presentPeek(of: url, on: host, firing: webView)
                return nil
            }
            // The page's new window is a real WebKit child: a tab whose web
            // view is made from `configuration` and handed back, so the page
            // gets a window from window.open() and WebKit performs the
            // navigation. Loading the URL into an unrelated tab instead left
            // `window.open()` returning null — an empty tab for a page that
            // opens a blank window and navigates it afterwards, as xterm.js's
            // link handler does (TASK-167).
            let opener = openerPlacement(for: webView, activeSpace: space)
            // Not for a window an extension page opens. `configuration` is a
            // copy of the opener's, and an extension page's is its context's:
            // CORS checks off for the extension's hosts, third-party cookie
            // blocking relaxed, the web view counted as one of the extension's
            // own pages. A web page must not load in a web view built from
            // that, so such a window stays what it was before TASK-167: a tab
            // of the space's own that the app loads, and no window for the
            // extension page.
            if Self.isExtensionContextConfiguration(configuration, opener: webView) {
                let tab = store.addTab(in: opener.space, url: url.absoluteString.isEmpty ? nil : url,
                                       parentID: opener.parentID)
                if opener.space.id == space.id { selectTab(id: tab.id) }
                return nil
            }
            let tab = store.addTab(in: opener.space, openedWith: configuration, parentID: opener.parentID)
            if opener.space.id == space.id {
                selectTab(id: tab.id)
            } else {
                // Opened by a tab of a space this window is not showing: it
                // stays in the background there. No window has claimed it, so
                // nothing else would make it answer its own window requests.
                tab.webView?.uiDelegate = self
            }
            return tab.webView
        }

        return nil
    }

    /// Where a window opened by `webView`'s page goes: the space holding the
    /// tab that opened it, and that tab as its parent. The active space is
    /// asked first, since a favourite's tab belongs to every space of its
    /// profile. The space matters because the new tab shares its opener's data
    /// store: put in whichever space is on screen, a window opened by a tab of
    /// another profile's space would carry that profile's cookies into this one.
    private func openerPlacement(for webView: WKWebView, activeSpace: Space) -> (space: Space, parentID: UUID?) {
        let spaces = [activeSpace] + store.spaces.filter { $0.id != activeSpace.id }
        for space in spaces {
            guard let tab = store.tab(hosting: webView, in: space) else { continue }
            // A peek opens windows on behalf of the tab it is peeked from.
            return (space, (store.tab(hostingPeek: tab) ?? tab).id)
        }
        return (activeSpace, selectedTabID)
    }

    /// Whether the configuration WebKit supplies for a new window is an
    /// extension context's (`WKWebExtensionContext.webViewConfiguration`),
    /// which is what an extension page's web view is built from and what its
    /// `window.open` child would inherit. The context marks its configuration
    /// with `_requiredWebExtensionBaseURL` (SPI, read by key behind a
    /// `responds(to:)` guard); the opener showing an extension page is the
    /// same answer without the SPI.
    private static func isExtensionContextConfiguration(_ configuration: WKWebViewConfiguration,
                                                        opener: WKWebView) -> Bool {
        if isExtensionPageURL(opener.url) { return true }
        guard configuration.responds(to: NSSelectorFromString("_requiredWebExtensionBaseURL")) else { return false }
        return configuration.value(forKey: "_requiredWebExtensionBaseURL") as? URL != nil
    }

    /// Whether a `window.open` asked for a popup rather than a tab. WebKit's
    /// `_wantsPopup` SPI (macOS 14.2+) implements the HTML "is popup" check;
    /// before it, explicit position or size is the tell.
    private static func wantsPopup(_ features: WKWindowFeatures) -> Bool {
        if features.responds(to: NSSelectorFromString("_wantsPopup")),
           let wantsPopup = features.value(forKey: "_wantsPopup") as? Bool {
            return wantsPopup
        }
        return features.x != nil || features.y != nil || features.width != nil || features.height != nil
    }

    // MARK: - JavaScript Dialogs

    private func showJSAlert(in webView: WKWebView, from frame: WKFrameInfo, message: String, showCancel: Bool = false, accessoryView: NSView? = nil, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        // The page's process waits on this dialog for as long as the user
        // takes; the tab must not mistake that for a hang (TASK-176).
        let tab = tab(owning: webView)
        tab?.scriptDialogDidBegin()
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            tab?.scriptDialogDidEnd()
            completion(response)
        }
        let alert = NSAlert()
        alert.messageText = "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if showCancel { alert.addButton(withTitle: "Cancel") }
        alert.accessoryView = accessoryView

        if let window = self.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(.alertSecondButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        showJSAlert(in: webView, from: frame, message: message) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        showJSAlert(in: webView, from: frame, message: message, showCancel: true) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = defaultText ?? ""
        showJSAlert(in: webView, from: frame, message: prompt, showCancel: true, accessoryView: textField) { response in
            completionHandler(response == .alertFirstButtonReturn ? textField.stringValue : nil)
        }
    }

    // MARK: - Window Close

    /// A page closed its own window with `window.close()`. WebKit decides
    /// whether it may (a window a script opened, or one with nothing to go
    /// back to) and only then calls this; the tab goes away like one the user
    /// closed, and stays reopenable.
    ///
    /// A window that closes itself has finished what it was opened for — a
    /// sign-in popup handing its result to its opener — so when it is the tab
    /// on screen the tab that opened it comes back, ahead of the usual close
    /// order's siblings (TASK-168).
    func webViewDidClose(_ webView: WKWebView) {
        for space in store.spaces {
            guard let index = space.tabs.firstIndex(where: { $0.webView === webView }) else { continue }
            let tab = space.tabs[index]
            if space.id == activeSpaceID, tab.id == selectedTabID {
                settlingSelectionForClose {
                    if store.splitGroup(containing: tab.id, in: space) == nil,
                       let opener = tab.parentID.flatMap({ space.displayableTab(id: $0) }) {
                        selectTab(id: opener.id)
                    } else {
                        settleSelectionLeaving(tabAt: index, in: space)
                    }
                }
            }
            store.closeTab(id: tab.id, in: space)
            return
        }
    }

    // MARK: - File Upload

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories

        if let window = self.window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK {
                    completionHandler(panel.urls)
                } else {
                    completionHandler(nil)
                }
            }
        } else {
            completionHandler(nil)
        }
    }

    // MARK: - Media Capture Permission

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let mediaType: String
        switch type {
        case .camera: mediaType = "camera"
        case .microphone: mediaType = "microphone"
        case .cameraAndMicrophone: mediaType = "camera and microphone"
        @unknown default: mediaType = "media"
        }

        let alert = NSAlert()
        alert.messageText = "Allow \(originString(from: origin)) to access your \(mediaType)?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                decisionHandler(response == .alertFirstButtonReturn ? .grant : .deny)
            }
        } else {
            decisionHandler(.deny)
        }
    }

    // MARK: - Picture-in-Picture
    //
    // Private WKUIDelegate SPI. WebKit's PIPViewController delegate calls
    // `pipShouldClose:` when the user clicks "Return to Window"; that path emits
    // `_webViewFullscreenMayReturnToInline:` after a UI<->web roundtrip. WebKit
    // also queues a request to exit PiP that only fires once the document is
    // visible again — which means we have to put the WKWebView back into the
    // view hierarchy ourselves. Selecting the originating tab does both: it
    // claims the webView (making the document visible, which lets WebKit's
    // queued callback fire and the video animate back inline) and restores any
    // peek overlay if the source was a peek tab.
    @objc(_webViewFullscreenMayReturnToInline:)
    func _webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        for space in TabStore.shared.spaces {
            // Hosts include pinned and favourite backing tabs, which are not in `space.tabs`.
            let hosts = space.tabs
                + space.pinnedEntries.compactMap { $0.tab }
                + (space.profile?.favorites.compactMap { $0.tab } ?? [])
            for tab in hosts {
                if tab.webView === webView || tab.peekTab?.webView === webView {
                    if activeSpaceID != space.id {
                        setActiveSpace(id: space.id)
                    }
                    selectTab(id: tab.id)
                    window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    return
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func originString(from origin: WKSecurityOrigin) -> String {
        if origin.port != 0 {
            return "\(origin.protocol)://\(origin.host):\(origin.port)"
        }
        return "\(origin.protocol)://\(origin.host)"
    }
}
