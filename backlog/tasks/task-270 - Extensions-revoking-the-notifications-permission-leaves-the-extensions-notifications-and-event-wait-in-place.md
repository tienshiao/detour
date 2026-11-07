---
id: TASK-270
title: >-
  Extensions: revoking the notifications permission leaves the extension's
  notifications and event wait in place
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T00:46:00Z'
labels:
  - extensions
  - notifications
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 317000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

Neither the Settings switch nor the extension's own `permissions.remove` of an optional `notifications` touches `ExtensionNotificationManager`. The banners stay in Notification Center, the parked `awaitEvent` stays parked, and `deliver` (ExtensionNotificationManager.swift ~697-713) answers a park admitted before the revocation without checking the permission again, so a click on an old banner still fires onClicked. Meanwhile `notifications.clear` is refused (TASK-239 gate), so the extension cannot take its own banners down.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 When notifications stops being active for an extension in a profile (Settings switch off, permissions.remove of the optional permission), its notifications in that profile are removed and no further onClicked/onClosed is delivered
- [x] #2 The parked wait is answered with the permission refusal, so the polyfill re-arms after a later grant (TASK-250 behaviour)
- [x] #3 Tests cover both revocation paths
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionNotificationManager.revoke(for:refusal:): remove the owner's entries (center removal included), clear its backlog, answer the park with the given refusal, keep the channel (instances, listens).
2. ExtensionPolyfillHandler.revokeNotificationsIfNotPermitted(ofExtension:): if permissionRefusal("notifications") is non-nil, call revoke with that refusal (existing manager only).
3. ExtensionManager.revokeNotificationsWhereNotPermitted(extensionID:) over every profile's handler; called from applySavedDecisions (setPermissionDecision, clearRemovedGrants) and from contextDidLoseGrants when the removed set holds notifications (covers a removal with no saved row).
4. Tests: manager-level revoke test; real-worker tests for the Settings switch (required) and permissions.remove (optional, two profiles), each checking removal, no onClicked, and the same worker re-parking after a new grant.
5. Wiki polyfill-layer + permissions, log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented as planned. ExtensionNotificationManager.revoke(for:refusal:) takes the owner's notifications (center included) and queued events, answers the park with the handler's permission refusal, and keeps the channel (incarnations, listens). ExtensionPolyfillHandler.revokeNotificationsIfNotPermitted(ofExtension:) calls it when permissionRefusal("notifications") is non-nil. ExtensionManager.revokeNotificationsWhereNotPermitted(extensionID:) sweeps every profile's handler: from applySavedDecisions when the keys hold the notifications API permission (setPermissionDecision, clearRemovedGrants) and from contextDidLoseGrants when the removed set holds notifications (covers a grant with no saved row). State-based, so repeats are no-ops.

Decisions:
- No onClosed fires for the notifications taken away: the extension no longer holds the permission whose events those are (Chrome does not dispatch notification events to an extension without the API), and AC #1 asks for none.
- A permissions.remove in one profile clears the saved grant, so every profile's context loses it (existing TASK-258 behaviour) and every profile's notifications go.
- The park is answered with permissionRefusal's text ("denied by the user" / "is optional and has not been granted"), which the polyfill's regex classes as 'permission', so it re-parks at the next notifications call after a grant.

Known gap (not closed): after permissions.remove, WebKit posts the grant removal to the main queue after its write; a click handled in that window still reaches onClicked through the earlier park. No earlier hook exists.

Tests: ExtensionNotificationEventManagerTests 11/11 (new testRevokingThePermissionAnswersTheParkWithTheRefusal); ExtensionNotificationEventDeliveryTests 10 (1 gated skip), new testTheSettingsSwitchOffTakesTheNotificationsAndAnswersTheWait, testPermissionsRemoveTakesTheNotificationsInEveryProfile (two profiles), testPermissionsRemoveWithoutASavedGrantStillTakesTheNotifications. With ExtensionNotificationManagerTests, ExtensionNotificationOrderingTests, ExtensionHistoryScopeTests, ExtensionPermissionRestoreTests: 186 run, 1 skipped, 0 failures. Negative controls: with the sweep disabled, the switch and remove tests fail (the old banner's click reached onClicked); with the contextDidLoseGrants sweep disabled, the unsaved-grant test fails.
/code-review --fix: no correctness bugs; gated the applySavedDecisions sweep on the notifications key and fixed a doc comment; suites re-run after it.
Runtime: Debug build launched in an isolated DETOUR_DATA_DIR (DetourVerify270), launched cleanly, quit by PID, defaults keys and data dir removed. The revocation itself is not observable without an installed extension showing a real banner; not verified at runtime beyond build+launch (covered by the real-worker tests).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Revoking notifications for an extension in a profile (Settings switch off, or the extension's permissions.remove of the optional permission) now takes its notifications there off screen with their queued events and answers its parked awaitEvent with the permission refusal, so no click or close on an old banner reaches onClicked/onClosed and the polyfill re-parks after a later grant. Sweep runs from setPermissionDecision/clearRemovedGrants (via applySavedDecisions) and contextDidLoseGrants. Tests: 4 new (manager + 3 real-worker), 186 across affected suites pass. Remaining: a click in the main-queue hop between WebKit's removal and its notification still delivers.
<!-- SECTION:FINAL_SUMMARY:END -->
