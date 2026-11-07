---
id: TASK-275
title: >-
  Native messaging: a failed connect leaves the host's pipes and stderr handler
  behind
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T02:47:00Z'
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
- [x] #1 A connect that throws at any point after creating pipes closes them and removes the stderr handler
- [x] #2 A test counts open descriptors (or handler registrations) across repeated failing connects and sees no growth
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. In NativeMessagingHost.connect(), keep the process and pipes local until the locked run()+registry insert succeeds; on any throw from that block (.quitting, run() failing) close all six pipe handles (FileHandle.close(), a no-op for the child ends Foundation already closed on a failed run) and rethrow. Assign stdoutPipe/stderrPipe/process only after success.
2. Install the stderr readabilityHandler only after the spawn succeeds, so a failed connect never has one (and closing never races a handler reading EOF on another thread).
3. Add a DEBUG-only seam to clear the quit flag, so the .quitting path can be tested and reset.
4. Tests in NativeMessagingHostLifecycleTests: count the test process's open descriptors (fcntl over getdtablesize) before/after N failing connects (manifest path = a directory, so isExecutableFile passes and run() fails with EACCES; and the quitting refusal), keep the hosts alive, assert the delta stays small. Confirm the test fails against the old code first.
5. Wiki native-messaging page + log, finalize task.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Findings: a failed Process.run() (EACCES on a directory path) has already closed the child's ends (stdin read, stdout/stderr write) through their FileHandles; the parent's three stay open. A quit refusal never calls run(), so all six plus the stderr reader's descriptor stayed (7). Measured before the fix with the new tests: 50 failed spawns left 149 descriptors open, 50 quit refusals 350, all held as long as the host object lived (self.process/pipes were assigned before run()).
Fix: process and pipes stay local until the locked run()+registry insert succeeds; the catch closes all six handles (a second close on a handle is a no-op and does not touch a reused descriptor number, checked with a probe that re-took fd 3) and rethrows. The stderr readabilityHandler is installed only after a successful spawn, so a failed connect never has one and the close cannot race a reader at EOF. StdinWriter/DispatchIO channel (TASK-265) is made after the spawn succeeds, so it is not on the failure path. Debug-only seam NativeMessagingHost.setRefusingNewHostsForTesting(_:) to test the quit refusal; tearDown lifts it.
Tests: NativeMessagingHostLifecycleTests 30/0 (3 new: failed spawn and quit refusal each with 50 kept-alive hosts, descriptor delta <= 10 via fcntl over getdtablesize(); a refused host connects and echoes later), NativeMessagingEnforcementTests 26/0, NativeHostManifestValidationTests 18/0, NativeMessagingFramingTests 12/0, NativeHostKeepAliveTests 17/0, NativeConnectLogLimiterTests 8/0 (111/0); after the review edit Lifecycle + ManifestValidation again 48/0. New tests failed before the fix (149 and 350).
/code-review --fix: no correctness bugs; removed a redundant defer in the quit test; clarified the stderr-handler comment (a grandchild holding stderr leaves the reader until teardown). Skipped: the isExecutableFile check accepts a directory (pre-existing, Chrome-compatible enough, and the test relies on it).
Runtime: Debug build launched with an isolated DETOUR_DATA_DIR (Verify275), ran, killed by PID, defaults keys and data dir removed. A failing connect was not exercised in the running app (needs a seeded nativeMessaging extension); the change is covered by the host-level tests only.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A NativeMessagingHost.connect() that throws after making the host's pipes (Detour quitting, or Process.run() failing) now closes all six pipe ends before rethrowing and never installs the stderr reader; the process and pipes are stored on the host only once the spawn succeeds. Before, each failed connect held 3 (failed run) to 7 (quit refusal) descriptors for as long as its host object lived. New descriptor-count tests in NativeMessagingHostLifecycleTests reproduce the leak (149 / 350 descriptors over 50 attempts) and pass with the fix; native messaging suites 111/0. Not exercised in the running app.
<!-- SECTION:FINAL_SUMMARY:END -->
