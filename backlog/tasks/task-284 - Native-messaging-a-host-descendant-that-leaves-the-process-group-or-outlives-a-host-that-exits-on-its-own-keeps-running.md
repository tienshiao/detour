---
id: TASK-284
title: >-
  Native messaging: a host descendant that leaves the process group, or outlives
  a host that exits on its own, keeps running
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - wiki/extensions/native-messaging.md
priority: low
type: task
ordinal: 331000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Limits recorded in the wiki by TASK-274.

Since TASK-274 Detour signals the host's process group, which reaches a wrapper script's non-exec child. Not reached: a descendant that calls `setsid` or otherwise daemonises, and the children of a host that exits by itself (the group is only signalled while the host is unreaped or inside the grace/quit windows). Chrome has the same limits on macOS, so this may stay as is; decide and record.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The decision (leave as Chrome does, or reach these descendants, for example by tracking the group after the host exits) is recorded in the native-messaging wiki page
- [ ] #2 If behaviour changes: tests with fake hosts cover a daemonising descendant and a child of a host that exited on its own, and no process outside Detour's hosts' groups is signalled
<!-- AC:END -->
