import Combine
import Foundation
import WebKit

/// The single seam every "this tab exists / is gone / changed" notification to
/// the WKWebExtension contexts goes through (TASK-50).
///
/// Why it exists: WebKit only knows a web view belongs to a tab once some
/// `WKWebExtensionContext` has been told `didOpenTab`. A web view built from a
/// profile's configuration *always* gets content scripts injected, so a tab that
/// nobody reports still runs extension code — and every `runtime.sendMessage`
/// from it then fails inside WebKit with "Tab not found for message for content
/// script message". Favourite backing tabs and Peek tabs live outside
/// `space.tabs` / `space.pinnedEntries`, so the TabStore observer never saw
/// them; routing every notification through one place makes those paths a
/// one-line call instead of a duplicated loop over `profile.extensionContexts`.
protocol ExtensionTabLifecycleNotifying: AnyObject {
    func didOpen(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]?)
    func didClose(_ tab: BrowserTab, in profile: Profile)
    func didActivate(_ tab: BrowserTab, previousActiveTab: BrowserTab?, in profile: Profile,
                     contexts: [WKWebExtensionContext]?)
    func didChangeProperties(_ tab: BrowserTab, in profile: Profile,
                             properties: WKWebExtension.TabChangedProperties)
}

/// Production notifier: forwards to the profile's loaded contexts, or to the
/// subset a caller passes (a context that just loaded is told about the tabs
/// that were already open — see `ExtensionManager.notifyExistingTabs`).
final class WKExtensionTabLifecycleNotifier: ExtensionTabLifecycleNotifying {

    private func targets(_ profile: Profile, _ contexts: [WKWebExtensionContext]?) -> [WKWebExtensionContext] {
        contexts ?? Array(profile.extensionContexts.values)
    }

    func didOpen(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]?) {
        for context in targets(profile, contexts) {
            context.didOpenTab(tab)
        }
    }

    func didClose(_ tab: BrowserTab, in profile: Profile) {
        for context in targets(profile, nil) {
            context.didCloseTab(tab, windowIsClosing: false)
        }
    }

    func didActivate(_ tab: BrowserTab, previousActiveTab: BrowserTab?, in profile: Profile,
                     contexts: [WKWebExtensionContext]?) {
        for context in targets(profile, contexts) {
            context.didActivateTab(tab, previousActiveTab: previousActiveTab)
        }
    }

    func didChangeProperties(_ tab: BrowserTab, in profile: Profile,
                             properties: WKWebExtension.TabChangedProperties) {
        for context in targets(profile, nil) {
            context.didChangeTabProperties(properties, for: tab)
        }
    }
}

/// Static front door for the seam. Tests swap `notifier` for a recorder.
///
/// **The placement rule (TASK-52).** A tab is reported open the moment it
/// becomes *enumerable* — when it enters one of the containers
/// `extensionWindowTabs` reads (`Space.tabs`, `Space.pinnedEntries` /
/// `PinnedEntry.tab`, `Profile.favorites` / `Favorite.tab`, `BrowserTab.peekTab`)
/// while carrying a web view built from a profile's configuration — and again
/// when an already-placed tab builds a new web view (`wake()`). Each of those
/// containers has a one-line `didSet` calling `didPlace`; no creation path
/// reports a tab itself, so there is exactly one rule to keep true instead of
/// one call per way a tab can come into being.
///
/// The ordering that rule buys: `didOpenTab` fires `tabs.onCreated`, whose
/// parameters resolve `window(for:)` and that window's tab list, so the tab must
/// already be listed when it is reported. A container's `didSet` runs *after*
/// the mutation, so it is — which is why placement, not construction, is the
/// trigger (registering inside `BrowserTab.init` would report a tab nothing can
/// place yet).
///
/// The profile comes from the web view's own
/// `configuration.webExtensionController` (`Profile.profile(owning:)`), not from
/// the space: favourite and Peek tabs belong to a profile without living in any
/// space, and a tab whose configuration carries no controller runs no extension
/// code and is deliberately never reported.
///
/// **The section-move rule (TASK-59).** Moving a live tab between the tab list,
/// the pinned section and the favourites bar of one profile is a hand-off, not a
/// close: the tab keeps the web view WebKit already maps and stays registered,
/// so no `didClose`/`didOpen` pair is sent (`TabStore.detachTab` reports a
/// detach, which this seam deliberately ignores; `didPlace` is silent for an
/// already-registered tab). What the contexts are told instead is whatever the
/// move actually changed — today that is the pinned flag, via
/// `didChangePinned`, at each of the four hand-offs that flip it (pin, unpin,
/// pinned -> favourite, favourite -> pinned). A move that leaves the flag alone
/// (tab list <-> favourites) announces nothing.
///
/// A move *between profiles* is the other case and stays a close + re-open:
/// `didOpen` closes a tab it finds registered elsewhere, and a profile swap
/// closes its tabs explicitly (`TabStore.updateSpace`).
enum ExtensionTabLifecycle {

