import Foundation
import WebKit

/// The store's half of Quick Detour (TASK-193.1). A Quick Detour's page is a
/// `BrowserTab` in `quickDetourTabs` and in no space: never saved with the
/// session, never slept or swept by the archive timer (it is archived when
/// its window closes, TASK-193.5), never offered by a space's palette,
/// sidebar or now-playing bar. What it does take part in is listed on each
/// query below and in `wiki/features/quick-detour.md`.
extension TabStore {

    /// Opens the page of a new Quick Detour window on `profile`: a tab built
    /// from the profile's configuration (its data store, its extension
    /// controller), one adopting `webView`, or one built from the
    /// `configuration` WebKit hands a window a Quick Detour page opened.
    ///
    /// The tab is subscribed like a space's tab, so its visits are recorded —
    /// under the profile's Quick Detour scope — and its late titles corrected;
    /// and it is reported open to the extension contexts by entering
    /// `quickDetourTabs`, which a Quick Detour window lists.
    @discardableResult
    func openQuickDetourTab(profile: Profile, id: UUID = UUID(), adopting webView: WKWebView? = nil,
                            openedWith configuration: WKWebViewConfiguration? = nil,
                            restoring archived: QuickDetourArchivedPage? = nil) -> BrowserTab {
        let tab: BrowserTab
        if let webView {
            tab = BrowserTab(id: id, webView: webView)
        } else if let configuration {
            // A window the page opened (`createWebViewWith`): WebKit's copy of
            // the opener's configuration, with a user content controller of its
            // own, as `addTab(in:openedWith:)` gives a space's.
            configuration.userContentController = Space.makeUserContentController(for: profile)
            tab = BrowserTab(id: id, configuration: configuration)
        } else {
            tab = BrowserTab(id: id, configuration: Space.makeWebViewConfiguration(for: profile))
        }
        tab.quickDetourProfile = profile
        tab.applyUserAgent()
        if let archived {
            // From the archive (TASK-193.5): after the profile is known, so the
            // first request carries its user agent.
            tab.restoreArchivedPage(title: archived.title, interactionState: archived.interactionState,
                                    fallbackURL: archived.url, faviconURL: archived.faviconURL)
            // The archived title, rather than the address a load shows, until
            // the page reports its own.
            if !archived.title.isEmpty { tab.title = archived.title }
        }
        subscribeToTab(tab, inSession: false)
        // Last: entering the list reports the tab open to the extension
        // contexts, whose `window(for:)` must already resolve its window.
        quickDetourTabs.append(tab)
        return tab
    }

    /// Closes a Quick Detour's tab: out of the list, its subscriptions
    /// dropped, its web view released and its extension registration closed
    /// (`teardown`). Idempotent. When it was the last Private page of the
    /// session the Private session's in-memory state goes, as when the last
    /// Private window closes.
    ///
    /// `disposition` (TASK-193.5): archived (the default — closed by hand, by
    /// an extension's `tabs.remove`, or `autoClosed` by the idle timer) onto
    /// the Archived Tabs page, before it is torn down; a Private page never
    /// is, nor one already archived at quit; `.discard` for a profile being
    /// deleted.
    func closeQuickDetourTab(_ tab: BrowserTab, disposition: QuickDetourCloseDisposition = .archive(autoClosed: false)) {
        guard let index = quickDetourTabs.firstIndex(where: { $0 === tab }) else { return }
        // Before the teardown, which releases the web view the record's
        // back/forward list is read from.
        if case .archive(let autoClosed) = disposition {
            archiveQuickDetourTab(tab, autoClosed: autoClosed)
        }
        quickDetourTabIDsArchivedAtQuit.remove(tab.id)
        takeDownQuickDetourTab(at: index)
        if tab.quickDetourProfile?.isIncognito == true, !hasLivePrivateSession {
            siteSettings?.discardPrivateSession()
        }
        notifyObservers { $0.tabStoreDidCloseQuickDetour(tab) }
    }

    /// What a close and a profile switch share, in this order: the tab leaves
    /// the list, loses its subscriptions and is torn down, which reports it
    /// closed to its profile's extension contexts.
    private func takeDownQuickDetourTab(at index: Int) {
        let tab = quickDetourTabs.remove(at: index)
        unsubscribeFromTab(tab)
        tab.teardown()
    }

    // MARK: - The profile pill (TASK-193.4)

