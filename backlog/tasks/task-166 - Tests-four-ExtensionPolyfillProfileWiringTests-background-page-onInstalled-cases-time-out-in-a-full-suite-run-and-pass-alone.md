---
id: TASK-166
title: >-
  Tests: four ExtensionPolyfillProfileWiringTests background-page onInstalled
  cases time out in a full-suite run and pass alone
status: Done
assignee: []
created_date: 2026-10-04 21:51
updated_date: '2026-11-04T08:54:00Z'
labels:
  - bug
  - tests
dependencies: []
references:
  - DetourTests/ExtensionPolyfillProfileWiringTests.swift
  - wiki/playbooks/build-and-test.md
priority: low
ordinal: 189000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen on 2026-10-04 on the epic-claude-extension branch, during TASK-132.8: a full DetourTests run fails four cases of ExtensionPolyfillProfileWiringTests, all about a background *page* (not a worker) getting runtime.onInstalled:

- testMV3BackgroundPageGetsRuntimeOnInstalledOnce
- testMV3BackgroundPageGetsTheUpdateAfterAVersionChange
- testMV3BackgroundScriptsPageGetsRuntimeOnInstalledOnce
- testBackgroundPageDeclaredWithARelativePathGetsRuntimeOnInstalledOnce

The first failure in each is the shared wait at ExtensionPolyfillProfileWiringTests.swift:3362, 'timed out after 20.0 s waiting for the background page to be dispatched the install'; the assertions after it then read nil.

What is known:
- Order-dependent, not random: the same four failed in two full runs of the TASK-132.8 tree (2,090 tests) and in a full run of its unmodified parent 303519d (1,987 tests), so they predate TASK-132.8. The four pass when run alone, and the suite passes when it runs first.
- The app's own log lines are the same in the passing and failing runs: 'install pending ... waking its background context', 'runtime.onInstalled mode: detour (background-page)', 'delivering install', 'dispatching install to 1 listener(s)'. What fails is the test's question to the background page through an extension page, so the delivery itself may be fine and the test's probe path may be what breaks.
- Ruled out as the cause: ExtensionRuntimeGetContextsTests and ExtensionSidePanelTests (the wiring suite passes when run after those two).

What is not known:
- Which earlier suite causes it.
- Whether main fails too. Every run above was on the epic branch; main has not been checked.
- Whether it is a test-only problem (state an earlier suite leaves in the shared test host, for example a leaked extension context, profile or web view) or a product bug that only shows once the process has loaded many extensions.

Why it matters: the project's rule is that the affected suites pass before a commit. Four standing failures make every full run need a baseline comparison on the parent commit (about 9 minutes in a separate worktree) to show they are not from the change under test, and they would hide a real regression in background-page onInstalled delivery.

Where to start: bisect the suite order with -only-testing (the wiring suite plus half of the suites that run before it) until one earlier suite is enough to make the four fail. wiki/playbooks/build-and-test.md section 8 (on the epic branch until it merges) has the technique used for the neighbouring leak found the same day, a closed test window kept alive by BrowserTab.releaseWebView: weak boxes of each test's objects printed at tearDown, and leaks --traceTree from inside the test host.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The earlier suite or suites that make the four cases fail are identified, with a minimal -only-testing order that reproduces the failure
- [x] #2 The cause is explained: what state crosses from the earlier suite and why it stops the background page answering the test's probe
- [x] #3 It is stated whether main is affected or only the epic branch
- [x] #4 The fix is in the right place: test isolation if the leak is the test's, product code with a regression test if a real extension would hit it
- [x] #5 A full DetourTests run passes these four cases three times in a row, and wiki/playbooks/build-and-test.md section 8 is updated with the cause
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-04, after merging main into epic-claude-extension (6cb00e3): a full run (2,382 tests, 12 skipped) fails seven cases of this suite, not four. The four in the description, plus:

- testAnExtensionTabNavigatedToTheBackgroundPathCannotClaimTheInstalledEvent
- testAnIframeOfTheBackgroundPagePathDoesNotClaimTheInstalledEvent
- testASupersededKeepAlivePortStopsInsteadOfReconnecting

The first two fail at the same shared wait (line 3362, 'timed out after 20.0 s waiting for the background page to be dispatched the install'); the third fails with 'no heartbeat from the real background page' (line 2987). So the common symptom is a background page that does not answer, not onInstalled in particular. The suite alone on the same build passes: 50 tests, 7 skipped, 0 failures. No other suite failed in the full run. The suite runs 41st of 141. Not checked: whether the three extra cases come from main's changes or from the changed set of suites that run before this one; main alone has still not had a full run.

2026-10-10, after merging main (c37c76a: TASK-167/168/169) into epic-claude-extension: a full run (2,415 tests, 12 skipped) fails eight cases of this suite: the seven above plus testAnOrdinaryExtensionPageCannotClaimTheInstalledEventThroughTheBridge, with the same 20 s wait. No other suite failed. The suite alone on the same build passes again: 50 tests, 7 skipped, 0 failures. So the eighth case is the same order-dependent symptom, not something the merge broke in that test; why it joined the list in this run is not known.

main at db9024b had a full run the same day (2,095 tests, 11 skipped) with 0 failures, so main is not affected by this in a full run (AC #3).

Separately, on main the same day: ExtensionOriginTrackingPreventionTests.testTrackingPreventionPassSparesOriginsWithALoggedInteraction passed in one full run, then timed out ('waiting for the uninteracted origin's localStorage to be deleted', 30 s) in a full run on main + TASK-169 and twice alone a few minutes later, on that branch and on main; it passed again in the epic's full run half an hour after that. Not investigated; recorded here because it is another test whose result changed with no code change.

2026-10-12, task sweep: main is not affected, as far as full runs show. The four cases passed in every full DetourTests run of main-based code on 2026-10-12 (four runs while TASK-175/176 were developed, the last at what is now main's tip 829d88a: 2,180 tests, 0 failures), and in the full run of main at db9024b on 2026-10-10. The failures have only been seen on epic-claude-extension. Criteria 1, 2, 4 and 5 are open.

2026-11-04: Cause found on main during TASK-257 (fix 7c2bc2a). WebKit's single network process fails after about 190 persistent data-store sessions over its lifetime: sandbox extensions fail with errno = 12, and localStorage silently keeps nothing. So the background page's probe result was lost once a full run had created enough stores. No single earlier suite causes it; the cause is the number of stores (AC #1 is answered by that: there is no minimal poisoning suite, it is the cumulative store count). It is test-only: the app creates one store per profile. Fix in TestEnvironmentSetup: terminate the network process between suites every 60 new recorded stores. Full runs with the cases passing: main at 7c2bc2a (3570 tests, 0 failures); epic-claude-extension after merging main, at 45f5da1 (the wiring suite passed whole, 53 passed, no errno = 12) and at fd35b40 (3860 tests, 0 failures). Wiki: wiki/platform/webkit-test-host-traps.md 'Network process exhaustion', and a new trap in wiki/playbooks/build-and-test.md (the epic's section 8 is not on main).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The full-run-only background-page onInstalled failures were WebKit network-process exhaustion (about 190 persistent stores per process lifetime; errno = 12; localStorage keeps nothing), not a leak from one suite. Fixed test-side in 7c2bc2a: the test host restarts the network process every 60 new stores. Passed in three full runs: main 7c2bc2a, and the epic branch at 45f5da1 and fd35b40.
<!-- SECTION:FINAL_SUMMARY:END -->
