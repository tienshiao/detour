import AppKit
import WebKit

// MARK: - WKNavigationDelegate

/// A Quick Detour's page navigates in place: there is no space to open a tab
/// in, no Peek and no split (TASK-193.1). What a browser window's policy does
/// besides that carries over — internal pages are armed only, external
/// applications are asked about, downloads go to the download manager, content
/// blocking follows the profile's per-site switch.
extension QuickDetourWindowController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let page = tab.flatMap { $0.webView === webView ? $0 : nil }
        if navigationAction.targetFrame?.isMainFrame == true {
            page?.didReceiveMainFrameNavigationPolicyRequest()
        }
        let policy = decidePolicy(for: navigationAction, in: webView, page: page)
        if policy == .allow, navigationAction.targetFrame?.isMainFrame == true {
            ContentBlockerManager.shared.configure(preferences, forNavigationTo: navigationAction.request.url,
                                                   profile: profile)
        }
        return (policy, preferences)
    }

    private func decidePolicy(for action: WKNavigationAction, in webView: WKWebView,
                              page: BrowserTab?) -> WKNavigationActionPolicy {
        if InternalPage.isInternal(action.request.url) {
            return page?.authorizesNavigation(action, in: webView) == true ? .allow : .cancel
        }

        // Cmd+click: another Quick Detour on the same profile, as a browser
        // window's opens a background tab. It names the same space in Open in
        // as this one (TASK-193.3).
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command),
           let url = action.request.url {
            DispatchQueue.main.async { [profile, store, sourceSpaceID] in
                QuickDetourWindowController.open(profile: profile,
                                                 sourceSpace: sourceSpaceID.flatMap { store.space(withID: $0) },
                                                 url: url)
            }
            return .cancel
        }

        if action.navigationType == .backForward, let url = action.request.url,
           let originalURL = ErrorPage.originalURL(from: url) {
            DispatchQueue.main.async { page?.load(originalURL) }
            return .cancel
        }

        if let url = action.request.url, let scheme = url.scheme,
           ExternalAppLaunchPolicy.isForExternalApp(scheme: scheme) {
            BrowserWindowController.handleExternalAppNavigation(
                to: url, action: action, profile: profile, window: window,
                isHosted: window != nil && webView.window === window,
                showToast: { [weak self] in self?.toastManager.show(message: $0) })
            return .cancel
        }

        if action.shouldPerformDownload { return .download }

        if let url = action.request.url { page?.applySpoofedUserAgent(for: url) }
        return .allow
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // An extension package is offered for install, as in a browser window.
        if BrowserWindowController.isCRXResponse(navigationResponse) {
            let url = navigationResponse.response.url
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                BrowserWindowController.downloadAndOfferCRX(from: url, scope: self.downloadScope) { [weak self] in
                    self?.toastManager.show(message: "Downloading extension")
                }
            }
            return .cancel
        }
        if !navigationResponse.canShowMIMEType { return .download }
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    /// A Private Quick Detour's downloads are its own, as a Private window's
    /// are (never saved, gone when it closes); a normal one's join the normal
    /// list every browser window shows.
    var downloadScope: DownloadScope {
        profile.isIncognito ? .incognito(spaceID: tabID) : .normal
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        startDownload(download, from: navigationResponse.response.url)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        startDownload(download, from: navigationAction.request.url)
    }

    private func startDownload(_ download: WKDownload, from url: URL?) {
        download.delegate = DownloadManager.shared
        _ = DownloadManager.shared.handleNewDownload(download, sourceURL: url, scope: downloadScope)
        // There is no downloads button in this window.
        toastManager.show(message: "Downloading \(url?.lastPathComponent ?? "file")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let page = tab, page.webView === webView else { return }
        page.nowPlayingDocumentDidCommit()
        if webView.url?.scheme == ErrorPage.scheme { return }
        page.didCommitNavigation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let page = tab, page.webView === webView else { return }
        page.didFailProvisionalNavigation(error: error)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let page = tab, page.webView === webView else { return }
        page.didStartProvisionalNavigation()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let page = tab, page.webView === webView else { return }
        guard !page.isTerminatingUnresponsiveProcess else { return }
        page.webProcessDidTerminate()
        guard page.noteProcessTermination() <= 2 else { return }
        page.reload()
    }

    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    func webViewWebProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        guard let page = tab, page.webView === webView else { return }
        page.webProcessDidBecomeUnresponsive()
    }

    @objc(_webViewWebProcessDidBecomeResponsive:)
    func webViewWebProcessDidBecomeResponsive(_ webView: WKWebView) {
        guard let page = tab, page.webView === webView else { return }
        page.webProcessDidBecomeResponsive()
    }

    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String,
                 performedAction action: NSObject, forURL url: URL) {
        let blockedLoad = NSSelectorFromString("blockedLoad")
        guard action.responds(to: blockedLoad), action.value(forKey: "blockedLoad") as? Bool == true,
              let page = tab, page.webView === webView else { return }
        page.recordBlockedLoad(of: url)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        HTTPAuthenticationPrompt.handle(challenge, in: window, completionHandler: completionHandler)
    }
}