    /// Replaces an open Quick Detour's page with a new one on `profile`, for
    /// the same window (the profile pill): a web view cannot change its data
    /// store, so the page on another profile is a new `BrowserTab` with id
    /// `id`, built from that profile's configuration, and the old one is
    /// closed. The caller loads the address into it.
    ///
    /// - For the extension contexts it is a close and an open, never a move:
    ///   the old tab's close is reported to its profile's contexts (its
    ///   `teardown`), then `betweenPages` runs — neither page is in
    ///   `quickDetourTabs` then, so the window lists no tab while it tells the
    ///   old profile's contexts it closed and the new profile's that it opened
    ///   — and then the new tab enters the list, which reports it open.
    /// - History: the new tab is subscribed as a Quick Detour's, so its visits
    ///   go to the new profile's Quick Detour scope (none for Private); the
    ///   old one's stay where they were recorded.
    /// - The Private session ends when the old page was its last user, as on
    ///   a close (`hasLivePrivateSession`); a page switched into Private is a
    ///   user of it from here.
    /// - Observers hear `tabStoreDidReplaceQuickDetour` — never
    ///   `tabStoreDidCloseQuickDetour`, which would close the window. The
    ///   download manager drops what was scoped to the old Private page.
    ///
    /// Refused (nil, nothing changes) for a tab that is not an open Quick
    /// Detour's, for its own profile and for a deleted one.
    @discardableResult
    func replaceQuickDetourTab(_ tab: BrowserTab, withPageOn profile: Profile, id: UUID = UUID(),
                               betweenPages: () -> Void = {}) -> BrowserTab? {
        guard let index = quickDetourTabs.firstIndex(where: { $0 === tab }), let oldProfile = tab.quickDetourProfile,
              oldProfile !== profile, !profile.isDeleted else { return nil }
        takeDownQuickDetourTab(at: index)
        betweenPages()
        let replacement = openQuickDetourTab(profile: profile, id: id)
        if oldProfile.isIncognito, !hasLivePrivateSession {
            siteSettings?.discardPrivateSession()
        }
        notifyObservers { $0.tabStoreDidReplaceQuickDetour(tab, with: replacement) }
        return replacement
    }

    // MARK: - Open in (TASK-193.3)

    /// Whether `moveQuickDetourTab(_:into:)` would move `tab` into `space`:
    /// an open Quick Detour's page with its web view, into a space in the
    /// store of the same profile — a Private page only into a Private
    /// window's space, a normal one only into a normal space. Another
    /// profile's space would need another data store, which a web view cannot
    /// change: Open in reloads the address there instead.
    func canMoveQuickDetourTab(_ tab: BrowserTab, into space: Space) -> Bool {
        guard isQuickDetourTab(tab), tab.webView != nil, let profile = tab.quickDetourProfile,
              spaces.contains(where: { $0 === space }) else { return false }
        return space.profileID == profile.id && space.isIncognito == profile.isIncognito
    }

    /// Moves an open Quick Detour's page into `space` as a tab of it (Open
    /// in, TASK-193.3): the same `BrowserTab`, the same id and the same web
    /// view, so its back/forward list, scroll position, form state and
    /// `window.opener` all survive, as a Peek's page does when it becomes a
    /// tab (`expandPeekToNewTab`), and its in-flight load carries on.
    ///
    /// - Placed by the new-tab rule (`insertTab`, no parent: the top of the
    ///   list), subscribed again as a space's tab (its changes now save the
    ///   session); its `spaceID` is set and `quickDetourProfile` cleared, so
    ///   from here its visits are the space's while the ones it recorded as a
    ///   Quick Detour stay under that scope (`historySpaceID`).
    /// - Not a close for the extension contexts: the tab keeps its
    ///   registration and is announced as a move out of its popup window
    ///   (`ExtensionTabLifecycle.didMove`: `tabs.onDetached` from the Quick
    ///   Detour's window, `tabs.onAttached` to whichever browser window lists
    ///   the space, which the caller has already switched or opened). WebKit
    ///   lists a window's tabs only while one is selected in it, so a caller
    ///   that selects the tab afterwards passes `announcingMove: false` and
    ///   announces once it has (`ExtensionTabLifecycle.didMove(tab,
    ///   fromIndex: 0, in: popup)`) — Open in does.
    /// - Observers hear `tabStoreDidInsertTab` and then
    ///   `tabStoreDidMoveQuickDetour` — never `tabStoreDidCloseQuickDetour`,
    ///   so its window does not take the page down when it closes.
    ///
    /// Refused (nothing changes) as `canMoveQuickDetourTab` says.
    @discardableResult
    func moveQuickDetourTab(_ tab: BrowserTab, into space: Space, announcingMove: Bool = true) -> Bool {
        guard canMoveQuickDetourTab(tab, into: space),
              let index = quickDetourTabs.firstIndex(where: { $0 === tab }) else { return false }
        // Read before anything changes: the window the contexts were told the
        // tab is in, its popup (`ExtensionTabLifecycle.windowShowingTab`).
        let oldWindow = announcingMove ? ExtensionTabLifecycle.windowShowingTab(tab) : nil
        quickDetourTabs.remove(at: index)
        unsubscribeFromTab(tab)
        tab.quickDetourProfile = nil
        insertTab(tab, in: space, parentID: nil)
        // The one tab of the popup it leaves.
        if announcingMove { ExtensionTabLifecycle.didMove(tab, fromIndex: 0, in: oldWindow) }
        notifyObservers { $0.tabStoreDidMoveQuickDetour(tab, into: space) }
        return true
    }

