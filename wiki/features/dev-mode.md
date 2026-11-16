---
type: Feature
title: Dev mode
description: "Which URLs count as local development (localhost, *.localhost, 127.0.0.0/8 in any IPv4 spelling, [::1], 0.0.0.0, *.test over http/https), the per-site override and its popover switch, the one function the effective state goes through, and how a dev-mode tab's sidebar row, split half and favourite tile are marked with a host line and, on the window's selected row only (like Arc), an orange hazard border; hub for the dev toolbar above the page and its capture buttons."
tags: [dev-mode, sidebar, tabs, url-rules, site-settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:39:04Z }
sources:
  - id: rule
    resource: ../../Detour/Browser/DevMode/DevMode.swift
    title: DevMode.swift (isLocalDevelopmentURL, devModeHostLabel, DevMode, DevModeRowMarking)
  - id: border
    resource: ../../Detour/Browser/DevMode/HazardBorderView.swift
    title: HazardBorderView.swift
  - id: tab-cell
    resource: ../../Detour/Browser/Sidebar/TabCellView.swift
    title: TabCellView.swift (updateDevMode, isRowSelected, TabRowView.isSelected)
  - id: sidebar-vc
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (the row paths that call updateDevMode)
  - id: favorites-bar
    resource: ../../Detour/Browser/Sidebar/FavoritesBarView.swift
    title: FavoritesBarView.swift (FavoriteTileView.refreshDevMode, isSelected)
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
  - id: task-186-2
    resource: backlog:TASK-186.2
    title: "Dev mode: an under-construction toolbar above the page with the URL"
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
  - id: palette
    resource: ../../Detour/Browser/DevMode/DevModePalette.swift
    title: DevModePalette.swift
  - id: task-197
    resource: backlog:TASK-197
    title: "Dev mode: tie the under-construction motif to the Detour branding (orange hazard border)"
  - id: harness-197
    resource: ../../docs/harness/task197-harness.patch
    title: TASK-197 colour comparison harness (options, contrast measurements)
  - id: harness-197b
    resource: ../../docs/harness/task197b-harness.patch
    title: TASK-197 selected-row-only border harness
  - resource: ./dev-toolbar.md
    title: Dev toolbar
  - resource: ./dev-toolbar-captures.md
    title: Dev toolbar captures
---

