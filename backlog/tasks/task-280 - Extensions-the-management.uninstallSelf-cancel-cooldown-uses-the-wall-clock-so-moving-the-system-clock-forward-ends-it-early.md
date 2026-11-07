---
id: TASK-280
title: >-
  Extensions: the management.uninstallSelf cancel cooldown uses the wall clock,
  so moving the system clock forward ends it early
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
labels:
  - extensions
  - management
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - DetourTests/ExtensionManagementSelfTests.swift
priority: low
type: bug
ordinal: 327000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Found while doing TASK-267.

After a cancelled `uninstallSelf({showConfirmDialog: true})` dialog, further calls are refused for 10 minutes so an extension cannot re-show the app-modal alert in a loop. The cooldown compares `Date` values, so a clock change (manual, NTP jump, time-zone tooling) can end it at once and a backwards change can stretch it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cooldown is measured with a monotonic clock and is unaffected by a change of the system time
- [ ] #2 The existing test seam still lets tests advance time; tests cover expiry and a non-expired refusal
<!-- AC:END -->
