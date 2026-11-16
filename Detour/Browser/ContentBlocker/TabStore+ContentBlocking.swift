import WebKit

/// A rules change reaching every live web view of the spaces and favourites
/// (TASK-368).
///
/// Each tab's web view has its own user content controller, filled with its
/// profile's rule lists when the web view is built
/// (`Space.makeUserContentController(for:)`). A list switched on or off, a
/// refresh and Clear Cache & Redownload's recompile post
/// `.contentBlockerRulesDidChange`, and the shared store then replaces the
/// lists on every live web view in one pass. Until TASK-368 each browser
/// window replaced them only on its selected tab's panes, and only when it
/// owned their web view: a background tab kept the lists it was created with
/// until it was selected during a later change or its web view was rebuilt.
///
/// The pass is the store's rather than a window's because a web view exists
/// once whatever windows show its tab (only one hosts it, the others show a
/// snapshot): a window would need the ownership check the old handler had,
/// and two windows showing the same space would each touch the same tabs.
extension TabStore {
    /// A live web view whose rule lists follow a profile's switches.
    struct ContentBlockingPage {
        let tab: BrowserTab
        let webView: WKWebView
        /// The profile whose lists the web view was given when it was built.
        let profile: Profile
    }

    /// Every live web view a rules change replaces the lists on, once each:
    /// each space's tabs and pinned backing tabs with the space's profile,
    /// each profile's favourites' backing tabs with that profile, and the
    /// Peek of any of them with its host's profile.
    ///
    /// Not here:
    /// - a sleeping tab: its next web view is built with the current lists;
    /// - a Quick Detour's or a quarantine's page: its window replaces them
    ///   (`QuickDetourWindowController.contentBlockerRulesDidChange`,
    ///   TASK-359), so they are not applied twice;
    /// - a web view built from an extension context's configuration
    ///   (`servedExtensionOriginHost`): it never had lists, and its
    ///   controller is the extension's;
    /// - a space without a usable profile: its web views got no lists.
    var contentBlockingPages: [ContentBlockingPage] {
        var pages: [ContentBlockingPage] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ tab: BrowserTab, _ profile: Profile) {
            for candidate in [tab, tab.peekTab].compactMap({ $0 }) {
                guard let webView = candidate.webView, candidate.servedExtensionOriginHost == nil,
                      seen.insert(ObjectIdentifier(webView)).inserted else { continue }
                pages.append(ContentBlockingPage(tab: candidate, webView: webView, profile: profile))
            }
        }
        for space in spaces {
            guard let profile = space.usableProfile else { continue }
            for tab in space.tabs + space.pinnedTabs { add(tab, profile) }
        }
        for profile in profiles where !profile.isDeleted {
            for tab in profile.favoriteTabs { add(tab, profile) }
        }
        return pages
    }

    /// Replaces the rule lists on every page of `contentBlockingPages` with
    /// what its profile has switched on now, from `contentRuleStore`.
    func replaceContentRuleListsOnLivePages() {
        for page in contentBlockingPages {
            ContentBlockerManager.replaceRuleLists(on: page.webView.configuration.userContentController,
                                                   profile: page.profile, from: contentRuleStore)
        }
    }

    /// Runs `replaceContentRuleListsOnLivePages` on every
    /// `.contentBlockerRulesDidChange`. The shared store's only: a test's
    /// store has its own tabs and no business with the app's rules changes.
    func observeContentBlockerRuleChanges() {
        guard contentBlockerRulesObserver == nil else { return }
        contentBlockerRulesObserver = NotificationCenter.default.addMainObserver(
            forName: .contentBlockerRulesDidChange, object: nil) { [weak self] _ in
            self?.replaceContentRuleListsOnLivePages()
        }
    }
}
