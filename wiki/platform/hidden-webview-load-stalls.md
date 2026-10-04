---
type: Investigation
title: Hidden web view load stalls
description: Why a tab opened in the background can sit part-loaded until it is shown — WebKit drops a hidden page's web process to background priority about a second after commit — and what Detour does about it.
tags: [webkit, loading, tabs, sidebar, performance]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:30:18Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-124
    resource: backlog:TASK-124
    title: "Sidebar: fade out the progress bar on a background tab whose load has stalled"
  - id: task-112
    resource: backlog:TASK-112
    title: "Favicons: some sites never get their favicon, and their sidebar rows show a stray grey box"
  - id: task-114
    resource: backlog:TASK-114
    title: "Tabs: a background tab whose load stalls shows its URL as the title until it is first shown"
  - id: notes-stalls
    resource: "Agent session notes, 2026-10-01 (not in the repository)"
    title: Hidden web view load stalls, root cause measurement
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift
  - id: favicon-bridge
    resource: ../../Detour/Browser/Shared/FaviconLinkBridge.swift
    title: FaviconLinkBridge.swift
  - id: stall-tests
    resource: ../../DetourTests/LoadProgressStallTests.swift
    title: LoadProgressStallTests.swift
  - id: title-tests
    resource: ../../DetourTests/BackgroundTabTitleTests.swift
    title: BackgroundTabTitleTests.swift
---

A page loading in a web view that is not on screen can stop making progress
and stay that way until the tab is shown. This is WebKit's process
throttling, not a Detour bug and not something the page does. Detour does not
fight it; it makes sure nothing a background tab needs (title, favicon, error
page, an honest progress bar) waits for the load to finish.

# Symptom

