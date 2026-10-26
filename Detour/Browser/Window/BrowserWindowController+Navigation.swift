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
        // Before the decision: a navigation refused below never starts, and the
        // tab must still learn its web process read the request (TASK-176).
        if navigationAction.targetFrame?.isMainFrame == true {
            tab(owning: webView)?.didReceiveMainFrameNavigationPolicyRequest()
        }
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

        // Opt-Cmd-click (TASK-193.5): a Quick Detour on the page's profile — a
        // Private page's is Private — in any frame, a `target=_blank` link
        // too, and inside a Peek. Before Cmd, which it contains; never routed
        // (the user chose where it opens). Off in Settings, it is a Cmd+click.
        // Only for a real click: a script's synthetic Opt-Cmd `click()` must
        // not open windows in front (it falls through to the Cmd branch).
        if navigationAction.navigationType == .linkActivated, Self.isUserGesture(navigationAction),
           let url = navigationAction.request.url,
           inPageLinkClickBranch(Self.linkClickModifiers(navigationAction.modifierFlags), target: url,
                                 quickDetourClickEnabled: QuickDetourSettings.shared.isOptionCommandClickEnabled)
            == .quickDetour {
            openQuickDetour(url, firing: webView)
            return .cancel
        }

        if navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command) {
            // A route that moves the link to another space (or a Private
            // window) opens it there instead of in a background tab here
            // (TASK-191.4).
            guard let url = navigationAction.request.url else { return .cancel }
            if let routed = routedDecision(for: inPageLinkRequest(for: navigationAction, to: url, in: webView,
                                                                  entry: Self.linkRoutingEntry(for: navigationAction))) {
                openRoutedLink(url, routed)
                return .cancel
            }
            if let space = activeSpace {
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
                self?.openLinkInSplit(url, from: clickedTab, in: space)
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

        // URLs a web view does not load itself (App Store, mailto, zoommtg,
        // etc.) belong to an external application — only after the user
        // confirms (TASK-84). Which schemes those are is the policy's rule.
        if let url = navigationAction.request.url,
           let scheme = url.scheme,
           ExternalAppLaunchPolicy.isForExternalApp(scheme: scheme) {
            handleExternalAppNavigation(to: url, action: navigationAction, in: webView)
            return .cancel
        }

        if navigationAction.shouldPerformDownload {
            return .download
        }

        // Air Traffic Control (TASK-191.4), then the Peek intercept. A plain
        // click to another host or a target=_blank link that a route sends to
        // another space (or a Private window) opens there; the tab stays on
        // its page. Which navigations may route at all — not redirects,
        // scripts, same-host clicks, Peek contents, subframes — is the pure
        // `linkRoutingEligibility`; that a route elsewhere wins over the
        // intercept is `inPageLinkOutcome`.
        //
        // Peek mode: intercept cross-host navigation, and every target=_blank
        // link, on pinned tabs and favourites (`PeekAnchor.shouldPeek`). A
        // _blank link reaches this with a nil targetFrame before WebKit would
        // call createWebViewWith; script window.open() never does. The anchored
        // tab is the pane that fired, not the selection: in a pinned split the
        // link can come from the unfocused pane (TASK-48) — see `peekHostTab`.
        // Only a link activation can route or peek: other navigations (subframe
        // loads, script navigations, reloads) skip the request's lookups.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            let routed = routedDecision(for: inPageLinkRequest(for: navigationAction, to: url, in: webView,
                                                               entry: Self.linkRoutingEntry(for: navigationAction)))
            var peekHost: BrowserTab?
            if let space = activeSpace,
               let tab = peekHostTab(firing: webView),
               let anchorURL = PeekAnchor.anchorURL(forTabID: tab.id,
                                                    pinnedEntries: space.pinnedEntries,
                                                    favorites: space.profile?.favorites ?? []),
               PeekAnchor.shouldPeek(anchorURL: anchorURL, to: url,
                                     opensNewWindow: navigationAction.targetFrame == nil) {
                peekHost = tab
            }
            if performInPageLinkOutcome(for: url, routed: routed, peekHost: peekHost, firing: webView) {
                return .cancel
            }
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
        if Self.isCRXResponse(navigationResponse) {
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

    /// Whether a response is an extension package, which is offered for
    /// install rather than downloaded — in a browser window or a Quick
    /// Detour (TASK-193.1).
    static func isCRXResponse(_ navigationResponse: WKNavigationResponse) -> Bool {
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        if mime == "application/x-chrome-extension" { return true }
        if let url = navigationResponse.response.url?.lastPathComponent.lowercased(),
           url.hasSuffix(".crx") { return true }
        return false
    }

    func handleCRXDownload(from url: URL?) {
        Self.downloadAndOfferCRX(from: url, scope: downloadScope) { [weak self] in
            self?.triggerDownloadAnimation(iconName: "puzzlepiece.extension.fill")
        }
    }

    /// Fetches the package at `url` as a listed download of `scope`, then
    /// runs the install gate and asks the user. Shared by a browser window
    /// and a Quick Detour window; `didStart` is the window's own feedback.
    static func downloadAndOfferCRX(from url: URL?, scope: DownloadScope, didStart: () -> Void) {
        guard let url else { return }

        let filename = url.lastPathComponent.hasSuffix(".crx") ? url.lastPathComponent : "Extension.crx"
        let item = DownloadManager.shared.addManualItem(filename: filename, sourceURL: url, scope: scope)

        didStart()

        // Download CRX data via URLSession with Chrome UA
        var request = URLRequest(url: url)
        request.setValue(UserAgentMode.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let wasCancelled = item.state == .cancelled
                DownloadManager.shared.removeDownload(item)
                guard !wasCancelled else { return }
                // The URL the bytes were served from, after this fetch's own
                // redirects: it is what the prompt names and what decides
                // whether this counts as a store install.
                finishCRXInstall(data: data, error: error, downloadURL: response?.url ?? url)
            }
        }
        item.observeURLSessionTask(task)
        task.resume()
    }

    private static func finishCRXInstall(data: Data?, error: Error?, downloadURL: URL) {
        guard let data, error == nil else {
            let alert = NSAlert()
            alert.messageText = "Failed to Download Extension"
            alert.informativeText = error?.localizedDescription ?? "Unknown error"
            alert.alertStyle = .critical
            alert.runModal()
            return
        }

        // What the alerts may say about where the file is from. Until the
        // signatures pass that is the URL alone, and a store host is then only
        // "not verified as signed by the store" (TASK-157).
        var origin = CRXInstallGate.Origin(unverified: downloadURL)
        do {
            // Nothing is unpacked, shown or installed from a file that does not
            // pass the gate: verified signatures (the store's own among them
            // for a file a store host served), an id that is not installed, and
            // a manifest key that agrees with the signing key (TASK-151).
            let verified = try CRXInstallGate.verify(crxData: data, downloadURL: downloadURL)
            origin = verified.origin
            let candidate = try CRXInstallGate.admit(verified, crxData: data) { Self.installedExtension(withID: $0) }
            let unpackedDir = candidate.directory
            defer { try? FileManager.default.removeItem(at: unpackedDir) }

            let manifest = candidate.manifest
            let displayName = WebExtension.resolveI18nName(manifest.name, basePath: unpackedDir, defaultLocale: manifest.defaultLocale)

            let permissionSummary = ExtensionPermissionDescriptions.formatForAlert(
                permissions: manifest.permissions ?? [],
                hostPermissions: manifest.hostPermissions ?? [],
                optionalPermissions: manifest.optionalPermissions
            )

            let confirmAlert = NSAlert()
            confirmAlert.messageText = "Install \"\(displayName)\"?"
            confirmAlert.informativeText = origin.description + "\n\n" + permissionSummary
            confirmAlert.alertStyle = .warning
            confirmAlert.addButton(withTitle: "Install")
            confirmAlert.addButton(withTitle: "Cancel")

            guard confirmAlert.runModal() == .alertFirstButtonReturn else { return }

            // The prompt ran a modal loop: the id may have been installed
            // meanwhile (a second download of the same file).
            if let existing = Self.installedExtension(withID: candidate.extensionID) {
                throw CRXInstallGate.Refusal.alreadyInstalled(existing)
            }

            // Where it came from decides whether it updates (TASK-113): a store
            // install polls the store; another CRX polls only a URL its
            // manifest names. "From the store" is the gate's verdict — served
            // by the store and signed by it — not the URL's (TASK-157).
            var options = ExtensionInstaller.Options()
            (options.source, options.updateURL) = ExtensionSource.classifyCRX(
                fromWebStore: candidate.origin == .webStore, manifestUpdateURL: manifest.updateURL)
            try ExtensionManager.shared.install(from: unpackedDir, publicKey: candidate.publicKey, options: options)

            let successAlert = NSAlert()
            successAlert.messageText = "Extension Installed"
            successAlert.informativeText = "\"\(displayName)\" has been installed and enabled."
            successAlert.alertStyle = .informational
            successAlert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = error is CRXInstallGate.Refusal ? "Extension Not Installed" : "Failed to Install Extension"
            alert.informativeText = error.localizedDescription + "\n\n" + origin.description
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    /// The installed extension with `id`, as the CRX install gate reports it.
    private static func installedExtension(withID id: String) -> CRXInstallGate.Installed? {
        ExtensionManager.shared.extension(withID: id).map {
            CRXInstallGate.Installed(name: $0.resolveI18n($0.manifest.name), version: $0.manifest.version)
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let sourceURL = navigationResponse.response.url
        download.delegate = DownloadManager.shared
        let item = DownloadManager.shared.handleNewDownload(download, sourceURL: sourceURL, scope: downloadScope)
        _ = item // suppress unused warning
        triggerDownloadAnimation()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let sourceURL = navigationAction.request.url
        download.delegate = DownloadManager.shared
        let item = DownloadManager.shared.handleNewDownload(download, sourceURL: sourceURL, scope: downloadScope)
        _ = item
        triggerDownloadAnimation()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let committingTab = tab(owning: webView)
        // Even an error page: the old page's Media Session is gone (TASK-192).
        committingTab?.nowPlayingDocumentDidCommit()
        if webView.url?.scheme == ErrorPage.scheme { return }
        committingTab?.didCommitNavigation()

        // Native WKWebExtension handles chrome.webNavigation events
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Native WKWebExtension handles chrome.webNavigation events
    }

    // The failure forwards as it is: the tab decides which failures earn an
    // error page (`BrowserTab.didFailProvisionalNavigation`), the same way for
    // an owned web view as for one it is its own delegate of. A failure after
    // commit (`didFail`) is deliberately not implemented; see there.

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab(owning: webView)?.didFailProvisionalNavigation(error: error)
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
        // The tab replaced an unresponsive process itself and issues the load
        // it was asked for when the kill returns (TASK-176): not a crash.
        guard !tab.isTerminatingUnresponsiveProcess else { return }
        tab.webProcessDidTerminate()
        guard tab.noteProcessTermination() <= 2 else { return }
        tab.reload()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab(owning: webView)?.didStartProvisionalNavigation()
    }

    /// `WKNavigationDelegatePrivate`: the web process has not answered for
    /// three seconds after a load request or an input event. WebKit does
    /// nothing further; see `UnresponsiveLoadRecovery`.
    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    func webViewWebProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        tab(owning: webView)?.webProcessDidBecomeUnresponsive()
    }

    @objc(_webViewWebProcessDidBecomeResponsive:)
    func webViewWebProcessDidBecomeResponsive(_ webView: WKWebView) {
        tab(owning: webView)?.webProcessDidBecomeResponsive()
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

    /// Opens `url` in a split from `clickedTab`, the tab whose page the link is
    /// in: Option-click, and the link menu's Open Link in Split View (TASK-185).
    func openLinkInSplit(_ url: URL, from clickedTab: BrowserTab, in space: Space) {
        if let group = store.splitGroup(containing: clickedTab.id, in: space),
           let otherPane = group.members.first(where: { $0.id != clickedTab.id }) {
            // Already split: send the link to the other pane.
            otherPane.load(url)
            return
        }
        // Selected right below, so not a background tab.
        let newPane: BrowserTab? = withoutBackgroundTabToast {
            switch store.splitOpening(from: clickedTab.id, in: space) {
            case .besideTab:
                // The clicked tab becomes the left pane.
                store.addTabInSplit(with: clickedTab.id, url: url, in: space)
            case .inNormalSection:
                // A favourite or a lone pinned tab stays put: a copy of it is the
                // left pane of a new split in the normal section.
                store.addSplitInNormalSection(copying: clickedTab.id, rightPane: .url(url), in: space)
            case nil:
                nil
            }
        }
        if let newPane {
            // The new right pane, focused.
            selectTab(id: newPane.id)
        } else {
            // A peek, a pinned split pane whose partner is dormant, an
            // extension's page — fall back to Cmd+click behavior (background tab).
            _ = store.addTab(in: space, url: url, parentID: selectedTabID)
        }
    }

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
        HTTPAuthenticationPrompt.handle(challenge, in: window, completionHandler: completionHandler)
    }
}

/// The HTTP Basic/Digest sign-in sheet: a browser window's and a Quick Detour
/// window's (TASK-193.1). Every other challenge gets WebKit's default.
enum HTTPAuthenticationPrompt {
    static func handle(_ challenge: URLAuthenticationChallenge, in window: NSWindow?,
                       completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let window else {
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
    /// (superseded) or is showing fine (media document). The 204 arrives after
    /// commit, where a tab no longer acts on any failure (TASK-178), so for a
    /// tab that half is a backstop. Callers that instead need "will another
    /// callback follow?" want `isSupersededNavigationError` alone.
    var isIgnoredNavigationError: Bool {
        isSupersededNavigationError || isPlugInHandledLoadError
    }
}
