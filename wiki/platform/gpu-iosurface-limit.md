---
type: Investigation
title: GPU process IOSurface limit
description: After days of uptime WebKit's GPU process reaches the kernel's 16,384-IOSurface limit, WebGL and canvas die in every page and YouTube stops playing; how it was diagnosed, the show-budget sleep rule and the GPU process recycler that contain it.
tags: [webkit, gpu, performance, sleeping, media]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:30:18Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-104
    resource: backlog:TASK-104
    title: GPU process leaks IOSurfaces until the 16384 per-process limit
  - id: task-105
    resource: backlog:TASK-105
    title: GPU-process recycle valve
  - id: task-106
    resource: backlog:TASK-106
    title: "File a WebKit bug: IOSurfacePool caps cached surfaces by bytes only"
  - id: task-109
    resource: backlog:TASK-109
    title: Does the GPU process ever get the memory-pressure pool flush
  - id: notes-gpu
    resource: "Agent session notes, 2026-09-21 and 2026-09-28 (not in the repository)"
    title: GPU IOSurface limit diagnosis and measurement recipes
  - id: recycler
    resource: ../../Detour/Browser/GPUProcessRecycler.swift
    title: GPUProcessRecycler.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (sleepStaleTabs, sleepShowBudget)
  - id: task-104-data
    resource: ../../docs/task-104
    title: Harness patch, sampler scripts, standalone spike and CSV results
  - id: iosurfacepool
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/cg/IOSurfacePool.cpp
    title: WebKit IOSurfacePool.cpp
---

The kernel caps a process at 16,384 IOSurfaces. WebKit's GPU process, which
is shared by every web view in the app, slowly accumulates surfaces that are
purged but never destroyed, and after anything from most of a day to a few
days of uptime it reaches the cap. The failure then shows up three layers away, as what looks like a
DNS or network problem on video sites. **For any "works again after a
restart" breakage of WebGL, canvas or video, count the GPU process's
IOSurfaces first.**

# Symptom

After long uptime (17 hours in the first report, 2.5 days in the
second):[^task-104][^task-105]

- YouTube shows "An error occurred. Please try again later."
- Console: `A server with the specified hostname could not be found
  (videoplayback)`, `403` on `videoplayback`, and `WebGL: context lost`.
- An extension's content script fails to fetch its own `webkit-extension://`
  resource.
- Reloading does not help. Toggling content blocking does not help.
  Restarting the app does, because the GPU process restarts.

# Root cause

Two links in the chain.

**1. The GPU process runs out of IOSurfaces.** `com.apple.WebKit.GPU` held
about 16.7k IOSurface regions against the limit of 16,384. From then on every
allocation fails with `IOSurface creation failed: e00002be … likely per
client IOSurface limit of 16384 reached` (subsystem `com.apple.WebKit`,
category `Layers`), thousands of times an hour, and WebGL contexts are lost
in every page.[^task-104]

**2. YouTube reads the broken canvas as a bot.** Its attestation fingerprints
WebGL and canvas. When that fails it serves a deliberately unusable player
response: `videoplayback` URLs whose `sig` equals `lsig`, whose `expire`
equals `mt` (decades in the future), an `ip=` parameter that is not the
client's address, and CDN hostnames that genuinely do not resolve. That is
where the hostname error and the 403 come from.[^task-104]

# Evidence

## The stranded surfaces

`vmmap` of the GPU process at failure: 16,682 IOSurface regions, 15,900 of
them `PURGE=E` (volatile, already emptied by the kernel, zero resident) and
only 781 `PURGE=N`. Most are small: 7,181 of 16K, 1,371 of 48K, 920 of 32K,
857 of 64K, then 512x512 tiles. The count grows with time, not with memory
use. The session had 16 tabs and 23 WebContent processes.[^task-104]

## What grows the count

Reproduced in 8 minutes with a harness driving 4 real pages through 2 x 150
tab switches, sampling the GPU process every 5 s
([run2.csv](../../docs/task-104/run2.csv)):[^task-104]

| Phase | GPU IOSurfaces |
|---|---|
| idle after load | 670 |
| after 150 switches | 1,647 |
| after 45 s settle | 1,708 |
| after 150 more switches | 1,997 |
| after settle | 1,997 |
| after closing 3 of 4 tabs | 1,495 |

- **Only hidden-to-visible transitions grow it**: about 2–4 surfaces per
  switch, with the purged count rising in step. Idle and settle phases are
  flat, even with animating pages.
- **It is WebKit, not Detour's hosting.** A plain-`WKWebView` binary cycling
  the same pages with `removeFromSuperview`/`addSubview`
  ([main.swift](../../docs/task-104/main.swift)) grows the same way: 533 →
  1,021 → 1,343 → 1,458.[^task-104]
- **Window occlusion counts too.** Ordering one window out and back 90 times
  with a single visible page: 433 → 695 (+2.9 per cycle), then +0.8 per cycle
  for the next 90. So switching apps churns the *visible* tab as well.[^task-104]
