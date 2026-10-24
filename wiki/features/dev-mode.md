---
type: Feature
title: Dev mode
description: "Which URLs count as local development (localhost, *.localhost, 127.0.0.0/8 in any IPv4 spelling, [::1], 0.0.0.0, *.test over http/https), the per-site override and its popover switch, the one function the effective state goes through, and how a dev-mode tab's sidebar row, split half and favourite tile are marked with a hazard border and a host line and follow a change at once."
tags: [dev-mode, sidebar, tabs, url-rules, site-settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T17:17:19Z }
sources:
  - id: rule
    resource: ../../Detour/Browser/DevMode/DevMode.swift
    title: DevMode.swift (isLocalDevelopmentURL, devModeHostLabel, DevMode, DevModeRowMarking)
  - id: border
    resource: ../../Detour/Browser/DevMode/HazardBorderView.swift
    title: HazardBorderView.swift
  - id: tab-cell
    resource: ../../Detour/Browser/Sidebar/TabCellView.swift
    title: TabCellView.swift (updateDevMode)
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (the row paths that call updateDevMode)
  - id: favorites-bar
    resource: ../../Detour/Browser/Sidebar/FavoritesBarView.swift
    title: FavoritesBarView.swift (FavoriteTileView.refreshDevMode)
  - id: classifier
    resource: ../../Detour/Browser/CommandPalette/AddressInputClassifier.swift
    title: AddressInputClassifier.swift (typed input, a separate rule)
  - id: tests
    resource: ../../DetourTests/DevModeTests.swift
    title: DevModeTests.swift
  - id: harness
    resource: ../../docs/harness/task186-1-harness.patch
    title: TASK-186.1 runtime harness
  - id: popover
    resource: ../../Detour/Browser/Sidebar/SettingsPopoverViewController.swift
    title: SettingsPopoverViewController.swift (the dev-mode switch)
  - id: popover-wiring
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
    title: BrowserWindowController+TabSidebar.swift (tabSidebarDidRequestShowSettings)
  - id: override-tests
    resource: ../../DetourTests/DevModeSiteOverrideTests.swift
    title: DevModeSiteOverrideTests.swift
  - id: harness-1865
    resource: ../../docs/harness/task186-5-harness.patch
    title: TASK-186.5 runtime harness
  - id: arc-row
    resource: ../../docs/dev-mode/arc-sidebar-row.png
    title: Arc's dev-mode sidebar row (reference image)
  - id: task-186
    resource: backlog:TASK-186
    title: Dev mode for local development URLs, sidebar row and in-page dev toolbar
  - id: task-186-1
    resource: backlog:TASK-186.1
    title: "Dev mode: detect local development URLs and mark the tab's sidebar row"
  - id: task-186-5
    resource: backlog:TASK-186.5
    title: "Dev mode: turn dev mode on or off per site from the address bar popover"
---

A tab whose page is a local development server is in **dev mode**, modelled
on Arc's.[^task-186] Its sidebar row gets an "under construction" look: a
yellow and black dashed border around the row and the page's host under the
title (Arc shows `localhost:4000`).[^arc-row] Local URLs are in dev mode by
default; the site settings popover turns it on for any site or off for a
local one, per profile.[^task-186-5] An in-page dev toolbar is a later part
of the same feature (TASK-186.2) and is not built yet.

# What it does

| Where | Marking |
|---|---|
| Normal tab row | Hazard border round the row (the hover rect), host line under the title |
| Pinned row, live or dormant | Same as a normal tab |
| Split row | Border round each local pane's half only; no host line |
| Favourite tile | Border only (a tile has no title) |

The row follows the tab's URL. Navigating away from the local URL drops the
marking; going back (or any navigation to a local URL) restores it. A
sleeping tab uses its stored `url`. A pinned entry reads its live tab's URL,
or its `pinnedURL` when dormant (`PinnedEntry.devModeURL`); a favourite reads
its tab's URL, or its own `url` when dormant (`Favorite.devModeURL`). A tab
whose local server is down still counts: the error page keeps the URL the
user asked for (see [error pages](./error-pages.md)).

# How it works

## The rule

`isLocalDevelopmentURL(_:)` is a pure function. It is true for an `http` or
`https` URL (scheme case-insensitive) whose host, lowercased and with one
trailing dot removed, is:

