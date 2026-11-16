---
type: Feature
title: Quick Detour entry points
description: "The other ways into a Quick Detour (TASK-193.5, TASK-300): Opt-Cmd-click on a link (any frame, a Peek, Private into Private, never routed) and its place in the modifier table, the link menu's Open Link in Quick Detour, Opt-Cmd-click on a sidebar tab opening a copy, and links from other apps through the Link Routes Quick Detour target."
tags: [window, links, sidebar]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
sources:
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
  - id: task-300
    resource: backlog:TASK-300
    title: "Link context menu: Open Link in Quick Detour"
  - id: entry-points
    resource: ../../Detour/Browser/QuickDetour/QuickDetourEntryPoints.swift
    title: QuickDetourEntryPoints.swift (the settings, the Opt-Cmd click, the routed link's profile, the idle rule)
---

Besides the [launcher](./quick-detour-launcher.md), a Quick Detour opens from a link, a sidebar tab and a link from another app: TASK-193.5, the user's decisions of 2026-10-26, and
the link menu's item of TASK-300.

# Opt-Cmd-click on a link

Opt-Cmd-click on a link in a browser window's page opens it in a **new
Quick Detour on the page's profile** (`tab(owning:)?.owningProfile`, else
the window's space's): a Private page's in a Private Quick Detour. Any
frame (an iframe's link too), a `target=_blank` link too (the policy sees it
first), and inside a Peek (the Peek's page is the window's space's
profile). Its Open in names the window's space. It is a branch of the
navigation policy before Cmd's, since Opt-Cmd contains Cmd:

| Modifiers | Before 193.5 | Now |
|---|---|---|
| Opt-Cmd | Cmd: a background tab (or where a route sends it) | **Quick Detour**, never routed |
| Opt-Cmd-Shift | Cmd | Quick Detour (Shift does not matter once Cmd and Option are held) |
| Opt-Cmd, setting off, or to a non-web URL (`mailto:`) | Cmd | Cmd, as before |
| Cmd, Cmd-Shift | background tab / route | unchanged |
| Shift, Shift-Option | Peek | unchanged |
| Option | split | unchanged |

`inPageLinkClickBranch(_:target:quickDetourClickEnabled:)` is that table,
pure; the policy and the routing rule (`linkRoutingEligibility`, which now
answers `.notRouted(.quickDetourClick)`) both read it, so Link
Routes never move an Opt-Cmd-click: the user chose where it opens.
Synthetic clicks carry no modifiers, so a page cannot fake one (as for
Cmd+click). **Inside a Quick Detour** Cmd+click already opened another
Quick Detour on the same profile; Opt-Cmd is a Cmd+click there, so it does
the same. **Not added**: Opt-Cmd on a script's `window.open` (not a link;
WebKit's policy never sees it).

# Open Link in Quick Detour (the link menu)

TASK-300 (user decision, Nov 8 2026) added the link menu's **Open Link in
Quick Detour**, after Open Link in New Window and before Open Link in Split
View (`BrowserWebView.willOpenMenu`, browser windows only; a Quick Detour
keeps WebKit's own link items). It is **always offered**: the Opt-Cmd-click
setting governs only the gesture. It is offered **inside a Peek** too (where
Split View is not). It works as the other items do: it sets
`contextMenuLinkAction = .openInQuickDetour` and performs WebKit's Open Link
in New Window item, whose `createWebViewWith` hands the link to
`openLinkInQuickDetourFromMenu(_:firing:in:)`. That does what an
Opt-Cmd-click on the link does: a web link (`QuickDetour.opensLinkInQuickDetour`,
http or https — the rule `inPageLinkClickBranch` now reads too) opens in
`openQuickDetour(_:firing:)`, the page's profile (Private in a Private
window; a Peek's is the window's space's), and is never routed; any other
link is no Quick Detour click, so it is a Cmd-click: a background tab.

# Opt-Cmd-click on a sidebar tab: a copy

Opt-Cmd-click on a tab in the sidebar opens **a copy**: the tab's address in
a new Quick Detour on the sidebar's profile (the active space's; the
Private profile in a Private window). The tab is not selected, moved, woken
or changed (decision 2). `DraggableTableView.mouseDown` takes the click
before the table's own handling (`onQuickDetourClick`, row and point), so
the selection never moves; the sidebar resolves the row
(`TabSidebarViewController.quickDetourCopyURL(forRow:at:)`):

| Row | Address copied |
|---|---|
| A normal tab, live | where it is now (`tab.url`) |
| A sleeping tab | its stored address (a sleeping tab's `url`), without waking it |
| A split row | the pane clicked: the left or right half of the row (`QuickDetour.splitRowPane`) |
| A pinned entry | its tab's address while live, else the saved `pinnedURL` |
| A pinned split | the pane clicked, as above |
| A favourite tile (`FavoriteTileView.mouseDown`) | its tab's address while live, else the favourite's URL; a dormant tile stays dormant |
| A folder, New Tab, the separator | nothing: the click does what it always did |

An internal page (the History page) opens as one (armed, as typed). The
rule is `QuickDetour.sidebarCopyURL(liveURL:storedURL:)`; with the setting
off the click is the table's (and the tile's) own.

The tab row menus (a tab, a pinned entry, a split row, a pinned split row)
offer **Open in Quick Detour** (TASK-300), whatever the setting: the same
copy through the same delegate call, the row's address resolved by
`quickDetourCopyURL(forRow:at:)` at the right-click point
(`DraggableTableView.lastMenuPoint`), so a split row copies the pane under
the pointer. None for a row with no address yet. Favourite tiles' menu has
no such item (only Remove from Favorites).

# Links from other apps: the Link Routes Quick Detour target

No switch of its own (decision 1): **Quick Detour** is a visible Open in
target in Settings > Links, for routes and the Default
([links from other apps](./link-routing-external-links.md)). The resolver
keeps it to links from other apps: a typed URL or a clicked link whose
route or Default names Quick Detour stays where it is (unchanged since
TASK-191.1). `linkPlacement` answers `.openInQuickDetour` whatever windows
are open, and `AppDelegate.openLink` opens a new Quick Detour with the link
instead of a tab (the Most Recent Space fallback TASK-191.2 left for it is
gone). "Links from Slack open in Quick Detour" is an app-only route (Any
URL, From app Slack, Open in Quick Detour).

**Which profile** (decided here): `QuickDetour.profileForRoutedLink` — the
profile of the frontmost Detour window (a browser window's active space's,
a Quick Detour's own; front to back, then windows not in the window list),
as the launcher's rule (TASK-193.4) — **but never Private**: a Private
window in front is passed over for the next window's profile, else the
first normal profile. A link from another app enters Private only through
a Private Window target (or Quarantine, TASK-194: a Quick Detour on the
Private profile with a store of its own, [Quarantine](./quarantine.md)); a Quick Detour route that sometimes opened Private
would overlap it by accident of which window was in front. Its Open in
names the most recent normal window's space when it is the same profile's.
The window is ordered front of Detour's windows, as a placed tab's window
is; Detour is not activated by the placement itself (the sender's
`NSWorkspace.open` does that).

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Link Routes](./link-routing.md) — the Quick Detour target, and Opt-Cmd's place in the click rule.
- [Tab lifecycle](../tabs/tab-lifecycle.md) — where each click lands.
- [Quarantine](./quarantine.md) — the Private-profile route target with a store of its own.
- [Quick Detour settings](./quick-detour-settings.md) — the ⌥⌘-click switch.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.
