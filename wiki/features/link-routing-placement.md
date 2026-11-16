---
type: Concept
title: Link placement
description: "Which window a routed link opens in, for links from other apps and routed clicks or typed URLs alike: the pure linkPlacement rule (the window showing the space brought forward, else the most recent normal window switched, Private into the most recent Private window, Quick Detour and Quarantine into new windows of their own), AppDelegate.placeTab and openLink, and what a routed link that turns out to be a download puts back."
tags: [links, spaces, windows, downloads]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:20Z }
sources:
  - id: placement
    resource: ../../Detour/Browser/LinkRouting/LinkPlacement.swift
    title: LinkPlacement.swift (linkPlacement, LinkPlacementWindow, LinkPlacement)
  - id: appdelegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (openLink, placeTab, place, restoreWindows)
  - id: placement-tests
    resource: ../../DetourTests/LinkPlacementTests.swift
    title: LinkPlacementTests.swift
  - id: task-191-2
    resource: backlog:TASK-191.2
    title: "TASK-191.2: send links from other apps to the routed space"
  - id: task-193-3
    resource: backlog:TASK-193.3
    title: "Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)"
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
  - id: task-194
    resource: backlog:TASK-194
    title: "Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose"
  - id: task-205
    resource: backlog:TASK-205
    title: Routed and new-tab clicks that turn into downloads leave an empty tab
---

Once the [resolver](./link-routing-resolver.md) has said where a link goes,
the pure `linkPlacement(for:windows:)` says which window it opens in, and
`AppDelegate.openLink(_:routedTo:)` carries that out. Links from other apps
([TASK-191.2](./link-routing-external-links.md)) and typed URLs or clicked
links a route moves ([TASK-191.4](./link-routing-in-page.md)) go through the
same code, so a routed click is placed exactly as a link from another app.
Part of [Link Routes](./link-routing.md).

# The rule

`linkPlacement` takes a snapshot of the browser windows, most recently
active first (`NSApp.browserWindowControllersFrontToBack`, then any
registered window missing from the window list, such as a minimized one).
For links from other apps the snapshot is taken again for every URL: an
earlier URL of the same open may have opened or switched a window. The
AppKit side (`place`) only carries the placement out.[^task-191-2]

| Decision | Placement | Why |
|---|---|---|
| A space a normal window shows | `.openInWindow`: a tab there, selected, the window brought forward (`makeKeyAndOrderFront`). Several show it: the most recent of them. | The space is already on screen; the user goes to it. |
| A space no window shows | `.switchWindow`: the most recent **normal** window switches to it (`setActiveSpace(selectTab: false)`), then as above. No normal window: `.openInNewWindow` (`createNewWindow(showing:)`). | User decision 2026-10-25 (the 191.2 proposal): as a space switch does, rather than a new window per link. A Private window is never switched to a normal space. |
| Private window | `.openInPrivateWindow`: a tab in the most recent Private window; none open: `.openInNewPrivateWindow` (`createNewWindowWithURL(_:incognito: true)`). | Decided 2026-10-24. |
| Most Recent Space (and the resolver's fallbacks to it) | `.mostRecentSpace`: exactly the code from before routes, a tab in the key browser window's active space, else `createNewWindowWithURL`. | Kept as it was. With Detour in the background there is no key window, so that is a new window every time (seen at runtime); unchanged on purpose. |
| Quick Detour | `.openInQuickDetour`: `AppDelegate.openLink` opens a new Quick Detour window with the link (no tab in any space), on `QuickDetour.profileForRoutedLink` — the frontmost Detour window's profile, but never Private (a Private window in front is passed over for the next window's; none: the first normal profile) — its Open in naming the most recent normal window's space of that profile. | TASK-193.5. Never Private: only a Private Window (or Quarantine) target takes a link from another app into Private; see [Quick Detour](./quick-detour-entry-points.md#links-from-other-apps-the-link-routes-quick-detour-target). The Most Recent Space fallback TASK-191.2 left for it is gone.[^task-193-5] |
| Quarantine | `.openInQuarantine`: `AppDelegate.openLink` opens a new quarantine window (`openInQuarantine`): a Quick Detour on the Private profile with a fresh store of its own, whose Open in names the space a routed click came from, else the most recent normal window's space. | TASK-194; see [Quarantine](./quarantine.md).[^task-194] |
| `.stay` | `.mostRecentSpace` | The resolver never says stay for an external link; if it did, the link still needs a window. A routed click or typed URL whose decision is `.stay` never reaches placement. |

A routed placement whose window or space has gone by the time it runs falls
back to the Most Recent Space path (or a new Private window).

# Carrying it out

The carrying-out is `AppDelegate.placeTab(routedTo:makeTab:didSelect:)`
since TASK-193.3: the same rule, with the tab made by a closure that gets the
receiving space once its window shows it (switched, or opened for it).
`openLink` passes one that opens the URL; Quick Detour's Open in passes one
that hands its own page over (`TabStore.moveQuickDetourTab`), and a
`didSelect` that announces the move to the extension contexts before the
window announces the tab active. A new Private window made for a placement
holds only the placed tab (no empty tab of its own). The placed tab never
shows the collapsed sidebar's "Opened new tab in background" toast, since it
is selected at once.[^task-193-3]

# A routed link that is a download

The route is decided at the click, before the response, so a link that turns
out to be a download has already switched a window's space or brought a
window forward. `openLink` records on the placed tab what the placement
changed (`BrowserTab.routedOpen`: the window clicked in, the placed window,
whether it was opened for the tab and whether it is Private, the space it
showed before). When the tab closes because its first navigation became a
download (see [Downloads](./downloads.md#a-tab-opened-for-a-download-closes)),
`AppDelegate.restoreWindows(after:)` acts on
`DownloadOpenedTabPolicy.restoration` (TASK-205):[^task-205]

| Placement | Put back |
|---|---|
| A window switched to the routed space (the clicked one or another) | Switched back to the space it showed |
| A window opened for the tab | Closed |
| A Private window opened for the tab | Left open and in front: the download is listed only there, and closing it would cancel it (TASK-156) |
| Any other window brought forward | The clicked window comes to the front again |

Only while the placed window is still the key window (Detour's front window
when none of Detour's is key: the user may have gone to another app) and
still shows the routed space; a user who moved on is not pulled back. A link
from another app has no clicked window, so only the placed window is put
back.

# Tests

`LinkPlacementTests`: every placement rule, several windows showing a space,
recency, Private in front, no windows. The same suite covers the sender and
`LaunchLinkTracker` ([links from other apps](./link-routing-external-links.md#tests)).
The AppKit side is exercised with real windows by `ExternalLinkRoutingTests`
and `InPageLinkRoutingTests`.

# Related

- [Link Routes](./link-routing.md): the hub.
- [Downloads](./downloads.md): the tab that closes when its first navigation is a download.
- [Quick Detour Open in](./quick-detour-open-in.md): reuses `placeTab`.
- [Quarantine](./quarantine.md): the quarantine window.

[^task-191-2]: TASK-191.2: send links from other apps to the routed space
[^task-193-3]: Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)
[^task-193-5]: Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive
[^task-194]: Quarantine: links in a throwaway Quick Detour window, then moved to a profile and space on purpose
[^task-205]: Routed and new-tab clicks that turn into downloads leave an empty tab
