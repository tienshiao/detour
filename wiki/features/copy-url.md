---
type: Feature
title: Copy URL
description: "Every copy of a page's or tab's address (Edit > Copy URL / Shift-Cmd-C in a browser or Quick Detour window, the faux address bar's and Quick Detour's Copy Link buttons, the sidebar tab menu's Copy URL / Copy Link) puts the address on the clipboard without its tracking parameters, through the shared tracking-parameter rule; Share… shares the clean link too; what is left alone (the dev toolbar's link button, the user's decision; a page's own Copy Link; Opt-Cmd-click copies into Quick Detour) and why; the loaded URL, history and session keep the original (TASK-326)."
tags: [links, privacy, clipboard, sidebar, window]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:41:01Z }
sources:
  - id: task-326
    resource: backlog:TASK-326
    title: "Copy URL: Shift-Cmd-C copies the URL with tracking parameters removed"
  - id: rule
    resource: ../../Detour/Browser/TrackingParameters.swift
    title: TrackingParameters.swift (copyableString, cleanLink)
  - id: tracking-parameters
    resource: ./tracking-parameters.md
    title: Tracking parameters (the shared rule, the downloaded filter and its switch)
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (copyCurrentURL, copyURL)
  - id: quick-detour
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift (copyCurrentURL)
  - id: sidebar
    resource: ../../Detour/Browser/Sidebar/TabSidebarViewController.swift
    title: TabSidebarViewController.swift (contextMenuCopyURL, makeSharingPicker)
  - id: checks
    resource: ../../docs/harness/task326-copy-url-checks.py
    title: TASK-326 runtime checks through the automation endpoint
  - id: checks-326-toolbar
    resource: ../../docs/harness/task326-dev-toolbar-copy-checks.py
    title: TASK-326 runtime check of the dev toolbar's copy (as loaded) beside Shift-Cmd-C (clean)
  - id: task-329
    resource: backlog:TASK-329
    title: "Links: strip tracking parameters with the AdGuard URL Tracking filter in addition to the built-in list"
---

Detour copies the clean link: whichever button or shortcut copies the
address of a page or tab, the clipboard gets that address without its
tracking parameters (`utm_*`, `fbclid`, `gclid`, …). Only the copied string
changes. The tab's URL, its history visits and its session record keep the
address as it was loaded.

# What it does

| Entry point | Code | Strips |
|---|---|---|
| Edit > Copy URL (Shift-Cmd-C), browser window | `BrowserWindowController.copyCurrentURL` → `copyURL(_:asLoaded:)` | yes |
| The faux address bar's link button (Copy Link) | `fauxAddressBar.onCopyURL` → `copyCurrentURL` | yes |
| A dev-mode page's toolbar link button (its own pane) | `copyURL(_:asLoaded: true)` | no: the address as loaded (the user's decision, 2026-11-14) |
| Edit > Copy URL (Shift-Cmd-C), Quick Detour window | `QuickDetourWindowController.copyCurrentURL` | yes |
| Quick Detour's title-bar Copy Link button | `titleBar.onCopyLink` → `copyCurrentURL` | yes |
| The sidebar tab menu's Copy URL / Copy Link (a tab, a split row, a pinned entry live or dormant, a pinned split) | `TabSidebarViewController.contextMenuCopyURL` | yes |
| A page's own context menu, Copy Link on a link | WebKit's item | no |
| The sidebar tab menu's Share… | `makeSharingPicker([TrackingParameters.cleanLink(for: url)])` | yes (see below) |
| Opt-Cmd-click on a sidebar tab or favourite ("a Quick Detour copy") | `QuickDetour.sidebarCopyURL` | no: it picks the address a new Quick Detour *loads*, not a clipboard string |

The three code paths that write the clipboard call
`TrackingParameters.copyableString(for:)` (the browser window's `copyURL`
skips it when the dev toolbar asks for the address as loaded). Each writes to a pasteboard
property (`urlPasteboard`, `.general` by default) that tests replace with a
private one.

