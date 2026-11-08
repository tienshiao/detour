import AppKit
import Combine

/// The capsule over a pane whose tab an extension is driving (TASK-132.13
/// AC #5). It lives in the tab's `WebViewContainerView`, so it travels with the
/// pane and is hidden with it when the tab is parked; the window that hosts the
/// container decides whether it shows and follows the tab's owners while it
/// does, as it does for the dev toolbar.
extension BrowserWindowController {

    /// Re-decides every hosted pane's capsule and follows each pane's
    /// automation owners from here on. Runs at the end of every claim; the
    /// claim that hosts a container again replaces the sinks of the one before.
    func refreshAutomationBanners() {
        automationBannerSubscriptions.removeAll()
        for tab in hostedPaneTabs {
            updateAutomationBanner(for: tab, owners: tab.automationOwners)
            // Not `receive(on:)`: `@Published` emits before the property is
            // set, so the sink takes the new set from the value, and the
            // capsule follows an attach or a Stop at once.
            tab.$automationOwners
                .dropFirst()
                .sink { [weak self, weak tab] owners in
                    guard let self, let tab else { return }
                    self.updateAutomationBanner(for: tab, owners: owners)
                }
                .store(in: &automationBannerSubscriptions)
        }
    }

    /// Shows `tab`'s capsule while `owners` is non-empty, hides it otherwise.
    /// Not for a pane this window does not display: a pane hosted elsewhere
    /// is that window's to decide, and a parked one is hidden with its
    /// container.
    private func updateAutomationBanner(for tab: BrowserTab, owners: Set<TabAutomationOwner>) {
        guard let container = tab.webViewContainer, container.isDescendant(of: contentContainerView),
              !tab.isAutomationParked else { return }
        container.updateAutomationBanner(TabAutomationPresentation(owners: owners)) { [weak tab] in
            guard let tab else { return }
            TabAutomationStop.stopAll(on: tab)
        }
    }
}