- **Growth is front-loaded per page** and is sustained by pages whose layer
  sizes keep changing (single-page apps that navigate). A video watch page
  churned about 25 surfaces per show against about 3 for a static
  page.[^task-104]
- **Freeing a web process frees its surfaces.** Sleeping three hidden tabs
  dropped the count 1,649 → 1,317 within 5 s.[^task-104]

## Mechanism, and where it is incomplete

From WebKit's source: the GPU process keeps one `WebCore::IOSurfacePool` per
WebContent connection. Released layer buffers go into the pool; its
collection timer only marks idle surfaces volatile, after which the kernel
purges them. The pool evicts by **bytes** only (`defaultMaximumBytesCached`,
256 MB on macOS) and a purged surface still counts at full byte weight.
Nothing caps the surface **count**. A FIXME in `evict()` asks whether
purgeable surfaces should count less against the cap.[^task-104]

That explains the shape but not the whole count. WebKit's low-memory handler
discards every pool, yet posting the simulated memory-pressure notification
(`notifyutil -p org.WebKit.lowMemory`) to a GPU process at 16,681 surfaces
only brought it to 14,230; the log confirmed
`GPUProcess::lowMemoryHandler: critical=1` ran. So most of the stranded
surfaces are buffers still referenced on behalf of WebContent processes
(volatile backing stores of hidden pages), not idle pool entries.[^task-109]
The comments in [TabStore.swift](../../Detour/Browser/TabStore.swift) and
`BrowserTab.showsSinceWake` still describe the pool-only model.

## Ruled out

- DNS, proxy and VPN causes, and network changes during the session. The
  failing hostnames do not exist; they come from the poisoned
  response.[^task-104]
- Content blocking.[^task-104]
- Detour's view hosting (control spike above).
- A memory-pressure warning as a cheap release valve (frees about
  15%).[^task-109]
- A synthetic fixture: 400 `will-change: transform` layers repainted every
  200 ms held the GPU process at 30–70 surfaces. Small synthetic layers do
  not land in the GPU process; use real pages.[^task-104]

# Fix

Nothing in the app can stop WebKit stranding surfaces. Two mitigations bound
it, and an upstream report is tracked in TASK-106.

## 1. Show budget — sleep the tabs that are shown most

`BrowserTab.showsSinceWake` counts how many times a window has hosted the
tab's web view since that web view was created. `noteShown()` increments it
when `BrowserWindowController` actually attaches a pane (`claimSingleWebView`,
`claimSplitWebViews` — not on a refresh of an already-attached pane) and when
the window's occlusion state goes from not-visible to visible. `wake()`
resets it.

`TabStore.sleepStaleTabs(now:)` then has two rules:

| Rule | Applies to | Sleeps when |
|---|---|---|
| Idle | normal, unpinned tabs | out of sight ≥ the profile's `sleepThreshold` |
| Show budget | any tab, including pinned entries' and favourites' backing tabs | `showsSinceWake` ≥ `sleepShowBudget` (50) **and** out of sight ≥ `sleepShowBudgetGrace` (15 min) |

Shared preconditions: not playing audio, container not parented in any
window, `lastDeselectedAt` set. A profile set to never sleep is honoured by
both. A split sleeps only when every partner also qualifies. A pinned entry
or favourite stays live with its tab asleep, so it wakes into its saved
interaction state.

The budget only ever *shortens* a threshold. It was a stated requirement that
a tab must never sleep right after being used, which is why spending the
budget does not sleep the tab by itself.[^task-104]

Harness overrides, read once at launch: `DETOUR_SLEEP_SHOW_BUDGET`,
`DETOUR_SLEEP_SHOW_BUDGET_GRACE_SECONDS`. See
[sleeping and archiving](../tabs/sleeping-and-archiving.md) for the rest of
the sleep policy.

This slows the growth but does not cap it: the visible tab's occlusion churn
is out of its reach, and the limit was hit again after 2.5 days with the
budget in place.[^task-105]

## 2. GPU process recycler — the backstop

Only the GPU process exiting frees everything. WebKit recovers from that by
design. A `SIGKILL` of a GPU process at 14.2k surfaces was logged as
`gpuProcessExited reason=Crash`, every WebContent process reconnected, none
was terminated, and the new GPU process started at 91
surfaces.[^task-105]

[GPUProcessRecycler.swift](../../Detour/Browser/GPUProcessRecycler.swift)
does this before the limit is reached. `AppDelegate` starts
`GPUProcessRecycler.shared` after session restore.

Every 120 s (`DETOUR_GPU_RECYCLE_CHECK_SECONDS`) it:

1. Gets the GPU pid from the SPI `-[WKWebView _gpuProcessIdentifier]` on any
   live tab web view. The pid tracks relaunches.