| Host | Notes |
|---|---|
| `localhost`, `*.localhost` | `localhost.example.com`, `mylocalhost`, `localhostx` are not |
| IPv4 in 127.0.0.0/8 | Parsed the WHATWG way: one to four parts, each decimal, `0x` hex or leading-`0` octal, the last filling the remaining bytes — so `127.1`, `2130706433`, `0x7f000001` and `0177.0.0.1` all count. `127.0.0.1.nip.io` is a domain, not an address |
| `0.0.0.0` | Including `0` and `0x0`, which the same parser reads as 0.0.0.0 |
| `[::1]` | Any spelling `inet_pton` accepts (`[0:0:0:0:0:0:0:1]`). The IPv4-mapped `[::ffff:127.0.0.1]` does not count |
| `*.test` | The bare TLD `test` does not; nor `test.com`, `mytest`, `foo.test.com` |

Not included, by decision: LAN addresses (`192.168.x.x`, `10.x.x.x`) and
`.local` names, which are as often a printer or a NAS as a dev server. Any
site can be switched on by hand instead.[^task-186-1] Other
schemes (`ws:`, `file:`, `view-source:`, `blob:`, `data:`, `detour:`) never
count.

WebKit's URL parser follows the URL Standard, which rewrites these spellings
to a dotted quad, so in practice the row should only see `127.0.0.1`-style
hosts (not checked in Detour); the rule does not depend on it.

`devModeHostLabel(for:)` is the host line: the lowercased host, IPv6 in
brackets, plus `:port` only when the port is not the scheme's default (80
for http, 443 for https). User info, path and query are dropped.

The rule is separate from
[`AddressInputClassifier`](../../Detour/Browser/CommandPalette/AddressInputClassifier.swift),
which decides how typed text becomes a URL (it also knows localhost and IP
literals, but answers a different question and treats any dotless name with
a port as local).

## One entry point for the effective state

