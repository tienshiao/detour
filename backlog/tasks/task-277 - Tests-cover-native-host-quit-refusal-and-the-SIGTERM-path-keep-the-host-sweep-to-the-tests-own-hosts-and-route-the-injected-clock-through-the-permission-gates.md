---
id: TASK-277
title: >-
  Tests: cover native host quit refusal and the SIGTERM path, keep the host
  sweep to the test's own hosts, and route the injected clock through the
  permission gates
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - native-messaging
  - tests
dependencies: []
references:
  - DetourTests/NativeMessagingHostLifecycleTests.swift
  - Detour/App/AppDelegate.swift
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: low
type: task
ordinal: 324000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

- Every NativeMessagingHostLifecycleTests case passes `refusingNewHosts: false`, so the `.quitting` refusal in `connect()` (TASK-243) has no automated test. The SIGTERM handler (ignore, sweep, cancel, SIG_DFL, re-raise, exit 143) rests on one manual measurement in the wiki.
- `terminateAllSpawnedHosts` sweeps the process-wide registry, so these tests also SIGTERM hosts other suites left alive in the test host, a source of cross-suite flakiness.
- `ExtensionPolyfillHandler` has a `now` test seam, but its instance call sites of `permissionRefusal`, `permissionRequestPlan`, `activeAPIPermissions` and `permissions.contains` never pass it, so grant/denial expiry in those paths always reads the wall clock.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test covers connect() refused while the app is quitting: no process is spawned and the extension gets the error
- [ ] #2 The SIGTERM-to-Detour path is covered by a test (in a child process if it cannot run in the test host) or the reason it is not is recorded
- [ ] #3 Lifecycle tests only terminate hosts they started
- [ ] #4 The permission gates use the handler's injected clock, with a test of an expired grant through it
<!-- AC:END -->