A tab whose page is a local development server is in **dev mode**, modelled
on Arc's.[^task-186] Its sidebar row gets an "under construction" look: the
page's host under the title (Arc shows `localhost:4000`)[^arc-row] and, while
it is the window's selected row, an orange and black dashed border around it
(the [app icon](../decisions/app-icon-design.md)'s orange).[^task-197] Local URLs are in dev mode by
default; the site settings popover turns it on for any site or off for a
local one, per profile.[^task-186-5] Above the page of a dev-mode tab sits
a striped toolbar with the URL[^task-186-2] and Copy URL, capture and Web
Inspector buttons ([dev toolbar](./dev-toolbar.md)).

# What it does

| Where | Selected | Not selected |
|---|---|---|
| Normal tab row | Hazard border round the row (the hover rect), host line under the title | Host line only |
| Pinned row, live or dormant | Same as a normal tab (a dormant row is never selected, so host line only) | Host line only |
| Split row | Border round each local pane's half, whichever pane is focused; no host line | Nothing |
| Favourite tile | Border (a tile has no title, so no host line) | Nothing |

Only the selected row is bordered, as in Arc, where an unselected dev-mode
tab shows its two lines (title and host) but no border (the user,
2026-10-24).[^task-197] A split row has no host line, so unselected it shows
no marking at all. Selection is per window: each window's sidebar borders
its own selected row, so two windows on one space can border different
rows. The border moves with every selection change and space switch; the
host line does not depend on selection, so nothing else in the row moves.

The row follows the tab's URL. Navigating away from the local URL drops the
marking; going back (or any navigation to a local URL) restores it. A
sleeping tab uses its stored `url`. A pinned entry reads its live tab's URL,
or its `pinnedURL` when dormant (`PinnedEntry.devModeURL`); a favourite reads
its tab's URL, or its own `url` when dormant (`Favorite.devModeURL`). A tab
whose local server is down still counts: the error page keeps the URL the
user asked for (see [error pages](./error-pages.md)).

# Pages

- [Dev toolbar](./dev-toolbar.md) — the striped bar above a dev-mode page: its controls, the layout rule that keeps it above a docked Web Inspector, which panes show it, and its tests and runtime checks.
- [Dev toolbar captures](./dev-toolbar-captures.md) — the visible-area and full-page capture buttons: clipboard or Downloads, the pixel caps, the method choice, busy and failure states.

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
popover (`SettingsPopoverViewController`): below the host header and the
content blocking section, it shares a section of its own with picture in
picture (TASK-213), which a Quick Detour's popover leaves out — it has no
sidebar rows or dev toolbar to change. It shows the effective state for the tab the popover
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
follows too.[^harness-1865] The window observes the same notification to
show or hide its hosted panes' toolbars
([dev toolbar](./dev-toolbar.md#which-panes-show-it)).

## Drawing

`HazardBorderView` is two `CAShapeLayer`s on the same rounded-rect path: a
solid orange stroke under a dashed near-black one (1.5 pt, 4/4 dashes), so
the dashes alternate orange and black. The colours, and the toolbar's
stripes, come from `DevModePalette`, defined once.[^palette] The path is rebuilt only
in `setFrameSize`; implicit animations are off; colours are re-resolved on
appearance changes and the layers' `contentsScale` follows the window. It
returns nil from `hitTest`.

`TabCellView.updateDevMode(_:)` makes the border views on first use (most
cells never need them), places them over the progress bar and under the
content, and frames them in `layout()` with the same rect as the hover
background (`rowHighlightRect(splitSide:)`), so a split half's border
matches its hover highlight. It returns early when the marking has not
changed, so the frequent row reloads (progress, title) cost a comparison.

**Only on the selected row.** What a marking shows is the pure
`DevModeRowMarking.display(isSelected:) -> DevModeRowDisplay` (`hostLabel`,
`showsMainBorder` for the row or a split's left half, `showsRightBorder`);
`hostLabel` is the same either way, which is what keeps the title and host
line still when the selection moves.[^rule] The cell learns its selection
from the table, not from the sidebar controller: `TabRowView` overrides
`isSelected`, which `NSTableView` keeps in step with its selection for every
live row view without reloading rows, and pushes it to its `TabCellView`'s
`isRowSelected`; a cell joining a row reads the row's `isSelected` in
`viewDidMoveToSuperview` (the table may select the row view before or after
adding the cell), and a cell out of a row is unselected.[^tab-cell] A
selection change only flips the borders' `isHidden` (the views are still made
on first show). The table's row selection already mirrors the window's
selected tab: `selectTab` selects the pinned or normal row (a split row for
either pane) and deselects all rows for a favourite's tab, and the selection
callbacks it suppresses meanwhile do not matter because row views are told
regardless. A favourite tile has no row: its `isSelected`, set by the bar's
`updateSelection(selectedTabID:)`, re-applies the same rule.[^favorites-bar]

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

### Colours: why brand orange

The hazard colour is the app icon's orange plate, rgb(255, 118, 0), in both
appearances, with near-black dashes; the toolbar keeps faint grey stripes.
The user chose it from five options captured side by side at 2x in light and
dark (2026-10-24).[^task-197] Measured WCAG contrast of the bright half
against the sidebar and the selected row:[^harness-197]

| Option | Light: sidebar / selected | Dark: sidebar / selected |
|---|---|---|
| `systemYellow` (the original) | 1.27 / 1.07 | 10.87 / 9.14 |
| brand orange #FF7600 (chosen) | 2.26 / 1.89 | 5.73 / 4.82 |
| `systemOrange` #FF9500 | 1.85 / 1.55 | 7.47 / 6.28 |

Rejected: yellow, because on the light-blue sidebar only the black dashes
showed, so the border read as a dotted black line; `systemOrange`, which
washed out to amber on the light tint; a 2 pt line, more sign-like but heavy
around the selected row and loud in dark mode; orange-tinted toolbar stripes,
pleasant peach in light mode but muddy brown (#3C3128) in dark. In dark mode
the near-black dashes almost vanish (about 1.3:1) whatever the hazard colour,
so there the bright half carries the border.

# Edge cases

- A selected split row with both panes local shows two borders, one per half.
- A pinned entry navigated away (live) loses the marking; making it dormant
  restores it from the pinned URL — checked at runtime.[^harness]
- During a split collapse the survivor's host line appears at once, while
  the old right segment is still fading.

# Tests

`DevModeTests` (42 tests): every host form above and its look-alikes, the
schemes, nil and hostless URLs, the label's ports, brackets, case and user
info, the row and split markings, the selected-row display rule (single,
split halves, unmarked, the host line independent of selection), a sleeping
tab following its URL, pinned and favourite URL fallbacks, the cell's host
line, borders (selected only, title and host line not moving on selection,
following its `TabRowView`, joining a selected row) and reuse, split halves
selected and not, and a favourite tile following its tab's navigation and
bordered only when selected, also through the bar's selection update.

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

The TASK-197 selected-row [harness](../../docs/harness/task197b-harness.patch)
logged every row's row-view and cell selection, host line and borders, and
captured each state at 2x in light and dark: a dev row selected, then
another through the table's own selection (the click path), with the border
moving and the first keeping its host line; a normal row selected (no
border anywhere); the split selected with either pane focused (its local
half bordered) and unselected (nothing); the favourite tile selected and
not; the live pinned row selected while the dormant one kept only its host
line; a space switch and back; two windows on one space each bordering its
own selection; and closing the selected tab, after which the new selection
was bordered. The title and host-line frames were identical in every step,
and the border sampled #FF7600 with near-black dashes.[^harness-197b]

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
- [Dev toolbar](./dev-toolbar.md) and [Dev toolbar captures](./dev-toolbar-captures.md) — what a dev-mode page shows above its content.

[^task-186]: Dev mode for local development URLs, sidebar row and in-page dev toolbar
[^arc-row]: Arc's dev-mode sidebar row (reference image)
[^task-186-1]: Dev mode: detect local development URLs and mark the tab's sidebar row
[^task-186-5]: Dev mode: turn dev mode on or off per site from the address bar popover
[^harness]: TASK-186.1 runtime harness
[^harness-1865]: TASK-186.5 runtime harness
[^override-tests]: DevModeSiteOverrideTests.swift
[^task-186-2]: Dev mode: an under-construction toolbar above the page with the URL
[^palette]: DevModePalette.swift
[^task-197]: Dev mode: tie the under-construction motif to the Detour branding (orange hazard border)
[^harness-197]: TASK-197 colour comparison harness (options, contrast measurements)
[^rule]: DevMode.swift (isLocalDevelopmentURL, devModeHostLabel, DevMode, DevModeRowMarking)
[^tab-cell]: TabCellView.swift (updateDevMode, isRowSelected, TabRowView.isSelected)
[^favorites-bar]: FavoritesBarView.swift (FavoriteTileView.refreshDevMode, isSelected)
[^harness-197b]: TASK-197 selected-row-only border harness
