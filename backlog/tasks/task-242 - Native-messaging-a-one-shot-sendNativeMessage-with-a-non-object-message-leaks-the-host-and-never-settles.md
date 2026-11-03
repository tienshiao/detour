---
id: TASK-242
title: >-
  Native messaging: a one-shot sendNativeMessage with a non-object message leaks
  the host and never settles
status: To Do
assignee: []
created_date: '2026-11-03T07:58:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 286000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-233. In ExtensionManager, runtime.sendNativeMessage whose message is not a dictionary (a string, number, array or null) starts the host process but never writes to it; the request is never settled and the host is never released, so the process lives until Detour quits and the caller's promise hangs. Chrome sends any JSON-serialisable value. Whether Detour should send it or refuse it with an error is part of the task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A one-shot request with a non-object message either reaches the host (and its reply settles the request) or is refused with an error before any process is started; the choice is recorded
- [ ] #2 No host process is left running in either case
- [ ] #3 Tests cover a string, an array and null, from both the promise and the callback forms
<!-- AC:END -->
