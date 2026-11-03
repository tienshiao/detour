---
id: TASK-241
title: 'Native messaging: a host that ignores SIGTERM is never killed'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T17:24:00Z'
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
- [x] #1 A host still running a grace period after SIGTERM is sent SIGKILL; a host that exits on SIGTERM is not
- [x] #2 A test with a fake host that traps SIGTERM shows the process gone after the grace period
- [ ] #3 The task records a signed-build check with 1Password after the change
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. teardownProcess: if the process is running, terminate (SIGTERM, as before) and schedule a SIGKILL after Termination.grace (2 s) on a global queue that captures the Process, not the host; skip it if !process.isRunning.
2. Injectable Termination(grace, onKill) seam for tests.
3. FakeNativeMessagingHost.silentIgnoringSIGTERM; Lifecycle tests for kill by disconnect and by release, no kill for a host that exits on SIGTERM or had already exited.
4. Suites + TSan, /code-review --fix, /verify with fake hosts, wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Chromium (main 1a95d4d): ~NativeMessageProcessHost posts base::EnsureProcessTerminated on macOS; kill_mac.cc waits kWaitBeforeKillSeconds = 2 for NOTE_EXIT, then kill(SIGKILL). It sends no SIGTERM on macOS (the pipes are closed first); kill_posix.cc BackgroundReaper also waits Seconds(2) then SIGKILL. Detour keeps its SIGTERM first (1Password exits on it) and adds the 2 s SIGKILL.
Change: NativeMessagingHost.teardownProcess terminates a running process and calls killIfStillRunning(process, after: termination), a DispatchQueue.global().asyncAfter that holds the Process (Sendable), never the host, and does nothing once process.isRunning is false (Foundation reaps the child; until the reap the pid is a zombie's and cannot be reused). Logs NM KILL (notice) and errno on a failed kill. Termination(grace: 2, onKill:) is an init seam for tests.
Tests: new FakeNativeMessagingHost.silentIgnoringSIGTERM (trap '' TERM; exec sleep); fixture tearDown now pkill -KILL. 4 new Lifecycle tests: TERM-ignoring host alive 250 ms into a 1 s grace and killed after it (onKill pid matches); same via release (host deallocates at once, process killed after 0.3 s); .silent host (exits on SIGTERM) never gets SIGKILL; already-exited host gets none. Mutation check: with the escalation call removed both kill tests fail (timed out, onKill []).
Suites: NativeMessagingHostLifecycleTests 17, NativeMessagingEnforcementTests 15, NativeMessagingFramingTests 8, NativeHostKeepAliveTests 17, ExtensionPolyfillProfileWiringTests 62 (13 skipped): 119 run, 0 failures. Lifecycle under -enableThreadSanitizer YES: 17 run, 0 failures, no TSan reports.
/code-review --fix: fixed the mid-grace check's margin (1 s grace), the wait racing onKill (wait for onKill and the exit together), and kill's return value (errno logged). Skipped: hosts are not terminated at quit, so pending SIGKILL timers die with the app and a TERM-ignoring host can outlive Detour (follow-up); isRunning-then-kill relies on Foundation reaping and clearing isRunning together (microsecond window, documented); the timer keeps the Process (and its handler's Connection and pipes) alive for 2 s after a prompt exit; the already-exited test does not distinguish the teardown's own isRunning guard.
/verify (Debug build, DETOUR_DATA_DIR isolated profile, seeded MV3 SW extension, DETOUR_NATIVE_MESSAGING_HOSTS_DIR fake hosts): connectNative to a host running trap '' TERM; exec sleep 742241, page port.disconnect() after 3 s: the process stayed up 2.1 s after Disconnecting, then NM KILL and NM EXIT status=9 reason=2 (signal), no sleep 742241 left. A 1Password-shaped silent host (exec sleep 742242) disconnected the same way exited at once with status=15 and no NM KILL. Own PID killed only; data dir and both defaults keys removed.
Not verified: AC #3, the signed-build check with 1Password, is owed by the user. Everything else is complete.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A native host still running 2 s after the teardown's SIGTERM is now sent SIGKILL (Chrome's macOS grace, kWaitBeforeKillSeconds = 2 in base/process/kill_mac.cc). The wait holds the Process, not the host, so a teardown from deinit escalates too, and it checks isRunning so a host that exits on SIGTERM (1Password's does) is sent nothing more. 4 new Lifecycle tests with a trap '' TERM fake host; 119 tests in 5 suites pass, Lifecycle clean under TSan; /verify showed a TERM-ignoring host killed (status 9) 2 s after its port disconnected and a silent host exiting on SIGTERM (status 15) with no SIGKILL. AC #3 (signed-build 1Password check) is owed by the user; everything else is complete. Follow-up: hosts are not terminated at quit.
<!-- SECTION:FINAL_SUMMARY:END -->
