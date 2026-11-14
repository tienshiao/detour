---
type: Feature
title: Copy URL
description: "Every copy of a page's or tab's address (Edit > Copy URL / Shift-Cmd-C in a browser or Quick Detour window, the faux address bar's and Quick Detour's Copy Link buttons, the dev toolbar's link button, the sidebar tab menu's Copy URL / Copy Link) puts the address on the clipboard without its tracking parameters, through the one rule and list in TrackingParameters that quarantine pages also use; what is left alone (a page's own Copy Link, Share…, Opt-Cmd-click copies into Quick Detour) and why; the loaded URL, history and session keep the original (TASK-326)."
tags: [links, privacy, clipboard, sidebar, window]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-14T20:30:00Z }
sources:
  - id: task-326
    resource: backlog:TASK-326
    title: "Copy URL: Shift-Cmd-C copies the URL with tracking parameters removed"
  - id: rule
    resource: ../../Detour/Browser/TrackingParameters.swift
    title: TrackingParameters.swift (the list, isTracking, removing, copyableString)
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (copyCurrentURL, copyURL)
  - id: quick-detour
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift (copyCurrentURL)
  - id: sidebar
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (contextMenuCopyURL)
  - id: checks
    resource: ../../docs/harness/task326-copy-url-checks.py
    title: TASK-326 runtime checks through the automation endpoint
---

Detour copies the clean link: whichever button or shortcut copies the
address of a page or tab, the clipboard gets that address without its
tracking parameters (`utm_*`, `fbclid`, `gclid`, …). Only the copied string
changes. The tab's URL, its history visits and its session record keep the
address as it was loaded.

# What it does

| Entry point | Code | Strips |
|---|---|---|
| Edit > Copy URL (Shift-Cmd-C), browser window | `BrowserWindowController.copyCurrentURL` → `copyURL(_:)` | yes |
| The faux address bar's link button (Copy Link) | `fauxAddressBar.onCopyURL` → `copyCurrentURL` | yes |
| A dev-mode page's toolbar link button (its own pane) | `copyURL(_:)` | yes |
| Edit > Copy URL (Shift-Cmd-C), Quick Detour window | `QuickDetourWindowController.copyCurrentURL` | yes |
| Quick Detour's title-bar Copy Link button | `titleBar.onCopyLink` → `copyCurrentURL` | yes |
| The sidebar tab menu's Copy URL / Copy Link (a tab, a split row, a pinned entry live or dormant, a pinned split) | `TabSidebarViewController.contextMenuCopyURL` | yes |
| A page's own context menu, Copy Link on a link | WebKit's item | no |
| The sidebar tab menu's Share… | `NSSharingServicePicker(items: [url])` | no (not a copy; see below) |
| Opt-Cmd-click on a sidebar tab or favourite ("a Quick Detour copy") | `QuickDetour.sidebarCopyURL` | no: it picks the address a new Quick Detour *loads*, not a clipboard string |

The three code paths that write the clipboard call
`TrackingParameters.copyableString(for:)`. Each writes to a pasteboard
property (`urlPasteboard`, `.general` by default) that tests replace with a
private one.

