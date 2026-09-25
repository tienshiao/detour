import AppKit
import WebKit

// MARK: - WKNavigationDelegate

extension BrowserWindowController: WKNavigationDelegate {
    /// The preferences variant, not the plain `decidePolicyFor:` — returning a
    /// `WKWebpagePreferences` is the only way to turn content blocking off for a
    /// page (the per-site switch, TASK-69). WebKit calls only one of the two, so
    /// implementing this one keeps every branch of the decision below in effect.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let policy = await decidePolicy(for: navigationAction, in: webView)
        // Main frame only: a subframe's preferences do not govern the document's
        // content blocking, and the host that decides is the page's. The profile
        // is the navigating tab's, not the window's active space: this delegate
        // stays on a tab's web view after a space switch, so a navigation still
        // in flight there must be judged against its own profile's whitelist.
        if policy == .allow, navigationAction.targetFrame?.isMainFrame == true,
           let profile = tab(owning: webView)?.owningProfile ?? activeSpace?.profile {
            ContentBlockerManager.shared.configure(preferences,
                                                   forNavigationTo: navigationAction.request.url,
                                                   profile: profile)
        }
        return (policy, preferences)
    }

    private func decidePolicy(for navigationAction: WKNavigationAction,
                              in webView: WKWebView) async -> WKNavigationActionPolicy {
        // Before everything else, so a refused internal URL is not Cmd+clicked
        // into a new tab, peeked, or offered to an external application.
        if InternalPage.isInternal(navigationAction.request.url) {
            // A web view that is no tab's is never armed.
            let allowed = tab(owning: webView)?.authorizesNavigation(navigationAction, in: webView) ?? false
            return allowed ? .allow : .cancel
        }

        if navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command) {
            if let url = navigationAction.request.url, let space = activeSpace {
                _ = store.addTab(in: space, url: url, parentID: selectedTabID)
            }
            return .cancel
        }

        // Shift+click: open link in peek view. The peek attaches to the pane
        // whose webview fired the link — never the peek webview, so
        // shift-clicking inside a peek still navigates it (see `peekHostTab`).
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.shift),
           let url = navigationAction.request.url,
           let tab = peekHostTab(firing: webView) {
            presentPeek(of: url, on: tab, firing: webView)
            return .cancel
        }

        // Option+click: open link in a split pane. Must run BEFORE the
        // shouldPerformDownload check below — WebKit sets that flag for
        // Alt-clicked links (Safari's Option-click-downloads convention),
        // which this deliberately retires; the context menu's "Download
        // Linked File" still covers it. Modifier precedence: Cmd (new tab),
        // then Shift (peek), then Option — the branch order above.
        // Not while a peek is open (mirrors the Shift branch): a click inside
        // the peek would resolve to the peek tab and fall through to a
        // surprise background tab; letting it pass keeps Option-click-download
        // working inside peeks.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.option),
           peekOverlayView == nil,
           let url = navigationAction.request.url,
           let space = activeSpace,
           let clickedTab = tab(owning: webView) {
            // Resolved from the firing webView, not selectedTab: in a split, a
            // link can be Option-clicked in the unfocused pane.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let group = self.store.splitGroup(containing: clickedTab.id, in: space),
                   let otherPane = group.members.first(where: { $0.id != clickedTab.id }) {
                    // Already split: send the link to the other pane.
                    otherPane.load(url)
                } else if let newTab = self.store.addTabInSplit(with: clickedTab.id, url: url, in: space) {
                    // New right pane, focused.
                    self.selectTab(id: newTab.id)
                } else {
                    // Pinned/favorite/peek tabs can't join groups — fall back
                    // to Cmd+click behavior (background tab).
                    _ = self.store.addTab(in: space, url: url, parentID: self.selectedTabID)
                }
            }
            return .cancel
        }

        // When navigating forward into an error page, re-attempt the original URL instead
        if navigationAction.navigationType == .backForward,
           let url = navigationAction.request.url,
           let originalURL = ErrorPage.originalURL(from: url) {
            DispatchQueue.main.async { [weak self] in
                self?.selectedTab?.load(originalURL)
            }
            return .cancel
        }

        // Non-HTTP(S) URLs (App Store, mailto, zoommtg, etc.) belong to an
        // external application — only after the user confirms (TASK-84).
        if let url = navigationAction.request.url,
           let scheme = url.scheme,
           scheme != "http", scheme != "https",
           scheme != "about", scheme != "blob", scheme != "webkit-extension", scheme != ErrorPage.scheme {
            handleExternalAppNavigation(to: url, action: navigationAction, in: webView)
            return .cancel
        }

        if navigationAction.shouldPerformDownload {
            return .download
        }

        // Peek mode: intercept cross-host navigation, and every target=_blank
        // link, on pinned tabs and favourites (`PeekAnchor.shouldPeek`). A
        // _blank link reaches this with a nil targetFrame before WebKit would
        // call createWebViewWith; script window.open() never does. The anchored
        // tab is the pane that fired, not the selection: in a pinned split the
        // link can come from the unfocused pane (TASK-48) — see `peekHostTab`.
        if navigationAction.navigationType == .linkActivated,
           let space = activeSpace,
           let tab = peekHostTab(firing: webView),
           let url = navigationAction.request.url,
           let anchorURL = PeekAnchor.anchorURL(forTabID: tab.id,
                                                pinnedEntries: space.pinnedEntries,
                                                favorites: space.profile?.favorites ?? []),
           PeekAnchor.shouldPeek(anchorURL: anchorURL, to: url,
                                 opensNewWindow: navigationAction.targetFrame == nil) {
            presentPeek(of: url, on: tab, firing: webView)
            return .cancel
        }

        // Apply Chrome UA spoofing for domains that require it — on the tab that
        // is navigating: `applySpoofedUserAgent` also *restores* the profile UA
        // for every other host, so keying this on `selectedTab` let any
        // background, peek or unfocused-pane navigation rewrite the focused
        // tab's UA.
        if let url = navigationAction.request.url, let tab = tab(owning: webView) {
            tab.applySpoofedUserAgent(for: url)
        }

        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // Intercept CRX extension downloads
        if isCRXResponse(navigationResponse) {
            DispatchQueue.main.async { [weak self] in
                self?.handleCRXDownload(from: navigationResponse.response.url)
            }
            return .cancel
        }

        if !navigationResponse.canShowMIMEType {
            return .download
        }
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    private func isCRXResponse(_ navigationResponse: WKNavigationResponse) -> Bool {
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        if mime == "application/x-chrome-extension" { return true }
        if let url = navigationResponse.response.url?.lastPathComponent.lowercased(),
           url.hasSuffix(".crx") { return true }
        return false
    }

    func handleCRXDownload(from url: URL?) {
        guard let url else { return }

        let filename = url.lastPathComponent.hasSuffix(".crx") ? url.lastPathComponent : "Extension.crx"
        let item = DownloadManager.shared.addManualItem(filename: filename, sourceURL: url)

        triggerDownloadAnimation(iconName: "puzzlepiece.extension.fill")

        // Download CRX data via URLSession with Chrome UA
        var request = URLRequest(url: url)
        request.setValue(UserAgentMode.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                let wasCancelled = item.state == .cancelled
                DownloadManager.shared.removeDownload(item)
                guard !wasCancelled else { return }
                self?.finishCRXInstall(data: data, error: error)
            }
        }
        item.observeURLSessionTask(task)
        task.resume()
    }

    private func finishCRXInstall(data: Data?, error: Error?) {
        guard let data, error == nil else {
            let alert = NSAlert()
            alert.messageText = "Failed to Download Extension"
            alert.informativeText = error?.localizedDescription ?? "Unknown error"
            alert.alertStyle = .critical
            alert.runModal()
            return
        }

        do {
            let crxResult = try CRXUnpacker.unpack(data: data)
            let unpackedDir = crxResult.directory
            defer { try? FileManager.default.removeItem(at: unpackedDir) }

            // Parse manifest for display name
            let manifestURL = unpackedDir.appendingPathComponent("manifest.json")
            let manifest = try ExtensionManifest.parse(at: manifestURL)
            let displayName = WebExtension.resolveI18nName(manifest.name, basePath: unpackedDir, defaultLocale: manifest.defaultLocale)

            let permissionSummary = ExtensionPermissionDescriptions.formatForAlert(
                permissions: manifest.permissions ?? [],
                hostPermissions: manifest.hostPermissions ?? [],
                optionalPermissions: manifest.optionalPermissions
            )

            let confirmAlert = NSAlert()
            confirmAlert.messageText = "Install \"\(displayName)\"?"
            confirmAlert.informativeText = permissionSummary
            confirmAlert.alertStyle = .warning
            confirmAlert.addButton(withTitle: "Install")
            confirmAlert.addButton(withTitle: "Cancel")

            guard confirmAlert.runModal() == .alertFirstButtonReturn else { return }

            try ExtensionManager.shared.install(from: unpackedDir, publicKey: crxResult.publicKey)

            let successAlert = NSAlert()
            successAlert.messageText = "Extension Installed"
            successAlert.informativeText = "\"\(displayName)\" has been installed and enabled."
            successAlert.alertStyle = .informational
            successAlert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Install Extension"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let sourceURL = navigationResponse.response.url
        download.delegate = DownloadManager.shared
        let item = DownloadManager.shared.handleNewDownload(download, sourceURL: sourceURL)
        _ = item // suppress unused warning
        triggerDownloadAnimation()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let sourceURL = navigationAction.request.url
        download.delegate = DownloadManager.shared
        let item = DownloadManager.shared.handleNewDownload(download, sourceURL: sourceURL)
        _ = item
        triggerDownloadAnimation()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.scheme == ErrorPage.scheme { return }
        tab(owning: webView)?.didCommitNavigation()

        // Native WKWebExtension handles chrome.webNavigation events
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Native WKWebExtension handles chrome.webNavigation events
    }

    // Both failure callbacks forward as they are: the tab decides which
    // failures earn an error page (`BrowserTab.didFailProvisionalNavigation`),
    // the same way for an owned web view as for one it is its own delegate of.

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab(owning: webView)?.didFailProvisionalNavigation(error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab(owning: webView)?.didFailNavigation(error: error)
    }

    /// A dead web content process leaves the view white and unresponsive with
    /// no callback ever following. This delegate is only wired on webviews
    /// this window owns (on-screen content), so reload — but cap rapid
    /// consecutive terminations: a page that kills its process on every load
    /// would otherwise drive an endless crash/reload cycle. Past the cap the
    /// pane stays blank; manual reloads still work, and 30s of quiet resets
    /// the streak (see noteProcessTermination).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(owning: webView) else {
            webView.reload()
            return
        }
        guard tab.noteProcessTermination() <= 2 else { return }
        tab.reload()
    }

    /// WebKit's per-list action report (`WKNavigationDelegatePrivate`): called
    /// whenever a content rule list acted on a load in `webView` — a real
    /// blocked load, unlike the `error`-event user script this replaces, which
    /// counted every resource that merely failed to load (TASK-69).
    ///
    /// `action` is a `_WKContentRuleListAction`; `blockedLoad` is read by key,
    /// the type being SPI, behind a `responds(to:)` guard like the feature's
    /// other SPI — an undefined key would raise an ObjC exception Swift cannot
    /// catch, on every blocked load. WebKit reports each list that acted on a
    /// URL, and the filter lists overlap, so the tab counts a URL once. A page
    /// whose content blockers are disabled (the per-site switch) produces no
    /// callbacks at all, so no whitelist check belongs here.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String,
                 performedAction action: NSObject, forURL url: URL) {
        guard action.responds(to: Self.blockedLoadSelector),
              action.value(forKey: "blockedLoad") as? Bool == true else { return }
        tab(owning: webView)?.recordBlockedLoad(of: url)
    }

    private static let blockedLoadSelector = NSSelectorFromString("blockedLoad")

    /// Resolve the tab (or peek tab) that owns the web view firing a navigation
    /// callback. Callbacks must act on the owning tab, not `selectedTab`: a peek
    /// web view or a navigation still in flight after a tab switch would
    /// otherwise attribute commits/errors (and error pages) to the wrong tab.
    ///
    /// The selected tab and its peek are checked first — the blocked-load report
    /// above fires once per blocked resource, hundreds of times on an ad-heavy
    /// page, and nearly always for the pane on screen. The other spaces come
    /// last: the delegate is never cleared from a tab's web view, so a tab of a
    /// space this window switched away from still reports here.
    func tab(owning webView: WKWebView) -> BrowserTab? {
        if let selected = selectedTab {
            if selected.webView === webView { return selected }
            if let peek = selected.peekTab, peek.webView === webView { return peek }
        }
        if let tab = tab(owning: webView, in: activeSpace) { return tab }
        return store.spaces.lazy
            .filter { $0.id != self.activeSpaceID }
            .compactMap { self.tab(owning: webView, in: $0) }
            .first
    }

    private func tab(owning webView: WKWebView, in space: Space?) -> BrowserTab? {
        space.flatMap { store.tab(hosting: webView, in: $0) }
    }

    /// The hosted pane a link activation fired from, for the peek branches
    /// (Shift+click, cross-host anchor): the selected tab or a pane of its split,
    /// never a peek's web view and never a background tab (TASK-48). Nil while a
    /// peek is up — the overlay owns the interaction.
    func peekHostTab(firing webView: WKWebView) -> BrowserTab? {
        guard peekOverlayView == nil, let selected = selectedTab else { return nil }
        let clicked = webView === selected.webView ? selected : tab(owning: webView)
        return PeekAnchor.interceptTab(clicked: clicked, selectedTab: selected,
                                       splitMembers: splitMembers(of: selected))
    }

    /// Presents `url` as a peek anchored on `tab`, the pane whose web view fired
    /// the link. `showPeekOverlay` anchors on `selectedTab`, so an unfocused pane
    /// is focused first (the synchronous `browserWebViewDidBecomeFirstResponder`
    /// retargets `selectedTabID`); if focus did not move the selection — a first
    /// responder that refuses to resign, or first responder already inside that
    /// pane while the selection names the other — fall back to selecting the pane
    /// outright rather than attaching the peek to the wrong tab. Deferred a turn so
    /// the policy decision returns before the view hierarchy changes.
    func presentPeek(of url: URL, on tab: BrowserTab, firing webView: WKWebView) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if tab.id != self.selectedTabID {
                self.window?.makeFirstResponder(webView)
                if tab.id != self.selectedTabID {
                    self.selectTab(id: tab.id)
                }
                guard tab.id == self.selectedTabID else { return }
            }
            let clickPoint = self.window.map {
                self.contentContainerView.convert($0.mouseLocationOutsideOfEventStream, from: nil)
            }
            self.showPeekOverlay(url: url, clickPoint: clickPoint)
        }
    }

    internal func triggerDownloadAnimation(iconName: String = "doc.fill") {
        guard let window = self.window else { return }
        let contentBounds = contentContainerView.bounds
        guard contentBounds.width > 0, contentBounds.height > 0 else { return }

        let sourcePoint = contentContainerView.convert(
            NSPoint(x: contentBounds.midX, y: contentBounds.midY), to: nil
        )
        guard sourcePoint.x.isFinite, sourcePoint.y.isFinite else { return }

        let destPoint: NSPoint
        if !sidebarItem.isCollapsed {
            let buttonFrame = tabSidebar.downloadButton.convert(tabSidebar.downloadButton.bounds, to: nil)
            guard buttonFrame.width > 0 else { return }
            destPoint = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        } else {
            destPoint = NSPoint(x: 20, y: 20)
        }

        DownloadAnimation.animate(in: window, from: sourcePoint, to: destPoint, iconName: iconName)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let window = self.window else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Log in to \(challenge.protectionSpace.host)"
        if let realm = challenge.protectionSpace.realm, !realm.isEmpty {
            alert.informativeText = realm
        }
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")

        let usernameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        usernameField.placeholderString = "Username"

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        passwordField.placeholderString = "Password"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 56))
        usernameField.frame = NSRect(x: 0, y: 32, width: 200, height: 24)
        passwordField.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        container.addSubview(usernameField)
        container.addSubview(passwordField)
        alert.accessoryView = container

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                let credential = URLCredential(user: usernameField.stringValue,
                                               password: passwordField.stringValue,
                                               persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
        }
    }
}

