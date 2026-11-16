---
id: TASK-353
title: Code comments contradicted by later tasks, and RuntimeInstalledEvent's NSLock
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T05:37:00Z'
updated_date: '2026-11-16T09:56:00Z'
labels:
  - cleanup
  - concurrency
dependencies: []
references:
  - Detour/Browser/Profile.swift
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
  - Detour/Extensions/Runtime/RuntimeInstalledEvent.swift
priority: low
type: chore
ordinal: 433000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in the wiki content lint (the wiki pages were corrected; the code comments were not). CLAUDE.md requires shared mutable state behind Synchronization.Mutex, never NSLock.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Profile.swift's comment that Private profile extension contexts 'live until quit' says what TASK-298 made true (a Private session end resets them)
- [x] #2 ExtensionAPIPolyfill.swift's watchPort comment agrees with TASK-142/TASK-263's measurements of WebKit's removePort
- [x] #3 ProvisionalInstalledEventClaims in RuntimeInstalledEvent.swift uses a Mutex instead of NSLock, with its tests passing
- [x] #4 docs/harness/task175-176-harness.patch no longer says data: URLs do not load (TASK-159)
- [x] #5 SettingsMetrics.designMaximumContentHeight's comment gives the current reason for 720 pt (the user's decision 2026-11-15: Profiles, ~1008 pt on the grouped form, opens at the cap and scrolls), not 'so Profiles opens whole'
- [x] #6 BrowserCommands.fixedShortcuts no longer marks Cut/Copy/Paste/Select All PROVISIONAL (the user's decision 2026-11-15: they stay fixed)
- [x] #7 HistoryDatabase.swift's comment above the title-maintenance triggers names the actual delete APIs and lists importVisits among the visit writers
- [x] #8 BrowserTab.wakeConfiguration's doc comment no longer says the space configuration has no handler for the webkit-extension scheme: WebKit installs the handler on every web view of the controller and refuses a main-frame load unless _requiredWebExtensionBaseURL names the extension (TASK-352)
- [x] #9 The doc comment on restartUnresponsiveBackground and the nativePortKeepAliveJS paragraph no longer blame an offscreen document's close for the worker terminating (TASK-68: the ITP pass in the same millisecond was the trigger)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Mutex: ProvisionalInstalledEventClaims keeps entries in a Synchronization.Mutex (prune+insert in one withLock; identity check+removal in withLock, undo outside), keeping the class's isolation; run RuntimeInstalledEvent* suites.
2. Comments: Profile.swift Private contexts (TASK-298 resetPrivateSession); polyfill watchPort comment (collected port removed without listeners, next ping re-anchors; TASK-142/263); task175-176 harness patch data: line (TASK-159); SettingsMetrics 720 pt reason (user decision 2026-11-15); ShortcutBindings fixedShortcuts no PROVISIONAL; HistoryDatabase trigger comment names the three deleteVisits APIs + importVisits.
3. Wiki: drop the 'still says / planned in TASK-353' sentences in settings-window-height, keyboard-shortcuts, native-port-keep-alive; lint; log line.
4. Build + tests, code review, backlog notes, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Chosen by Claude (lead agreed; not yet confirmed by the user): ProvisionalInstalledEventClaims keeps its record in a Synchronization.Mutex, as AC #3 asks. The class is main-actor by default isolation (no nonisolated, no @unchecked Sendable) and both callers are main-actor, so the lock is uncontended; alternative: drop the lock outright as TASK-244 did for main-actor test doubles.
AC #4: the harness patch line now says a file: URL goes to the external-app path and data: loads since TASK-159 (schemesLoadedInTheBrowser has data, not file). The patch still parses (git apply --stat); it no longer applies to today's AppDelegate, and the original did not either.
AC #9 (added by the lead): restartUnresponsiveBackground's doc comment and the nativePortKeepAliveJS doc paragraph now name the ITP purge (TASK-68's correction, TASK-70) as the trigger; the offscreen close is recorded as the coincidence it was.
Wiki: native-port-keep-alive (stale-comments gotcha rewritten), settings-window-height, keyboard-shortcuts; lint 0 errors, 0 warnings; log line added.

Tests (2026-11-16, lane-a, sandbox off, .derived): RuntimeInstalledEventTests + RuntimeInstalledEventLoadFailureTests 33/33, run twice (before and after the review's comment edits). onInstalled real-context tests: NewProfileExtensionLoadTests (incl. the TASK-134 failing-worker case) 9/9, the 7 ExtensionPolyfillTests testRuntimeOnInstalled*, the 5 ExtensionPolyfillProfileWiringTests onInstalled tests and WKExtensionIntegrationTests.testRuntimeOnInstalledIsNotDelivered: 22/22, 0 failures. No /verify: no UI or behaviour change (comments plus a lock swap), per the brief.
Review: /code-review medium --fix found no correctness bugs; it fixed four comment issues (Mutex comment overclaimed protection off the main thread, harness claim narrowed to a Detour-hosted offscreen close, two rewraps). Its wiki finding (sentences recording TASK-353 as change history = status) was applied by me: the three pages now state the fact only, and the task-353 sources were dropped. Wiki lint 0 errors, 0 warnings.
Not verified: nothing at runtime; the harness patch parses (git apply --stat) but did not apply to today's AppDelegate before this change either.

2026-11-16: the user confirmed: ProvisionalInstalledEventClaims keeps its record in a Mutex rather than dropping the lock.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Code comments brought in line with the tasks that superseded them: Private contexts reset at Private-session end (TASK-298, Profile.swift); a collected port's removal runs no onDisconnect listeners (TASK-142, watchPort); data: URLs load since TASK-159 (harness patch); the 720 pt Settings cap with Profiles scrolling, and Cut/Copy/Paste/Select All fixed (the user's 2026-11-15 decisions); the history triggers' writer list (importVisits, the three deleteVisits APIs); wakeConfiguration's reason is WebKit's _requiredWebExtensionBaseURL gate (TASK-352); the worker termination blamed on the ITP purge, not an offscreen close (TASK-68/70). ProvisionalInstalledEventClaims keeps its record in a Synchronization.Mutex instead of NSLock (main-actor class, so uncontended; dropping the lock is the alternative). Wiki: native-port-keep-alive, settings-window-height, keyboard-shortcuts. RuntimeInstalledEvent suites 33/33 and 22 onInstalled real-context tests passed.
<!-- SECTION:FINAL_SUMMARY:END -->
