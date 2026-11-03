---
id: TASK-241
title: 'Native messaging: a host that ignores SIGTERM is never killed'
status: To Do
assignee: []
created_date: '2026-11-03T07:58:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
priority: low
type: bug
ordinal: 285000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-233. NativeMessagingHost teardown sends SIGTERM only. A host that ignores or blocks SIGTERM keeps running as a child of Detour after its port or request is gone. Chrome sends SIGTERM and kills the process after a grace period (about 2 s). This is the 1Password native host path, so the change needs a signed-build check.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A host still running a grace period after SIGTERM is sent SIGKILL; a host that exits on SIGTERM is not
- [ ] #2 A test with a fake host that traps SIGTERM shows the process gone after the grace period
- [ ] #3 The task records a signed-build check with 1Password after the change
<!-- AC:END -->
