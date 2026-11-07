---
id: TASK-273
title: >-
  Extensions: an unanswered notification authorization prompt stalls
  notifications.create in every profile
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T01:36:00Z'
labels:
  - extensions
  - notifications
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 320000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`ExtensionNotificationManager.authorize()` (~331-350, TASK-253) has every create and update in every profile wait on the one in-flight authorization request, with no timeout. If the user leaves the macOS prompt sitting in Notification Center, every `await chrome.notifications.create(...)` hangs indefinitely and the pending entries pile up.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A create or update made while authorization is unanswered gets an answer within a bounded time (created and shown once authorized, or refused/queued with the behaviour recorded)
- [x] #2 Pending entries waiting on authorization are bounded
- [x] #3 Tests drive an authorization request that never completes with the fake center
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Chrome answers notifications.create once the notification is handed to its display service; it never waits on the OS permission. Keep TASK-253's wait for an answered prompt but bound it: once the prompt has been up for authorizationAnswerTimeout (5 s, well inside WebKit's 30 s worker unload timer), every create/update waiting on it is answered (create: its id; update: true) and stays recorded; it is shown once the user allows, dropped as today if they decline. Shows joining a check already past the timeout are answered at once. The timeout is scheduled only when the status is not determined (just before requestAuthorization), so a status-only check schedules nothing.
2. While the prompt is up, bound the shows waiting on it per owner (authorizationWaitLimit = 32). One past the limit is refused as a failed add (TASK-271 semantics): a create's entry goes, an update puts back the entry it replaced; create still answers its id, update answers false. A burst joining a status-only check is never limited.
3. Timeout injected through the scheduleAuthorizationTimeout seam; tests fire it by hand.
4. Tests in ExtensionNotificationManagerTests and one ExtensionNotificationOrderingTests test from both transports with a prompt that never completes.
5. Wiki polyfill-layer, log, finalize.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (AC1): answer, not refuse. Chrome's notifications.create answers as soon as the notification is handed to its NotificationDisplayService and never waits on the macOS permission, so answering after a bounded wait is the closest match; refusing would surface an error Chrome never gives. 5 s lets a user who answers promptly give the real answer and stays well inside WebKit's 30 s unload of a worker whose reply is pending. Create answers its id, update true (both are recorded); each is shown once allowed, or dropped silently (no onClosed, as with TASK-253's decline) if declined.
Decision (AC2): per-owner limit of 32 shows waiting on one prompt (another owner is counted separately); one past it is settled as a failed add (a create answers its id but is neither listed nor added; an update answers false and restores the entry it replaced, TASK-271). Shows cleared or superseded while waiting still count, as each still holds a waiting task and continuation; so a progress-bar extension updating more than 32 times while the prompt is up gets false for the rest, and 33 creates of the same id while the prompt is up end with the 33rd's failed-add removing the id (a later create replaces outright, as before).
Code review (/code-review --fix, 6 findings): fixed the two real ones in one change - the wait limit and the timeout applied to every check, including the status-only read every create does once authorized, so a 40-create burst while the status XPC was in flight refused 8 of them, and every create spawned a 5 s sleeping task. Now both apply only while prompting (AuthorizationCheck.prompting); the fake center can hold status queries, and testABurstPastTheLimitWhileTheStatusIsReadIsShownInFull covers it. Skipped as design choices: counting superseded/cleared waiters, failed-add semantics for a refused same-id create, silent drop on a later decline, uncancellable timeout task (now only per real prompt).
Tests: ExtensionNotificationManagerTests 65/0 and ExtensionNotificationOrderingTests 23/0 (88 total, after the review fix); ExtensionNotificationEventManagerTests + ExtensionNotificationEventDeliveryTests 28, 0 failures, 1 skipped (the env-gated unload leg).
New tests: testUnansweredPromptAnswersTheWaitingCallsAfterTheTimeoutAndShowsThemOnceAllowed, testUnansweredPromptThenDeclinedDropsTheAnsweredCreates, testAnEarlierChecksTimeoutDoesNotAnswerALaterCheck, testCreatesPastTheWaitLimitAreRefused, testAnUpdatePastTheWaitLimitLeavesTheNotificationItWasUpdating, testABurstPastTheLimitWhileTheStatusIsReadIsShownInFull (manager); testUnansweredPromptAnswersCreateAndUpdateFromBothTransports (ordering, page + worker, fake center holding the prompt forever).
Runtime: /verify built the Debug app into .derived (dylib mtime matched), launched it via launch-detour.sh with DETOUR_DATA_DIR=DetourVerify273, it came up and wrote its databases, killed by PID; defaults keys and data dir removed. Not verified at runtime: the real prompt path - triggering a notification or authorization prompt for com.detourbrowser.mac is the user's decision (shared with the production app), so the unanswered-prompt behaviour is covered only by the fake center.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
An unanswered macOS notification prompt no longer stalls notifications.create/update in every profile. Once the prompt has been up 5 s, every create and update waiting on it is answered (create its id, update true) and stays recorded; it is shown once the user allows, or dropped if they decline - closest to Chrome, which never waits on the OS permission. While the prompt is up, at most 32 of one owner's calls wait on it; one more is settled as a failed add. The timeout is injected (scheduleAuthorizationTimeout) and scheduled only when actually prompting. Tests: 88/0 manager+ordering, 28 event tests (1 env-gated skip). Real prompt path not exercised at runtime (user's decision).
<!-- SECTION:FINAL_SUMMARY:END -->
