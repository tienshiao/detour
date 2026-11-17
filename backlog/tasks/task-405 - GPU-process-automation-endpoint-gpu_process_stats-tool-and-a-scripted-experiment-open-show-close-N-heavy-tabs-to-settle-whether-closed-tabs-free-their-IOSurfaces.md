---
id: TASK-405
title: >-
  GPU process: automation endpoint gpu_process_stats tool and a scripted
  experiment (open, show, close N heavy tabs) to settle whether closed tabs free
  their IOSurfaces
status: To Do
assignee: []
created_date: '2026-11-17T19:47:00Z'
updated_date: '2026-11-17T20:36:00Z'
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
- [ ] #1 The automation endpoint exposes the GPU pid, total IOSurface regions and non-resident regions, with tests in the endpoint's suites
- [ ] #2 A script in docs/harness runs baseline -> open N tabs of a fixture or real heavy site -> show each -> close all -> wait -> sample, and prints the deltas
- [ ] #3 The result for Detour and for the plain WKWebView spike is recorded in this task and the wiki's GPU IOSurface page
- [ ] #4 What the WebProcessPool instances in a normal session are (per profile, per extension context, per tab, …) and how many web processes that costs compared with one shared pool, recorded here with a recommendation
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Scope added 2026-11-17 (user asked): also find out how many WebKit process pools Detour runs and whether that multiplies web processes. When the recycler fired on 2026-11-17 at 11:10:56, gpuProcessDidExit was logged by 13 distinct WebProcessPool instances. Detour never sets a processPool. Search shares one pool explicitly; its commit f9c1941 cut load start from ~41 ms to ~9 ms and removed a 284 ms registerUserInstalledFonts per pool, and Nook and Lilo share one too. If tabs spread across pools they can't share web processes, so there are more processes and more GPU IOSurface pools. Also a variable worth one run: WebKit's web process cache (_WKProcessPoolConfiguration.usesWebProcessCache, which Feather turns off), since a cached process outlives its closed tab.
<!-- SECTION:NOTES:END -->
