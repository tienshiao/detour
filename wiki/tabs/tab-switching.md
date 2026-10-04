---
type: Feature
title: Tab switching by keyboard
description: Cmd+Option+Up/Down steps through a space's sidebar rows in order; Control+Tab switches between recently used tabs with a preview overlay. Both treat a split as one item.
tags: [tabs, keyboard, switcher, mru, sidebar]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:43:31Z }
sources:
  - id: navigation
    resource: ../../Detour/Browser/Sidebar/TabNavigation.swift
    title: TabNavigation.swift
  - id: order
    resource: ../../Detour/Browser/Window/RecentTabOrder.swift
    title: RecentTabOrder.swift
  - id: switcher
    resource: ../../Detour/Browser/Window/RecentTabSwitcher.swift
    title: RecentTabSwitcher.swift
  - id: switcher-ext
    resource: ../../Detour/Browser/Window/BrowserWindowController+RecentTabSwitcher.swift
    title: BrowserWindowController+RecentTabSwitcher.swift
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (navigateTab, stampDeselected)
  - id: nav-tests
    resource: ../../DetourTests/TabNavigationTests.swift
    title: TabNavigationTests.swift
  - id: order-tests
    resource: ../../DetourTests/RecentTabOrderTests.swift
    title: RecentTabOrderTests.swift
  - id: task-107
    resource: backlog:TASK-107
    title: Cmd+Option+Up/Down selects the previous/next tab in the space's sidebar order
  - id: task-108
    resource: backlog:TASK-108
    title: Control+Tab MRU switcher with an overlay
  - id: task-133
    resource: backlog:TASK-133
    title: The Control+Tab switcher does not swallow the keys it handles
---

# What it does

| Keys | Order | Scope |
|---|---|---|
| Cmd+Option+Down / Up (Navigate > Next Tab / Previous Tab) | the sidebar's row order, wrapping | the active space's pinned rows and normal rows |
| Control+Tab / Control+Shift+Tab | most recently used first | the active space's live tabs: pinned, favourites and normal |

Neither ever switches space. In both, a [split](./split-tabs.md) is one item.

# How it works

## Sidebar order: `TabNavigation`

Two pure functions:

- `tabNavigationStops(pinnedItems:tabItems:)` builds the stops from the same
  flattened pinned items and tab items the sidebar renders: pinned rows first
  (folder rows are skipped; entries hidden in a collapsed folder are already
  absent, except the exposed selected one), then normal items. A stop has a
  `target` (`.pinnedEntry(id)` or `.tab(id)`, the *left* member for a split)
  and `tabIDs`, the live tabs the row stands for. A dormant pinned row is a stop
  with no `tabIDs`.
- `tabNavigationTarget(in:selectedTabID:offset:)` finds the stop whose `tabIDs`
  contain the selection and moves by `offset`, wrapping. With no current stop (a
  favourite, or nothing, is selected) forward starts at the first stop and
  backward at the last. It returns nil when there is nowhere else to go, which
  also disables the menu items.

`BrowserWindowController.navigateTab` then calls the **same delegate methods a
row click does** (`tabSidebar(_:didSelectPinnedTabAt:)` /
`didSelectTabAt:`). That is how a split focuses its remembered pane and a
dormant pinned entry is activated, with no second selection path to keep in
step. It scrolls the row into view on the next main-queue turn, because a
dormant entry selects asynchronously.

