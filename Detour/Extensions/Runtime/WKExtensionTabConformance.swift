import AppKit
import WebKit

// MARK: - BrowserTab + WKWebExtensionTab

extension BrowserTab: WKWebExtensionTab {
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard webView?.configuration.webExtensionController === context.webExtensionController else {
            return nil
        }
        return webView
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        let controllers = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
        // The window that currently shows this tab.
        if let wc = controllers.first(where: { $0.selectedTabID == id }) { return wc }
        // A presented Peek belongs to the window presenting it: two windows on
        // the same space both *list* the host's live peek, so the membership
        // fallback below could pick the one that is not showing it and WebKit
        // would then compute `isActive` against the wrong window (TASK-51).
        if let wc = controllers.first(where: { $0.extensionActiveTab === self }) { return wc }
        // Otherwise any window that lists it — the same enumeration as `tabs(for:)`,
        // so a tab is never listed by a window it does not belong to: a favourite
        // (per-profile, listed by every window on the profile) and a Peek (no
        // spaceID; hosted by any tab of the window, selected or not) both resolve
        // here (TASK-50).
        if let wc = controllers.first(where: { wc in wc.extensionTabs.contains { $0 === self } }) { return wc }
        // Fallback: the window on this tab's space.
        guard let spaceID else { return nil }
        return controllers.first { $0.activeSpaceID == spaceID }
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

    /// Required for `activeTab` to work. When `userGesturePerformed(in:)` is called,
    /// WebKit checks this to decide whether to create a temporary match pattern for the
    /// tab's URL. Defaults to `false` if not implemented, which silently blocks the grant.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        defer { completionHandler(nil) }
        let store = TabStore.shared
        // Favourites and Peeks are listed to extensions (TASK-50) but live outside
        // `space.tabs`, where `closeTab` looks — each closes through its own path.
        if let (profile, favorite) = store.favorite(backedBy: self) {
            store.deactivateFavorite(id: favorite.id, profileID: profile.id)
            return
        }
        if let host = store.tab(hostingPeek: self) {
            let controllers = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            if let wc = controllers.first(where: { $0.extensionActiveTab === self }) {
                wc.closePeekOverlay()
            } else {
                // Hidden or parked: no overlay to animate away.
                host.peekTab?.teardown()
                host.clearPeekState()
                store.scheduleSave()
            }
            return
        }
        guard let spaceID, let space = store.space(withID: spaceID) else { return }
        if let entry = space.pinnedEntries.first(where: { $0.tab === self }) {
            store.closePinnedTab(id: entry.id, in: space)
        } else {
            store.closeTab(id: id, in: space)
        }
    }
}