    /// Replaced by tests; the production value forwards to real contexts.
    static var notifier: any ExtensionTabLifecycleNotifying = WKExtensionTabLifecycleNotifier()

    /// Reports `tab` as open and remembers which profile was told, so the close
    /// side can be a plain `didClose(tab)` from `BrowserTab.teardown()` — the one
    /// point every tab (normal, pinned, favourite, peek) passes through, and the
    /// last moment its web view still exists.
    ///
    /// Re-notifying an already-registered tab is deliberate: `didOpenTab` is
    /// idempotent in WebKit, and a context that loads later has to be told about
    /// tabs that were opened before it existed.
    ///
    /// Also installs the tab's property observers, so its url/title/loading
    /// changes reach the contexts for as long as it stays registered.
    static func didOpen(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]? = nil) {
        // A tab re-reported under a different profile (its web view was rebuilt
        // from a new configuration after a profile swap) leaves the old
        // profile's contexts first, or they keep a phantom tab nothing closes.
        if let previous = tab.extensionRegisteredProfile, previous !== profile {
            didClose(tab)
        }
        tab.extensionRegisteredProfile = profile
        installPropertyObservers(on: tab)
        notifier.didOpen(tab, in: profile, contexts: contexts)
    }

    /// The profile whose extension controller built `tab`'s web view — nil for a
    /// tab with no web view (dormant tile, sleeping tab, parked peek), for a
    /// configuration carrying no controller (a test configuration, a space with
    /// no usable profile), and for a controller whose profile is gone.
    private static func owningProfile(of tab: BrowserTab) -> Profile? {
        guard let controller = tab.webView?.configuration.webExtensionController else { return nil }
        return Profile.profile(owning: controller)
    }

    /// `tab` just entered a container the window enumeration reads — report it
    /// open if it is a live extension-controller tab nobody has reported yet
    /// (TASK-52). Silent otherwise, so the container hooks can be unconditional.
    static func didPlace(_ tab: BrowserTab) {
        guard tab.extensionRegisteredProfile == nil, let profile = owningProfile(of: tab) else { return }
        didOpen(tab, in: profile)
    }

    /// A container's whole contents after a mutation. `didPlace` is already
    /// silent for a registered tab, so the hook passes the list as-is rather
    /// than diffing against `oldValue` (which would copy the array on every
    /// insert, remove and reorder just to find the newcomers).
    static func didPlace(listed tabs: [BrowserTab]) {
        for tab in tabs { didPlace(tab) }
    }

    /// `space` just entered `TabStore.spaces`. Its live tabs were placed while
    /// the space was detached (session restore, Undo Delete Space), so they were
    /// reported when no window could list them; re-announce them now that one
    /// can — like `didCreateWebView`, this bypasses the registered guard.
    static func didList(_ space: Space) {
        for tab in space.tabs + space.pinnedTabs {
            didCreateWebView(for: tab)
        }
    }

    /// An already-placed tab built a *new* web view (`BrowserTab.wake()`). Unlike
    /// `didPlace` this re-opens a tab that is already registered: WebKit maps a
    /// tab to a particular web view, so the new one has to be announced or the
    /// contexts keep the released view (TASK-52). Silent when the tab has no web
    /// view or the configuration carries no controller.
    static func didCreateWebView(for tab: BrowserTab) {
        guard let profile = owningProfile(of: tab) else { return }
        didOpen(tab, in: profile)
    }

    /// Property changes are observed on the tab itself rather than through
    /// `TabStore`'s per-tab subscriptions: those only cover tabs in a space's list
    /// or on `Profile.favorites`, so a Peek (held only by its host) never reached
    /// `didChangeTabProperties`, and pinned tabs were routed to a hook nobody
    /// mapped. One installation per registration; `didClose` removes them.
    private static func installPropertyObservers(on tab: BrowserTab) {
        guard tab.extensionPropertyObservers.isEmpty else { return }
        func observe<T: Equatable>(_ keyPath: KeyPath<BrowserTab, Published<T>.Publisher>,
                                   _ properties: WKWebExtension.TabChangedProperties) {
            tab[keyPath: keyPath]
                .dropFirst()
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak tab] _ in
                    guard let tab, let profile = tab.extensionRegisteredProfile else { return }
                    notifier.didChangeProperties(tab, in: profile, properties: properties)
                }
                .store(in: &tab.extensionPropertyObservers)
        }
        observe(\.$url, .URL)
        observe(\.$title, .title)
        observe(\.$isLoading, .loading)
    }

    /// No-op for a tab that was never reported open, and idempotent: the
    /// registration is cleared *before* notifying, so a second teardown (the
    /// peek close path fires two, by animation completion and by safety net)
    /// sends nothing.
    static func didClose(_ tab: BrowserTab) {
        guard let profile = tab.extensionRegisteredProfile else { return }
        tab.extensionRegisteredProfile = nil
        tab.extensionPropertyObservers.removeAll()
        notifier.didClose(tab, in: profile)
    }

    /// `previousActiveTab` is the tab the window was showing before, so
    /// extensions see the handover rather than an isolated activation (TASK-51).
    /// It is nil for a re-announcement that isn't a change of active tab — a
    /// woken pane, or a context being told about the tab that was already
    /// active when it loaded.
    static func didActivate(_ tab: BrowserTab, previousActiveTab: BrowserTab? = nil,
                            in profile: Profile, contexts: [WKWebExtensionContext]? = nil) {
        notifier.didActivate(tab, previousActiveTab: previousActiveTab, in: profile, contexts: contexts)
    }

    static func didChangeProperties(_ tab: BrowserTab, in profile: Profile,
                                    properties: WKWebExtension.TabChangedProperties) {
        notifier.didChangeProperties(tab, in: profile, properties: properties)
    }

    /// `tab` just crossed into or out of the pinned section (the section-move
    /// rule above): same tab, same web view, same profile, so the registration
    /// stands and the one thing extensions can observe — the flag
    /// `BrowserTab.isPinned(for:)` answers, which drives `tabs.query({pinned})`
    /// — is announced on its own (TASK-59).
    ///
    /// Call it *after* the tab is in the container it moved into: handling the
    /// change resolves the tab's window and index, which a tab in no section
    /// cannot answer. No-op for a tab no context was told about (a dormant entry
    /// that just materialized a sleeping tab, an incognito tab).
    static func didChangePinned(_ tab: BrowserTab) {
        guard let profile = tab.extensionRegisteredProfile else { return }
        didChangeProperties(tab, in: profile, properties: .pinned)
    }
}

/// The tabs a window reports to an extension, in sidebar order: pinned, then
/// normal, then the window profile's live favourite backing tabs — each
/// immediately followed by its Peek tab when that peek is live (a parked peek
/// has no web view, so WebKit has nothing to map it to and it must not appear).
func extensionWindowTabs(pinned: [BrowserTab], normal: [BrowserTab],
                         favorites: [BrowserTab]) -> [BrowserTab] {
    (pinned + normal + favorites).flatMap { tab -> [BrowserTab] in
        guard let peek = tab.peekTab, peek.webView != nil else { return [tab] }
        return [tab, peek]
    }
}
