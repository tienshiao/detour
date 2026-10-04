---
type: Concept
title: Sleeping and archiving
description: The two rules that put a tab to sleep, the rule that archives one, everything that keeps a tab awake, and how a wake that fails keeps the restored session instead of showing an error page.
tags: [tabs, sleep, archive, memory, policy]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:43:31Z }
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (sleepStaleTabs, archiveStaleTabs)
  - id: browsertab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift (sleep, wake, loadIfStalled)
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift (stampDeselected, noteShown call sites)
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (SleepThreshold, ArchiveThreshold)
  - id: budget-tests
    resource: ../../DetourTests/SleepShowBudgetTests.swift
    title: SleepShowBudgetTests.swift
  - id: wake-tests
    resource: ../../DetourTests/BrowserTabWakeTests.swift
    title: BrowserTabWakeTests.swift
  - id: task-104
    resource: backlog:TASK-104
    title: GPU process leaks IOSurfaces until the 16384 per-process limit
  - id: task-45
    resource: backlog:TASK-45
    title: A failed wake of a restored ordinary tab replaces its restored session with an error page
  - id: task-115
    resource: backlog:TASK-115
    title: Sidebar Archive Tab / Archive Tabs Below record the tab as archived
---

# Summary

A sleeping tab keeps its `BrowserTab` (title, URL, favicon, list position) and
its serialized `interactionState`, but has no `WKWebView` and so no web content
process. An archived tab is a *closed* tab whose
[closed-tab record](./closed-tabs-and-archive.md) carries `archivedAt`. One
timer, `TabStore.startArchiveTimer`, fires every 300 s and runs
`sleepStaleTabs()` then `archiveStaleTabs()`. Both take an injectable `now`, so
tests drive them with a clock.

# Rules

## The clock: `lastDeselectedAt`

Both sweeps measure from `BrowserTab.lastDeselectedAt`: the moment the tab last
left a window's screen. **nil means "selected somewhere" and exempts the tab
from both sweeps.**

- `stampDeselected` sets it in `selectTab` (for the outgoing tab), in
  `setActiveSpace` and in `windowWillClose`. The last two exist because
  `selectTab` cannot stamp a tab once `activeSpaceID` has moved; before they
  were added, a pinned tab left behind by a space switch never slept.[^task-104]
- **Every pane of a split is stamped.** The unfocused pane has no selection of
  its own and would otherwise never go stale.
- `selectTab` clears it for every member of the selected group.
- It is persisted (`tab.lastDeselectedAt`). A restored tab with no saved value
  gets the restore time.
- Two windows on one space share the single timestamp. The window that
  deselects stamps it while the other may still be showing the tab, which is
  why the sleep sweep also checks the view hierarchy (below).

## Sleeping: two rules

`sleepStaleTabs` sleeps a tab when either rule says so.

| Rule | Applies to | Condition |
|---|---|---|
| Idle | normal tabs only | off screen longer than the profile's `sleepThreshold` (15 min, 30 min, **1 h default**, 2 h, never) |
| Show budget | normal tabs, pinned entries' backing tabs, favourites' backing tabs | `showsSinceWake >= sleepShowBudget` (50) and off screen longer than `sleepShowBudgetGrace` (15 min) |

Why the second rule exists: every hidden-to-visible transition of a web view
strands a few IOSurfaces in WebKit's GPU process, and only the tab's web
content process going away frees them. The tabs shown most often are exactly
the ones the idle rule never reaches (pinned and favourite tabs, which it skips
outright). See [GPU IOSurface limit](../platform/gpu-iosurface-limit.md). The
rule only ever *shortens* a threshold; it cannot sleep a tab right after use.

`showsSinceWake` is incremented by `BrowserTab.noteShown()`: when a window
actually attaches the tab's container (not on the refresh branch of a claim,
which runs on every `windowDidBecomeKey`), and when a window carrying it comes
back from being fully occluded. `wake()` resets it. It is never persisted.

`DETOUR_SLEEP_SHOW_BUDGET` and `DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS`
override the two constants, read once at launch; a non-positive or unparseable
value is ignored rather than disabling the rule.

In a harness run with the budget at 20 and the grace at 30 s, the sweep slept
the three hidden tabs and the GPU process's IOSurface count fell from 1649 to
1317 within 5 s.[^task-104]

## What keeps a tab awake

A tab is not slept by the sweep when any of these holds:

- it is playing audio (`isPlayingAudio`);
- `lastDeselectedAt == nil` (selected in some window);
- its `webViewContainer` has a superview, i.e. some window is hosting it right
  now. "Has a superview" means "hosted somewhere" throughout the window code,
  which is why tearing down a split view removes each pane from it;
- it is one member of a split whose partner is not also asleep or eligible. A
  split renders both panes at once, so sleeping one blanks a visible pane. For a
  [pinned split](./split-tabs.md) the partner is resolved through the entries,
  not through `splitGroupID` on the tabs;
- its profile's `sleepThreshold` is `.never`. Both rules honour this.

Pinned and favourite backing tabs that sleep stay **live but asleep**: the
entry or favourite keeps its `tab`, so selecting it wakes into the cached
interaction state. That is different from a *dormant* tile, which has no tab at
all and loads its home URL from scratch.

## What sleeping does

