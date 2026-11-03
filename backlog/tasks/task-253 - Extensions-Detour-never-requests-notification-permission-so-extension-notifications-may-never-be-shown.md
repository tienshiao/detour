---
id: TASK-253
title: >-
  Extensions: Detour never requests notification permission, so extension
  notifications may never be shown
status: Done
assignee: []
created_date: '2026-11-03T17:09:00Z'
updated_date: '2026-11-03T19:59:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: medium
type: bug
ordinal: 297000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noted during TASK-238 and TASK-240: nothing in Detour calls UNUserNotificationCenter.requestAuthorization. Whether an extension's notifications.create shows a banner therefore depends on whether the bundle id happened to be authorized on that Mac (it was on the dev machine for one agent, not for another). On a fresh install the API reports success and nothing appears. When to ask (at first notifications.create, at extension install, from Settings) and what to answer the extension when the user declines are product decisions for this task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The point at which Detour asks for notification permission is decided and recorded, and implemented
- [x] #2 When permission is denied, notifications.create behaves as recorded (Chrome-like answer or error), and getAll does not list notifications that were never shown
- [ ] #3 Tests cover the granted and denied paths with a fake center; a runtime check on a fresh bundle id shows the prompt and a banner
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend ExtensionNotificationCenter with authorizationStatus() and requestAuthorization(); system impl maps UNAuthorizationStatus (provisional/ephemeral = authorized). Remove the unused requestPermission().
2. ExtensionNotificationManager.show: record the entry synchronously as before, then await authorize() (one check in flight; waiters resume FIFO; status re-asked per create/update), skip the add when the entry was cleared/superseded during the wait, drop the entry (and any banner under its identifier) when not authorized; create still answers the id, update answers false.
3. Tests with HeldNotificationCenter (authorization controls): granted, denied, notDetermined->granted->denied in Settings, declined, concurrent first creates share one prompt, clear/update during the wait (granted and declined), denied re-create/update of a shown id; real-context denied test from page and worker; adjust existing ordering tests whose clear now arrives during the authorization wait.
4. Wiki (polyfill-layer, testing-extensions), /code-review --fix, /verify, suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User decision (2026-11-03): ask for notification authorization the first time any extension calls notifications.create; that create waits for the answer. When permission is denied (or was denied earlier), notifications.create succeeds silently with the id, as Chrome does when the OS blocks notifications, and the notification is not listed in getAll since it was never shown. From TASK-249 review: ExtensionNotificationManager.requestPermission() is unused and calls UNUserNotificationCenter directly around the ExtensionNotificationCenter seam; replace it with the authorization path through the seam. Optionally move HeldNotificationCenter into shared test support.

Implemented (2026-11-03). Decisions applied as recorded: authorization is requested the first time any extension calls notifications.create, and that create waits. ExtensionNotificationCenter gained authorizationStatus()/requestAuthorization() (provisional counts as authorized); the unused requestPermission() is gone. The status is asked afresh for every create and update (not cached), so a System Settings change applies to the next call. One check in flight at a time: creates/updates arriving meanwhile wait on it and resume in call order (a continuation list; awaiting a shared Task's value resumed waiters in reverse order and reordered the adds). The entry is still recorded before the wait, so a clear during the wait answers true and an update merges into the waiting create; a create cleared or superseded during the wait never calls add. Denied (now or earlier): create answers its id, nothing is shown, the entry is dropped, so getAll does not list it and clear/update answer false for that id (choice: a never-shown notification does not exist, matching getAll); a banner shown earlier under a reused identifier is taken away.

Tests: ExtensionNotificationManagerTests +9 (authorized, denied, not determined -> granted -> denied in Settings, declined, concurrent first creates share one prompt, clear/update during the wait granted and declined, denied re-create/update of a shown id); ExtensionNotificationOrderingTests +2 real-context (denied from page and worker; not determined -> one prompt -> shown from both transports, added by review). Existing ordering tests adjusted: a clear issued before the add task runs now arrives during the authorization wait, so those cases no longer add. Runs: ExtensionNotificationManagerTests 46 + ExtensionNotificationOrderingTests 16 + ExtensionPolyfillTests 185 + WebKitDelegateReachabilityTests 1 = 248 passed; the two notification suites passed 3 more iterations (186 tests).

/code-review --fix: fixed: denied path no longer issues removals for a fresh identifier; dead .ephemeral arm removed; concurrency test now asserts the late create joined the check; real-context prompt test added. Not fixed (risks): no timeout on the prompt wait (a prompt ignored into Notification Center leaves creates waiting; the decision says create waits); the status query per create adds a round trip (decision: re-check rather than cache); a throwing requestAuthorization leaves the status not determined, so each create re-requests; the bridge-level clear races are timing-dependent between the authorization wait and the add in flight (both paths are covered deterministically at manager level).

/verify: Debug build (.derived), DETOUR_DATA_DIR=DetourVerify253, a hand-seeded MV3 probe extension (notifications permission row) whose worker calls notifications.create at start. On this Mac com.detourbrowser.mac was still NOT DETERMINED: the system prompt banner '“Detour” Notifications' appeared (screenshot; NotificationCenter logged an askpermissions record req com.detourbrowser.mac) and the create stayed pending, as decided. The prompt was NOT answered: the Debug build shares the bundle id with the installed app, and answering would change the user's Notification Center settings. The instance was killed, data dir and defaults keys removed. Owed by the user: the banner after Allow, and the denied path at runtime. Steps: build Debug (.derived), launch with an isolated DETOUR_DATA_DIR and an extension declaring notifications that calls chrome.notifications.create; answer the '“Detour” Notifications' prompt with Allow and check the banner shows and create resolves; then turn Detour off in System Settings > Notifications, create again, and check create resolves with the id while getAll is {}. Note the prompt from this run may still sit in Notification Center; answering it sets the installed Detour's permission.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Detour now asks for notification authorization the first time any extension calls notifications.create, through the ExtensionNotificationCenter seam (authorizationStatus/requestAuthorization; requestPermission removed). That create waits for the answer; concurrent creates share one prompt and resume in call order; the status is re-asked per create so System Settings changes apply. When not allowed, create answers its id silently (Chrome-like) while nothing is shown, getAll omits it, and clear/update answer false. 11 new tests (9 manager, 2 real-context); 248 tests across the notification, polyfill and reachability suites pass. Runtime: the system prompt appeared for com.detourbrowser.mac (not determined on this Mac) and the create waited. AC #3's banner-after-Allow check is owed by the user (steps in the notes): answering the prompt would have changed the installed app's settings. Risks: no timeout on an unanswered prompt; one settings round trip per create.
<!-- SECTION:FINAL_SUMMARY:END -->
