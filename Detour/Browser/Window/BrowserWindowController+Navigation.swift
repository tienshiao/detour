import AppKit
import WebKit

// MARK: - WKNavigationDelegate

extension BrowserWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.navigationType == .linkActivated && navigationAction.modifierFlags.contains(.command) {
            if let url = navigationAction.request.url, let space = activeSpace {
                _ = store.addTab(in: space, url: url, parentID: selectedTabID)
            }
            return .cancel
        }

        // Shift+click: open link in peek view
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.shift),
           let url = navigationAction.request.url,
           let tab = selectedTab,
           webView === tab.webView,
           peekOverlayView == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let clickPoint = self.window.map {
                    self.contentContainerView.convert($0.mouseLocationOutsideOfEventStream, from: nil)
                }
                self.showPeekOverlay(url: url, clickPoint: clickPoint)
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

        // Open non-HTTP(S) URLs (App Store, mailto, etc.) externally
        if let url = navigationAction.request.url,
           let scheme = url.scheme,
           scheme != "http", scheme != "https",
           scheme != "about", scheme != ErrorPage.scheme {
            NSWorkspace.shared.open(url)
            return .cancel
        }

        if navigationAction.shouldPerformDownload {
            return .download
        }

        // Peek mode: intercept cross-host navigation on pinned tabs
        // Only intercept on the pinned tab's own webView, not the peek webView
        if let tab = selectedTab,
           let pinnedEntry = activeSpace?.pinnedEntries.first(where: { $0.tab?.id == tab.id }),
           webView === tab.webView,
           peekOverlayView == nil,
           let url = navigationAction.request.url,
           let pinnedHost = pinnedEntry.pinnedURL.host,
           let targetHost = url.host,
           targetHost != pinnedHost,
           navigationAction.navigationType == .linkActivated {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let clickPoint = self.window.map {
                    self.contentContainerView.convert($0.mouseLocationOutsideOfEventStream, from: nil)
                }
                self.showPeekOverlay(url: url, clickPoint: clickPoint)
            }
            return .cancel
        }

        // Fire chrome.webNavigation.onBeforeNavigate for extensions
        if let tab = selectedTab, let url = navigationAction.request.url {
            let mgr = ExtensionManager.shared
            let tabID = mgr.tabIDMap.intID(for: tab.id)
            mgr.fireWebNavigationEvent("onBeforeNavigate", details: [
                "tabId": tabID,
                "url": url.absoluteString,
                "frameId": 0,
                "timeStamp": Date().timeIntervalSince1970 * 1000
            ])
        }

        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
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
        selectedTab?.didCommitNavigation()

        // Fire chrome.webNavigation.onCommitted for extensions
        if let tab = selectedTab, let url = webView.url, let spaceID = activeSpaceID {
            let mgr = ExtensionManager.shared
            let tabID = mgr.tabIDMap.intID(for: tab.id)
            mgr.fireWebNavigationEvent("onCommitted", details: [
                "tabId": tabID,
                "url": url.absoluteString,
                "frameId": 0,
                "timeStamp": Date().timeIntervalSince1970 * 1000
            ])
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Fire chrome.webNavigation.onCompleted for extensions
        if let tab = selectedTab, let url = webView.url {
            let mgr = ExtensionManager.shared
            let tabID = mgr.tabIDMap.intID(for: tab.id)
            mgr.fireWebNavigationEvent("onCompleted", details: [
                "tabId": tabID,
                "url": url.absoluteString,
                "frameId": 0,
                "timeStamp": Date().timeIntervalSince1970 * 1000
            ])
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // WebKitErrorFrameLoadInterruptedByPolicyChange (102) fires when a navigation
        // becomes a download — not a real failure, so don't show an error page.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        selectedTab?.didFailProvisionalNavigation(error: error)

        // Fire chrome.webNavigation.onErrorOccurred for extensions
        if let tab = selectedTab, let url = webView.url ?? tab.url {
            let mgr = ExtensionManager.shared
            let tabID = mgr.tabIDMap.intID(for: tab.id)
            mgr.fireWebNavigationEvent("onErrorOccurred", details: [
                "tabId": tabID,
                "url": url.absoluteString,
                "frameId": 0,
                "error": nsError.localizedDescription,
                "timeStamp": Date().timeIntervalSince1970 * 1000
            ])
        }
    }

    internal func triggerDownloadAnimation() {
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

        DownloadAnimation.animate(in: window, from: sourcePoint, to: destPoint)
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
