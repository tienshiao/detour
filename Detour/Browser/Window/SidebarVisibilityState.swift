import Foundation

/// Pure model of the window sidebar's visibility mode (TASK-39).
///
/// The sidebar is either *pinned* (shown, `autoHides == false`) or *auto-hidden*
/// (collapsed, revealed temporarily by hovering the left window edge). The mode
/// follows what the user sees: any collapse or expand that did not come from
/// hover — Toggle Sidebar, dragging the split view divider, the split view
/// autosave restoring a collapsed sidebar at launch — sets `autoHides` to the
/// new collapsed state. Hover reveal and hover auto-hide never change the mode.
/// While a popover is open on the window, a hover-revealed sidebar stays put.
///
/// The hover hide is level-triggered (TASK-169): whenever the sidebar is
/// hover-revealed, not held, past the reveal grace period, and the pointer is
/// known to be elsewhere, the hide delay is running. Every report of where the
/// pointer is — an enter or exit event, the end of the grace period, the
/// window's periodic sample — goes through the same rule, so one missed exit
/// event cannot leave the sidebar open.
///
/// `BrowserWindowController` feeds events in and applies the returned actions;
/// it never mutates the mode directly.
struct SidebarVisibilityState: Equatable {
    /// Auto-hide mode: the sidebar stays collapsed except while hover-revealed.
    /// Also drives `automaticallyAdjustsSafeAreaInsets` on macOS 26.
    private(set) var autoHides = false
    /// The sidebar is currently shown only because the pointer hit the left edge;
    /// it hides again once the pointer is elsewhere.
    private(set) var openedByHover = false
    /// The collapsed state this window last requested (or accepted from
    /// outside). Source attribution for `isCollapsed` KVO: an observed value
    /// equal to it is this window's own toggle or hover change (whether its KVO
    /// fires synchronously inside `toggleSidebar` or later); a different value
    /// came from outside — a divider drag or an autosave restore.
    private(set) var expectedCollapsed = false
    /// A popover anchored to this window is open. Hover auto-hide waits for it
    /// to close: collapsing the sidebar takes a sidebar-anchored popover's
    /// positioning view away, and the popover with it (TASK-127).
    private(set) var heldOpen = false
    /// The short period right after a hover reveal. The sidebar is still
    /// sliding in under the pointer, so a pointer seen outside it does not
    /// start the hide delay yet; `hoverGraceEnded` looks again.
    private(set) var inRevealGrace = false
    /// The hide delay is running: a `scheduleAutoHide` was emitted and neither
    /// cancelled nor answered by `hoverHide`. Keeps the periodic pointer sample
    /// from restarting the delay on every tick.
    private(set) var hidePending = false

    /// The window should keep sampling where the pointer is: a hover-revealed
    /// sidebar must not depend on an exit event to hide again.
    var watchesPointer: Bool { openedByHover }

    enum Event: Equatable {
        /// View > Toggle Sidebar, Cmd+S, or the sidebar button.
        case toggle(isCollapsed: Bool)
        /// The pointer entered the left-edge hover zone.
        case hoverReveal(isCollapsed: Bool)
        /// The grace period started by `startHoverGrace` is over.
        case hoverGraceEnded(pointerInSidebar: Bool)
        /// Where the pointer is: the sidebar's tracking area reported an enter
        /// or an exit, or the window sampled the pointer position.
        case pointerObserved(inSidebar: Bool)
        /// The hover auto-hide delay elapsed. `pointerInSidebar` is where the
        /// pointer is now, not where it was when the delay started.
        case hoverHide(isCollapsed: Bool, pointerInSidebar: Bool)
        /// `sidebarItem.isCollapsed` changed (KVO), from any source. Also sent
        /// once right after setup, in case the split view autosave restored a
        /// collapsed sidebar without a KVO notification: with `expectedCollapsed`
        /// still at its initial `false`, that restore is adopted as external.
        case collapsedChanged(Bool)
        /// The window's first popover was shown.
        case holdBegan
        /// The window's last popover closed (or was found to be gone).
        case holdEnded(pointerInSidebar: Bool)
    }

