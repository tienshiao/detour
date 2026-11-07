---
id: TASK-291
title: >-
  Tests: three background-page onInstalled cases time out again in a full run of
  the epic branch (4,052 tests) and pass alone
status: To Do
assignee: []
created_date: '2026-11-07T22:52:00Z'
labels:
  - bug
  - tests
dependencies: []
references:
  - DetourTests/ExtensionPolyfillProfileWiringTests.swift
  - wiki/platform/webkit-test-host-traps.md
  - wiki/playbooks/build-and-test.md
priority: low
ordinal: 338000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-166 (Done) fixed the full-run-only timeouts of the background-page runtime.onInstalled cases in ExtensionPolyfillProfileWiringTests: WebKit's network process fails after about 190 persistent data-store sessions, and since 7c2bc2a the test host terminates it every 60 new stores. That held for the epic branch at fd35b40 (3,860 tests, 0 failures).

On 2026-11-07, after merging main into epic-claude-extension (2f40cfd, 4,052 tests), a full DetourTests run failed three of the original four again:
- testMV3BackgroundPageGetsRuntimeOnInstalledOnce
- testMV3BackgroundPageGetsTheUpdateAfterAVersionChange
- testMV3BackgroundScriptsPageGetsRuntimeOnInstalledOnce
(testBackgroundPageDeclaredWithARelativePathGetsRuntimeOnInstalledOnce passed.)

Each is the shared 20 s wait, "timed out after 20.0 s waiting for the background page to be dispatched the install", followed by a caught InvalidTransition { phase: idle, targetPhase: failed(deinit) } at teardown. The wiring suite was the 59th of 234 suites to start. Run alone, the suite passes (67 tests, 13 skipped, 0 failures).

Different from TASK-166: the full-run log has no errno = 12 line, so the network-process exhaustion signature is absent. The log does show, around the failing cases, WebKit failing to take an RBS assertion ("XPCConnectionTerminationWatchdog ... target is not running") for a WebContent process, and pboard "Connection invalid" for the next one. That WebContent process may have been terminated or crashed while the background page loaded.

Not known: whether main fails too (main has fewer tests, and its last full runs passed); whether it is the same exhaustion at a lower threshold, another process-level limit, or a background page whose WebContent process dies.

Why it matters: the project rule is that the affected suites pass before a commit, and standing failures force a baseline run on the parent for every full run of the epic.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause is identified and explained: what state of the shared test host stops the background page from answering, and why it now shows at the epic's test count
- [ ] #2 It is stated whether main fails too
- [ ] #3 The fix is in the right place: test isolation if the problem is the test host's, product code with a regression test if a real extension could hit it
- [ ] #4 Three full DetourTests runs of the epic branch in a row pass all four background-page onInstalled cases
- [ ] #5 The wiki page for the cause (webkit-test-host-traps or build-and-test) records what was found
<!-- AC:END -->