Dormant tiles that cannot open (`dormantTileRefusal` non-nil, e.g. a disabled
extension's page) are filtered out of the stops. Selecting one only toasts and
leaves the selection where it was, so every later press would re-target it and
the keyboard could never step past it.[^task-107]

Favourites are not stops.

## Recently used: `RecentTabSwitcher`

**Order.** `recentTabOrder(_:selectedTabID:)` lists the item holding the
selection first, then every item *left since launch*, newest first. "Left" is
`BrowserTab.switcherPreviewAt`, an in-memory stamp set in `stampDeselected`. A
tab not visited this session is not offered, so after a relaunch the list
starts with only the current tab. This is deliberate: the switcher only offers
pages it has a picture of.

`switcherPreviewAt` is separate from the persisted `lastDeselectedAt`, which
stays the [sleep and archive clock](./sleeping-and-archiving.md). Do not merge
them: one is "when was this last looked at this session", the other survives
relaunch and drives eviction.

**State.** `RecentTabSwitcherState` holds the highlight. Index 0 is the current
item, so a forward start lands on index 1 (the previous tab) and a backward
start on the last. Both directions wrap. With nothing selected in the window
there is no current item: a forward start lands on index 0 and one entry is
enough.

**Keys.** One `NSEvent` local monitor per window, for `.keyDown` and
`.flagsChanged`, filtered to events of that window:

- Control+Tab begins or advances; with Shift it goes backward. Key repeat
  advances.
- Releasing Control (seen as `flagsChanged`) commits.
- While active: Escape cancels, Return commits, Left/Right move.
- The window resigning key cancels.
- The overlay appears only after `revealDelay` (0.15 s), so a quick tap flips
  to the previous tab without flashing it.

**Entries.** `recentTabSwitcherEntries()` gathers the space's live pinned
backing tabs, the profile's live favourite tabs and the normal tabs, groups
split members into one entry, and orders them. Dormant tiles have no tab and
are never offered; Peeks are not tabs. Choosing a split focuses the currently
selected member, else this window's remembered pane, else the member left most
recently.

**Previews.** `captureSwitcherPreview(of:)` uses `WKWebView.takeSnapshot` at
480 px wide. It is taken as a tab is left (in `stampDeselected`) and, for the
visible panes, when the switcher begins.

- It never hosts or wakes a hidden tab to take a picture. Every show of a page
  costs GPU surfaces ([GPU IOSurface limit](../platform/gpu-iosurface-limit.md)).
  A failed capture keeps the older picture; with none, the card shows the
  favicon.
- `takeSnapshot` was chosen by measurement. A synchronous `cacheDisplay` of a
  1372×1100 web view took 46 to 48 ms per call, which would block every tab
  switch. `takeSnapshot` returns at once, delivers in 16 to 57 ms, and still
  renders correctly after the view has left the window.[^task-108]
- A per-tab counter (`switcherPreviewRequest`) drops a slower, older snapshot
  that arrives after a newer one.
- Previews live in memory only and survive sleep.

Clicks on a card arrive as *secondary* clicks, because Control is held; the
card view handles `rightMouseDown` as a click.

# Edge cases

## Open defect: handled keys are probably not swallowed

The monitor is installed as

```swift
MainActor.assumeIsolated { self?.handle(event) ?? event }
```

`handle(_:)` returns `NSEvent?` and returns nil to swallow a key (Control+Tab
itself, and every key while the switcher is active). Optional chaining flattens
that to one optional, so "handled, swallow it" and "self is gone" are the same
nil, and `?? event` turns both back into the event. A standalone program with
the same shape returned the event in the swallow case.[^task-133] The likely
effect is that the switcher acts on the key *and* the key continues to the
first responder. This has not been observed in the app, and what it visibly
breaks is not known. The code on `main` still has this shape; TASK-133 holds
the acceptance tests for the fix.

## Not verified at runtime

Recorded as unexercised for the switcher: hover highlight, split, pinned and
favourite entries, a row long enough to scroll, dark mode, and the effect of
the leave-time snapshots on the GPU surface count.[^task-108] For
Cmd+Option+Up/Down no manual pass was recorded.[^task-107]

# Tests

`TabNavigationTests` (11) and `RecentTabOrderTests` (10) cover the pure order
and state. The switcher's event handling was checked with an in-process harness
posting real key and mouse events (quick tap, hold and advance, Shift start,
Escape, card click);[^task-108] see
[in-process UI automation](../playbooks/in-process-ui-automation.md). A click
test fails by design when another application has focus: resigning key cancels
the switcher.

# Related

- [Split tabs](./split-tabs.md): why a split is one stop and one card.
- [Pinned tabs and folders](./pinned-tabs-and-folders.md): the flattened order and dormant tiles the stops are built from.
- [Sidebar row layout](../sidebar/row-layout.md): the same items as table rows.
- [Sidebar keyboard focus](../sidebar/keyboard-focus.md): what holds first responder when these keys arrive.
- [App shell](../architecture/app-shell.md): the Navigate menu and key equivalents.
- [Sleeping and archiving](./sleeping-and-archiving.md): the other, persisted, deselection clock.

[^task-107]: Cmd+Option+Up/Down selects the previous/next tab in the space's sidebar order
[^task-108]: Control+Tab MRU switcher with an overlay
[^task-133]: The Control+Tab switcher does not swallow the keys it handles
