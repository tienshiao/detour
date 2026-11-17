---
id: TASK-406
title: >-
  GPU recycler: recycle at a lower threshold while the screen is locked or the
  display is asleep (pending TASK-404/405 data)
status: To Do
assignee: []
created_date: '2026-11-17T19:47:00Z'
updated_date: '2026-11-17T20:40:00Z'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User decision 2026-11-17: recycle at >= 6,000 IOSurfaces while the screen is locked or the display is asleep. The existing guards still apply (no media in use, minimumInterval 1 h). The other tiers are unchanged (12k background >= 5 min, 14k idle >= 60 s, 16,384 exhausted).
<!-- SECTION:NOTES:END -->
