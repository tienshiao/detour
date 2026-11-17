---
id: TASK-405
title: >-
  GPU process: automation endpoint gpu_process_stats tool and a scripted
  experiment (open, show, close N heavy tabs) to settle whether closed tabs free
  their IOSurfaces
status: Done
assignee:
  - '@claude'
created_date: '2026-11-17T19:47:00Z'
updated_date: '2026-11-17T21:17:00Z'
labels:
  - gpu
  - webkit
  - automation
dependencies:
  - TASK-404
priority: medium
type: task
ordinal: 486000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hand observation on 2026-11-17 (TASK-404) suggested that closing tabs and the exit of their WebContent processes left about 1,500 IOSurfaces in the GPU process. The answer decides whether TASK-104's show-budget sleep can help at all, and if they are not freed it is the reproduction for the WebKit bug in TASK-106. A deterministic run in an isolated profile, compared against the plain-WKWebView spike in docs/task-104, separates Detour from WebKit.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The automation endpoint exposes the GPU pid, total IOSurface regions and non-resident regions, with tests in the endpoint's suites
- [x] #2 A script in docs/harness runs baseline -> open N tabs of a fixture or real heavy site -> show each -> close all -> wait -> sample, and prints the deltas
- [x] #3 The result for Detour and for the plain WKWebView spike is recorded in this task and the wiki's GPU IOSurface page
- [x] #4 What the WebProcessPool instances in a normal session are (per profile, per extension context, per tab, …) and how many web processes that costs compared with one shared pool, recorded here with a recommendation
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Endpoint tool gpu_process_stats (counts, tab processes, footprint, process pools via SPI, per-tab detail) and trim_back_forward_cache, with AutomationGPUToolsTests.
2. docs/harness/task405-gpu-experiment.py: close mode (rounds) and bfcache mode; DETOUR_SHARED_PROCESS_POOL experiment switch for the pool comparison.
3. Plain WKWebView control: docs/task-405/spike-rounds.swift.
4. Record results in this task, the wiki and docs/task-405.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Scope added 2026-11-17 (user asked): also find out how many WebKit process pools Detour runs and whether that multiplies web processes. When the recycler fired on 2026-11-17 at 11:10:56, gpuProcessDidExit was logged by 13 distinct WebProcessPool instances. Detour never sets a processPool. Search shares one pool explicitly; its commit f9c1941 cut load start from ~41 ms to ~9 ms and removed a 284 ms registerUserInstalledFonts per pool, and Nook and Lilo share one too. If tabs spread across pools they can't share web processes, so there are more processes and more GPU IOSurface pools. Also a variable worth one run: WebKit's web process cache (_WKProcessPoolConfiguration.usesWebProcessCache, which Feather turns off), since a cached process outlives its closed tab.

Results 2026-11-17 (isolated Debug build; six real pages: two YouTube, GitHub, two apple.com, developer.apple.com; raw samples in docs/task-405).

Closing:
- One batch of 6 tabs, shown 3x, then closed freed 62-65% of what it added: 1,028 -> 357, 921 -> 347.
- About 350 regions stayed with no web view and every process exited.
- Four rounds in one session left 338 / 624 / 912 / 1,198 behind: about +290 per batch, roughly 48 per closed tab, mostly non-resident.

Plain WKWebView spike (fresh configuration per view, remove/addSubview switching, close = remove + release): left 527 / 675 / 810 / 946 behind. Same linear growth, about +140 per round. So WebKit strands surfaces of closed web views, Detour is not the cause, and this is the reproduction for TASK-106.

Back/forward cache: 6 tabs, each navigated 3 more times across sites and hidden, held 2,367 regions and 14 web processes. trim_back_forward_cache brought that to 1,521 and 7 within 30 s: 846 freed (36%), half the processes. Justifies TASK-408.

Process pools: every tab has its own WKProcessPool, because each WKWebViewConfiguration is fresh (6 tabs -> 7 pools). The 13 pools on 2026-11-17 were the open tabs. Web process cache and prewarming are off in all of them. With one shared pool (DETOUR_SHARED_PROCESS_POOL=1): 6 processes either way, 65% freed, remainder 386. Recommendation: no IOSurface or process-count reason to share a pool. The only possible gain is per-pool start-up cost (Search measured ~30 ms per load and a 284 ms font registration per pool), which belongs in a separate perf task if wanted. The switch stays as an experiment-only environment variable.

Implication: sleeping/closing tabs frees the larger part but leaves a permanent remainder per web process ever created, so the GPU recycler (incl. TASK-406's away tier) is the actual control.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added gpu_process_stats and trim_back_forward_cache to the automation endpoint (AutomationGPUToolsTests), the experiment script docs/harness/task405-gpu-experiment.py (close rounds and bfcache modes) and a plain WKWebView control (docs/task-405/spike-rounds.swift).

Findings:
- Closing tabs frees 62-65% of their IOSurfaces but strands about 48 per closed tab, cumulatively. A plain WKWebView app does the same, so it's WebKit.
- Trimming back/forward caches frees 36% and half the web processes.
- Each tab has its own process pool; sharing one changes nothing for IOSurfaces.

Tests: AutomationGPUToolsTests 7, plus AutomationStagingTests, AutomationToolsTests and GPUSurfaceTelemetryTests: 64/64. Runtime: five experiment runs and one spike run, numbers above.
<!-- SECTION:FINAL_SUMMARY:END -->
