---
id: TASK-234
title: >-
  Extensions: notifications.clear issued while notifications.create is still
  adding the notification is lost
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T03:00:00Z'
updated_date: '2026-11-03T05:36:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 278000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-231.4 (pre-existing). ExtensionNotificationManager.create records the notification in its maps only once UNUserNotificationCenter.add returns. An extension that calls notifications.create('x') and then notifications.clear('x') without awaiting: clear runs removeDeliveredNotifications before the notification exists and finds nothing in the maps; when add returns, the entry is recorded and the banner shows, so getAll lists a notification the extension cleared. Since TASK-231.4 the bookkeeping is on the main actor, so the fix is about ordering, not threads.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A clear (and an update) issued while the create is still in flight takes effect: the notification is not shown, or is removed once added, and getAll does not list it
- [x] #2 Tests cover create-then-clear and create-then-update without awaiting, in a real extension context and at the manager level
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a minimal ExtensionNotificationCenter protocol seam (add / remove by identifier) with a UNUserNotificationCenter-backed implementation; ExtensionNotificationManager takes it in init, shared keeps the system center and the delegate.
2. Record the entry (with a per-create generation token) before calling add. clear removes the entry and the delivered/pending notification at once; when an add returns and its entry is gone, the manager removes the notification again; when a newer create owns the identifier (generation differs), the stale add does nothing. A failed add removes its entry only if it is still the current generation. update sees a pending entry and re-creates. getAll lists pending entries.
3. ExtensionPolyfillHandler gets an injectable notificationManager (default .shared) so the real-context tests can use a gated fake center.
4. Tests: manager level (create-then-clear, create-then-update, create-clear-create, failed add, another extension's clear) with a fake center whose add waits for release; real extension context in ExtensionPolyfillIntegrationTests for page and worker transports.
5. API Explorer notifications page: add a create-then-clear button if it fits. Wiki note, /code-review --fix, /verify, suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision: record the entry before add (approach 1), not per-id serialization. create records the entry with a fresh generation before calling the center's add. clear drops the entry and removes the notification at once; when an add returns and its entry is gone, the manager removes the notification again (the clear's removal can reach the center before the notification does). update finds the in-flight entry and re-creates (wasUpdated true). create, clear, create again: the first add returning sees a newer generation and does nothing, the second notification stands (the newer add replaces what the first showed). getAll lists in-flight entries. A failed add drops its entry only if it is still the current generation, and removes whatever is shown under the id so getAll and the screen agree. Serialization was rejected: a queue per id, clear would wait on the add, and getAll still needs an answer in between.
Seam: none existed (existing tests hit the real UNUserNotificationCenter with no authorization request; nothing in Detour calls requestPermission()). Added ExtensionNotificationCenter (add / removeNotifications) with SystemExtensionNotificationCenter; ExtensionNotificationManager(center:) for tests, shared keeps the system center and is its delegate. ExtensionPolyfillHandler.notificationManager (lazy, default .shared) is the handler-level seam, like historyDatabase.
Tests: ExtensionNotificationManagerTests (14, HeldNotificationCenter holds each add until released) and ExtensionNotificationOrderingTests (4, production profile wiring, page + worker transports, plus another extension's clear in the same profile). The real-context suite uses Profile.extensionController rather than ExtensionPolyfillIntegrationTests' hand-built controller, because a worker's polyfill request finds its handler through Profile.profile(owning:) and that controller has no owning profile. With the old ordering restored temporarily, 9 of the 18 tests fail (clear and update legs of both suites). Permission gating: notifications.* has no native permission gate (pre-existing, unchanged); not tested here.

Review (/code-review --fix): 9 findings, 1 fixed — update now answers wasUpdated false when its add fails (a failed add drops the entry and removes the shown notification), with testFailedUpdateAnswersFalseAndDropsTheEntry. Skipped as out of scope or behaviour changes: notifications are keyed by extensionID:notificationID only, so the same extension in two profiles (including Private) shares and can clear the other profile's notifications (pre-existing); clear always answers true (Chrome reports whether it existed); requestPermission() is never called; update replaces rather than merges options; a dismiss response ignores generations (unreachable without a dismiss category); callback-form and cross-profile real-context legs not added; getAll scans all entries.
Tests run: ExtensionNotificationManagerTests 15/15, ExtensionNotificationOrderingTests 4/4 (page + worker), ExtensionPolyfillTests 180/180, ExtensionPolyfillIntegrationTests 26 with 1 failure = testStorageManagedInRealExtensionContextSurvivesGarbageCollection 'no collection observed in 10 rounds' (the GC precondition, unrelated), passed on a rerun alone; ExtensionPolyfillProfileWiringTests 62 (13 env-gated skips, 0 failures); WebKitDelegateReachabilityTests 0 failures. With the old record-after-add ordering restored temporarily, 9 of the 18 new tests failed.
/verify: Debug build in DETOUR_DATA_DIR=DetourVerify234 with API Explorer seeded (permission rows) and a start-up snippet appended to the seeded copy's background.js calling its new notificationCreateThenClear handler from the worker: {wasCleared:true, listedAfterClear:false, notifications:{}}; a plain awaited create was listed by getAll and its clear emptied it; no 'Failed to create notification' error, so the real center accepted the adds (this machine's bundle id is authorized). Not verified: that no banner flashes on screen (only a screenshot ~20 s later, showing none); the API Explorer popup buttons were not clicked.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
notifications.clear and notifications.update issued while notifications.create is still adding the notification now take effect. ExtensionNotificationManager records the entry (with a per-create generation) before the center's add; clear drops it and removes the notification, and removes it again when the in-flight add returns; update finds the in-flight entry; a create superseded by a later create for the same id leaves the newer one alone, so create-clear-create shows the second notification. update answers false when its add fails. A minimal ExtensionNotificationCenter seam (UNUserNotificationCenter-backed in production) and ExtensionPolyfillHandler.notificationManager let tests hold adds in flight. Tests at the manager level (15) and from a real extension page and worker through the production profile wiring (4). API Explorer gains a Notifications section with create-then-clear from the worker and the popup. Follow-ups: per-profile notification isolation, clear's wasCleared, requesting notification authorization, update merging options.
<!-- SECTION:FINAL_SUMMARY:END -->