/// WebKit's own navigation error domain (`WebKitErrorDomain` in
/// WebKitErrors.h, a deprecated legacy-WebKit symbol — spelled out here).
private let webKitErrorDomain = "WebKitErrorDomain"

extension Error {
    /// Download-policy interruptions (WebKitErrorDomain 102) and cancellations
    /// (`NSURLErrorCancelled`, e.g. a page that navigates itself before its
    /// first load finishes) are not real navigation failures: a superseded load
    /// is followed by the load that replaced it, so a delegate that waits for
    /// a navigation to end must keep waiting for the replacement's
    /// `didFinish`/`didFail` rather than settle on one of these.
    var isSupersededNavigationError: Bool {
        let nsError = self as NSError
        // WebKitErrorFrameLoadInterruptedByPolicyChange
        if nsError.domain == webKitErrorDomain, nsError.code == 102 { return true }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        return false
    }

    /// A media document (a standalone video/audio URL): once the media player
    /// takes over fetching, WebKit cancels the main-resource load with
    /// `WebKitErrorPlugInWillHandleLoad` (204). The document is committed and
    /// keeps playing, so it is not a failure — but unlike a superseded load it
    /// IS the end of the navigation: WebKit reports it through `didFail` and no
    /// `didFinish` follows (TASK-121).
    var isPlugInHandledLoadError: Bool {
        let nsError = self as NSError
        return nsError.domain == webKitErrorDomain && nsError.code == 204
    }

    /// The failures a tab must not turn into an error page, whichever
    /// navigation delegate reports them: the page either is still loading
    /// (superseded) or is showing fine (media document). Callers that instead
    /// need "will another callback follow?" want `isSupersededNavigationError`
    /// alone.
    var isIgnoredNavigationError: Bool {
        isSupersededNavigationError || isPlugInHandledLoadError
    }
}
