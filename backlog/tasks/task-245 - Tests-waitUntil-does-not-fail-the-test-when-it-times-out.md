---
id: TASK-245
title: 'Tests: waitUntil does not fail the test when it times out'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T18:30:00Z'
labels:
  - tests
dependencies: []
references:
  - DetourTests/ExtensionTestSupport.swift
priority: low
type: chore
ordinal: 289000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noted during TASK-236. The shared waitUntil helper in DetourTests/ExtensionTestSupport.swift (used in ~57 test files) does not throw or stop the test on timeout, so a failed wait lets the test continue on stale state and the real failure shows up later as a confusing assertion, or not at all.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A waitUntil timeout fails the test at the wait, naming what was awaited, and does not continue the test body
- [x] #2 Every caller compiles and the full suite passes; callers that relied on a timeout not failing are found and fixed or recorded
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Before: waitUntil (DetourTests/ExtensionTestSupport.swift) already recorded XCTFail on timeout but then returned, so the test body went on with stale state. Its return type is Void, so no caller could check a result, and every timeout already failed the test. That means no caller depended on a timeout passing.

Change: on timeout waitUntil records XCTFail at the call site and throws WaitTimedOut(what, timeout), so the body stops at the wait. The XCTFail stays so a do/catch or try? around the wait cannot hide the timeout. The cost is that a timeout reports twice (the call-site failure plus XCTest's caught-error failure); this is deliberate. Call sites were already 'try await waitUntil', so they needed no edits. New pollUntil(timeout:pollInterval:_:) -> Bool never fails, for a wait whose timeout is an expected outcome.

Callers changed:
- ExtensionPageRehostTests had its own non-throwing private waitUntil (3 s timeout, 20 ms polls; it XCTFailed and returned). It was removed, and its 9 waits now use the shared helper with try. The trailing uninstall in testReinstallKeepsTheOldOriginPendingWhileTheReplacementLoads moved into a defer so a throw cannot skip it (review finding).
- ExtensionPrivateStoreTests' closed-gate leg expects its wait to run out, and polled by hand for that reason. It now uses pollUntil.
- TabHoverCardTests.waitUntilShowing is expectation-based and was left alone.

Tests: new WaitUntilTests (3 tests): the happy path, a timeout throwing WaitTimedOut with the failure recorded at the call-site line (via XCTExpectFailure), and pollUntil returning false without failing. Full suite under caffeinate (load 9-10): 3471 tests, 17 skipped, 0 failures. That run predates the review's defer edit, the pollUntil rename and WaitUntilTests, so ExtensionPageRehostTests and ExtensionPrivateStoreTests were rerun after those changes (22 tests, 0 failures), and WaitUntilTests was run on its own (3 tests, 0 failures). Test build: 0 concurrency warnings. /verify skipped (test-only).

Review (/code-review --fix): fixed the skipped-uninstall bug and renamed poll to pollUntil, because the name clashed with POSIX poll(2). Kept by design: the double report. Left as is: the rehost waits now time out at 10 s instead of 3 s and poll every 100 ms instead of 20 ms (the longer bound suits loaded runs).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A waitUntil timeout now fails the test at the wait, naming what was awaited and the timeout, and stops the test body by throwing WaitTimedOut. pollUntil is the non-failing variant. The private non-throwing waitUntil in ExtensionPageRehostTests was folded into the shared one, and the hand-rolled expected-timeout loop in ExtensionPrivateStoreTests now uses pollUntil. The full suite passed (3471 tests), and so did WaitUntilTests (3).
<!-- SECTION:FINAL_SUMMARY:END -->
