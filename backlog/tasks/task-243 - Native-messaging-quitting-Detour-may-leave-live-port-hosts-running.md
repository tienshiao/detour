---
id: TASK-243
title: 'Native messaging: quitting Detour may leave live port hosts running'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T18:10:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - Detour/App/AppDelegate.swift
priority: low
type: bug
ordinal: 287000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen during TASK-233 runtime verification: after the app was sent SIGTERM, a silent connectNative host process (holding the keep-alive) kept running. Whether a normal quit (Cmd+Q, applicationWillTerminate) ends live port hosts, or only a SIGTERM leaks them, is unknown. Orphaned hosts (e.g. 1Password's) would keep running after Detour is gone.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 What a normal quit and a SIGTERM each do to live native hosts is measured and recorded
- [x] #2 After a normal quit no native host process started by Detour is left running
- [ ] #3 The task records a signed-build check with 1Password after the change, if behaviour changed
- [x] #4 A host that ignores SIGTERM, or one torn down less than its 2 s SIGKILL grace before quit (TASK-241), does not outlive Detour
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure a normal quit and an app SIGTERM on HEAD with two fake port hosts (silent keep-alive, TERM-ignoring).
2. Track every spawned host process in a static Mutex registry until its termination handler runs; make the TASK-241 SIGKILL timer a cancellable source stored there.
3. terminateAllSpawnedHosts(within:): SIGTERM all, bounded wait for all together, SIGKILL the rest; call it last in applicationWillTerminate.
4. SIGTERM to the app: DispatchSource handler on a global queue that ends the hosts, then re-raises under SIG_DFL.
5. Lifecycle tests; runtime verify quit + SIGTERM; suites; /code-review --fix; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
From TASK-241 review: the SIGKILL escalation timer dies with the app, so a TERM-ignoring host can outlive Detour; quit should terminate hosts with a short bounded wait before SIGKILL. Optionally cancel the SIGKILL timer from the termination handler so the Process and pipes are freed as soon as a host exits.

Measured on HEAD (5d93e31), Debug build, isolated profile, two connectNative ports held by the worker: a silent host (exec sleep, holds the keep-alive) and one with trap '' TERM. Normal quit (NSApp.terminate via a temporary env-gated harness, quit alert answered): willTerminate ran no teardown, both hosts were left running with ppid 1. SIGTERM to the app: died at once, both hosts left running with ppid 1.

Change: NativeMessagingHost keeps a static Mutex registry of every spawned host process until its termination handler runs, so it covers owned hosts, one-shot hosts and torn-down hosts still inside their TASK-241 grace. run() and the entry happen under one lock. terminateAllSpawnedHosts(within:refusingNewHosts:) sends SIGTERM to every running host, waits for them all together, then sends SIGKILL to the rest, and refuses later connect() calls (NativeMessagingError.quitting). The normal quit calls it last in applicationWillTerminate. It is not in applicationShouldTerminate, whose quit alert can still cancel, and willTerminate is where every terminate that goes ahead ends.
Wait chosen: quitGrace = 1 s for all hosts together, against Chrome's 2 s per host, because it delays quit. A host that exits on SIGTERM takes about 2 ms, so the second is only spent on one that ignores SIGTERM.
SIGTERM to the app: handled, with a DispatchSource on a global queue (works with main busy or hung). It ends the hosts the same way, cancels the source, restores SIG_DFL and re-sends SIGTERM, so the app still dies of the signal (exit status 143) and runs no quit path. Worth it: a kill, a launchd job or a test runner sends SIGTERM, and the leak was observed. Checked: Foundation's Process resets signal dispositions in the child, so hosts do not inherit the ignored SIGTERM, and isRunning updates while the main thread blocks.
Optional item done: the TASK-241 SIGKILL timer is now a DispatchSourceTimer kept in the registry entry and cancelled by the termination handler, so the Process and its pipes go when the host exits.

After the change, same setup: the normal quit logged the silent host's exit (status 15) 3 ms into willTerminate and SIGKILLed the TERM-ignoring one (status 9) at the 1 s deadline, and both were gone after the quit. SIGTERM: the same, exit status 143. Repeated after the review's fixes, with the same result. The harness was removed before the commit, and the profile and defaults keys were cleaned.

Tests: NativeMessagingHostLifecycleTests adds testQuitEndsEveryLiveHostIncludingOneIgnoringSIGTERM, testQuitKillsAHostTornDownWithinItsGracePeriod and testAnExitedHostReleasesItsSIGKILLTimer (this one passes without the explicit cancel, since dropping the entry frees the source, but fails on the old asyncAfter). Run: Enforcement, Lifecycle (20), Framing, NativeHostKeepAliveTests and ExtensionPolyfillProfileWiringTests: 130 tests, 13 env-gated skips, 0 failures, after the review fixes too. Not tested: the SIGTERM handler itself (it would need a separate process to signal; checked at runtime only) and the isQuitting refusal (the flag cannot be cleared within the test host).

/code-review --fix: fixed (1) a crash from releasing a never-resumed timer source when the host was already untracked, (2 and 3) a host started during or after a SIGTERM sweep (run under lock, isQuitting), and (4) dead spawnedProcessCount; also loosened a wall-clock bound in the test. Skipped: polling in place of a semaphore (at most 1 s, only for a TERM-ignoring host).

Signed build OWED BY THE USER (AC #3): at quit, 1Password's host now gets SIGTERM, where before it only saw its stdin close as the app exited. Check that 1Password's BrowserSupport exits cleanly at a Detour quit and reconnects on relaunch.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
No native host started by Detour outlives a normal quit or a SIGTERM to the app, including one that ignores SIGTERM or one torn down inside its 2 s grace period. Before the change, both kinds of host survived both kinds of exit with ppid 1. Now every spawned host is tracked until it exits; the quit (applicationWillTerminate) and a DispatchSource SIGTERM handler send it SIGTERM, wait 1 s for all of them together, then send SIGKILL. The SIGTERM path still ends in exit status 143. Everything is done except the signed-build check with 1Password (AC #3), which the user owes: 1Password's host now gets SIGTERM at quit.
<!-- SECTION:FINAL_SUMMARY:END -->
