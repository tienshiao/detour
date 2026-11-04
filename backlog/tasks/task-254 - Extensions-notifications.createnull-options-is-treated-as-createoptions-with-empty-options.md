---
id: TASK-254
title: >-
  Extensions: notifications.create(null, options) is treated as create(options)
  with empty options
status: Done
assignee: []
created_date: '2026-11-03T17:09:00Z'
updated_date: '2026-11-03T22:18:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: bug
ordinal: 298000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-240. The notificationsJS polyfill (ExtensionAPIPolyfill.swift, around the create argument parsing) takes the options-first path when the first argument is an object, and typeof null is "object", so create(null, options) creates a notification with empty options and a generated id. Chrome treats a null id as absent and uses the options.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 create(null, options) and create(undefined, options) use the given options with a generated id
- [x] #2 JS-level tests cover null, undefined, a string id and options-only, in promise and callback forms
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fix: notifications.create takes the options-first path only for a non-null object in the first slot; a null or undefined id is sent as null (absent), so the options are used and the native side generates the id (Chrome: create(notificationId?, options, callback?)).
Tests: ExtensionPolyfillTests testNotificationsCreateArgumentForms (null, undefined, string id, options only; promise and callback forms; checks the answered id and the shown title via HeldNotificationCenter.addedRequests). ExtensionNotificationOrderingTests testCreateWithANullIDUsesTheOptionsFromBothTransports (real context, page and worker: generated id, given title shown, listed by getAll). Run: ExtensionPolyfillTests + ExtensionNotificationOrderingTests + ExtensionNotificationManagerTests, 258 tests, 0 failures.
Review: /code-review low --fix, no findings.
/verify: Debug build, isolated DETOUR_DATA_DIR, seeded worker probe (notifications permission) calling create(null, {...}), create(undefined, {...}, cb) and getAll. Both answered a generated UUID id, the callback had no lastError. The Debug bundle is not allowed to notify, so the manager dropped both ("Notifications are not allowed") and getAll was {}, the expected denied path; the shown title in the running app is covered by the tests only. Data dir and defaults keys removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
notifications.create(null, options) and create(undefined, options) now use the given options with a generated id, as Chrome does; only an options object in the first slot means the id was left out. JS-level tests cover null, undefined, a string id and options only in both forms, and a real-context test checks create(null, options) from the page and the worker. 258 tests passed; review clean; a worker probe in the running app got generated ids.
<!-- SECTION:FINAL_SUMMARY:END -->
