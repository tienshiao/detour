---
id: TASK-109
title: >-
  GPU process: find out whether Detour's GPU process ever gets the
  memory-pressure/suspension pool flush (and how Safari avoids TASK-104)
status: To Do
assignee: []
created_date: '2026-09-23 06:49'
labels:
  - webkit
  - performance
dependencies: []
priority: low
ordinal: 109000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-104, feeds TASK-105. Same system WebKit as Safari, so any Safari difference is in what empties the pool, not the pool. WebKit main: every lowMemoryHandler call, critical or not (GPUProcess::lowMemoryHandler -> GPUConnectionToWebProcess::lowMemoryHandler -> RemoteSharedResourceCache::lowMemoryHandler -> IOSurfacePool::discardAllSurfaces), and GPUProcess::prepareToSuspend (lowMemoryHandler Critical::Yes) discard every connection's pool. Observed Sep 22 2026: three GPU processes logged 6 non-critical lowMemoryHandler calls each in 3h (one, pid 7284, gone — possibly the previous Detour); a 3-minute-old Detour GPU process held 1132 IOSurfaces vs 273/338 for two 7-day-old GPU processes of other WebKit apps. Unknown whether WebKit suspends the GPU process on macOS. Safari may also see it less because it kills background tab processes over the inactive memory limit (fewer live pools) — or not avoid it at all (evict() FIXME; unverified user reports).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Over a long Detour session, count lowMemoryHandler / prepareToSuspend events for Detour's own GPU pid (/usr/bin/log show filtered by processIdentifier, sandbox off) and compare with other apps' GPU processes
- [ ] #2 Optional: run the docs/task-104 switching pattern against Safari via AppleScript (set current tab of window 1) and sample its GPU process with vmmap
- [ ] #3 Conclusion recorded; if Detour misses flushes, evaluate a memory-pressure warning as a cheaper TASK-105 valve than killing the GPU process
<!-- AC:END -->
