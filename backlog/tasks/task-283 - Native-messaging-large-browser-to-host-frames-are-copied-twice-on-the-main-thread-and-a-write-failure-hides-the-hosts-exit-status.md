---
id: TASK-283
title: >-
  Native messaging: large browser-to-host frames are copied twice on the main
  thread, and a write failure hides the host's exit status
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
labels:
  - extensions
  - native-messaging
  - performance
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - DetourTests/NativeMessagingHostLifecycleTests.swift
priority: low
type: task
ordinal: 330000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Found in TASK-265's code review.

- Since TASK-265 the browser-to-host limit is Chrome's 64 MiB. `encodeMessage` copies the body into a new `Data`, then `DispatchData(bytes:)` copies it again, so a 64 MiB message costs two main-thread memcpys and about 128 MiB of transient memory on top of JSON serialization.
- When queued writes fail after a host exits, `NativeHostEnding` prefers the write failure, so the disconnect reason reads "Native host write failed: Broken pipe" instead of the exit status. Only logs and diagnostics see the reason today.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Sending a frame makes at most one copy of the body on the main thread
- [ ] #2 A host that exits with queued writes pending is reported with its exit status
- [ ] #3 Tests cover the disconnect reason for a host that exits with writes queued
<!-- AC:END -->