**Decision (TASK-326 AC #6; confirmed by the user on 2026-11-14 with one
change):** every Detour command that copies "this page's" or "this tab's"
address strips, so the copied link is the same clean one whichever button
made it, **except the dev toolbar's link button**, which copies its pane's
address as loaded (`copyURL(_:asLoaded: true)`): a developer testing how
their own site handles `utm_*` on localhost wants the exact address, and
the toolbar is a developer's tool, not a way to share a link. Shift-Cmd-C
in the same window still strips. A link copied from inside the page
(WebKit's Copy Link) is the page's content and stays as the page wrote it.
The first cut (Claude's while the user was away) stripped the dev toolbar's
copy too.[^task-326]

Share… in the sidebar tab menu shares the clean link too (the user's call,
Nov 14 2026, after the first cut had left it alone): it is the other place a
page's address leaves Detour on the user's request, and a link sent from
Detour should be the same clean one whichever way it was sent. The picker is
built through `TabSidebarViewController.makeSharingPicker`, which a test
replaces to see the items.

# How it works

`TrackingParameters.copyableString(for:)` is the string of
`TrackingParameters.cleanLink(for:)` (Share… takes `cleanLink` directly): the built-in names (click IDs, `_ga`,
mail tools' IDs, every `utm_`) plus, while it is downloaded and turned on,
the AdGuard URL Tracking filter's site rules and exceptions (TASK-329,
TASK-337). The rule, the list, its exceptions, its switch in Settings >
Content Blocking and its tests are on
[Tracking parameters](tracking-parameters.md). Quarantine pages use the same
rule for their navigations
([Quarantine](quarantine.md#link-tracking-parameters)), so a name added to
the list changes both; with the list off or not downloaded, copies fall back
to the built-in names.

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
| `CopyURLTests` | in a real browser window with a private pasteboard: `copyCurrentURL`, the Edit menu item's Shift-Cmd-C binding, the faux address bar button, the sidebar's Copy Link (unselected tab), Copy URL (selected tab) and a pinned tab's, each also checking the tab's URL keeps its parameters |
| `CopyURLTests` (TASK-329 cases) | Copy URL, the sidebar's Copy URL and Share… with the downloaded filter installed, and without it |
| `DevToolbarHostingTests` | the dev toolbar's link button copying its own pane's address as loaded, and Copy URL for the same tab still stripping |
| `QuickDetourWindowTests` | the title bar's Copy Link and `copyCurrentURL` on a loopback page, and the page keeping its address |

The rule itself (`TrackingParametersTests`), the downloaded filter
(`TrackingParameterFilterTests`), its download path and switch
(`TrackingParameterListTests`, `SettingsSwitchRowTests`) and the quarantine
navigations (`QuarantineTests`, `QuarantineWindowTests`) are listed on
[Tracking parameters](tracking-parameters.md#tests).

At runtime (2026-11-14, `docs/harness/task326-copy-url-checks.py` through
the [automation endpoint](automation-endpoint.md)): a loopback page loaded
with `utm_source`, `utm_medium`, `fbclid`, `gclid` and `_ga`; Edit > Copy
URL by menu path, Shift-Cmd-C by key equivalent, the faux address bar's
button and the sidebar row's Copy URL all put the clean address on the
real clipboard (read with `pbpaste`); `list_tabs`, the history database
and the session database kept the tracked address.[^checks] A right click
on a sidebar row's label or icon does not open the tab menu through the
endpoint; one on the row's own background does. The downloaded filter's
Copy URL checks (TASK-329) and the switch's (TASK-337) are on
[Tracking parameters](tracking-parameters.md#runtime-checks).

At runtime for the dev toolbar (2026-11-14, after the user's decision,
`docs/harness/task326-dev-toolbar-copy-checks.py`): on a loopback page in
dev mode loaded with `utm_source` and `gclid`, a click on the toolbar's
Copy URL button (found by `hit_test`'s label) put the address as loaded on
the real clipboard, and Shift-Cmd-C in the same window then put the clean
one.[^checks-326-toolbar]

[^task-326]: TASK-326
[^checks]: docs/harness/task326-copy-url-checks.py
[^checks-326-toolbar]: docs/harness/task326-dev-toolbar-copy-checks.py

# Related

- [Tracking parameters](tracking-parameters.md): the shared rule Copy URL applies, the downloaded AdGuard filter and its switch.
- [Quarantine](quarantine.md#link-tracking-parameters): the same rule applied to a quarantine page's navigations.
- [Dev toolbar](dev-toolbar.md): the dev-mode toolbar, whose link button copies the address as loaded.
- [WebKit privacy protections](../platform/webkit-privacy-protections.md): WebKit's own click-ID filtering, which keeps `utm_*`.
- [Quick Detour](quick-detour.md): the title bar's Copy Link and the Opt-Cmd-click copy, which is a load, not a clipboard copy.
