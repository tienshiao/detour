---
id: TASK-275
title: >-
  Native messaging: a failed connect leaves the host's pipes and stderr handler
  behind
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
priority: low
type: bug
ordinal: 322000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`NativeMessagingHost.connect()` assigns the pipes, `self.process` and the stderr `readabilityHandler` (~220-225) before the locked `run()` + registry insert (~311-315). When connect throws (`.quitting`, or `run()` failing), `connection` stays nil, and `disconnect()` / `deinit` return early on `guard let connection`, never reaching `teardownProcess`. Each failed connect leaks pipe descriptors and a readability source on a stderr pipe whose write end Detour still holds, so it never sees EOF. Matters on the quit path and on repeated spawn failures.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A connect that throws at any point after creating pipes closes them and removes the stderr handler
- [ ] #2 A test counts open descriptors (or handler registrations) across repeated failing connects and sees no growth
<!-- AC:END -->