Every consumer asks `DevMode.isActive(for: url, profileID:)` (or the
`BrowserTab` overload, which uses the tab's `owningProfile`), never
`isLocalDevelopmentURL` directly. The rule itself is the pure
`DevMode.isActive(url:override:)`: the site's override, else the URL
rule.[^task-186-5] With no profile there is no override.
`DevMode.rowMarking(for:profileID:)` and
`DevMode.splitRowMarking(left:right:profileID:)` turn it into a
`DevModeRowMarking` (`.none`, `.tab(hostLabel:)`, `.split(left:right:)`)
for the cell.

The sidebar passes the profile of the page a row is on
(`profileIDForTableView`: the page's space's profile), since a dormant
pinned entry or favourite has no tab to ask; the favourites bar carries its
page's `profileID` down to each tile.

## The per-site override

A `devMode` row of the [site settings](../architecture/site-settings.md)
table, per profile. `true` turns dev mode on for any site, `false` turns it
off for a local one.

- **Key:** `devModeSiteKey(for:)`, the host plus a non-default port — the
  same string as the host line — so `localhost:3000` and `localhost:4000`
  are separate apps. Only `http`/`https` pages have a key, so a `detour:`,
  `file:` or extension page is never in dev mode and its switch is disabled.
- **Matching:** exact. `example.com` does not cover `www.example.com`.
  The scheme is not part of the key: `http://` and `https://` on the same
  host and port are one site.
- **Private:** kept in memory only (`persistsInPrivate = false`) and dropped
  with the last Private space, as for picture in picture.
- **No redundant rows:** `DevMode.setEnabled(_:for:profileID:)`, which the
  switch calls, removes the site's row when the new value is what the URL
  rule gives anyway, and stores an override only when it differs. Turning a
  remote site on and then off again leaves no row; the site then follows
  the rule again. The rule depends only on the host, so it is the same for
  every page of one key.

## The switch

"Dev mode for this site" is the third per-site switch in the address bar's
popover (`SettingsPopoverViewController`), under content blocking and
picture in picture. It shows the effective state for the tab the popover
opened on, and is disabled when the page has no site key. The button that
opens the popover is `slider.horizontal.3`, labelled "Site Settings" (it was
`puzzlepiece.extension` while the popover was mostly extensions).

**Rows follow at once.** `SiteSettingsStore` posts
`didChangeNotification` with the setting and profile on every change. Each
window's `TabSidebarViewController` observes it; for a `devMode` change it
walks the instantiated cells of every page whose profile matches, recomputes
each row's marking and calls `updateDevMode`, and asks the page's
favourites bar to re-read its tiles. No reload, no navigation: rows of
other sites keep their marking, and `updateDevMode` returns early for them.
Every window has its own sidebar, so a second window on the same space
follows too.[^harness-1865]

## Drawing

`HazardBorderView` is two `CAShapeLayer`s on the same rounded-rect path: a
solid `systemYellow` stroke under a dashed near-black one (1.5 pt, 4/4
dashes), so the dashes alternate yellow and black. The path is rebuilt only
in `setFrameSize`; implicit animations are off; colours are re-resolved on
appearance changes and the layers' `contentsScale` follows the window. It
returns nil from `hitTest`.

`TabCellView.updateDevMode(_:)` makes the border views on first use (most
cells never need them), places them over the progress bar and under the
content, and frames them in `layout()` with the same rect as the hover
background (`rowHighlightRect(splitSide:)`), so a split half's border
matches its hover highlight. It returns early when the marking has not
changed, so the frequent row reloads (progress, title) cost a comparison.

**Row height is unchanged.** The host line is a 10 pt label hung under the
title (`topAnchor` = title's bottom − 2); the title's centre-Y constraint
moves up by half the host line's height, so the two lines are centred in the
existing 36 pt row and [row layout](../sidebar/row-layout.md) is untouched.
Measured in the running app: title 16…32, host line 5…18 in a 36 pt
cell.[^harness]

The sidebar calls `updateDevMode` on every path that fills a tab cell — the
same paths that must pass `sidebarProgress` (see
[tab cell](../sidebar/tab-cell.md)), plus the pinned refresh in
`applyState` that turns a dissolved pinned split back into a single row.
The favourite tile owns a `HazardBorderView` and binds the live tab's `$url`
in `refreshDevMode()`, called wherever the tile is built or reused, like
its favicon binding.

# Edge cases

- A split row with both panes local shows two borders, one per half.
- A pinned entry navigated away (live) loses the marking; making it dormant
  restores it from the pinned URL — checked at runtime.[^harness]
- During a split collapse the survivor's host line appears at once, while
  the old right segment is still fading.

# Tests

`DevModeTests` (31 tests): every host form above and its look-alikes, the
schemes, nil and hostless URLs, the label's ports, brackets, case and user
info, the row and split markings, a sleeping tab following its URL, pinned
and favourite URL fallbacks, the cell's host line, borders and reuse, split
halves, and a favourite tile following its tab's navigation.

`DevModeSiteOverrideTests` (15 tests, TASK-186.5): the rule (override true
on a remote site, false on a local one, nil falling back), the site key
(ports, case, IPv6, a trailing dot, no key for non-web pages), the store's
row and its exact matching, a choice equal to the default leaving no row,
Private kept in memory and dropped with the session, content blocking and
picture in picture still covering subdomains, the change notification, the
row marking, the popover switch and the button's label.[^override-tests]

At runtime the [harness](../../docs/harness/task186-1-harness.patch)
captured the sidebar in light and dark with a local normal tab (selected and
not), a local pinned tab, local and non-local favourites, a split with one
local pane, and non-local rows, then navigated the local tab away and back
and the pinned tab away and dormant. All eight captures matched the logged
cell state.[^harness]

The TASK-186.5 [harness](../../docs/harness/task186-5-harness.patch) used
`kubernetes.docker.internal` (127.0.0.1 in `/etc/hosts`, not local by the
rule) as the remote site. It turned dev mode on for it and off for
`localhost:8865` from the popover, and logged the rows of two windows on the
same space in the same run-loop turn as each click: both followed every time.
Switching each back to its default removed its row. A Private window's choice
held in the store and wrote no row. The popover and the new button were
captured in light and dark.[^harness-1865]

# Related

- [Tab cell](../sidebar/tab-cell.md) — the row view that draws the marking.
- [Row layout](../sidebar/row-layout.md) — the row heights the host line fits inside.
- [Favourites](../tabs/favorites.md) and [Pinned tabs and folders](../tabs/pinned-tabs-and-folders.md) — which URL a dormant item reads.
- [Split tabs](../tabs/split-tabs.md) — why a split row marks halves.
- [Suggestion pipeline](./suggestion-pipeline.md) — `AddressInputClassifier`, the separate typed-input rule.

[^task-186]: Dev mode for local development URLs, sidebar row and in-page dev toolbar
[^arc-row]: Arc's dev-mode sidebar row (reference image)
[^task-186-1]: Dev mode: detect local development URLs and mark the tab's sidebar row
[^task-186-5]: Dev mode: turn dev mode on or off per site from the address bar popover
[^harness]: TASK-186.1 runtime harness
[^harness-1865]: TASK-186.5 runtime harness
[^override-tests]: DevModeSiteOverrideTests.swift
