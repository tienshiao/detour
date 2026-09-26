import AppKit
import WebKit

/// Opening an extension's options page from the browser side (TASK-103): the
/// Extensions menu's "Options…" item and the "Settings…" button in Extension
/// settings. `runtime.openOptionsPage()` from the extension itself goes through
/// the controller delegate, which reuses `optionsPageTab(for:in:preferring:)`.
///
/// Options and extension storage are per profile, so every entry point names
/// the profile whose context serves the page: the page is loaded with that
/// context's `webViewConfiguration`, and it opens in one of that profile's spaces.
extension ExtensionManager {

    /// The tab showing `extensionID`'s options page in `profile`: an existing
    /// one when a tab in any of the profile's spaces (normal or pinned) already
    /// shows it, otherwise a new extension tab in `preferredSpaceID` when that
    /// space belongs to the profile, else in the profile's first space.
    ///
    /// Nil when the profile holds no context for the extension (it is off
    /// there), when the context has no options page or web view configuration,
    /// or when the profile has no open space.
    @MainActor
    func optionsPageTab(for extensionID: String, in profile: Profile,
                        preferring preferredSpaceID: UUID? = nil) -> (tab: BrowserTab, space: Space)? {
        guard let context = profile.extensionContext(for: extensionID) else { return nil }
        return optionsPageTab(for: context, in: profile, preferring: preferredSpaceID)
    }

    /// `optionsPageTab(for:in:preferring:)` for a context already in hand.
    @MainActor
    func optionsPageTab(for context: WKWebExtensionContext, in profile: Profile,
                        preferring preferredSpaceID: UUID? = nil) -> (tab: BrowserTab, space: Space)? {
        guard let optionsURL = context.optionsPageURL,
              let configuration = context.webViewConfiguration else { return nil }

        let profileSpaces = TabStore.shared.spaces.filter { $0.profileID == profile.id }
        for space in profileSpaces {
            if let tab = (space.tabs + space.pinnedTabs).first(where: {
                Self.isOptionsPage($0.webView?.url ?? $0.url, optionsURL: optionsURL, baseURL: context.baseURL)
            }) {
                return (tab, space)
            }
        }

        let target = profileSpaces.first { $0.id == preferredSpaceID } ?? profileSpaces.first
        guard let space = target else { return nil }
        let tab = TabStore.shared.addExtensionTab(in: space, url: optionsURL, configuration: configuration)
        return (tab, space)
    }

    /// Whether `url` shows the options page: the context's own origin (scheme
    /// and host of its base URL — a fresh UUID host per loaded context, so
    /// another profile's copy never matches) and the options page's path.
    /// Query and fragment are ignored: an options page may route with either.
    static func isOptionsPage(_ url: URL?, optionsURL: URL, baseURL: URL) -> Bool {
        guard let url else { return false }
        return url.scheme == baseURL.scheme
            && url.host == baseURL.host
            && url.path == optionsURL.path
    }

    /// Open (or bring forward) `extensionID`'s options page in `profile` and
    /// show it in a browser window.
    ///
    /// The page opens in the space of the frontmost window already showing the
    /// profile (key, then main, then front-to-back), else the profile's first
    /// space. It is presented in a window already showing that space; else a
    /// normal window is switched to the space (a Private profile's spaces are
    /// only ever shown by their own Private window); else, for a normal
    /// profile, a new window opens on the space.
    ///
    /// - Returns: false when nothing could be opened — the extension is off in
    ///   the profile, it has no options page, or the profile has no open space
    ///   or window to show it in.
    @MainActor
    @discardableResult
    func openOptionsPage(for extensionID: String, in profile: Profile) -> Bool {
        let key = NSApp.keyWindow?.windowController as? BrowserWindowController
        let main = NSApp.mainWindow?.windowController as? BrowserWindowController
        let frontToBack = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
        let windows = [key, main].compactMap { $0 } + frontToBack

        let preferredSpaceID = windows.first { $0.activeSpace?.profileID == profile.id }?.activeSpaceID
        guard let opened = optionsPageTab(for: extensionID, in: profile,
                                          preferring: preferredSpaceID) else { return false }
        let tab = opened.tab
        let space = opened.space

        if let wc = windows.first(where: { $0.activeSpaceID == space.id }) {
            wc.selectTab(id: tab.id)
            wc.window?.makeKeyAndOrderFront(nil)
            return true
        }

        // Not on screen. Private spaces belong to their own Private window, so
        // there is nothing to switch or create for one.
        guard !profile.isIncognito else { return false }

        if let wc = windows.first(where: { !$0.isIncognito }) {
            wc.setActiveSpace(id: space.id, selectTab: false)
            wc.selectTab(id: tab.id)
            wc.window?.makeKeyAndOrderFront(nil)
            return true
        }

        guard let appDelegate = NSApp.delegate as? AppDelegate else { return false }
        let wc = appDelegate.createNewWindow(showing: space)
        wc.selectTab(id: tab.id)
        return true
    }
}
