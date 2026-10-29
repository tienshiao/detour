---
type: Feature
title: Dev mode
description: "Which URLs count as local development (localhost, *.localhost, 127.0.0.0/8 in any IPv4 spelling, [::1], 0.0.0.0, *.test over http/https), the per-site override and its popover switch, the one function the effective state goes through, how a dev-mode tab's sidebar row, split half and favourite tile are marked with a host line and, on the window's selected row only (like Arc), a hazard border, and the striped toolbar above a dev-mode page (inside the tab's container, frame-based so the docked Web Inspector keeps working) with its capture buttons (visible area and full page, to the clipboard or Downloads) and its Console, Network and element picker buttons."
tags: [dev-mode, sidebar, tabs, url-rules, site-settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T21:45:00Z }
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
  - id: inspector-group
    resource: ../../Detour/Browser/DevMode/DevToolbarInspectorGroup.swift
    title: DevToolbarInspectorGroup.swift
  - id: inspector-control
    resource: ../../Detour/Browser/DevMode/WebInspectorControl.swift
    title: WebInspectorControl.swift
  - id: inspector-tests
    resource: ../../DetourTests/WebInspectorControlTests.swift
    title: WebInspectorControlTests.swift
  - id: capture-group
    resource: ../../Detour/Browser/DevMode/DevToolbarCaptureGroup.swift
    title: DevToolbarCaptureGroup.swift
  - id: page-capture
    resource: ../../Detour/Browser/DevMode/PageCapture.swift
    title: PageCapture.swift (PageCapture, CaptureImage, CaptureDelivery)
  - id: capture-geometry
    resource: ../../Detour/Browser/DevMode/PageCaptureGeometry.swift
    title: PageCaptureGeometry.swift (CaptureGeometry, CaptureFileName)
  - id: capture-tests
    resource: ../../DetourTests/PageCaptureTests.swift
    title: PageCaptureTests.swift
  - id: harness-1863
    resource: ../../docs/harness/task186-3-harness.patch
    title: TASK-186.3 runtime harness
  - id: task-186-3
    resource: backlog:TASK-186.3
    title: "Dev mode: capture buttons in the dev toolbar"
  - id: harness-1864
    resource: ../../docs/harness/task186-4-harness.patch
    title: TASK-186.4 runtime harness
  - id: task-186-4
    resource: backlog:TASK-186.4
    title: "Dev mode: toolbar buttons that toggle the Web Inspector's Console and Network tabs"
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
---

