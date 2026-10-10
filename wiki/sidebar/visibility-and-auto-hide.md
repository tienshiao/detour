---
type: Feature
title: Sidebar visibility and auto-hide
description: The sidebar's two modes (pinned and auto-hidden), the pure SidebarVisibilityState reducer that attributes every collapse to its source, edge-hover reveal, the level-triggered hover hide, and how open popovers hold a revealed sidebar.
tags: [sidebar, window, state-machine, popover]
status: stable
resource: ../../Detour/Browser/Window/SidebarVisibilityState.swift
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-10T07:45:28Z }
sources:
  - id: state
    resource: ../../Detour/Browser/Window/SidebarVisibilityState.swift
    title: SidebarVisibilityState.swift
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (setupSplitView, handleSidebarEvent, pointer sample, popover hold)
  - id: state-tests
    resource: ../../DetourTests/SidebarVisibilityStateTests.swift
    title: SidebarVisibilityStateTests.swift (also BrowserWindowSidebarModeTests)
  - id: harness
    resource: ../../docs/harness/task169-harness.patch
    title: TASK-169 runtime harness (temporary code, kept as a patch)
  - id: task-39
    resource: backlog:TASK-39
    title: Collapsing the sidebar by dragging its divider leaves Toggle Sidebar out of sync
  - id: task-126
    resource: backlog:TASK-126
    title: The Downloads button's left and bottom edges do not respond to clicks
  - id: task-127
    resource: backlog:TASK-127
    title: With auto-hide on, the downloads popover disappears when the sidebar hides
  - id: task-169
    resource: backlog:TASK-169
    title: A hover-revealed sidebar sometimes stays open instead of hiding again
---

# What it does

The [sidebar](./overview.md) is in one of two modes.

- **Pinned** — shown, and it stays shown.
- **Auto-hidden** — collapsed. Moving the pointer to the window's left edge
  reveals it; it hides again shortly after the pointer is no longer over it.

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
| `inRevealGrace` | The short period right after a hover reveal, while the sidebar slides in |
| `hidePending` | The hide delay is running |

| Event | From | Effect |
|---|---|---|
| `.toggle(isCollapsed:)` | Menu, Cmd+S, the button | Decided from what is visible: collapsed or hover-revealed → pin and show; pinned → hide. One press always flips what the user sees. Toggling a hover-revealed sidebar pins it in place |
| `.hoverReveal(isCollapsed:)` | Pointer entered the edge strip | Only in auto-hide mode and while collapsed: expand, start the grace period |
| `.hoverGraceEnded(pointerInSidebar:)` | The grace timer | Ends the grace period and applies the hide rule to where the pointer is now |
| `.pointerObserved(inSidebar:)` | The sidebar's tracking area (enter, exit) and the window's pointer sample | Applies the hide rule |
| `.hoverHide(isCollapsed:pointerInSidebar:)` | The hide delay elapsed | Collapse, unless `heldOpen` or the pointer is back in the sidebar |
| `.collapsedChanged(Bool)` | KVO on `sidebarItem.isCollapsed`, plus once at setup | Attribution, below |
| `.holdBegan` / `.holdEnded(pointerInSidebar:)` | A popover of the window is up / none is any more | Suspend hover hide / apply the hide rule |

Actions: `setSafeAreaAdjusts`, `setCollapsed`, `cancelAutoHide`,
`startHoverGrace`, `scheduleAutoHide`. `watchesPointer` (true while
`openedByHover`) tells the window when to run its pointer sample.

## The hide rule is level-triggered

Every report of where the pointer is goes through one rule (`settleHide`):

- pointer in the sidebar → no hide is pending (a pending one is cancelled);
- pointer elsewhere, and the sidebar is hover-revealed, not held and past
  the grace period → the hide delay is running (started once, not restarted
  by repeated reports).

When the delay elapses the reducer is told where the pointer is *then*; a
pointer that came back without an enter event keeps the sidebar.

Before TASK-169 the hide was edge-triggered: only a `mouseExited` from the
sidebar's tracking area started the delay, and the window dropped any exit
that arrived in the 0.5 s after a reveal. A sidebar whose one exit was
dropped or never sent stayed open until the pointer entered and left it
again. Two ways to get there were established:[^task-169]

- **An exit during the grace period.** A quick in-and-out (the pointer
  brushes the window edge and returns to the page) exits while the grace
  period is running. Nothing looked at the pointer again when it ended. With
  the old rule and injected events the sidebar was still open 3 s later with
  `openedByHover` true and no hide scheduled; a second exit hid it.
- **No exit at all.** AppKit sends no `mouseExited` while a drag session is
  live (a tab dragged out of the revealed sidebar onto the page), nor
  reliably when the view under a still pointer changes; `TabCellView`
  already works around both for row hover
  ([AppKit gotchas](../platform/appkit-gotchas.md)). The tracking areas are
  also `.activeInActiveApp`, so a pointer that leaves while another app is
  active reports nothing. Same stuck state with the old rule.

