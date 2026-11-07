---
id: TASK-264
title: >-
  Extensions: a Private-profile extension stops receiving
  notifications.onClicked and onClosed once a Private session starts or ends
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T00:31:00Z'
labels:
  - extensions
  - notifications
  - private
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
  - Detour/Browser/TabStore.swift
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: medium
type: bug
ordinal: 311000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`TabStore.startPrivateSessionIfNeeded` and `endPrivateSessionIfUnused` (TabStore.swift ~2584-2607) call `removePrivateProfileNotifications`, which reaches `ExtensionNotificationManager.removeAll(profileID:)`. That also runs `dropEventChannels`, answering the worker's parked `notifications.awaitEvent` with "notifications: the extension was unloaded" (ExtensionNotificationManager.swift ~547-550, ~718-724).

The Private profile's extension contexts stay loaded between sessions (the comment on `startPrivateSessionIfNeeded` says so), so the worker is still alive. The polyfill's park loop (ExtensionAPIPolyfill.swift ~2519-2524) only re-arms after a refusal that matches the permission regex; the "unloaded" text sets `stopped = 'final'`, so the worker never parks again. The channel is recreated with `listens = false`, so later clicks and closes pile up in the backlog unseen until WebKit restarts the worker.

Effect: an extension allowed in Private loses every click/close event from the first Private window it opens. `testRemovingTheOwnerDropsItsChannel` only covers `removeAll(profileID:)` as "the profile is gone"; nothing covers a session boundary with a live worker.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After a Private session boundary (start or end) with the extension's worker still loaded, a click on a notification created afterwards reaches the worker's onClicked, and a dismiss reaches onClosed
- [x] #2 The session boundary still removes every Private-profile notification (delivered and pending) and the events queued for them, as TASK-238 requires
- [x] #3 Unloading the extension from the profile, and removing the profile, still answer the parked wait so the context stops waiting
- [x] #4 Tests cover a session boundary with a parked worker against the fake notification center
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionNotificationManager: add removeSession(profileID:) for a session boundary: removes the profile's notifications (delivered and pending, as removeAll does) and drops the events queued in its owners' channels, but keeps each channel's park, incarnation history and listens flag, so a live worker stays parked. removeAll(for:) / removeAll(profileID:) keep dropping the channels and answering the park (unload, profile deletion).
2. ExtensionPolyfillHandler: removeSessionNotifications() -> removeSession; TabStore.removePrivateProfileNotifications (session start, session end, quit) uses it; profile deletion keeps removeAllNotifications.
3. Tests: manager-level (park survives a boundary, backlog dropped, later click/close delivered, other profile untouched, removeAll still settles the park afterwards); TabStore-level with privateSessionStore; real Private-profile worker in ExtensionNotificationEventDeliveryTests across a start and an end boundary (onClicked + onClosed byUser).
4. Wiki polyfill-layer notification events section, wiki log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: ExtensionNotificationManager.removeSession(profileID:) (notifications delivered/pending + the owners' queued events go; each channel's park, incarnation history and listens flag stay). ExtensionPolyfillHandler.removeSessionNotifications() calls it; TabStore.removePrivateProfileNotifications (session start, session end, quit) now uses it. Profile deletion keeps removeAllNotifications -> removeAll(profileID:), and Profile.unloadExtension keeps removeAll(for:): both still answer the park 'notifications: the extension was unloaded' and forget the channel.

Decision: the boundary drops every queued event of the Private profile's owners, including a click made between sessions that a worker WebKit unloaded has not yet acknowledged (the code review raised it). Kept: those events belong to notifications of the ended session that the boundary takes away, which TASK-238 and AC #2 ask for. The polyfill side was left as is: 'unloaded' stays final, which AC #3 needs.

Tests: new ExtensionNotificationEventManagerTests.testASessionBoundaryKeepsTheParkAndDropsTheQueuedEvents (manager level: the park stands, queued events and notifications go, another profile is untouched, then a click and a dismissal reach the park, and removeAll(for:) / removeAll(profileID:) still settle it), ExtensionNotificationManagerTests.testAPrivateSessionBoundaryLeavesTheWorkersWaitStanding (TabStore start and end against the fake center), and ExtensionNotificationEventDeliveryTests.testAPrivateWorkerHearsEventsAcrossSessionBoundaries (a real Private-profile worker in the shared store: onClicked after the start and onClosed(byUser) after the end, in one incarnation). Both TabStore-level tests fail against the old wiring (park answered 'unloaded'; the real worker never got the click) and pass with the fix. Runs: ExtensionNotificationEventManagerTests + EventDeliveryTests + ManagerTests + OrderingTests 88 tests, 0 failures, 1 skipped (the gated unload leg). After the review fix (a precondition assertion in the new Private fixture): the review fork re-ran the notification suites + ExtensionWindowsCreatePrivateTests, 104 tests, 0 failures, 1 skipped.

Runtime (/verify): Debug build into .derived (dylib mtime matched), launched with DETOUR_DATA_DIR=DetourVerify264, ran cleanly (log: 'Not removing leftover extension notifications: another Detour process is running', as expected beside the production app); killed by PID; defaults keys and the data dir removed. Not verified at runtime: a real banner click/dismiss in a Private session. That would need a Private-allowed extension and posting real banners from the dev build; the real-worker test covers the path with the fake center.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A Private session starting or ending no longer stops the Private profile's extension workers hearing notifications.onClicked/onClosed. The boundary used removeAll(profileID:), which answered each worker's parked notifications.awaitEvent with 'the extension was unloaded'. The polyfill treats that as final, so a worker that was still loaded never parked again. Now TabStore.removePrivateProfileNotifications calls the new ExtensionNotificationManager.removeSession(profileID:) through ExtensionPolyfillHandler.removeSessionNotifications(): it takes the notifications (delivered and pending) and their queued events, as TASK-238 requires, but leaves the parks standing. Unloading the extension and deleting the profile still end the wait. Three new tests (manager, TabStore with the fake center, a real Private worker) fail on the old wiring and pass now; the notification suites pass (104 tests, 0 failures, 1 gated skip). Wiki polyfill-layer updated. Not run in the app: a real banner in a Private session.
<!-- SECTION:FINAL_SUMMARY:END -->
