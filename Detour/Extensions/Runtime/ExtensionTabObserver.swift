import Foundation
import WebKit

/// Observes TabStore mutations and notifies WKWebExtensionContexts about tab lifecycle events.
/// Only notifies contexts belonging to the tab's profile.
class ExtensionTabObserver: TabStoreObserver {

    func tabStoreDidInsertTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        for context in contexts(for: space) {
            context.didOpenTab(tab)
        }
    }

    func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        for context in contexts(for: space) {
            context.didCloseTab(tab, windowIsClosing: false)
        }
    }

    func tabStoreDidUpdateTab(_ tab: BrowserTab, at index: Int, in space: Space) {
        for context in contexts(for: space) {
            context.didChangeTabProperties(.URL, for: tab)
            context.didChangeTabProperties(.title, for: tab)
            context.didChangeTabProperties(.loading, for: tab)
        }
    }

    /// Dispatch a tab activation event. Called externally when tab selection changes.
    func dispatchActivated(tabID: UUID, spaceID: UUID) {
        guard let space = TabStore.shared.space(withID: spaceID),
              let tab = space.tabs.first(where: { $0.id == tabID })
                ?? space.pinnedEntries.compactMap({ $0.tab }).first(where: { $0.id == tabID }) else {
            return
        }
        for context in contexts(for: space) {
            context.didActivateTab(tab, previousActiveTab: nil)
        }
    }

    /// Get the extension contexts for a space's profile.
    private func contexts(for space: Space) -> [WKWebExtensionContext] {
        guard let profile = space.profile else { return [] }
        return Array(profile.extensionContexts.values)
    }
}
