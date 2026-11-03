---
id: TASK-248
title: >-
  Extensions: notifications left from an earlier launch stay in Notification
  Center and can no longer be cleared
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T16:33:00Z'
updated_date: '2026-11-03T20:07:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 292000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-238. Notification identifiers are opaque per entry since TASK-238 (detour-ext-notification.v3|<UUID>), and the manager keeps entries in memory only. A banner delivered in an earlier launch, in the v3, v2 or legacy <ext>:<id> form, is orphaned after a relaunch: clicks on it are ignored and the extension's clear or create with the same id no longer reaches it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 At launch, Detour removes every delivered and pending extension notification it created in an earlier launch (v3, v2 and legacy identifier forms), and nothing else
- [x] #2 The ExtensionNotificationCenter seam can list delivered notifications, and a manager-level test covers the cleanup with a fake center
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Seam: deliveredIdentifiers/pendingIdentifiers on ExtensionNotificationCenter (system: deliveredNotifications/pendingNotificationRequests).
2. Manager: isExtensionNotificationIdentifier (v3 prefix, v2 prefix, legacy anchored on a 32 a-p or UUID extension id followed by a colon) and removeLeftoverNotifications(), which skips identifiers with a current entry, so ordering with creates does not matter.
3. AppDelegate: run it at launch, not in the XCTest host and not while another Detour process (same bundle id, same Notification Center) runs.
4. Manager tests with HeldNotificationCenter: all forms removed, non-extension ids kept, this launch's kept (incl. one created during the listing).
5. Wiki, review, verify, notification suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Other posters: nothing in Detour besides ExtensionNotificationManager uses UserNotifications (downloads and the updater do not; Sparkle's gentle reminders are not enabled). The legacy form is anchored on the extension-id shape (32 a-p or a UUID string, the keys of Profile.extensionContexts) all the same.
Timing: no ordering with creates needed; the filter runs after the listing and skips identifiers with a current entry. Not gated on authorization (listing never prompts).
Safety decision: skipped while another process with the bundle id runs (production + DETOUR_DATA_DIR share one Notification Center), and in the XCTest host (launch precedes installSharedForTesting).
Review (/code-review --fix): fixed a doc comment displaced from startsUpdater; updated the sharedIfCreated doc. Skipped: TOCTOU between the instance check and the listing (tiny launch window, would need a cross-process lock); async let for the two listings (breaks the test hook ordering, negligible); legacy regex could match a future <UUID>: poster (intended, tested).
Tests: ExtensionNotificationManagerTests 49/49 (3 new), ExtensionNotificationOrderingTests 16/16, WebKitDelegateReachabilityTests, 66 total, 0 failures.
/verify: Debug build in DETOUR_DATA_DIR=DetourVerify248 launched; with the user's production Detour running it logged 'Not removing leftover extension notifications: another Detour process is running', as designed. NOT verified at runtime: the removal branch itself (needs a launch with no other Detour running) and whether the TASK-238 v2 leftovers are gone; the notification DB was not read (classifier refused, privacy). The user can confirm by quitting production Detour and launching once.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Launch now removes every extension notification an earlier launch left in Notification Center (v3, v2 and legacy <extension id>:<id> identifiers), keeping anything this launch created and anything not shaped like an extension notification. The ExtensionNotificationCenter seam lists delivered and pending identifiers. Skipped in the test host and while another Detour process runs. Manager-level tests cover all three forms, non-extension identifiers and this launch's notifications. Runtime removal branch not observed (production Detour was running).
<!-- SECTION:FINAL_SUMMARY:END -->