Neither was caught in the user's own session; the report (the sidebar
staying open after returning to a web-app tab) fits both. Other candidates
were checked and not found to cause it: see Edge cases.

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

`toggleSidebar(nil)` and `setPosition(0, ofDividerAt: 0)` flip `isCollapsed`
and fire KVO synchronously inside the call,[^task-39] and a late
notification of a single change is attributed the same way.

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
  window's leading edge carrying a tracking area tagged with
  `SidebarHoverZone.edge`; a second tracking area tagged `.sidebar` covers
  the sidebar view. The strip is a `ClickThroughView` (`hitTest` returns
  `nil`). As a plain `NSView` it took every click in the window's leftmost
  20 pt, including the left side of the Downloads button, and with the
  sidebar hidden the page's left edge.[^task-126] Tracking areas do not
  depend on hit-testing. `mouseEntered` / `mouseExited` only decode the zone
  and call `sidebarHoverZoneEntered` / `sidebarHoverZoneExited`, which is
  where tests come in.
- **Timers** — three, all `Timer`s scheduled in the default run loop mode:
  the grace period and the hide delay (`sidebarHoverDelay`, 0.5 s each), and
  the pointer sample (`sidebarPointerSampleInterval`, 0.25 s, only while
  `watchesPointer`). `windowWillClose` stops them. The two intervals are
  variables only so that tests can shorten them.
- **Pointer sample** — `sampleSidebarPointer` re-checks the popover hold and
  sends `.pointerObserved` with the pointer's position.
- **A mouse button down puts the hide off.** `sidebarPointerReading` is what
  the window's own three looks at the pointer use (the sample, the end of
  the grace period, the elapsed hide delay). It is `nil` while any mouse
  button is down: the sample skips that tick, and the two timers report the
  pointer as in the sidebar, which keeps the session; the sample starts the
  delay again once the button is up. A press or drag that began in the
  sidebar keeps it, as when only exit events counted, and the page is not
  resized under a drag in it. Before TASK-169 a hide already due did fire
  during a press.
- **Where the pointer is** — `isPointerInSidebar` tests
  `window.mouseLocationOutsideOfEventStream` against the sidebar view's
  `visibleRect`. Not `bounds`: while the sidebar slides in, its bounds reach
  past the window's edge, and a pointer 120 pt left of the window tested as
  inside them; `visibleRect` was empty at that moment and equal to the
  bounds once the sidebar had settled.[^task-169] A window that is not
  visible (hidden app, minimized, closed) has no pointer in it, so its hover
  session ends rather than being sampled for as long as it stays hidden.
  `sidebarPointerProbeForTesting` replaces the real pointer, position and
  buttons, in tests.
- **Popover hold** — the window observes `NSPopover.didShowNotification` and
  `didCloseNotification` and keeps, weakly, the popovers whose window is a
  child of this window. `refreshSidebarPopoverHold` derives the hold from
  those that are still `isShown` on this window and sends `.holdBegan` /
  `.holdEnded` when that differs from the reducer; it runs on both
  notifications, on every pointer sample and when the hide delay elapses.
  `NSPopover` does not expose what it is anchored to, and while the sidebar
  is hover-revealed the pointer is in it, so that is where a popover comes
  from. This covers the downloads popover, the site settings popover and
  extension popups without touching their call sites.

# Edge cases

- **Why the hold exists.** Moving the pointer from a hover-revealed sidebar
  into a popover it opened leaves the sidebar; the hide then collapsed the
  sidebar, removed the popover's anchor view, and the popover went with
  it.[^task-127]
- **Hold ends with the pointer outside.** `.holdEnded(pointerInSidebar:
  false)` starts the hide delay; no exit event is needed.
- **Context menus.** A default-mode `Timer` does not fire while AppKit
  tracks a menu, so neither the hide delay nor the sample runs under an open
  sidebar context menu; an overdue hide runs when the menu closes and
  decides from where the pointer is then. The earlier
  `DispatchQueue.main.asyncAfter` hide did fire in the event-tracking mode
  and collapsed the sidebar under the menu.[^task-169] The same holds for a
  drag session: the sidebar stays while a tab is dragged out of it and
  hides after the drop if the pointer is elsewhere.
- **Pointer over the sidebar's area but on another window.** The position
  test is geometric. A window that covers the sidebar (Settings, another
  app) with the pointer on it counts as "in the sidebar", so the sidebar
  stays until the pointer moves off that area. Before TASK-169 the exit
  event hid it.
- **A reveal in the same run loop turn as a collapse does not hold.**
  `toggleSidebar(nil)` twice in one turn, collapse then expand, ends
  collapsed, with a KVO `isCollapsed = true` after both calls returned
  (standalone probe; the tests hit it too until they let the collapse
  settle first).[^task-169] The reducer adopts that as an external collapse:
  the sidebar is hidden and still in auto-hide mode, and the pointer has to
  leave the edge strip and come back to reveal it. The opposite order, and
  two toggles 50 ms apart in either order, produced no unrequested change.
  No sequence tried produced an unrequested *expand*, which is what would
  silently pin the sidebar.
