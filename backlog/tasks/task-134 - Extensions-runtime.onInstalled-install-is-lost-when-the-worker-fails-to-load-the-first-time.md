---
id: TASK-134
title: >-
  Extensions: runtime.onInstalled 'install' is lost when the worker fails to
  load the first time
status: Done
assignee: []
created_date: '2026-10-04 01:54'
updated_date: '2026-10-04 08:46'
labels:
  - bug
  - extensions
dependencies: []
priority: medium
ordinal: 157000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-03 during TASK-132.4 with the Claude extension (before its load failure was fixed on the epic branch).

Detour delivers runtime.onInstalled itself. The polyfill's runtimeOnInstalledJS schedules a claim with setTimeout(claim, 0) (ExtensionAPIPolyfill.swift, scheduleClaim); the handler's 'runtime.claimInstalledEvent' case (ExtensionPolyfillHandler.swift) calls AppDatabase.claimRuntimeInstalledEvent(extensionID:profileID:isPrivateProfile:currentVersion:) (Detour/Storage/Database.swift), which reads the owed event and saves the ledger row in one transaction. Its doc comment states the design: the ledger advances before the worker dispatches, so a worker that dies in between loses the event rather than risking it twice.

The hole: the polyfill module is imported before the extension's own modules, so its timer is queued first and still fires when the extension's module evaluation then throws. Observed on the unmodified Claude extension (log .claude/scratch/task132.4/02-baseline-log.txt in the main checkout, untracked): 17:44:02.734 uncaught exception in the extension's module; 17:44:02.736 'runtime.onInstalled: delivering install (previous none, now 1.0.98)'; 17:44:02.737 'The background content failed to load'. The three recovery reloads that followed logged no further delivery. So 'install' was consumed by a worker that had registered no listener, and an extension whose first load fails never receives 'install' once a later version (or a fixed environment) loads. The ledger row was not read in that failing run; it was read as 1.0.98 in a later successful one.

The same shape applies to 'update': a new version whose worker fails at load consumes the 'update' event.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A test reproduces it: an extension whose worker throws at module evaluation on its first load, then loads successfully, receives onInstalled with reason install on the successful load
- [x] #2 An event is recorded as delivered only when a listener was actually there to receive it (or the equivalent rule chosen), and that rule is written in the claim's doc comment and docs/extensions.md
- [x] #3 The existing guarantee holds: an event is never delivered twice, including across the automatic context reloads after a background load failure and across a relaunch
- [x] #4 The same holds for reason update
- [x] #5 The existing onInstalled tests (RuntimeInstalledEvent, the polyfill and profile-wiring suites) pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. The polyfill's claim reports how many onInstalled listeners the context has (listeners).
2. RuntimeInstalledEvent.claimDisposition(listenerCount:backgroundLoadFailed:) decides: a listener -> deliver; none and the context already lists backgroundContentFailedToLoad -> withhold; none and no failure yet -> deliver provisionally.
3. A provisional claim is remembered with the claiming context (ProvisionalInstalledEventClaims) and undone (AppDatabase.undoRuntimeInstalledEventClaim) when Profile's error observer sees that context fail to load.
4. Tests: the rule, the undo and its refusals, the provisional record; real workers that throw at evaluation, for install and for update.
5. Doc comment on the claim, docs/extensions.md, wiki/extensions/runtime-installed-event.md.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Rule chosen (AC #2): an event is recorded as delivered when the claiming context had a listener, or had none and its background content did not fail to load. Refusing every listener-less claim was rejected: an extension that does not listen would never settle, so wakeForPendingInstalledEvent would start its worker at every launch and a later version that adds a listener would be told 'install' instead of 'update'. A claim that found a listener is never undone, which is what keeps AC #3 (never twice): a listener registered before a later throw may get the event in a dying worker, the same accepted loss as before.
Measured order (test host log): the failing worker's claim reaches the handler ('delivering install …, 0 listener(s)') about 0.5 ms BEFORE errorsDidUpdate reports backgroundContentFailedToLoad, so the path that matters is provisional-then-undo; 'withhold' covers a claim that arrives after the report. Each of the three recovery reloads repeats it.
Reproduction (AC #1, #4), with the old rule forced by a temporary switch: NewProfileExtensionLoadTests.testInstallSurvivesAWorkerThatFailsToLoad and testUpdateSurvivesAWorkerThatFailsToLoad both failed — ledger ['1.0.0'] after the failed loads instead of [] / ['0.9.0'], and the working worker then got no event.
With the fix: NewProfileExtensionLoadTests 8/8, RuntimeInstalledEventLoadFailureTests 14/14, RuntimeInstalledEventTests 19/19. The polyfill and profile-wiring suites (AC #5) run in the integrated pass.
Limits: the provisional record is in memory (a quit between a listener-less claim and its failure report keeps the ledger advanced); a context that still lists an old load failure withholds listener-less claims until it is replaced.

Integrated on branch bugfix-batch; full DetourTests suite there: 1970 tests, 11 skipped (gated measurement legs), 0 failures. Code review of the batch range run with --fix. The polyfill, profile-wiring and RuntimeInstalledEvent suites are part of that run.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A background context whose script throws still sends the polyfill's onInstalled claim (about 0.5 ms before WebKit reports the load failed), and the ledger recorded the event as delivered to nobody. The claim now reports its listener count. With a listener it is a delivery; without one it is recorded provisionally and undone when that context reports backgroundContentFailedToLoad (or withheld if the failure is already listed), so the context that eventually loads still owes install or update. A claim that found a listener is never undone, so nothing is delivered twice. Verified by real-worker tests for install and update (failing before the fix), rule/undo/provisional unit tests, and the full suite. Not verified in the launched app with the Claude extension.
<!-- SECTION:FINAL_SUMMARY:END -->
