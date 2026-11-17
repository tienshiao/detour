---
type: Investigation
title: How other WebKit browsers manage tabs and web views
description: A 2026-11-17 survey of six open-source macOS WebKit browsers (Search, Zigzag, Nook, Lilo, Zephium, Ora) — when they create, hide, suspend and discard web views, how they react to memory pressure, how they share process pools — and how Detour compares; none of them handles the GPU process's IOSurface limit.
tags: [webkit, sleeping, memory, gpu, research]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-17T20:30:00Z }
stale_after: 2027-05-01T00:00:00Z
sources:
  - id: byearc
    resource: https://byearc.com/
    title: byearc.com list of Arc-style browsers (source of the repository links)
  - id: survey
    resource: "Agent code reading of the six repositories at their HEAD on 2026-11-17 (shallow clones, not in this repository)"
    title: Tab lifecycle survey
  - id: task-404
    resource: backlog:TASK-404
    title: Persist the IOSurface growth curve and per-event deltas
  - id: task-405
    resource: backlog:TASK-405
    title: gpu_process_stats tool and the closed-tab experiment
  - id: task-407
    resource: backlog:TASK-407
    title: Sleep tabs on memory pressure
  - id: task-408
    resource: backlog:TASK-408
    title: Trim the back/forward cache of tabs hidden for a while
---

# Why this survey exists

After the GPU process reached its IOSurface limit in 20.5 hours on
2026-11-17 (TASK-403), the question was whether other WebKit browsers have the
same problem and what they do about it. byearc.com lists 22 Arc-style WebKit
browsers with public repositories. A code search across the 18 that hold source
found no IOSurface counting, GPU process recycling or WebGL context-loss
handling in any of them. `_gpuProcessIdentifier` appears only in diagnostics
panels and benchmarks (Lilo, Feather, Zephium, Search, Nook, Zigzag). Six of the
larger ones were then read in depth.[^survey]

Every claim below is from code reading at each repository's HEAD on
2026-11-17. Nothing was run.

# Findings

| | Default idle discard | Memory pressure | Live-view cap | Lighter tier | Restore |
|---|---|---|---|---|---|
| **Detour** | 1 h (profile setting), plus the TASK-104 show budget | since TASK-407: warning → 5 min for 2 min (normal tabs); critical → every hidden tab incl. pinned and favourites; at most once per 30 s | none | none | lazy |
| Search | 30 min (on by default) | `DispatchSource`: warning → 5 min, critical → 0 | none | — | lazy |
| Zigzag | 1 h; 15 min when more than 20 tabs are awake | warning or critical → 5 min for 2 min; favourites only on critical | soft (20) | sleeps background tabs whose process uses > 0.7 core for 3 min | lazy |
| Nook | 30 min (Standard) | clears every hidden tab's back/forward cache, then unloads 1 tab (warning) or up to half (critical), at most once per 30 s | 8, in Power Saving only | back/forward cache cleared after 5 min hidden | warms the current space one tab at a time |
| Lilo | off (Balanced); 10 min (Aggressive) | active space capped at 6, then 1 | 24/16/10 by RAM, total WebContent footprint ≤ 40% of RAM | freezes pages after 5 min (`_suspendPage:`) | lazy |
| Zephium | 30 min | caps to 2/12, critical 0/4, heaviest first | 24 soft, 64 hard; pages > 256 MB discarded after 3 min | `inactiveSchedulingPolicy = .suspend` after 5 min; hidden views moved to an off-screen window after 10 s | lazy |
| Ora | 1 h | none | none | — | lazy |

- **Tab switch.** All six take the outgoing web view out of the window, as
  Detour does. Zephium first hides it and later moves it into a never-shown
  window. So every one of them pays WebKit's hidden→visible IOSurface cost on
  each switch (see [GPU process IOSurface limit](gpu-iosurface-limit.md)).
- **One tab in two windows.** Nook, Zigzag and Lilo keep one live view and show
  a "shown in another window / Show Here" placeholder elsewhere. Search gives
  each window its own tab, and its own view for every pin. Zephium has one
  window. Ora builds an uncoordinated view per window. Detour instead shows a
  snapshot and hands the view to the focused window. The hand-over adds show
  events that a placeholder design would not.
- **Process pools.** Search, Nook and Lilo share one `WKProcessPool`
  explicitly. Search's commit f9c1941 measured a 284 ms
  `registerUserInstalledFonts` per pool and load start falling from about 41 ms
  to 9 ms once shared. Nook and Lilo also use `_WKProcessPoolConfiguration`
  (prewarming; Nook `suspendsWebProcessesAggressivelyOnMemoryPressure`).
  Feather turns off WebKit's web process cache and prewarming. Detour sets no
  pool. When its GPU process was recycled on 2026-11-17, 13 distinct
  `WebProcessPool` instances logged `gpuProcessDidExit`. They turned out to be one pool per open
  tab; sharing one changed nothing measurable for IOSurfaces or process count
  (TASK-405).[^task-405]
- **Back/forward cache.** Clearing it (`_clearBackForwardCache`) keeps the
  back/forward list: Back still works, but a trimmed entry loads again instead
  of resuming frozen. Nook's commit a6f5104 measured 3.5 GB held by six tabs'
  caches, and the total going from 5.7 GB to 2.5 GB after trimming. Detour
  leaves WebKit's defaults (TASK-408).[^task-408]
- **Crash handling.** Search, Zigzag, Nook, Lilo and Zephium reload a visible
  tab whose content process died, mark hidden ones to reload when shown, and
  stop after two to four deaths within 30 to 60 s. Ora has no handler. Lilo
  also kills a page hung off screen for 30 s, because "WebKit routed the site's
  next pages to it, so they never loaded" (its commit cb5a7de2). Detour's
  equivalent is [Unresponsive web process](unresponsive-web-process.md).

# How Detour compares

- **Ahead:** it is the only one that has diagnosed and contained the
  IOSurface limit (show budget, recycler, abandoned-process reaper,
  `gpu-surfaces` telemetry).[^task-404] Its multi-window snapshot is also more
  polished than the placeholders.
- **Behind:** until TASK-407 it was one of two (with Ora) with no
  memory-pressure reaction; it now follows Zigzag's shape, with pinned and
  favourite tabs reached on critical. It ties Ora and Zigzag for the longest default idle threshold. It has no live
  view budget and no suspend tier. Each live web process gets its own IOSurface
  pool in the GPU process, so these memory measures also slow the limit.
  Follow-ups: TASK-407 (memory pressure)[^task-407], TASK-408 (back/forward
  cache), TASK-405 (process pools).

# Related

- [GPU process IOSurface limit](gpu-iosurface-limit.md) — the problem this survey was for.
- [Sleeping and archiving](../tabs/sleeping-and-archiving.md) — Detour's own sleep rules.
- [Web view ownership](../architecture/webview-ownership.md) — Detour's one-owner, snapshot-elsewhere design.

[^survey]: Tab lifecycle survey
[^task-404]: Persist the IOSurface growth curve and per-event deltas
[^task-405]: gpu_process_stats tool and the closed-tab experiment
[^task-407]: Sleep tabs on memory pressure
[^task-408]: Trim the back/forward cache of tabs hidden for a while
