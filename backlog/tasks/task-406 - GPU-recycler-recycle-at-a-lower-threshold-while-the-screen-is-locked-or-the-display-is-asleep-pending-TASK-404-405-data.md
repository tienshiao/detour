---
id: TASK-406
title: >-
  GPU recycler: recycle at a lower threshold while the screen is locked or the
  display is asleep (pending TASK-404/405 data)
status: In Progress
assignee: []
created_date: '2026-11-17T19:47:00Z'
updated_date: '2026-11-17T20:46:00Z'
labels:
  - gpu
  - webkit
dependencies:
  - TASK-404
priority: medium
type: feature
ordinal: 487000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On 2026-11-17 the display was off 03:05-08:01 and the GPU process was recycled only at 16,697 surfaces at 11:10 during active use (TASK-403). While the screen is locked or the display asleep nobody sees a recycle, so a much lower threshold (for example 6,000) would make the busy-user rules a rare fallback. Not started yet: the user decides the threshold once TASK-404/405 show how much closing and sleeping tabs actually frees.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The threshold and gate are confirmed by the user
- [ ] #2 GPUProcessRecyclePolicyTests cover the locked/asleep gate, including media and the rate limit still blocking
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. GPUProcessRecyclePolicy: add awayLimit (6,000) and Inputs.userAway; decide() recycles at >= awayLimit while away, after the media and minimumInterval guards; the other tiers are unchanged (keep below softLimit when not away).
2. GPUProcessRecycler.userIsAway(): read at each check — CGSessionCopyCurrentDictionary()[CGSSessionScreenIsLocked], or every online display (CGGetOnlineDisplayList) CGDisplayIsAsleep. No displays = not away.
3. DETOUR_GPU_RECYCLE_AWAY_LIMIT env override; away= in the gate-closed notice and the recycle line.
4. GPUProcessRecyclePolicyTests: away over the limit (active+busy too), away below the limit keeps, media and rate limit still block, not-away 6k..12k keeps, env parsing.
5. Wiki gpu-iosurface-limit.md tier table/overrides/log fields; wiki/log.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User decision 2026-11-17: recycle at >= 6,000 IOSurfaces while the screen is locked or the display is asleep. The existing guards still apply (no media in use, minimumInterval 1 h). The other tiers are unchanged (12k background >= 5 min, 14k idle >= 60 s, 16,384 exhausted).

Implemented 2026-11-17 (agent, branch gpu-406-407): GPUProcessRecyclePolicy.awayLimit = 6,000 + Inputs.userAway; decide() recycles at >= awayLimit while away, after the media and minimumInterval guards; not away, everything below softLimit still keeps. GPUProcessRecycler.userIsAway() reads CGSessionCopyCurrentDictionary()[CGSSessionScreenIsLocked] or CGDisplayIsAsleep over every online display at each check (no notifications). DETOUR_GPU_RECYCLE_AWAY_LIMIT override; away= added to the gate-closed notice and the recycle line.
Probe (standalone swiftc binary, unprivileged, sandbox off): the session dictionary and the display list answer (unlocked: lock key absent, display 5 awake). Inside the Bash sandbox both come back empty, which reads as not away. The locked and asleep answers were NOT observed.
Claude's choices: no grace once away (a recycle can fire on the first 2-minute check after the lock); no online display at all = not away.
Tests: GPUProcessRecyclePolicyTests 23/0 (6 new: default, away recycles even active+busy, away below limit keeps, away + media waits, away + rate limit waits/reopens, not away 6k..12k keeps; env parsing extended), GPUSurfaceTelemetryTests 18/0.
/code-review not run by the implementing agent (left to the lead).
<!-- SECTION:NOTES:END -->
