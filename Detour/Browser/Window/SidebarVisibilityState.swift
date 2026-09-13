import Foundation

/// Pure model of the window sidebar's visibility mode (TASK-39).
///
/// The sidebar is either *pinned* (shown, `autoHides == false`) or *auto-hidden*
/// (collapsed, revealed temporarily by hovering the left window edge). The mode
/// follows what the user sees: any collapse or expand that did not come from
/// hover — Toggle Sidebar, dragging the split view divider, the split view
/// autosave restoring a collapsed sidebar at launch — sets `autoHides` to the
/// new collapsed state. Hover reveal and hover auto-hide never change the mode.
///
/// `BrowserWindowController` feeds events in and applies the returned actions;
/// it never mutates the mode directly.
struct SidebarVisibilityState: Equatable {
    /// Auto-hide mode: the sidebar stays collapsed except while hover-revealed.
    /// Also drives `automaticallyAdjustsSafeAreaInsets` on macOS 26.
    private(set) var autoHides = false
    /// The sidebar is currently shown only because the pointer hit the left edge;
    /// leaving the sidebar hides it again.
    private(set) var openedByHover = false
    /// The collapsed state this window last requested (or accepted from
    /// outside). Source attribution for `isCollapsed` KVO: an observed value
    /// equal to it is this window's own toggle or hover change (whether its KVO
    /// fires synchronously inside `toggleSidebar` or later); a different value
    /// came from outside — a divider drag or an autosave restore.
    private(set) var expectedCollapsed = false

    enum Event: Equatable {
        /// View > Toggle Sidebar, Cmd+S, or the sidebar button.
        case toggle(isCollapsed: Bool)
        /// The pointer entered the left-edge hover zone.
        case hoverReveal(isCollapsed: Bool)
        /// The hover auto-hide delay elapsed after the pointer left the sidebar.
        case hoverHide(isCollapsed: Bool)
        /// `sidebarItem.isCollapsed` changed (KVO), from any source.
        case collapsedChanged(Bool)
        /// Initial sync after setup: the split view autosave may already have
        /// restored a collapsed sidebar before the KVO observer existed.
        case restored(isCollapsed: Bool)
    }

    enum Action: Equatable {
        /// Set `automaticallyAdjustsSafeAreaInsets` on the content item (macOS 26).
        /// Emitted before `setCollapsed` so the layout pass sees the final value.
        case setSafeAreaAdjusts(Bool)
        /// Collapse or expand the sidebar (no-op when already in that state).
        case setCollapsed(Bool)
        /// Cancel a pending hover auto-hide.
        case cancelAutoHide
        /// Start the short grace period that ignores the sidebar exit right
        /// after a hover reveal.
        case startHoverGrace
    }

    mutating func reduce(_ event: Event) -> [Action] {
        switch event {
        case .toggle(let isCollapsed):
            // Decide from what is visible, not the flag: a collapsed or
            // hover-revealed sidebar gets pinned; a pinned one gets hidden.
            // Pinning a hover-revealed sidebar keeps it on screen.
            let currentlyHidden = isCollapsed || openedByHover
            openedByHover = false
            autoHides = !currentlyHidden
            var actions: [Action] = [.cancelAutoHide, .setSafeAreaAdjusts(autoHides)]
            expectedCollapsed = autoHides
            if isCollapsed != autoHides {
                actions.append(.setCollapsed(autoHides))
            }
            return actions

        case .hoverReveal(let isCollapsed):
            guard autoHides, isCollapsed else { return [] }
            openedByHover = true
            expectedCollapsed = false
            return [.setCollapsed(false), .startHoverGrace]

        case .hoverHide(let isCollapsed):
            guard openedByHover else { return [] }
            openedByHover = false
            guard !isCollapsed else { return [] }
            expectedCollapsed = true
            return [.setCollapsed(true)]

        case .collapsedChanged(let collapsed):
            if collapsed == expectedCollapsed {
                // Our own toggle/hover change (or a redundant notification).
                // A collapse always ends a hover session.
                if collapsed { openedByHover = false }
                return []
            }
            return adoptExternal(collapsed: collapsed)

        case .restored(let isCollapsed):
            guard isCollapsed != expectedCollapsed || isCollapsed != autoHides else { return [] }
            return adoptExternal(collapsed: isCollapsed)
        }
    }

    /// A collapse/expand that did not come from this window: the mode follows it.
    /// Never emits `setCollapsed`, so the KVO observer cannot re-enter a toggle.
    private mutating func adoptExternal(collapsed: Bool) -> [Action] {
        expectedCollapsed = collapsed
        openedByHover = false
        var actions: [Action] = [.cancelAutoHide]
        if autoHides != collapsed {
            autoHides = collapsed
            actions.append(.setSafeAreaAdjusts(collapsed))
        }
        return actions
    }
}
