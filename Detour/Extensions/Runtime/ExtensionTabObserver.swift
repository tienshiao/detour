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
/// Nor are *closes*: `BrowserTab.teardown()` reports them, at the last moment
/// the web view exists, and every removal path tears down before it notifies.
/// A removal that is *not* a teardown — `detachTab`, a hand-off to another
/// section of the same profile — must stay silent here (TASK-59): the tab keeps
/// its web view and its registration, and the section it lands in announces
/// whatever the move changed.
class ExtensionTabObserver: TabStoreObserver {

    /// A profile created mid-session gets its enabled extensions (TASK-27).
    func tabStoreDidAddProfile(_ profile: Profile) {
        ExtensionManager.shared.profileWasAdded(profile)
    }
}
