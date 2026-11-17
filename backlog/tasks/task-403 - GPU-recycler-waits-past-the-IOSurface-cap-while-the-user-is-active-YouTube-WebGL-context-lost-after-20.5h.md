---
id: TASK-403
title: >-
  GPU recycler: waits past the IOSurface cap while the user is active (YouTube
  WebGL context lost after 20.5h)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-17T19:18:00Z'
updated_date: '2026-11-17T19:26:00Z'
labels:
  - gpu
  - webkit
dependencies: []
references:
  - Detour/Browser/GPUProcessRecycler.swift
  - DetourTests/GPUProcessRecyclePolicyTests.swift
priority: high
type: bug
ordinal: 484000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Recurrence of TASK-104 on 2026-11-17 in the running build (Detour pid 89056, up 20.5h since Nov 16 14:42). YouTube showed 'WebGL: context lost' and would not play. The GPU process (pid 89095) first logged 'per client IOSurface limit of 16384 reached' at 11:09:17. The TASK-105 recycler killed it at 11:10:56 at 16697 IOSurfaces, about 100 s after it had already broken; the replacement process was healthy (481 surfaces).

Why it fired late can't be proven, because the recycler logs its 'gate closed' decisions at .info, which isn't persisted. Only the final notice line exists. pmset shows the display was off 03:05-08:01 and 08:35-09:46. In both windows the 60 s idle gate (>=15k) and the 5 min inactive gate (>=12k) would have opened, so the count most likely crossed 15k during active use after 09:46. The recycler then waited for 60 s without input, which never came before the cap. HTMLMediaElement playback was on and off 10:09-10:13 and around 11:00.

At >=16384 the GPU process is already broken (WebGL/canvas dead, YouTube serves its poisoned player response), yet the policy still waited for idle or inactivity. A user retrying the broken page keeps it broken.

User decision 2026-11-17: add an 'exhausted' tier that recycles on the next tick even while the user is active, still skipping it while a tab plays audio or captures camera/mic. Lower the active-use threshold from 15k to 14k. Persist the gate-closed decisions.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Policy: at or above the exhausted limit (16,384) the decision is recycle while Detour is active and the user is not idle, provided no media is in use and minimumInterval has passed
- [x] #2 Policy: the exhausted tier still waits while media is in use and within minimumInterval
- [x] #3 Policy: the active-use (hard) limit defaults to 14,000; the soft limit (12,000, inactive >= 5 min) is unchanged
- [x] #4 A closed gate over the soft limit is logged at notice with count, active, idle seconds and media, rate-limited so a long wait does not flood the log
- [x] #5 GPUProcessRecyclePolicyTests cover the new tier and the new default
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. GPUProcessRecyclePolicy: add exhaustedLimit (16,384, env DETOUR_GPU_RECYCLE_EXHAUSTED_LIMIT) as a final recycle rule after the media and rate-limit guards; hardLimit default 14,000.
2. GPUProcessRecycler.evaluate: the gate-closed line becomes notice at most every 10 min (count, inactiveFor, userIdle, media, sinceLastRecycle), info in between.
3. Tests in GPUProcessRecyclePolicyTests; wiki gpu-iosurface-limit, app-shell, debug-harness.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Review (/code-review medium --fix): 7 findings, 3 fixed (the log line formats Doubles with .fixed(precision: 0) so a non-finite idle value can't trap; it logs the decision's inputs, not live state; test renamed testLimitDefaults). Not changed: exhaustedLimit is compared with the VM region count, which ran ~300 above live surfaces at failure in TASK-104, so the tier can fire a few hundred surfaces before allocations actually fail. Accepted: that is a recycle shortly before the break rather than after. No ordering check between the env overrides (harness only). Info lines in between drop the detail (the notice line carries it).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Recurrence 2026-11-17: the production GPU process hit the 16,384 IOSurface cap after 20.5 h, and the recycler fired 100 s after the first failed allocation, at 16,697. pmset puts the crossing of 15k in active use after 09:46, when the idle gate never opened, but the gate decisions were only logged at info, so this can't be proven.

Changes, with the user's choice on 2026-11-17: a new exhausted tier (>= 16,384) recycles on the next check even while the user is busy, still blocked by audio/capture and the 1 h rate limit. hardLimit is now 14,000 (softLimit 12,000 unchanged). The gate-closed decision is logged at notice with its inputs, once per 10 min.

Verification: GPUProcessRecyclePolicyTests 17/17 pass. Runtime check of an isolated Debug build (DETOUR_DATA_DIR, WebGL aquarium page, 10 s checks). Run A (soft=1, hard/exhausted=100000) logged one notice 'recycle gate closed (inactiveFor=11s, userIdle=62s, media=false, sinceLastRecycle=-1s)', then info lines. Run B (exhausted=1, hard=100000, inactive grace 1 h, idle grace 100000 s) logged 'Recycling GPU process 28222 at 72 IOSurfaces'. The WebContent process reconnected 0.3 s later, and the next tick waited on the rate limit (sinceLastRecycle=11s).

Not verified: the busy-user path with real input (CGEvent idle can't be forced via the endpoint; covered by policy tests), and the signed production build.

Open: the growth is again near the pre-show-budget rate. A sampler of the new production GPU process is running this session.
<!-- SECTION:FINAL_SUMMARY:END -->