2. Counts the process's IOSurfaces off the main thread
   (`ioSurfaceCount(pid:)`): a `proc_pidinfo(PROC_PIDREGIONINFO)` walk
   counting regions whose `pri_user_tag` is 88 (`VM_MEMORY_IOSURFACE`). It
   needs no privileges for a same-user process, matches `vmmap --summary`,
   and takes about 54 ms at 32k regions.[^task-105]
3. Asks the pure `GPUProcessRecyclePolicy.decide`.
4. On `.recycle`, re-resolves the pid, requires it to be unchanged and named
   `com.apple.WebKit.GPU`, then sends `SIGKILL`. The name alone is not
   enough: it also matches another app's GPU process on a reused pid.

| Surfaces | Decision |
|---|---|
| < 12,000 (`softLimit`) | keep |
| ≥ 12,000 | recycle once the app has been inactive ≥ 5 min (`inactiveGrace`) |
| ≥ 15,000 (`hardLimit`) | also recycle as soon as the app is inactive, or while it is active once there has been no keyboard or pointer input for 60 s (`userIdleGrace`) |
| any | never while a tab plays audio or captures camera or microphone; never within 1 h of the last recycle (`minimumInterval`) |

Why each gate exists:

- A recycle interrupts playing media and loses WebGL contexts, so it waits
  until nobody is watching.
- Camera and microphone capture run in the GPU process.
- WebKit terminates every WebContent process when its GPU process exits
  repeatedly in a short window, hence the one-hour floor.[^task-105]
- A direct count replaced the planned WebGL canary: a canary only fires after
  pages have already broken.[^task-105]

Overrides for harness runs: `DETOUR_GPU_RECYCLE_SOFT_LIMIT`,
`_HARD_LIMIT`, `_INACTIVE_GRACE_SECONDS`, `_USER_IDLE_SECONDS`,
`_MIN_INTERVAL_SECONDS`. A non-positive or unparseable value is ignored
rather than disabling a guard.

# How to measure

These need to run outside a sandboxed shell.

```sh
# total IOSurface regions (last column)
vmmap --summary <gpu pid> | grep '^IOSurface'
# purged-but-alive surfaces
vmmap <gpu pid> | grep '^IOSurface' | grep -c PURGE=E
# allocation failures
/usr/bin/log show --predicate 'processIdentifier == <gpu pid> AND eventMessage CONTAINS "per client IOSurface limit"'
```

- `vmmap` on a WebContent process prints nothing useful for this.[^notes-gpu]
- The recycler logs under subsystem `com.detourbrowser.mac`, category
  `gpu-recycle`. Only the recycle itself is logged at notice level; the
  "gate closed" line is info, and info/debug lines are not persisted for
  `log show`.[^notes-gpu]
- An unfocused app's timer still fired on schedule in a 10 s harness
  run.[^task-105]
- The harness and samplers are in [docs/task-104](../../docs/task-104)
  (`task104-harness.patch`, `run_harness.sh`, `run_harness_sleep.sh`,
  `run_spike.sh`). The scripts contain absolute paths from the session that
  wrote them and need editing before reuse.

# Tests

- [GPUProcessRecyclePolicyTests](../../DetourTests/GPUProcessRecyclePolicyTests.swift):
  the gate, the rate limit, environment parsing, region counting on the test
  process itself.
- [SleepShowBudgetTests](../../DetourTests/SleepShowBudgetTests.swift): the
  budget rule for normal, pinned and favourite tabs, the grace, audio and
  split partners, reset on wake.

# Open questions

- What exactly holds the bulk of the purged surfaces alive, given that the
  pool flush does not release them.[^task-109]
- Whether WebKit ever suspends the GPU process on macOS, and why Safari on
  the same WebKit is not known to hit this (fewer live web processes is one
  guess; unverified).[^task-109]
- Screen-share capture has no public state on `WKWebView`, so the media gate
  does not cover it.[^task-105]
- Limits and the per-process cap were measured on one macOS release.

# Related

- [Sleeping and archiving](../tabs/sleeping-and-archiving.md) — the sleep policy the show budget extends.
- [BrowserTab](../architecture/browser-tab.md) — `showsSinceWake`, `noteShown`, `wake`.
- [Web view ownership](../architecture/webview-ownership.md) — where panes are attached, and so where shows are counted.
- [Media and picture-in-picture](./media-and-pip.md) — the audio and capture state the recycler's gate reads.
- [WebKit helper diagnostics](../playbooks/webkit-helper-diagnostics.md) — finding WebKit's helper processes.
- [Reading runtime logs](../playbooks/reading-runtime-logs.md) — `log show` recipes and their traps.
- [Debug harness](../playbooks/debug-harness.md) — how env-gated harness patches like the one in `docs/task-104` are applied.
- [WebKit source lookup](./webkit-source-lookup.md) — reading `IOSurfacePool.cpp` and the GPU process sources.

[^task-104]: GPU process leaks IOSurfaces until the 16384 per-process limit
[^task-105]: GPU-process recycle valve
[^task-109]: Does the GPU process ever get the memory-pressure pool flush
[^notes-gpu]: GPU IOSurface limit diagnosis and measurement recipes
