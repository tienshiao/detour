---
type: Feature
title: Sidebar visibility and auto-hide
description: The sidebar's two modes (pinned and auto-hidden), the pure SidebarVisibilityState reducer that attributes every collapse to its source, edge-hover reveal, and how open popovers hold a revealed sidebar.
tags: [sidebar, window, state-machine, popover]
status: stable
resource: ../../Detour/Browser/Window/SidebarVisibilityState.swift
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:41:30Z }
sources:
  - id: state
    resource: ../../Detour/Browser/Window/SidebarVisibilityState.swift
    title: SidebarVisibilityState.swift
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (setupSplitView, handleSidebarEvent, popover hold)
  - id: state-tests
    resource: ../../DetourTests/SidebarVisibilityStateTests.swift
    title: SidebarVisibilityStateTests.swift (also BrowserWindowSidebarModeTests)
  - id: task-39
    resource: backlog:TASK-39
    title: Collapsing the sidebar by dragging its divider leaves Toggle Sidebar out of sync
  - id: task-126
    resource: backlog:TASK-126
    title: The Downloads button's left and bottom edges do not respond to clicks
  - id: task-127
    resource: backlog:TASK-127
    title: With auto-hide on, the downloads popover disappears when the sidebar hides
---

# What it does

The [sidebar](./overview.md) is in one of two modes.

- **Pinned** — shown, and it stays shown.
- **Auto-hidden** — collapsed. Moving the pointer to the window's left edge
  reveals it; it hides again shortly after the pointer leaves it.

The mode follows what the user last did to the sidebar by any means other
than hover: View > Toggle Sidebar (Cmd+S), the sidebar button, dragging the
split divider until it collapses, or a collapsed sidebar restored from the
split view's autosave at launch. Hover reveal and hover hide never change
the mode. While the sidebar is collapsed the traffic lights are hidden, and
on macOS 26 the content item's `automaticallyAdjustsSafeAreaInsets` is set
to match the mode.

# How it works

## The reducer

`SidebarVisibilityState` is a value type with one method,
`reduce(_ event:) -> [Action]`. `BrowserWindowController` feeds it events and
applies the actions (`handleSidebarEvent`); it never changes the mode itself.

| State | Meaning |
|---|---|
| `autoHides` | The mode. `false` is pinned |
| `openedByHover` | Shown right now only because of an edge hover |
| `expectedCollapsed` | The collapsed state this window last asked for, or accepted from outside |
| `heldOpen` | A popover of this window is open |

| Event | From | Effect |
|---|---|---|
| `.toggle(isCollapsed:)` | Menu, Cmd+S, the button | Decided from what is visible: collapsed or hover-revealed → pin and show; pinned → hide. One press always flips what the user sees. Toggling a hover-revealed sidebar pins it in place |
| `.hoverReveal(isCollapsed:)` | Pointer entered the edge strip | Only in auto-hide mode and while collapsed: expand, start the grace period |
| `.hoverHide(isCollapsed:)` | The hide delay elapsed | Collapse, unless `heldOpen` |
| `.collapsedChanged(Bool)` | KVO on `sidebarItem.isCollapsed`, plus once at setup | Attribution, below |
| `.holdBegan` / `.holdEnded(pointerInSidebar:)` | First popover shown / last popover closed | Suspend hover hide / restart the hide delay if the pointer is already outside |

Actions: `setSafeAreaAdjusts`, `setCollapsed`, `cancelAutoHide`,
`startHoverGrace`, `scheduleAutoHide`.

## Attributing a collapse

The original bug: a divider drag collapsed the sidebar but left the mode flag
at "pinned", so the first Toggle Sidebar press did nothing visible and the
edge hover did nothing either.[^task-39] The mode had to follow collapses
the window did not ask for, without being flipped by its own.

The window cannot tell from the KVO callback who caused a change, so the
state remembers what it asked for. `expectedCollapsed` is set *before* any
`setCollapsed` action is applied. When `.collapsedChanged(v)` arrives:

- `v == expectedCollapsed` — this window's own toggle or hover change, or a
  redundant notification. No mode change (a collapse still ends a hover
  session).
- `v != expectedCollapsed` — external: a divider drag or an autosave
  restore. `adoptExternal` sets `autoHides = v` and the safe-area setting.

This holds whatever the timing. `toggleSidebar(nil)` and
`setPosition(0, ofDividerAt: 0)` were both observed to flip `isCollapsed`
and fire KVO synchronously inside the call, but a late notification is
attributed the same way.[^task-39]

Re-entrancy is safe for the same reason: `setCollapsed` triggers the KVO
inside `handleSidebarEvent`, the nested `reduce` sees the already-updated
`expectedCollapsed` and returns no actions. The external path never emits
`setCollapsed`, so the observer cannot start a toggle.

## Window glue

- `setupSplitView` creates the sidebar item (200–350 pt, `canCollapse`),
  registers the `isCollapsed` observer, then adds the split view to the
  window. Loading the split view applies the autosave, so a restored
  collapse arrives through the observer.[^task-39] One more
  `.collapsedChanged(sidebarItem.isCollapsed)` is sent right after as a
  safety net; the reducer ignores it if the observer already saw the
  restore.
