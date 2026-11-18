---
id: TASK-106
title: >-
  File a WebKit bug: IOSurfacePool caps cached surfaces by bytes only, so purged
  surfaces exhaust the GPU process's 16384-IOSurface limit
status: To Do
assignee: []
created_date: 2026-09-22 03:10
updated_date: '2026-11-18T08:42:00Z'
labels:
  - webkit
dependencies: []
priority: low
ordinal: 106000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-104 (evidence in docs/task-104: Detour harness CSVs, standalone plain-WKWebView spike main.swift reproducing the growth, prod vmmap histogram). Report against WebCore/platform/graphics/cg/IOSurfacePool.cpp: defaultMaximumBytesCached is 256 MB on macOS per GPUConnectionToWebProcess pool, purged (volatile, 0-resident) surfaces stay cached at full byte weight, nothing caps count or age, and only memory pressure discards — with N web processes the GPU process hits the kernel's per-process IOSurface limit, after which every allocation fails (WebGL context lost, canvases dead, YouTube bot detection trips). Ask for a count cap and/or dropping purged surfaces on the collection timer.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Bug filed at bugs.webkit.org with the spike as a standalone reproduction and the bug number recorded in TASK-104
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-17 (TASK-405): a standalone reproduction exists, docs/task-405/spike-rounds.swift (plain WKWebView; fresh configuration per view; open 6 real pages, switch with removeFromSuperview/addSubview, close by remove + release, 4 rounds). The GPU process kept 527 / 675 / 810 / 946 IOSurface regions after each round with every view closed: about 140 stranded per round, growing without bound. Detour's equivalent run strands about 290 per round of 6 tabs (docs/task-405/run4-rounds.json).

2026-11-17 evening, Safari repro (strongest evidence for the report): Safari 27.0 runs its own staged WebKit 21625.1.29.18.28 (/System/Volumes/Preboot/Cryptexes/App/System/Library/StagedFrameworks/Safari/WebKit.framework, newer than the system's 21624.5.1.11.3). Its browsing GPU process (the one under that path) went from 71 to 4,062 IOSurface regions after about 11 YouTube tabs were cmd-clicked open, then watched and closed one at a time. Every removeGPUConnectionToWebProcess was logged; 4,020 remained ten minutes later. vmmap: 2,612 PURGE=V, 1,249 PURGE=E, 201 PURGE=N; 1,884 of them 16K. Detour (system WebKit) in the same run: 9 tabs, 1,742 to 5,820, ~90% PURGE=E, 2,705 of them 16K. So the leak is about 360 to 450 surfaces per closed YouTube tab, against ~48 for the TASK-405 fixture pages, and the newer WebKit has it too. Report steps: Safari, open and close YouTube tabs, count the GPU process's IOSurfaces with vmmap --summary.
<!-- SECTION:NOTES:END -->