// MARK: - WKUIDelegate

extension QuickDetourWindowController: WKUIDelegate {

    /// A window the page opens — a `target=_blank` link, `window.open`, Open
    /// Link in New Window — is another Quick Detour on the same profile. It is
    /// a real WebKit child, so the page gets its window (`window.opener`, a
    /// sign-in popup handing its result back).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, !InternalPage.isInternal(url) else { return nil }
        // A page may not open a `data:` URL in a window of its own (TASK-159).
        if url.scheme?.lowercased() == "data" { return nil }
        let child = QuickDetourWindowController(profile: profile,
                                                sourceSpace: sourceSpaceID.flatMap { store.space(withID: $0) },
                                                openedWith: configuration)
        child.showWindow(nil)
        return child.tab?.webView
    }

    /// The page closed its own window (`window.close()`), as a sign-in popup
    /// does when it is done.
    func webViewDidClose(_ webView: WKWebView) {
        guard tab?.webView === webView else { return }
        window?.close()
    }

    private func runScriptDialog(in webView: WKWebView, from frame: WKFrameInfo, message: String,
                                 showCancel: Bool = false, accessoryView: NSView? = nil,
                                 completion: @escaping (NSApplication.ModalResponse) -> Void) {
        // The page's process waits on the dialog; it is not a hang (TASK-176).
        let page = tab.flatMap { $0.webView === webView ? $0 : nil }
        page?.scriptDialogDidBegin()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            page?.scriptDialogDidEnd()
            completion(response)
        }
        let alert = NSAlert()
        alert.messageText = "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if showCancel { alert.addButton(withTitle: "Cancel") }
        alert.accessoryView = accessoryView
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(.alertSecondButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        runScriptDialog(in: webView, from: frame, message: message) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        runScriptDialog(in: webView, from: frame, message: message, showCancel: true) {
            completionHandler($0 == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        runScriptDialog(in: webView, from: frame, message: prompt, showCancel: true, accessoryView: field) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let window else { return decisionHandler(.deny) }
        let what: String
        switch type {
        case .camera: what = "camera"
        case .microphone: what = "microphone"
        case .cameraAndMicrophone: what = "camera and microphone"
        @unknown default: what = "media"
        }
        let site = origin.port != 0 ? "\(origin.protocol)://\(origin.host):\(origin.port)"
            : "\(origin.protocol)://\(origin.host)"
        let alert = NSAlert()
        alert.messageText = "Allow \(site) to access your \(what)?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.beginSheetModal(for: window) { decisionHandler($0 == .alertFirstButtonReturn ? .grant : .deny) }
    }
}

// MARK: - WKWebExtensionWindow

/// What the extension contexts see (TASK-193.1): a window of type `popup`
/// holding one tab, the page, which is also its active tab. Listed only to the
/// contexts of the window's profile (`extensionProfileID`), and Private when
/// the profile is.
extension QuickDetourWindowController: ExtensionListedWindow {
    var extensionTabs: [BrowserTab] {
        guard let tab, tab.webView != nil else { return [] }
        return [tab]
    }

    var extensionActiveTab: BrowserTab? {
        extensionTabs.first
    }

    var extensionProfileID: UUID? { profile.id }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        extensionTabs
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        extensionActiveTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .popup
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        profile.isIncognito
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        window?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        window?.screen?.frame ?? .null
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.close()
        completionHandler(nil)
    }
}
