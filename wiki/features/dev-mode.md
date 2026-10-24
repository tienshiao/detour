---
type: Feature
title: Dev mode
description: "Which URLs count as local development (localhost, *.localhost, 127.0.0.0/8 in any IPv4 spelling, [::1], 0.0.0.0, *.test over http/https), the per-site override and its popover switch, the one function the effective state goes through, how a dev-mode tab's sidebar row, split half and favourite tile are marked with a hazard border and a host line, and the striped toolbar above a dev-mode page (inside the tab's container, frame-based so the docked Web Inspector keeps working)."
tags: [dev-mode, sidebar, tabs, url-rules, site-settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T19:40:00Z }
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
  - id: toolbar-layout
    resource: ../../Detour/Browser/DevMode/DevToolbarLayout.swift
    title: DevToolbarLayout.swift
  - id: toolbar-view
    resource: ../../Detour/Browser/DevMode/DevToolbarView.swift
    title: DevToolbarView.swift
  - id: container
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (WebViewContainerView, the toolbar's host)
  - id: window-toolbar
    resource: ../../Detour/Browser/Window/BrowserWindowController+DevToolbar.swift
    title: BrowserWindowController+DevToolbar.swift
  - id: drag-strip
    resource: ../../Detour/Browser/Shared/WindowDragView.swift
    title: WindowDragView.swift (WindowDragPassThrough)
  - id: toolbar-tests
    resource: ../../DetourTests/DevToolbarLayoutTests.swift
    title: DevToolbarLayoutTests.swift
  - id: hosting-tests
    resource: ../../DetourTests/DevToolbarHostingTests.swift
    title: DevToolbarHostingTests.swift
  - id: harness-1862
    resource: ../../docs/harness/task186-2-harness.patch
    title: TASK-186.2 runtime harness
  - id: webkit-inspector
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Inspector/mac/WebInspectorUIProxyMac.mm
    title: WebInspectorUIProxyMac.mm (inspectedViewFrameDidChange, platformDetach)
  - id: task-186-2
    resource: backlog:TASK-186.2
    title: "Dev mode: an under-construction toolbar above the page with the URL"
  - id: arc-toolbar
    resource: ../../docs/dev-mode/arc-dev-toolbar.png
    title: Arc's dev toolbar (reference image)
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
local one, per profile.[^task-186-5] Above the page of a dev-mode tab sits
a striped toolbar with the URL ([below](#the-dev-toolbar)).[^task-186-2]

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

## The dev toolbar

A 30 pt bar across the top of a dev-mode tab's web content, modelled on
Arc's (faint diagonal stripes on a light bar).[^arc-toolbar] Left to right:
an info button (`info.circle`, "Site Settings"), the page's URL in 11 pt
monospace, truncated in the middle, and a trailing stack holding the copy
button (`link`, "Copy URL").[^toolbar-view]

| Control | Does |
|---|---|
| Info | Opens the site settings popover (the one behind the address bar's slider button) under the info button, without the address bar's hover buttons showing |
| URL | Opens the command palette prefilled with the URL, navigating the tab in place (a new tab while a Peek is up), anchored at the toolbar |
| Copy | Copies the toolbar's own pane's URL, with the "URL copied" toast, through the same `copyURL` the address bar uses |
| Background | Moves the window (`performDrag`), as the drag strip it sits in would |

A click on a control in the unfocused pane of a split focuses that pane
first (`makeFirstResponder` on its web view), so the palette and the popover
act on it. TASK-186.3 and TASK-186.4 add their buttons with
`addTrailingGroup(_:)`, which puts a hairline separator before each group.
Every button carries an accessibility label; the bar is an accessibility
toolbar.

**Decisions** (user, TASK-186.2):[^task-186-2] the URL opens the palette (no
inline editing); the info button opens the site popover; no toolbar inside a
Peek panel (the Peek's web view is bare, never in a container) while the
host's stays under the overlay; window fullscreen keeps the toolbar;
element (video) fullscreen needs nothing.

### Where it lives, and the layout rule

The toolbar is a subview of the tab's `WebViewContainerView`, a sibling of
the web view, laid out by frames.[^container] Nothing outside the container
knows about it: a split pane, an ownership-transfer snapshot of the
container and the PiP hold all carry it.

**Only the web view's top edge moves.** Showing the toolbar sets the web
view's height to `container.height − 30 − webView.minY`, keeping its x,
width and bottom; hiding it gives the 30 pt back. This is what makes it work
with the docked Web Inspector, which is the web view's other sibling.
WebKit re-frames the inspected web view itself whenever the inspector docks,
undocks, resizes or the container resizes, and it keeps the web view's top
(`NSMaxY`) where it was, "so banners in Safari still work"
(`inspectedViewFrameDidChange`, `platformDetach`).[^webkit-inspector] So the
toolbar behaves like a Safari banner:

- **Bottom dock:** the inspector takes the bottom; the web view's `minY`
  rises and the toolbar keeps the full width.
- **Left or right dock:** the inspector spans the container's full height
  and the web view narrows, so the toolbar follows the web view's x and
  width (it observes the web view's `frameDidChangeNotification`), never
  the container's.

The geometry is the pure `DevToolbarLayout.frames(containerBounds:webViewFrame:toolbarHeight:showsToolbar:)`
plus `toolbarFrame(containerBounds:webViewFrame:)` for the WebKit-driven
case.[^toolbar-layout] The container re-applies it in `resizeSubviews`:
autoresizing keeps the web view's margins, which holds the gap through a
window resize, but not when a container that showed the toolbar at zero
size (they are made at zero size and framed when hosted) is first sized.
A container whose page never needed the toolbar has none and is untouched,
so a non-dev tab lays out exactly as before.

**Corners.** The container rounds every subview to the pane's radius. While
the toolbar shows, it rounds only its top corners and the web view only its
bottom ones, so the two read as one card with no notch; all four come back
when it hides. The mask is in the layer's own coordinates, which AppKit
flips for `WKWebView` (a flipped view): there the bottom corners are the
`MaxY` ones. It is decided from `view.isFlipped`: the layer's
`contentsAreFlipped()` read unflipped while a split pane was being
re-hosted and rounded the page's top corners instead.[^harness-1862]

### Which panes show it

`BrowserWindowController+DevToolbar` decides, per pane this window hosts
(`hostedPaneTabs`: the selected tab, or both panes of its split, whose
containers are in this window), with `DevMode.isActive(for: tab.url,
profileID:)` for the window's profile.[^window-toolbar]

- **Claim:** `claimWebView` ends with `refreshDevToolbars()`, which decides
  every hosted pane, points its controls at this window (so whichever
  window owns the container drives it) and subscribes to each pane's
  `$url`. `removeContentViews` drops the subscriptions; a window showing a
  snapshot follows nothing.
- **Navigation:** the `$url` sink re-decides that pane, the unfocused one
  of a split included.
- **The per-site switch:** the window observes
  `SiteSettingsStore.didChangeNotification` too; for a `devMode` change on
  its profile it re-decides the hosted panes in the same turn.
- **Space or profile change:** goes through `selectTab`, hence a claim.

**Snapshots.** The handoff snapshot is of the container, so it includes the
toolbar. `liveSnapshot(for:)` (a second window showing a tab another window
hosts) now pictures the container too while it shows the toolbar; the bare
web view is 30 pt shorter and sat offset in the stand-in.

**Find bar.** It is pinned 12 pt below the content area's top, which is on
the toolbar. `updateFindBarPlacement()` moves it down by 30 pt while a
hosted pane's toolbar lies under its spot. That test is geometric, not "the
focused pane": the find bar sits over a split's left pane whichever pane is
focused, and a left-docked inspector moves the toolbar out from under it.

**The drag strip.** The content area's top 38 pt is a `WindowDragView` over
everything, which forwards a click by calling `mouseDown` and then a
synthesized `mouseUp` on the view underneath. An `NSButton` cannot take that:
its `mouseDown` tracks the real event queue for a mouse-up the strip has
already consumed. Views that handle their own clicks adopt
`WindowDragPassThrough`, and the strip's `hitTest` returns nil over them, so
the event goes straight to the button.[^drag-strip]

# Edge cases

- A split row with both panes local shows two borders, one per half.
- A pinned entry navigated away (live) loses the marking; making it dormant
  restores it from the pinned URL — checked at runtime.[^harness]
- During a split collapse the survivor's host line appears at once, while
  the old right segment is still fading.

- A side-docked inspector stops about 66 pt below the window's top:
  WebKit intersects its frame with the window's `contentLayoutRect` (below
  the title bar). It does so with or without the toolbar.[^webkit-inspector][^harness-1862]
- The split separation and formation veneers snapshot the bare web view, so
  for their 0.22 s a dev-mode pane's card shows no toolbar.

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

`DevToolbarLayoutTests` (21 tests, TASK-186.2): the pure layout with no
inspector, docked bottom, right and left, on-then-off returning the original
frame, a container resize, a web view that lost its gap, a container shorter
than the bar; and the container applying it (shown, hidden, never made, the
web view re-framed by someone else, resize, zero-size first, the corner
masks for an unflipped and a flipped web view, the label, the accessibility
labels, a trailing group).[^toolbar-tests] `DevToolbarHostingTests` (11, in a
Private window so the switch writes nothing): local and remote tabs,
navigation, switching tabs, the switch both ways, a split with one local
pane and its unfocused pane navigating, a Peek, the URL click (and focusing
the other pane first), and the copy button writing its own pane's URL to a
private pasteboard (`urlPasteboard`).[^hosting-tests]

The TASK-186.2 [harness](../../docs/harness/task186-2-harness.patch) checked
in the running app, with `window.innerHeight` against the container: a
local tab (730 under a 30 pt bar in a 760 pt container), a remote one (760),
the same tab navigating away and back, the copy button and toast, a posted
click on the URL through the drag strip, a resize, a split with one local
pane, the info popover, the inspector docked bottom, right and left (the bar
following the web view's width, the switch toggling it while docked), the
switch, a Peek, the find bar at 42 pt, dark mode, and a second window's
snapshot lining up with the live view.[^harness-1862]

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
[^task-186-2]: Dev mode: an under-construction toolbar above the page with the URL
[^arc-toolbar]: Arc's dev toolbar (reference image)
[^toolbar-view]: DevToolbarView.swift
[^container]: BrowserTab.swift (WebViewContainerView, the toolbar's host)
[^webkit-inspector]: WebInspectorUIProxyMac.mm (inspectedViewFrameDidChange, platformDetach)
[^toolbar-layout]: DevToolbarLayout.swift
[^harness-1862]: TASK-186.2 runtime harness
[^window-toolbar]: BrowserWindowController+DevToolbar.swift
[^drag-strip]: WindowDragView.swift (WindowDragPassThrough)
[^toolbar-tests]: DevToolbarLayoutTests.swift
[^hosting-tests]: DevToolbarHostingTests.swift
