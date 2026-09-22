---
id: TASK-105
title: >-
  GPU-process recycle valve: when the app has been in the background with
  nothing playing and a WebGL canary reports the GPU process starved, relaunch
  it
status: To Do
assignee: []
created_date: '2026-09-22 03:10'
labels:
  - webkit
  - performance
dependencies: []
priority: medium
ordinal: 105000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-104. The IOSurfacePool exhaustion also grows from window occlusion churn on the VISIBLE tab (+2.9 surfaces per Cmd-Tab cycle measured), which the tab sleep policy cannot reclaim. WebKit recovers from a GPU process exit by design (GPUProcessProxy::gpuProcessExited -> pages reconnect via gpuProcessConnectionDidBecomeAvailable, media reloads and resumes, WebGL pages get webglcontextlost), so a controlled relaunch while nobody is looking is a viable backstop. Detection: a canary (canvas.getContext('webgl') returning null in a lightweight internal page, or the count of 'IOSurface creation failed' if a reliable signal exists) — never time-based alone. Gate: app inactive for >= N minutes AND no tab isPlayingAudio AND no download/PiP in progress; never more than once per hour (WebKit terminates all web processes after repeated GPU exits in a short window). Needs a way to find and terminate the GPU process (WebKit SPI or a process-table lookup of the com.apple.WebKit.GPU child).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Canary detects the starved GPU process state reproduced by docs/task-104 harness runs
- [ ] #2 Relaunch only fires under the gate and at most once per hour; pages repaint, playing media is never interrupted because the gate excludes it
- [ ] #3 Tests cover the gate and the rate limit
<!-- AC:END -->