**Decision (TASK-326 AC #6, made by Claude while the user was away, not
confirmed by the user):** every Detour command that copies "this page's" or
"this tab's" address strips, so the copied link is the same clean one
whichever button made it. A link copied from inside the page (WebKit's Copy
Link) is the page's content and stays as the page wrote it. Alternative:
strip only Shift-Cmd-C (the task's required scope); flipping it back is a
one-line change per entry point. The dev toolbar is the debatable one: a
developer testing how their own site handles `utm_*` on localhost gets the
clean address from its button too (the palette, Cmd+L, still shows the
full address).[^task-326]

Share… in the sidebar tab menu shares the tab's `URL` object and was left as
it is: it is not a copy, and the task did not cover it. It is the one other
place a page's address leaves Detour on the user's request.

# How it works

`TrackingParameters` holds the one list and the pure rule; quarantine
pages use the same one for their navigations
([Quarantine](quarantine.md#link-tracking-parameters)), so a name added to
the list changes both.

- **The list** (`TrackingParameters.names`): click IDs (`gclid`, `gclsrc`,
  `dclid`, `gbraid`, `wbraid`, `fbclid`, `msclkid`, `igshid`, `yclid`,
  `twclid`, `ttclid`, `li_fat_id`, `rb_clickid`), Google Analytics' linker
  `_ga`, mail tools' IDs (`mc_eid`, `mc_cid`, `_hsenc`, `_hsmi`, `mkt_tok`,
  `oly_anon_id`, `oly_enc_id`, `vero_id`, `s_cid`), plus any name starting
  with `utm_` (longer than the prefix). Names are compared without case and
  after percent-decoding (`utm%5Fsource` is `utm_source`). A name that only
  resembles one (`ref`, `source`, `utm`, `gclid_extra`, `ga`) is kept.
- **The rule** (`TrackingParameters.removing(from:)`): only http(s) URLs;
  the query is split on `&` in its percent-encoded form, so the parameters
  kept keep their order, repeats and exact bytes (`+`, `%2B`, `%5B%5D`). A
  URL with no tracking parameter is returned as it is, byte for byte. When
  something is removed, empty pieces (`a=1&&b`, a trailing `&`) go too, and
  a query left empty is dropped with its `?`. The fragment is kept, even
  when it looks like a query.

# Edge cases

- A non-web address (`detour://history`, `mailto:`, `file:`) is copied
  unchanged.
- A sleeping or dormant pinned tab's Copy URL strips its stored address the
  same way.
- The toast is unchanged ("URL copied" in a browser window, "Link copied" in
  Quick Detour); it does not say parameters were removed.

# Tests

| Suite | Covers |
|---|---|
| `TrackingParametersTests` | the list (AC #1's names, case, lookalikes kept), order and encoding of the rest, percent-encoded names and values, repeated keys, only-tracking queries and stray `&`, fragments, URLs left unchanged, non-web schemes |
| `CopyURLTests` | in a real browser window with a private pasteboard: `copyCurrentURL`, the Edit menu item's Shift-Cmd-C binding, the faux address bar button, the sidebar's Copy Link (unselected tab), Copy URL (selected tab) and a pinned tab's, each also checking the tab's URL keeps its parameters |
| `DevToolbarHostingTests` | the dev toolbar's link button |
| `QuickDetourWindowTests` | the title bar's Copy Link and `copyCurrentURL` on a loopback page, and the page keeping its address |
| `QuarantineTests`, `QuarantineWindowTests` | the quarantine navigation rule, which uses the same list |

At runtime (2026-11-14, `docs/harness/task326-copy-url-checks.py` through
the [automation endpoint](automation-endpoint.md)): a loopback page loaded
with `utm_source`, `utm_medium`, `fbclid`, `gclid` and `_ga`; Edit > Copy
URL by menu path, Shift-Cmd-C by key equivalent, the faux address bar's
button and the sidebar row's Copy URL all put the clean address on the
real clipboard (read with `pbpaste`); `list_tabs`, the history database
and the session database kept the tracked address.[^checks] A right click
on a sidebar row's label or icon does not open the tab menu through the
endpoint; one on the row's own background does.

[^task-326]: TASK-326
[^checks]: docs/harness/task326-copy-url-checks.py

# Related

- [Quarantine](quarantine.md#link-tracking-parameters): the same list removed from a quarantine page's navigations.
- [WebKit privacy protections](../platform/webkit-privacy-protections.md): WebKit's own click-ID filtering, which keeps `utm_*`.
- [Quick Detour](quick-detour.md): the title bar's Copy Link and the Opt-Cmd-click copy, which is a load, not a clipboard copy.
