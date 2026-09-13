import Foundation
import WebKit

/// Observes TabStore mutations and notifies WKWebExtensionContexts about tab lifecycle events.
/// Only notifies contexts belonging to the tab's profile — every notification
/// goes through `ExtensionTabLifecycle` so the off-list paths (favourites,
/// peeks) can report the same events from outside the store (TASK-50).
/// Property changes are not routed here: `ExtensionTabLifecycle.didOpen`
/// observes them on the tab itself, which covers peeks and pinned tabs that
/// never produce an indexed store update.
class ExtensionTabObserver: TabStoreObserver {

    /// Tests drive a private `TabStore(appDB:)`; the app uses the shared one.
    private let store: TabStore

    init(store: TabStore = .shared) {
        self.store = store
    }

    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        guard let profile = space.profile else { return }
        ExtensionTabLifecycle.didOpen(tab, in: profile)
    }

    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        ExtensionTabLifecycle.didClose(tab)
    }

    /// A profile created mid-session gets its enabled extensions (TASK-27).
    func tabStoreDidAddProfile(_ profile: Profile) {
        ExtensionManager.shared.profileWasAdded(profile)
    }

    /// Dispatch a tab activation event. Called externally when tab selection changes.
    func dispatchActivated(tabID: UUID, spaceID: UUID) {
        guard let space = store.space(withID: spaceID), let profile = space.profile,
              let tab = space.tabs.first(where: { $0.id == tabID })
                ?? space.pinnedTabs.first(where: { $0.id == tabID })
                ?? profile.favoriteTabs.first(where: { $0.id == tabID }) else {
            return
        }
        ExtensionTabLifecycle.didActivate(tab, in: profile)
    }
}