- `sidebarCollapsedStateChanged` is the single funnel for both, and also
  hides or shows the traffic lights.
- **Edge strip** — `setupEdgeHoverTracking` lays a 20 pt wide view along the
  window's leading edge carrying a tracking area tagged `zone: "edge"`; a
  second tracking area tagged `"sidebar"` covers the sidebar view. The strip
  is a `ClickThroughView` (`hitTest` returns `nil`). As a plain `NSView` it
  took every click in the window's leftmost 20 pt, including the left side
  of the Downloads button, and with the sidebar hidden the page's left
  edge.[^task-126] Tracking areas do not depend on hit-testing.
- **Timing** — entering the edge sends `.hoverReveal`; the sidebar exit that
  follows within 0.5 s is ignored (`sidebarHoverGraceActive`). Leaving the
  sidebar schedules `.hoverHide` 0.5 s later; re-entering cancels it.
- **Popover hold** — the window observes `NSPopover.didShowNotification` and
  `didCloseNotification` and counts any popover whose window is a child of
  this window. `NSPopover` does not expose what it is anchored to, and while
  the sidebar is hover-revealed the pointer is in it, so that is where a
  popover comes from. This covers the downloads popover, the site settings
  popover and extension popups without touching their call sites.

# Edge cases

- **Why the hold exists.** Moving the pointer from a hover-revealed sidebar
  into a popover it opened leaves the sidebar; the hide then collapsed the
  sidebar, removed the popover's anchor view, and the popover went with
  it.[^task-127]
- **Hold ends with the pointer outside.** No exit event is coming, so
  `.holdEnded(pointerInSidebar: false)` returns `scheduleAutoHide`.
- **No drag-out affordance.** After a drag collapse there is no handle to
  drag the sidebar back; the edge hover and Toggle Sidebar are the way back.
  If AppKit does let the divider be dragged out, that expand is external and
  adopts pinned mode.[^task-39]
- **Show Archived Tabs** on a collapsed sidebar goes through
  `toggleSidebarAutoHide()`, which pins it.
- **A new tab opened while the sidebar is collapsed** shows an "Opened new
  tab in background" toast, since the row cannot be seen.
- **Content resizes.** Collapsing resizes the content container without
  changing the window frame; the split-formation veneer listens for the
  container's frame change for that reason
  ([split tabs hosting](../tabs/split-tabs-hosting.md)).

Known gaps, recorded and not fixed:[^task-127]

- The hold starts at `didShow`. A hide already due can fire before a popover
  that is presented late (an extension popup waits for its page to load). At
  `willShow` the popover's window is not yet a child of the browser window.
- Opening an extension popup *from* the settings popover closes one popover
  before the next shows; if that takes longer than the hide delay with the
  pointer outside, the sidebar can hide in between.
- The hold is released only by `didClose`. A standalone probe showed a
  `.semitransient` popover staying up with no `didClose` when its sidebar was
  collapsed under it; not reproduced in the app.
- Sidebar context menus are `NSMenu`, not popovers, and are not covered.

Not exercised with a real pointer: hover reveal firing through the
click-through strip, and the popover hold. Both were driven by injecting
reducer events in the running app; real tracking-area enter and exit events
cannot be synthesized.[^task-126][^task-127]

One difference from the task record: TASK-39's plan names a separate
`.restored(isCollapsed:)` event. The code has none; the setup-time sync
sends `.collapsedChanged`.

# Tests

- `SidebarVisibilityStateTests` drives the reducer through a small harness
  that models the synchronous KVO: toggle, drag collapse, hover, delayed
  KVO, re-entrancy, popover hold.
- `BrowserWindowSidebarModeTests` (same file) drives a real incognito
  `BrowserWindowController`: `setPosition(0, …)` collapses, the mode
  follows, one toggle expands; and an autosave round trip under a unique
  autosave name. AppKit writes the split view autosave on its own schedule,
  so that test polls for the write and skips if none appears within
  5 s.[^task-39]

# Related

- [Sidebar overview](./overview.md)
- [Browser window controller](../architecture/browser-window-controller.md) — owns the split view and applies the reducer's actions.
- [AppKit gotchas](../platform/appkit-gotchas.md) — click-eating overlay views, popovers and their anchor views.
- [UI probes](../playbooks/ui-probes.md) — the hit-test map that found the edge strip.
- [App shell](../architecture/app-shell.md) — the View > Toggle Sidebar menu item.
- [Profile data removal](../architecture/profile-data-removal.md) — `UserDefaultsScope`, which scopes the split view's autosave name to the data directory.

[^task-39]: Collapsing the sidebar by dragging its divider leaves Toggle Sidebar out of sync
[^task-126]: The Downloads button's left and bottom edges do not respond to clicks
[^task-127]: With auto-hide on, the downloads popover disappears when the sidebar hides
