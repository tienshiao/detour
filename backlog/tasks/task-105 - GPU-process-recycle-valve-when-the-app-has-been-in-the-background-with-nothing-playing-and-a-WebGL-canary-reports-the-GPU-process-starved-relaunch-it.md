---
id: TASK-105
title: >-
  GPU-process recycle valve: when the app has been in the background with
  nothing playing and a WebGL canary reports the GPU process starved, relaunch
  it
status: Done
assignee:
  - '@claude'
created_date: '2026-09-22 03:10'
updated_date: '2026-10-13 01:22'
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
- [x] #1 Canary detects the starved GPU process state reproduced by docs/task-104 harness runs
- [x] #2 Relaunch only fires under the gate and at most once per hour; pages repaint, playing media is never interrupted because the gate excludes it
- [x] #3 Tests cover the gate and the rate limit
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. GPUProcessRecyclePolicy (pure): soft 12k IOSurfaces -> recycle only after app inactive >= 5 min; hard 15k -> also while active once user input idle >= 60 s; never while any tab plays audio; >= 1 h between recycles. DETOUR_GPU_RECYCLE_* env overrides for the harness.
2. GPUProcessRecycler (driver): 120 s timer; GPU pid via -[WKWebView _gpuProcessIdentifier] on any live tab web view; count VM_MEMORY_IOSURFACE regions via proc_pidinfo off-main; SIGKILL after re-checking proc_name == com.apple.WebKit.GPU. Started from AppDelegate after startArchiveTimer.
3. Replaces the WebGL canary: the direct count detects the state before breakage (canary would only fire after YouTube already failed).
4. Tests: GPUProcessRecyclePolicyTests (gate, rate limit, env parsing, region counting).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Sep 28 2026: recurred in prod after 2.5 days despite the TASK-104 show budget (16,681 surfaces). Signal found that beats a WebGL canary: proc_pidinfo(PROC_PIDREGIONINFO) over the GPU pid counting regions with pri_user_tag == VM_MEMORY_IOSURFACE (88) works from an unsandboxed same-user process, 32k regions in 54 ms, matches vmmap. GPU pid via -[WKWebView _gpuProcessIdentifier] / -[WKProcessPool _gpuProcessIdentifier] (runtime-listed SPI). Lets us recycle BEFORE the limit instead of detecting breakage. TASK-109 showed the memory-pressure flush frees only ~15%.

Live test (user-approved) on prod Detour pid 43917: SIGKILL of GPU pid 43948 at 14.2k surfaces -> WebKit logged gpuProcessExited reason=Crash, every WebContent reconnected (GPUProcessConnection::didClose), zero WebContent terminations, new GPU pid 51354 at 91 surfaces. Harness run (isolated DETOUR_DATA_DIR, soft/hard=1, check 10 s, min interval 30 s): recycler logged 'Recycling GPU process 56699 at 62 IOSurfaces', subsequent ticks resolved the NEW pid 56773 via _gpuProcessIdentifier (0 surfaces on an idle page -> keep). GPUProcessRecyclePolicyTests 14/14 + SleepShowBudgetTests green. Note: an unfocused app's timer ran on schedule (no App Nap stall observed at 10 s).

Code review (--fix): media gate now also blocks on camera/microphone capture (WKWebView cameraCaptureState/microphoneCaptureState != .none — capture runs in the GPU process); kill re-resolves _gpuProcessIdentifier and requires the same pid (proc_name alone matches other apps' GPU processes). Screen-share capture has no public state and is not covered.

2026-10-12, task sweep: all three criteria were met and the code has been on main since c13b3d0 (2026-09-28); the status was never changed. The signal is the GPU process's IOSurface count, not the WebGL canary of the title. One defect found since and fixed under TASK-175 (829d88a): the recycler asked only the first live web view for the GPU pid, and a web view answers for its own process pool, so it could read 'no GPU process' and skip a check. No recycle appears in the installed app's log for the last three days: WebKit itself replaced the GPU process five times on 2026-10-12, so the count never reached the soft limit.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
GPUProcessRecycler counts the GPU process's IOSurfaces every 120 s and kills the process (WebKit relaunches it, pages reconnect) once the count passes 12,000 with the app inactive for 5 minutes, or 15,000 with the user idle for a minute; never while a tab plays audio or captures camera or microphone, and at most once an hour. The policy is a pure function with 14 tests. Verified by a live SIGKILL at 14.2k surfaces and a harness run with lowered limits.
<!-- SECTION:FINAL_SUMMARY:END -->
