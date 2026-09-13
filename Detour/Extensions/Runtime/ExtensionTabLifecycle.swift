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
    func didActivate(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]?)
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

    func didActivate(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]?) {
        for context in targets(profile, contexts) {
            context.didActivateTab(tab, previousActiveTab: nil)
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
        tab.extensionRegisteredProfile = profile
        installPropertyObservers(on: tab)
        notifier.didOpen(tab, in: profile, contexts: contexts)
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

    static func didActivate(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]? = nil) {
        notifier.didActivate(tab, in: profile, contexts: contexts)
    }

    static func didChangeProperties(_ tab: BrowserTab, in profile: Profile,
                                    properties: WKWebExtension.TabChangedProperties) {
        notifier.didChangeProperties(tab, in: profile, properties: properties)
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