    /// The Open in button and dropdown for a Quick Detour of `profile` opened
    /// from `sourceSpaceID`, from the store's spaces, profiles and
    /// `spaceUseOrder` (`QuickDetour.openInMenu`).
    func quickDetourOpenInMenu(profile: Profile, sourceSpaceID: UUID?) -> QuickDetourOpenInMenu {
        QuickDetour.openInMenu(windowProfile: Self.openInSnapshot(of: profile), sourceSpaceID: sourceSpaceID,
                               spaces: spaces.map(Self.openInSnapshot(of:)),
                               profiles: profiles.map(Self.openInSnapshot(of:)), useOrder: spaceUseOrder)
    }

    /// The profile pill's menu for a Quick Detour on `windowProfile`, from
    /// the store's profiles (`QuickDetour.profileMenu`).
    func quickDetourProfileMenu(windowProfile: Profile) -> QuickDetourProfileMenu {
        QuickDetour.profileMenu(windowProfileID: windowProfile.id, profiles: profiles.map(Self.openInSnapshot(of:)))
    }

    /// A profile as the Quick Detour rules (Open in, the profile pill) see it.
    static func openInSnapshot(of profile: Profile) -> QuickDetourProfileSnapshot {
        QuickDetourProfileSnapshot(id: profile.id, name: profile.name, isPrivate: profile.isIncognito,
                                   isDeleted: profile.isDeleted)
    }

    private static func openInSnapshot(of space: Space) -> QuickDetourSpaceSnapshot {
        QuickDetourSpaceSnapshot(id: space.id, name: space.name, emoji: space.emoji, profileID: space.profileID,
                                 isPrivate: space.isIncognito)
    }

    /// Closes every Quick Detour of `profile` — a profile being deleted.
    func closeQuickDetourTabs(of profile: Profile) {
        for tab in quickDetourTabs where tab.quickDetourProfile === profile {
            closeQuickDetourTab(tab, disposition: .discard)
        }
    }

    /// The open Quick Detour tab with `id`.
    func quickDetourTab(withID id: UUID) -> BrowserTab? {
        quickDetourTabs.first { $0.id == id }
    }

    /// Whether `tab` is an open Quick Detour's page.
    func isQuickDetourTab(_ tab: BrowserTab) -> Bool {
        quickDetourTabs.contains { $0 === tab }
    }

    /// Whether anything still uses the Private session: a Private window's
    /// space or a Private Quick Detour. The session's in-memory state (the
    /// Private site settings) goes only when neither is left.
    var hasLivePrivateSession: Bool {
        spaces.contains(where: \.isIncognito) || quickDetourTabs.contains { $0.quickDetourProfile?.isIncognito == true }
    }

    /// The download scopes of the Private pages still open: each Private
    /// window's space and each Private Quick Detour's tab. A Private download
    /// whose scope is not here is dropped (`DownloadManager`).
    var liveIncognitoDownloadScopeIDs: Set<UUID> {
        Set(spaces.lazy.filter(\.isIncognito).map(\.id))
            .union(quickDetourTabs.lazy.filter { $0.quickDetourProfile?.isIncognito == true }.map(\.id))
    }

    /// Every tab that may own a web view: the spaces' tabs and pinned backing
    /// tabs, the favourites' backing tabs, their Peeks, and the Quick Detour
    /// tabs. What the GPU process recycler asks about media.
    var allLiveTabs: [BrowserTab] {
        let owners = spaces.flatMap { $0.tabs + $0.pinnedTabs } + profiles.flatMap(\.favoriteTabs)
        return owners + owners.compactMap(\.peekTab) + quickDetourTabs
    }
}
