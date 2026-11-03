---
id: TASK-236
title: >-
  Tests: testAnArmedWorkerHoldsOneAnchorAndADisarmStopsReanchoring is flaky
  under Thread Sanitizer
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T03:00:00Z'
updated_date: '2026-11-03T06:26:00Z'
labels:
  - tests
dependencies: []
references:
  - DetourTests/ExtensionPolyfillProfileWiringTests.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 280000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen during TASK-231.4: ExtensionPolyfillProfileWiringTests.testAnArmedWorkerHoldsOneAnchorAndADisarmStopsReanchoring failed 2 of 5 runs under -enableThreadSanitizer YES, and 1 of 5 on the commit before that task's changes, always with 3 anchors opened where at most openedAtDisarm + 1 (2) is allowed; no ThreadSanitizer report. It passes in normal runs. The test toggles the simulated native host connected/connected/disconnected/disconnected back to back and sleeps 0.5 s; under TSan's slowdown the worker evidently re-anchors once more than the assertion allows. Whether that extra anchor is a real behaviour on a slow machine or only a test timing assumption is open.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The cause of the extra anchor is recorded: a test timing assumption, or a real re-anchor the keep-alive logic should not make
- [x] #2 The test passes 10 of 10 runs under Thread Sanitizer (-test-iterations 10) and in normal runs, without loosening it beyond what the recorded cause justifies
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure on current main under TSan (10 iterations). 2. Instrument the test to compare Detour's and the worker's anchor counts at the disarm and after the re-arm. 3. If timing: wait on the worker's own counters (anchorsOpened, repliesSent) instead of the fixed sleep, with a bound the cause justifies. 4. Rerun TSan x10, normal x10, both suites; code review; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Baseline on c9d7506 (after TASK-232/233), before any change: -enableThreadSanitizer YES -test-iterations 10, only this test: 7 of 10 failed, every failure 'XCTAssertLessThanOrEqual failed: ("3") is greater than ("2")' at the opened <= openedAtDisarm + 1 assertion; no ThreadSanitizer report. Load average ~24 at the time.

Cause (AC #1): a test timing assumption, not a wrong re-anchor. Instrumented TSan run (10 iterations): Detour's anchor count equalled the worker's at the disarm every time (1 = 1), so the old read was not early; the brief re-arm then opened 2 anchors in 7 runs and 1 in 3, all while the worker was armed, none after it handled the stop. Every arm sends keepalive-start and its immediate ping back to back (startKeepAlivePinging), and the worker schedules a re-anchor (setTimeout 0) for each; they coalesce only when the ping arrives before the start's task runs. Under TSan the start's task usually runs first, so the ping re-anchors again (close + open, one anchor still held). reanchorNow checks armed, so nothing opens once the stop is handled; there were no re-anchor requests and no port ends in the window. Harmless by design (the ping re-anchor is the backstop for a port that ended unseen), so no app change.
Fix: the test waits for the worker to report armed == false with repliesSent past the disarm (the re-arm's start, ping and stop all handled, port messages being ordered), allows openedAtDisarm + 2 (one per trigger; it can also be 0 when the stop arrives before the start's task), waits for Detour's count to reach the worker's and asserts them equal, then keeps a 0.5 s window to check nothing more opens while disarmed. The test extension's keepAliveStatus reply now includes repliesSent.
Verification: after the change, TSan -test-iterations 10: 10/10 pass (run twice, before and after the review fixes); normal -test-iterations 10: 10/10 (twice). ExtensionPolyfillProfileWiringTests (62, 13 skipped measurement legs, 0 failures) and NativeHostKeepAliveTests (17, 0 failures) in one normal run, before the review's test-only touch-ups (the changed test was rerun 20 times after them). /code-review --fix: fixed the doc comment (zero to two anchors) and turned the exact-count waits into >= waits plus an equality assertion with a message; skipped waitUntil not throwing on timeout (shared helper, pre-existing) and the remaining 0.5 s window (a negative check needs one). Test-only change: /verify not applicable, keep-alive logic unchanged, no signed-build check owed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The extra anchor came from test timing: every arm sends keepalive-start and a ping back to back, and the worker re-anchors for each unless the two coalesce. Under ThreadSanitizer they usually don't, so a brief re-arm opened two anchors (7 of 10 baseline runs on c9d7506 failed with 3 > 2). Both re-anchors happen while armed, which is harmless and by design, so the keep-alive logic is unchanged. The test now waits on the worker's anchorsOpened/repliesSent instead of a 0.5 s sleep and allows the two anchors the start and the ping can each make. TSan 10/10 and normal 10/10; the wiring and keep-alive suites pass. Wiki: native-port-keep-alive gotcha.
<!-- SECTION:FINAL_SUMMARY:END -->
