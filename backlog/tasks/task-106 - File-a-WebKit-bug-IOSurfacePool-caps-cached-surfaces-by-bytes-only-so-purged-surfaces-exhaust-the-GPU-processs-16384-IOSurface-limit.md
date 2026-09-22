---
id: TASK-106
title: >-
  File a WebKit bug: IOSurfacePool caps cached surfaces by bytes only, so purged
  surfaces exhaust the GPU process's 16384-IOSurface limit
status: To Do
assignee: []
created_date: '2026-09-22 03:10'
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