`BrowserTab.sleep(force:)` parks the Peek (`parkPeek`), archives
`webView.interactionState` into `cachedInteractionState`, releases the web view
and its container, and sets `isSleeping`. It returns without doing anything
while the tab plays audio unless `force` is set.

`force: true` pauses media first and is used where the web view *must* go
because the configuration it was built from is no longer right: a space moved
to another profile (`updateSpace`), a tab carried across profiles
(`carry`). An extension context reload uses `retarget(to:)` instead, which also
discards the interaction state, because restoring it would put the tab back on
the dead origin.

Sleeping is not a close for the extension contexts: the tab stays registered
and the wake re-reports its new web view. A parked Peek *is* closed for them
([Peek](./peek.md)).

## Waking

`wake()` builds a web view from the configuration of the tab's *current*
`spaceID` (or, for an extension page, of the context serving its origin),
restores the cached interaction state or loads `url`, and resets the show
budget. Callers: `selectTab` (every member of the selected split),
`claimWebView` (`wakeIfNeeded`), `load`, `reload`.

`wakeIfNeeded` guards on `webView == nil`, not on `isSleeping`: a tab that lost
its web view without being flagged asleep is rebuilt too instead of hosting as
an empty pane.

## A wake that fails keeps the session

A restored tab woken offline used to get an error page over its just-restored
back/forward list, and its saved title was replaced by the raw URL.[^task-45]
Two flags on `BrowserTab` now separate the concerns that `lastAttemptedURL`
had been made to carry:

- `awaitingFirstURL`: set by `wake()` until the fresh web view reports a real
  URL. While set, the URL observer ignores the web view's initial nil, so
  `tab.url` survives the wake. Tabs created sleeping and extension pages
  waiting for their context depend on this.
- `restoringSession`: set when `wake()` hands the web view cached interaction
  state; cleared by a commit, a user `load()`/`reload()`, or releasing the web
  view. While set, a provisional failure shows no error page, the persisted
  title outranks the raw URL, and WebKit's fall-back to `about:blank` reaches
  neither `tab.url` nor the retry target.

`claimWebView` ends with `loadIfStalled()` for each pane: a claimed web view
with no URL that is not loading gets its tab's URL loaded. This is deliberately
not `load(_:)`. It is nobody's request, so it does not set `lastAttemptedURL`
or `navigationPending`, and a failure leaves the restored session in place.
`reload()` after that *is* a request, and a failing retry earns the
[error page](../features/error-pages.md).

## Archiving

`archiveStaleTabs` closes normal tabs whose `lastDeselectedAt` is older than the
profile's `archiveThreshold` (**12 h default**, 24 h, 7 days, 30 days, never),
by calling `closeTab(id:in:archivedAt: now, registersUndo: false)`.

- Only `space.tabs` of non-incognito spaces. Pinned entries and favourites are
  never archived.
- A split member is archived only when the whole group is stale.
- The last remaining tab of a space is never archived: if every tab is stale,
  the last one in list order stays.
- The sweep registers no undo (it must not fill the undo stack). The sidebar's
  "Archive Tab" and "Archive Tabs Below" go through the same `closeTab` with
  `archivedAt` set and *do* register undo, named "Archive Tab"; a redo keeps the
  stamp.[^task-115]
- Unlike the sleep sweep, the archive sweep checks neither audio playback nor
  whether a window is hosting the tab. It relies on `lastDeselectedAt` alone.

# Where it lives

- [TabStore.swift](../../Detour/Browser/TabStore.swift): `startArchiveTimer`,
  `sleepStaleTabs(now:)`, `archiveStaleTabs(now:)`, `sleepShowBudget`,
  `sleepShowBudgetGrace`.
- [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift): `sleep(force:)`,
  `wake(supersededByLoad:)`, `retarget(to:)`, `parkPeek(force:)`, `noteShown()`,
  `loadIfStalled()`.
- [BrowserWindowController.swift](../../Detour/Browser/Window/BrowserWindowController.swift):
  `stampDeselected`, the occlusion handler, the `noteShown()` call sites in the
  two claim functions.
- [Profile.swift](../../Detour/Browser/Profile.swift): `SleepThreshold`,
  `ArchiveThreshold`.

# Tests

`SleepShowBudgetTests` (both rules, the audio, selected, hosted and split
exemptions, the environment overrides), `BrowserTabWakeTests` (failed wake
keeps session, title and favicon; reload after a failed wake; a commit ends the
protection), `TabStoreTests` ("Archive vs close records"), `SplitTabTests`.

# Related

- [Tab lifecycle](./tab-lifecycle.md): creation, close and persistence around these sweeps.
- [Closed tabs and the archive](./closed-tabs-and-archive.md): what an archived tab becomes.
- [GPU IOSurface limit](../platform/gpu-iosurface-limit.md): the investigation behind the show budget.
- [Hidden web view load stalls](../platform/hidden-webview-load-stalls.md): the other cost of an unshown web view.
- [BrowserTab](../architecture/browser-tab.md): the sleep and wake mechanics in detail.
- [Extension pages](../extensions/extension-pages.md): `retarget(to:)` and pages waiting for a context.

[^task-104]: GPU process leaks IOSurfaces until the 16384 per-process limit
[^task-45]: A failed wake of a restored ordinary tab replaces its restored session with an error page
[^task-115]: Sidebar Archive Tab / Archive Tabs Below record the tab as archived