A tab opened in the background (Cmd+click, `store.addTab` without selecting,
an extension's `tabs.create({active: false})`) shows, for as long as it stays
unselected:

- a sidebar progress bar that never completes (first reported as "a stray
  grey box" behind the row — it is `TabCellView`'s progress bar);
- the stripped URL instead of the document title;
- the generic globe instead of the favicon.

Selecting the tab once fixes all three within a moment.[^task-112]

Typical state of a stuck page: `document.readyState` is `loading` or
`interactive`, `estimatedProgress` sits around 0.9, the main HTML is fully
received, and any `<link rel=icon>` is already in the DOM.[^task-112][^notes-stalls]

# Root cause

WebKit's `ProcessThrottler` manages each WebContent process's priority on
macOS through RunningBoard assertions. A web view that WebKit does not
consider visible loses its foreground activities when the navigation commits
(the "Provisional Load" activity ends). The process moves to "WebProcess
Background Assertion" and the foreground assertion is released about one
second later.[^notes-stalls]

At background priority the process is scheduled behind everything else. On an
idle machine that makes no visible difference. Under heavy system CPU load
(load average several times the core count) the process gets almost no CPU,
so:

- a light page finishes inside the one-second window and looks normal;
- a script-heavy page that needs more than about a second of CPU freezes
  mid-load until the view becomes visible;
- several hidden loads at once starve each other further.

So whether a given page stalls depends on machine load, on the page, and on
how many hidden pages are loading — which is why the set of stuck pages
varied from run to run.[^task-112]

# Evidence

All measurements were made with a standalone `swiftc` binary hosting plain
`WKWebView`s (no Detour code, no extensions, no content blocker), one hidden
web view at a time unless noted.

| Observation | How it was seen |
|---|---|
| Process drops to a background assertion at commit; foreground released 1 s later | `log stream` on subsystem `com.apple.WebKit`, category `ProcessSuspension` ("Updating process assertion type to 1")[^notes-stalls] |
| Stalled process is not blocked on I/O, it is simply not running | `sample` of the WebContent process: main thread parked at one program counter inside the page's large script bundle for the whole sample, 0% CPU[^notes-stalls] |
| Not specific to Detour | The plain spike with 10 URLs opened together leaves pages stuck; with 2 pages both finish in under 2 s[^task-112] |
| Being in a window is not enough | No window, an off-screen window, and a hidden view in an on-screen window all report `visibilityState: hidden` and all stall[^task-112] |
| A pending script call restores speed | With a pending `callAsyncJavaScript` promise the same hidden page finishes in about 2 s[^notes-stalls] |

## Ruled out

- **Page script gating on `visibilityState`** — faking the value changes
  nothing.[^notes-stalls]
- **`requestAnimationFrame` not firing while hidden.**[^notes-stalls]
- **Hidden-page timer throttling and visibility-based process suppression**
  (the private preferences `_hiddenPageDOMTimerThrottlingEnabled` and
  `_pageVisibilityBasedProcessSuppressionEnabled`) — turning them off does not
  help.[^notes-stalls]
- **App Nap.**[^task-124]
- **Network** — the main resource was fully received.[^notes-stalls]
- **Detour's configuration** (extension controller, content rule lists, data
  store, user agent) — the plain spike reproduces it.[^task-112]
- **An earlier reading** in TASK-112, that WebKit "stalls hidden pages when
  many load at once", was a correct observation with the wrong cause; the
  priority drop explains it.[^notes-stalls]

## What restores speed

- WebKit seeing the view as visible: in an ordered-in window and not
  `isHidden`. A view that is merely covered by a sibling view still counts as
  visible (the page reports `visibilityState: visible`).[^notes-stalls]
- Any foreground activity. `evaluateJavaScript` and `callAsyncJavaScript`
  hold one while pending, so a pending `callAsyncJavaScript` promise (re-issued
  after each navigation) or a once-a-second `evaluateJavaScript("1")` keeps a
  hidden load at foreground priority.[^notes-stalls]
- There is no macOS SPI for "always foreground":
  `_alwaysRunsAtForegroundPriority` is iOS only, and
  `_clientNavigationsRunAtForegroundPriority` only covers the load up to
  commit.[^notes-stalls]

# Fix

The product decision was to accept the de-prioritisation — background tabs
yielding CPU is the efficient behaviour — and to fix what the user sees
instead of forcing priority.[^task-124] Three changes, each removing a
dependency on `isLoading` going false:

| Symptom | Change | Where |
|---|---|---|
| Favicon missing | A user script in a private `WKContentWorld` reports `<link rel=icon>` as soon as the parser or a script inserts it; the end-of-load lookup stays as a fallback | [FaviconLinkBridge.swift](../../Detour/Browser/Shared/FaviconLinkBridge.swift), `BrowserTab.pageDidReportFaviconLink`; see [favicons](../features/favicons.md) |
| URL shown as title | The tab's own navigation delegate (used while no window has claimed the web view) forwards `didCommit` to `didCommitNavigation()`, which is what ends the "show the attempted URL" state | `extension BrowserTab: WKNavigationDelegate` in [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift); see [BrowserTab](../architecture/browser-tab.md) |
| Progress bar going nowhere | `isLoadProgressStalled` + `sidebarProgress` | below |

## The stalled-progress flag

`BrowserTab.isLoadProgressStalled` is published and becomes true when all of
these hold for `BrowserTab.loadStallInterval` (2 s):

- a load is in flight (`isLoading`),
- the web view is in no window (`webView?.window == nil`),
- neither `isLoading` nor `estimatedProgress` has changed.

Any change to either restarts the timer and clears the flag
(`restartLoadStallTimer`). A tab whose web view is on screen is never marked
stalled; the timer just re-arms so the tab is caught if it goes to the
background mid-load. `noteShown()` clears the flag when a window attaches the
pane or comes back from occlusion, because progress may never move again on
its own (a hung subresource).

`sidebarProgress` is `0` while stalled and `estimatedProgress` otherwise.
Every sidebar row path draws `sidebarProgress`; the [tab cell](../sidebar/tab-cell.md)
already fades its bar out at zero. `TabStore.subscribeToTab` notifies
observers when the flag flips so the row redraws.

`isLoading` and `estimatedProgress` themselves are untouched: the load is
real and still in flight, so the reload/stop button, extension tab status and
history recording keep seeing the truth.

# Rules for future work

- Do not gate anything a background tab needs on `isLoading == false`. It may
  not happen until the tab is shown.
- Do not "fix" the stall by holding a foreground activity unless the product
  decision changes. The technique works and is recorded above.
- When measuring load behaviour, record the machine's load average first;
  results are not comparable without it.[^notes-stalls]
- A feature that must drive an unselected tab (screenshots, synthetic input)
  cannot rely on a hidden web view at all. That design problem belongs to the
  [Claude extension epic](../extensions/claude-extension-epic.md).

# Tests

- [LoadProgressStallTests](../../DetourTests/LoadProgressStallTests.swift):
  hidden and stalled, cleared when the load moves, a hosted tab never stalled,
  showing a stalled tab clears it without progress moving.
- [BackgroundTabTitleTests](../../DetourTests/BackgroundTabTitleTests.swift):
  title at commit while the load never finishes.
- [FaviconLinkBridgeTests](../../DetourTests/FaviconLinkBridgeTests.swift):
  icon found while loading. It defines `StallingSchemeHandler`, a custom
  scheme handler that holds one subresource open so a load never ends — the
  deterministic way to test "still loading" without the network.
- Live check of the fade: a background tab whose image request never answers
  showed the bar at 1 s, lost it by 4.5 s, and got it back on
  selection.[^task-124]

# Open questions

- The assertion timing was measured on one macOS release; a WebKit update can
  change the one-second grace or the throttler's rules.
- The sources do not record whether a web view in an ordered-in but fully
  occluded window keeps foreground priority.

# Related

- [BrowserTab](../architecture/browser-tab.md) — the unclaimed-web-view delegate and published load state.
- [Web view ownership](../architecture/webview-ownership.md) — why a background tab's web view is in no window.
- [Tab cell](../sidebar/tab-cell.md) — how the row draws and fades the progress bar.
- [Favicons](../features/favicons.md) — the icon pipeline that no longer waits for the load.
- [Error pages](../features/error-pages.md) — failures in unclaimed tabs, the same delegate gap.
- [WKWebView delegate order](./wkwebview-delegate-order.md) — the standalone-spike technique used here.
- [WebKit helper diagnostics](../playbooks/webkit-helper-diagnostics.md) — finding and sampling the right WebContent process.
- [Reading runtime logs](../playbooks/reading-runtime-logs.md) — `log stream` recipes for the `ProcessSuspension` category.

[^task-124]: Sidebar: fade out the progress bar on a background tab whose load has stalled
[^task-112]: Favicons: some sites never get their favicon, and their sidebar rows show a stray grey box
[^notes-stalls]: Hidden web view load stalls, root cause measurement