A tab whose page is a local development server is in **dev mode**, modelled
on Arc's.[^task-186] Its sidebar row gets an "under construction" look: the
page's host under the title (Arc shows `localhost:4000`)[^arc-row] and, while
it is the window's selected row, an orange and black dashed border around it
(the [app icon](../decisions/app-icon-design.md)'s orange).[^task-197] Local URLs are in dev mode by
default; the site settings popover turns it on for any site or off for a
local one, per profile.[^task-186-5] Above the page of a dev-mode tab sits
a striped toolbar with the URL ([below](#the-dev-toolbar)).[^task-186-2]

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
follows too.[^harness-1865]

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

## The dev toolbar

A 30 pt bar across the top of a dev-mode tab's web content, modelled on
Arc's (faint diagonal stripes on a light bar).[^arc-toolbar] Left to right:
an info button (`info.circle`, "Site Settings"), the page's URL in 11 pt
monospace, truncated in the middle, and a trailing stack holding the copy
button (`link`, "Copy URL"), after a hairline the capture group: Capture
Visible Area (`camera`) and Capture Full Page (`rectangle.expand.vertical`),
and after another the Web Inspector group: Console (`terminal`), Network
(`globe`) and Select Element (`scope`), as in
Arc.[^toolbar-view][^capture-group][^inspector-group]

| Control | Does |
|---|---|
| Info | Opens the site settings popover (the one behind the address bar's slider button) under the info button, without the address bar's hover buttons showing |
| URL | Opens the command palette prefilled with the URL, navigating the tab in place (a new tab while a Peek is up), anchored at the toolbar |
| Copy | Copies the toolbar's own pane's URL, with the "URL copied" toast, through the same `copyURL` the address bar uses |
| Capture Visible Area | Puts a PNG of this pane's visible page on the clipboard ("Screenshot copied"); Option-click saves it to Downloads ([below](#captures)) |
| Capture Full Page | The same for the whole document ("Full-page screenshot copied") |
| Console | Opens this pane's inspector on Console; closes it when it already shows Console; switches to Console when it shows another tab |
| Network | The same for the Network tab |
| Select Element | Toggles WebKit's element picker; the button is tinted with the accent colour while it is on. Picking an element opens the inspector on Elements |
| Background | Moves the window (`performDrag`), as the drag strip it sits in would |

A click on a control in the unfocused pane of a split focuses that pane
first (`makeFirstResponder` on its web view), so the palette and the popover
act on it; they stop if the pane did not take focus. The inspector buttons
and the capture buttons focus the pane too but act on their pane's own web
view either way: the call names its web view, so it cannot land on the
other pane.
Groups are added with `addTrailingGroup(_:order:)`, which puts a hairline
separator (fixed at 1 x 14 pt: with two groups an unsized separator
stretched across the bar, see [AppKit gotchas](../platform/appkit-gotchas.md#layout))
before each group and keeps them in `TrailingGroupOrder`
(`.capture` before `.inspector`), so the capture group lands between the
link and the inspector whichever is added first. Every button
carries an accessibility label; the bar is an accessibility toolbar.

### Captures

TASK-186.3.[^task-186-3] Decisions (user): two buttons, the visible area and
the full page; a click puts a PNG on the clipboard with a toast; an
Option-click saves it to Downloads instead, with a toast naming the file; no
area selection. The toast has no action, so there is no "Show in Finder".

| | Visible area | Full page |
|---|---|---|
| What | `takeSnapshot` of the pane's web view `bounds`: the page only, never the toolbar or a docked inspector (siblings in the container) | The whole document, wherever it is scrolled; the page is not scrolled |
| How | Public API | WebKit's private whole-document snapshot (`_usesContentsRect`) while the raw image is at most 2^26 px, then scaled down to the caps; above that, `createPDF` rasterised at the capped size |
| Size | Web view points x the device scale (1172 x 830 pt at 2x → 2344 x 1660 px) | Document points x the device scale, scaled down to at most 16384 px on the long edge and 2^26 px in all; the toast then says "(scaled down)" |

Why the full page cannot be a big snapshot rect, what each method does with
fixed, sticky, filtered and GPU content, and how device pixels are read out
of the snapshot are on [WKWebView snapshots](../platform/wkwebview-snapshots.md).[^page-capture]

- **Pixel math** is the pure `CaptureGeometry` (`pixelSize(points:scale:)`
  with the caps, `fullPageMethod`, `documentPoints`, `dpi`).[^capture-geometry]
  The scale comes from the page: `devicePixelRatio / pageZoom`. The PNG
  records 72 dpi per pixel per point (144 at 2x), so it previews at the
  page's size. 16384 px is the texture limit of most GPUs and about the
  largest image paste targets accept unshrunk; 2^26 px is 256 MB of RGBA,
  which the page's process paints and the app copies and encodes. PNG
  encoding, scaling and PDF rasterising run off the main thread.
- **Clipboard:** a pasteboard item with `public.png`, plus `public.tiff`
  made on demand (from the PNG, LZW, same DPI) by an
  `NSPasteboardItemDataProvider`, for apps that read only TIFF; a TIFF of a
  tall page is tens of MB, so it is not made unless asked for.
- **File:** `CaptureFileName.make`: "Screenshot localhost-3000 2026-10-24 at
  21.05.03.png", "... (full page).png" (the host line with `:` as `-`,
  since Finder shows a colon as a slash; no host, no host part); then
  `unique`, which adds " (2)", " (3)" so nothing is overwritten (two captures
  in one second), and the write is `.withoutOverwriting`. The folder is
  `DownloadManager.shared.downloadsDirectory` (the user's Downloads; no
  setting chooses another). The toast names the file and the folder.
- **Busy and failure:** both buttons of the pane are disabled while its
  capture is in flight (a visible capture takes under 0.1 s, a 5320 pt page
  at 2x about 2.5 s with encoding). A web view with no page, a failed
  snapshot or PDF, or no answer within 60 s shows "Couldn't capture the
  page"; a failed write "Couldn't save the screenshot".
- **Seams:** the window's `capturePasteboard` and `captureSaveDirectory`, and
  the group's `modifierFlags`, so tests and the harness never touch the
  user's clipboard or Downloads.
- **The toast moves below the toolbar.** It sits at the content area's top
  right, over the capture buttons when the pane there shows a toolbar; the
  window's `toastTopInset()` puts it 30 pt lower then (the same geometric
  test as the find bar), so it never covers the button just pressed.

Tests: `PageCaptureGeometryTests` (pure), `PageCaptureImageTests` (PNG, PDF,
pasteboard, files), `PageCaptureWebViewTests` (real web views at 2x through
`_overrideDeviceScaleFactor`: visible, full page by both methods, no page)
and `DevToolbarCaptureGroupTests`.[^capture-tests] Runtime: on a 2x virtual
display, single tab, split, docked inspector, light and dark.[^harness-1863]

**The inspector buttons** (TASK-186.4)[^task-186-4] use private WebKit API
kept in one type, `WebInspectorControl`; the calls, the guards and what was
rejected are on [Driving the Web Inspector](../platform/web-inspector-control.md).
The decision is the pure `InspectorToggle.action(isVisible:currentTab:requested:)`:
closed → `.show(tab)`, open on that tab → `.close`, open on another or an
unknown tab → `.switchTo(tab)`. `WebInspectorToggler` reads the frontend's
selected tab when the inspector is open, opens a closed one where WebKit
last had it (docked by default, on the saved side) and waits for the
frontend to load before picking Network; a second press while it is still
opening retargets that open. A button whose calls this WebKit lacks is left
out. Console and Network show no pressed state: the user can switch tabs
inside the inspector without the app hearing of it.

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

- A selected split row with both panes local shows two borders, one per half.
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

`DevModeTests` (41 tests): every host form above and its look-alikes, the
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

`WebInspectorControlTests` (22, TASK-186.4): the toggle rule (closed,
same tab, other tab, unknown tab), the frontend's tab types, which buttons a
WebKit gets from the selectors it answers, a canary that this Mac's WebKit
answers all of them, the group's buttons and labels, a capture group added
later landing before it, no group without capabilities, the picker's tint,
and in a Private window the group installed once across claims and the
unfocused pane's buttons acting on that pane's web view (a recording
`webInspectorToggler`).[^inspector-tests]

The TASK-186.4 [harness](../../docs/harness/task186-4-harness.patch) pressed
the real buttons and logged the frontend's own selected tab after each:
Console from closed opened docked on Console, again closed it; Network from
closed opened on Network; Console on Network switched, Network on Network
closed; Console after the user picked Elements switched; two presses in one
turn opened on the second; a right-docked inspector closed and reopened
docked right; in a split the unfocused pane's Console docked an inspector in
that pane only; a 422 pt pane got its own inspector window. The picker
turned on and off with its tint; picking an element was not verified
(synthetic mouse events do not reach WebKit's overlay).[^harness-1864]

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


## Colours: why brand orange

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
[^inspector-group]: DevToolbarInspectorGroup.swift
[^inspector-control]: WebInspectorControl.swift
[^inspector-tests]: WebInspectorControlTests.swift
[^harness-1864]: TASK-186.4 runtime harness
[^task-186-3]: Dev mode: capture buttons in the dev toolbar
[^capture-group]: DevToolbarCaptureGroup.swift
[^page-capture]: PageCapture.swift (PageCapture, CaptureImage, CaptureDelivery)
[^capture-geometry]: PageCaptureGeometry.swift (CaptureGeometry, CaptureFileName)
[^capture-tests]: PageCaptureTests.swift
[^harness-1863]: TASK-186.3 runtime harness
[^task-186-4]: Dev mode: toolbar buttons that toggle the Web Inspector's Console and Network tabs
[^hosting-tests]: DevToolbarHostingTests.swift
[^palette]: DevModePalette.swift
[^task-197]: Dev mode: tie the under-construction motif to the Detour branding (orange hazard border)
[^harness-197]: TASK-197 colour comparison harness (options, contrast measurements)
[^rule]: DevMode.swift (isLocalDevelopmentURL, devModeHostLabel, DevMode, DevModeRowMarking)
[^tab-cell]: TabCellView.swift (updateDevMode, isRowSelected, TabRowView.isSelected)
[^favorites-bar]: FavoritesBarView.swift (FavoriteTileView.refreshDevMode, isSelected)
[^harness-197b]: TASK-197 selected-row-only border harness
