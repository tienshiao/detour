---
id: TASK-166
title: >-
  Tests: four ExtensionPolyfillProfileWiringTests background-page onInstalled
  cases time out in a full-suite run and pass alone
status: To Do
assignee: []
created_date: '2026-10-04 21:51'
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
- [ ] #1 The earlier suite or suites that make the four cases fail are identified, with a minimal -only-testing order that reproduces the failure
- [ ] #2 The cause is explained: what state crosses from the earlier suite and why it stops the background page answering the test's probe
- [ ] #3 It is stated whether main is affected or only the epic branch
- [ ] #4 The fix is in the right place: test isolation if the leak is the test's, product code with a regression test if a real extension would hit it
- [ ] #5 A full DetourTests run passes these four cases three times in a row, and wiki/playbooks/build-and-test.md section 8 is updated with the cause
<!-- AC:END -->
