---
id: TASK-271
title: >-
  Extensions: a notifications.update whose add fails also removes the
  notification it was updating
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T00:56:00Z'
labels:
  - extensions
  - notifications
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 318000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

On a failed `add`, `ExtensionNotificationManager.addFinished` (~480-486) calls `removeEntry` and `removeNotifications` for the shared identifier. For an update that means the update answers `wasUpdated: false` but the notification the earlier create showed is gone too. Chrome leaves the original in place. `add` rarely fails, hence low priority.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A failed update answers wasUpdated false and leaves the original notification shown and listed by getAll
- [x] #2 A failed create still leaves no entry behind
- [x] #3 Tests cover both with the fake center failing add
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Entry gains fallbacks: an update records the entry it replaces (generation + shown options), newest first, followed by that entry's own fallbacks; a create starts with none.
2. addFinished: a current update whose add fails restores its newest fallback as the entry (no center removal: the earlier add's notification still shows, or its own add settles it). A current create that fails keeps today's behaviour (drop + remove).
3. Superseded adds keep the chain honest: one that fails, or is skipped because it was superseded during authorization (never added), is excised from the current entry's fallbacks; one that succeeds drops the older fallbacks; a current success clears them (bounded memory).
4. Tests in ExtensionNotificationManagerTests against HeldNotificationCenter (release failing:): failed update after a shown create keeps the original listed/shown with its options; failed update while the create is in flight; failed update after the create already failed; chained updates; failed create leaves no entry. Rewrite testFailedUpdateAnswersFalseAndDropsTheEntry.
5. Doc comments + wiki polyfill-layer failed-add paragraph, wiki log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision: only an update falls back. A create for an id the owner already has replaces outright (Chrome's create does not merge), so its failed add still drops the entry and takes the old banner away (AC2; testFailedCreateOverAShownNotificationLeavesNoEntry). The fallback chain lives on Entry.fallbacks (generation + shown options, newest first); a superseded add that fails or is skipped during the authorization wait is dropped from it, a superseded add that succeeds prunes older ones, a current success clears it.
Tests: ExtensionNotificationManagerTests 58/0 (9 new or rewritten failure tests, incl. one added by /code-review), ExtensionNotificationOrderingTests 21/0, ExtensionNotificationEventManagerTests + ExtensionNotificationEventDeliveryTests 21/0 (1 skipped: the TEST_RUNNER_NOTIFICATION_UNLOAD_LEG-gated leg).
/code-review --fix: fixed a stale Entry.generation doc, a wiki line break, and added a test for the superseded-success prune. Left open (pre-existing in-flight-merge semantics, beyond this task): an update skipped during the authorization wait answers true even if the later update then fails and falls back past it; an update merges into an in-flight update's options, so a failed earlier update's fields can show through a later successful one.
Runtime: Debug build launched in an isolated data dir (Verify271) via the launcher; app started, cleaned up afterwards. A failing UNUserNotificationCenter.add cannot be induced in the running app, so the failure path itself is verified only by the fake-center tests.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A notifications.update whose UNUserNotificationCenter add fails now answers wasUpdated false and puts back the entry it replaced, so the notification the create (or an earlier update) showed stays listed by getAll, on screen, and merged into by the next update, as in Chrome. A failed create still drops its entry. Update entries carry the entries they replaced as fallbacks only while adds are in flight; failed or skipped generations are dropped from them. Covered by new HeldNotificationCenter tests (failed update after a shown create, while the create is in flight, with the create failing before or after, an update that superseded the create before its add, chained updates in both failure orders and with the earlier update shown first, failed create over a shown id). Wiki polyfill-layer updated. Follow-ups: the two in-flight-merge answers noted above.
<!-- SECTION:FINAL_SUMMARY:END -->
