import Foundation
import WebKit

/// Observes TabStore mutations and notifies WKWebExtensionContexts about tab lifecycle events.
/// Only notifies contexts belonging to the tab's profile — every notification
/// goes through `ExtensionTabLifecycle` so the off-list paths (favourites,
/// peeks) can report the same events from outside the store (TASK-50).
/// Property changes are not routed here: `ExtensionTabLifecycle.didOpen`
/// observes them on the tab itself, which covers peeks and pinned tabs that
/// never produce an indexed store update, and activations are announced by the
/// window that owns them (`announceExtensionActiveTabIfChanged`, TASK-51) — a
/// store mutation cannot tell which window's active tab changed.
/// Nor are *opens*: a tab is reported when it becomes enumerable, by the
/// `didSet` on the container it enters (TASK-52) — an insert notification is one
/// creation path among several, and the off-list ones never produce one.
class ExtensionTabObserver: TabStoreObserver {

    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        ExtensionTabLifecycle.didClose(tab)
    }

    /// A profile created mid-session gets its enabled extensions (TASK-27).
    func tabStoreDidAddProfile(_ profile: Profile) {
        ExtensionManager.shared.profileWasAdded(profile)
    }
}