- **No drag-out affordance.** After a drag collapse there is no handle to
  drag the sidebar back; the edge hover and Toggle Sidebar are the way back.
  If AppKit does let the divider be dragged out, that expand is external and
  adopts pinned mode.[^task-39]
- **Cmd+S pins.** Toggle Sidebar is Cmd+S and reaches the menu after the
  page has had the key. Pressed in a web app out of habit, it pins a hidden
  or hover-revealed sidebar, which looks the same as a sidebar that failed
  to hide.
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
  `didShow` was posted about 0.5 s after `show(relativeTo:of:preferredEdge:)`
  returned for an animated popover, which is as long as the hide
  delay.[^task-169]
- Opening an extension popup *from* the settings popover closes one popover
  before the next shows; if that takes longer than the hide delay with the
  pointer outside, the sidebar can hide in between.
- Inline editing in the sidebar is not a hold: a hover-revealed sidebar
  hides under a rename if the pointer is elsewhere.

What standalone probes showed about a popover losing its `didClose`
(macOS 26):[^task-169] removing the anchor's view from the hierarchy closes
the popover and posts `didClose`; a shown popover whose last reference is
dropped stays alive and shown; ordering the parent window out, or minimizing
it, leaves a `.semitransient` popover `isShown` with no `didClose`, and it
comes back with the window (a `.transient` one closes on minimize). No case
was found where a popover is gone and `didClose` never comes; TASK-127
recorded one observation of a `.semitransient` popover staying up over a
collapsed anchor, in which case it is still shown and the hold is right.
The hold no longer depends on it either way.

Not exercised with a real pointer: the hover reveal through the
click-through strip, the hover hide, and the popover hold. Real
tracking-area enter and exit events cannot be synthesized — posted
`mouseMoved` events do not produce them — so checks call
`sidebarHoverZoneEntered` / `sidebarHoverZoneExited` in the running
app.[^task-126][^task-127][^task-169] The pointer *position* can be real:
the [TASK-169 harness](../../docs/harness/task169-harness.patch) moves the
window instead of the pointer. With the real pointer away from the sidebar
it hid without any exit event; "stays while the real pointer is over it" was
only run with the stand-in.

One difference from the task record: TASK-39's plan names a separate
`.restored(isCollapsed:)` event. The code has none; the setup-time sync
sends `.collapsedChanged`.

# Tests

- `SidebarVisibilityStateTests` drives the reducer through a small harness
  that models the synchronous KVO and a pointer the reducer only learns
  about through events: toggle, drag collapse, hover, delayed KVO,
  re-entrancy, popover hold, and the hide rule (an exit during the grace
  period, a missed exit found by the sample, a missed enter, repeated
  reports, hold and grace interplay).
- `BrowserWindowSidebarModeTests` (same file) drives a real incognito
  `BrowserWindowController`: `setPosition(0, …)` collapses, the mode
  follows, one toggle expands; an autosave round trip under a unique
  autosave name (AppKit writes the split view autosave on its own schedule,
  so that test polls for the write and skips if none appears within
  5 s[^task-39]); and the hover glue with the pointer replaced by
  `sidebarPointerProbeForTesting` and the delays shortened — hides with no
  exit event, hides after an exit during the grace period, stays while the
  pointer is in it, stays while a real `NSPopover` is shown and hides when
  it closes, stays after Toggle Sidebar. These wait on real timers; each
  wait can only err one way (a timer never fires early). A hide earlier than
  the grace period plus the hide delay fails them: it would not have come
  from the hover rule. The mouse-button rule and the visible-window rule are
  not under test: the probe replaces both.

# Related

- [Sidebar overview](./overview.md)
- [Browser window controller](../architecture/browser-window-controller.md) — owns the split view and applies the reducer's actions.
- [AppKit gotchas](../platform/appkit-gotchas.md) — click-eating overlay views, missing `mouseExited`, popovers and their anchor views, timers during menu tracking.
- [UI probes](../playbooks/ui-probes.md) — the hit-test map that found the edge strip.
- [In-process UI automation](../playbooks/in-process-ui-automation.md) — what can be driven from inside the app.
- [App shell](../architecture/app-shell.md) — the View > Toggle Sidebar menu item.
- [Profile data removal](../architecture/profile-data-removal.md) — `UserDefaultsScope`, which scopes the split view's autosave name to the data directory.

[^task-39]: Collapsing the sidebar by dragging its divider leaves Toggle Sidebar out of sync
[^task-126]: The Downloads button's left and bottom edges do not respond to clicks
[^task-127]: With auto-hide on, the downloads popover disappears when the sidebar hides
[^task-169]: A hover-revealed sidebar sometimes stays open instead of hiding again
