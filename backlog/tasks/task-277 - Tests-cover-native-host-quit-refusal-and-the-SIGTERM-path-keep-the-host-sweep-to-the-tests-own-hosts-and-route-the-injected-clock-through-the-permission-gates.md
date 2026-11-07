---
id: TASK-277
title: >-
  Tests: cover native host quit refusal and the SIGTERM path, keep the host
  sweep to the test's own hosts, and route the injected clock through the
  permission gates
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T03:35:00Z'
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
- [x] #1 A test covers connect() refused while the app is quitting: no process is spawned and the extension gets the error
- [x] #2 The SIGTERM-to-Detour path is covered by a test (in a child process if it cannot run in the test host) or the reason it is not is recorded
- [x] #3 Lifecycle tests only terminate hosts they started
- [x] #4 The permission gates use the handler's injected clock, with a test of an expired grant through it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
AC review against 926451b/ce147a2/6f6972f/5d22152:
- AC1 partly met: testAConnectRefusedForQuittingClosesItsPipes (host level: .quitting, processCount 0). Missing: the extension-facing error. Add an extension-context test in NativeMessagingEnforcementTests (sendNativeMessage promise + callback lastError + connectNative port.error, no process, no live host) by generalising the TASK-266 every-path helper.
- AC2 not met. Extract the SIGTERM source body into makeEndingSignalSource(_:endHosts:) (SIG_IGN, dispatch source, endHosts, cancel, SIG_DFL, re-raise); production passes SIGTERM + the real sweep. Test it in the test host with SIGURG (default action: discard), a witness signal source and a scoped sweep: host ended, refusal set, handler ran once, re-raise delivered after the sweep, disposition back to SIG_DFL. Exit 143 is the kernel's default action, measured by docs/harness/task274-harness.patch; recorded.
- AC3 not met. SpawnedProcess records its executable; DEBUG terminateSpawnedHostsForTesting(running:within:refusingNewHosts:) shares the sweep, filtered to those executables; production terminateAllSpawnedHosts unchanged. Lifecycle tests sweep only their fixtures' scripts; a test that an out-of-scope host survives.
- AC4 not met. Instance call sites pass now(): permissionRefusal, permissions.contains, permissionRequestPlan, activeAPIPermissions and activeHostPermissions in buildExtensionInfo. Test in ExtensionPermissionRestoreTests: grants/denial expiring in 1 h on the wall clock, handler clock 2 h ahead -> contains false, history.search refused, getSelf drops them, request prompts instead of answering false.
- Wiki native-messaging + log; run NativeMessagingHostLifecycleTests, NativeMessagingEnforcementTests, ExtensionPermissionRestoreTests, ExtensionHistoryScopeTests.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Already met before this task (cited): AC1 host level by testAConnectRefusedForQuittingClosesItsPipes (6f6972f: .quitting, processCount 0); nothing covered the extension-facing error, the SIGTERM sequence, the sweep scope or the clock.

Done:
- AC1: NativeMessagingEnforcementTests.testWhileQuittingEveryPathIsRefusedWithoutSpawning: with the refusal set, an extension page's sendNativeMessage promise, callback runtime.lastError and connectNative port.error all carry 'Detour is quitting'; no fake host process, no live host, no pending one-shot. The TASK-266 every-path helper was split so both use it; the suite's tearDown lifts the refusal.
- AC2: decision: the SIGTERM source body is now NativeMessagingHost.makeHostEndingSignalSource(_:endHosts:) (SIG_IGN, dispatch source, endHosts, cancel, SIG_DFL, re-send); production passes SIGTERM and the full sweep. testASignalSourceEndsTheHostsThenLetsTheSignalTakeItsDefaultCourse drives it with a real SIGURG (default action discard) in the test host: handler runs once, the host is ended and new connects refused, the disposition is still SIG_IGN after the sweep, a witness signal source sees both deliveries (EVFILT_SIGNAL sees even a discarded signal), and the disposition is SIG_DFL afterwards. Why not a child process: the test host cannot take SIGTERM; spawning Detour.app from a test is ruled out by the launch rule (isolated DETOUR_DATA_DIR only through the wrapper), and there is no helper target to fork into. What stays untested automatically: SIGTERM's default action killing Detour with 143 (the kernel's) - checked at runtime below.
- AC3: registry entries record their manifest path; Debug-only terminateSpawnedHostsForTesting(running:within:refusingNewHosts:) runs the same sweep filtered to those executables; terminateAllSpawnedHosts (production) unchanged in behaviour. All seven lifecycle sweeps go through quit(within:) naming the test's fixtures' scripts; the superset assertion in testQuitEndsEveryLiveHostIncludingOneIgnoringSIGTERM is now an equality. testATestsSweepEndsOnlyTheHostsItNames: an unnamed host keeps running and connected.
- AC4: ExtensionPolyfillHandler passes self.now() to permissionRefusal (instance wrapper), permissions.contains, permissionRequestPlan, and activeAPIPermissions + activeHostPermissions in buildExtensionInfo. ExtensionPermissionRestoreTests.testThePermissionGatesReadExpiryOnTheHandlersClock: history grant, management denial and an optional host grant expiring in 1 h (WebKit still holds them), handler clock +2 h: contains false, history.search refused as optional-not-granted, getSelf drops history and the host, management.getAll's refusal turns from denied to optional-not-granted, and permissions.request prompts instead of answering false; wall-clock leg as positive control. ExtensionManager.now (5dab639) untouched.

Code review (/code-review --fix fork): 6 findings, fixed 3 (10 s timeout on the new call helper, XCTUnwrap instead of ?? "" for the expected text, dropped an unused helper parameter); I strengthened the signal test's order check (disposition still SIG_IGN after the sweep) in place of a weak log.last assertion. Left: the static gates' now: Date = Date() defaults (21 existing call sites), executable stored in Release builds too (tiny).

Tests (Debug, .derived, one run after the review fixes): NativeMessagingHostLifecycleTests 40/0, NativeMessagingEnforcementTests 27/0, ExtensionPermissionRestoreTests 59/0, ExtensionHistoryScopeTests 36/0 - 162 tests, 0 failures.
Runtime (/verify): Debug build launched only through launch-detour.sh with DETOUR_DATA_DIR=T277Verify86785, kill -TERM after 8 s: log 'Signal 15: ending native hosts before exiting' from the extracted source, exit status 143. No hosts were running, so the NM QUIT line (logged only when there are hosts) did not appear; the sweep with live hosts at runtime rests on the TASK-274 harness run. Defaults keys and the data dir removed. Not verified: a signed build.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Closed the test gaps around native-host quitting and the polyfill permission clock. An extension-context test shows every native messaging path from a page gets 'Detour is quitting' with no host started; the SIGTERM handler's sequence is extracted into makeHostEndingSignalSource and exercised with a real SIGURG in the test host (exit 143 itself is the kernel's, checked at runtime with an isolated launch); lifecycle tests sweep only their own fixtures' hosts through a Debug-only scoped sweep, production unchanged; the polyfill handler's injected now clock now reaches every permission gate, with an expired-grant/denial test through the handler. 162 tests in the four affected suites pass. Follow-up: drop the static gates' Date() defaults so a new gate cannot silently read the wall clock.
<!-- SECTION:FINAL_SUMMARY:END -->