    enum Action: Equatable {
        /// Set `automaticallyAdjustsSafeAreaInsets` on the content item (macOS 26).
        /// Emitted before `setCollapsed` so the layout pass sees the final value.
        case setSafeAreaAdjusts(Bool)
        /// Collapse or expand the sidebar (no-op when already in that state).
        case setCollapsed(Bool)
        /// Cancel a pending hover auto-hide.
        case cancelAutoHide
        /// Start the short grace period after a hover reveal; answer with
        /// `hoverGraceEnded` when it is over.
        case startHoverGrace
        /// Start the hover auto-hide delay; answer with `hoverHide` when it
        /// elapses.
        case scheduleAutoHide
    }

    mutating func reduce(_ event: Event) -> [Action] {
        switch event {
        case .toggle(let isCollapsed):
            // Decide from what is visible, not the flag: a collapsed or
            // hover-revealed sidebar gets pinned; a pinned one gets hidden.
            // Pinning a hover-revealed sidebar keeps it on screen.
            let currentlyHidden = isCollapsed || openedByHover
            endHoverSession()
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
            inRevealGrace = true
            hidePending = false
            expectedCollapsed = false
            return [.setCollapsed(false), .startHoverGrace]

        case .hoverGraceEnded(let pointerInSidebar):
            // An exit during the grace period was ignored, and no second exit
            // is coming: look at where the pointer is now.
            inRevealGrace = false
            return settleHide(pointerInSidebar: pointerInSidebar)

        case .pointerObserved(let inSidebar):
            return settleHide(pointerInSidebar: inSidebar)

        case .hoverHide(let isCollapsed, let pointerInSidebar):
            hidePending = false
            // Held: the hover session stays open; `holdEnded` reschedules.
            guard openedByHover, !heldOpen else { return [] }
            // The pointer came back without an enter event cancelling the
            // delay. The session goes on; the next exit or sample restarts it.
            guard !pointerInSidebar else { return [] }
            endHoverSession()
            guard !isCollapsed else { return [] }
            expectedCollapsed = true
            return [.setCollapsed(true)]

        case .collapsedChanged(let collapsed):
            if collapsed == expectedCollapsed {
                // Our own toggle/hover change (or a redundant notification).
                // A collapse always ends a hover session.
                if collapsed { endHoverSession() }
                return []
            }
            return adoptExternal(collapsed: collapsed)

        case .holdBegan:
            heldOpen = true
            hidePending = false
            return openedByHover ? [.cancelAutoHide] : []

        case .holdEnded(let pointerInSidebar):
            heldOpen = false
            // The pointer left for the popover while it was open, and that
            // exit did not start the delay. No further exit event is coming.
            return settleHide(pointerInSidebar: pointerInSidebar)
        }
    }

    /// The hide rule, applied to every report of where the pointer is. With
    /// the pointer in the sidebar no hide is pending; with the pointer
    /// elsewhere — and the sidebar hover-revealed, not held, and past the
    /// reveal grace period — one is. Idempotent: repeating a report neither
    /// restarts nor stacks the delay.
    private mutating func settleHide(pointerInSidebar: Bool) -> [Action] {
        guard openedByHover else { return [] }
        if pointerInSidebar {
            guard hidePending else { return [] }
            hidePending = false
            return [.cancelAutoHide]
        }
        guard !heldOpen, !inRevealGrace, !hidePending else { return [] }
        hidePending = true
        return [.scheduleAutoHide]
    }

    private mutating func endHoverSession() {
        openedByHover = false
        inRevealGrace = false
        hidePending = false
    }

    /// A collapse/expand that did not come from this window: the mode follows it.
    /// Never emits `setCollapsed`, so the KVO observer cannot re-enter a toggle.
    private mutating func adoptExternal(collapsed: Bool) -> [Action] {
        expectedCollapsed = collapsed
        endHoverSession()
        var actions: [Action] = [.cancelAutoHide]
        if autoHides != collapsed {
            autoHides = collapsed
            actions.append(.setSafeAreaAdjusts(collapsed))
        }
        return actions
    }
}
