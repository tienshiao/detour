---
id: TASK-269
title: >-
  Extensions: notifications.create with an empty id keeps it instead of
  generating one
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T01:24:00Z'
labels:
  - extensions
  - notifications
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: low
type: bug
ordinal: 316000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

Chrome generates an id when `notificationId` is "not set or empty". Detour's handler (ExtensionPolyfillHandler.swift ~772) passes `""` through and `ExtensionNotificationManager.create` (~408) keeps it as a literal id, so every `create('', ...)` replaces the previous notification and `getAll` lists a single `""` entry. TASK-254 fixed the null case only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 create('', options) generates a fresh id, returned to the caller, like create(null, options) and create(options)
- [x] #2 Two create('', ...) calls produce two notifications
- [x] #3 Tests cover the empty-string id from both transports
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionNotificationManager.create treats an empty notificationID like nil (generated UUID), so the fix holds for every caller and both transports (the handler passes the string through).
2. Tests: manager unit test (two create('') give two distinct generated ids, both listed, no '' entry); ExtensionPolyfillTests argument forms gain an empty-id form (promise + callback); ExtensionNotificationOrderingTests real-context test from the page and the worker (two create('') -> two notifications, getAll lists both, no '').
3. Wiki polyfill-layer note + log; run the three suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision: the fix is in ExtensionNotificationManager.create (an empty id becomes nil, so show() generates a UUID) rather than the polyfill JS, so every caller and both transports get it; update('')/clear('') keep answering false since nothing can be stored under ''.
Tests (with -derivedDataPath .derived): ExtensionNotificationManagerTests 59/0, ExtensionNotificationOrderingTests 22/0, ExtensionPolyfillTests 197/0 (278 total, 0 failures). New: ExtensionNotificationManagerTests.testCreateWithAnEmptyIDGeneratesAFreshIDEachTime (two create('') -> two distinct ids, two adds, nothing under ''); ExtensionNotificationOrderingTests.testCreateWithAnEmptyIDGeneratesOneFromBothTransports (real extension context, page and worker, two creates each, getAll lists all four and no ''); ExtensionPolyfillTests.testNotificationsCreateArgumentForms gains an 'empty id' form (promise + callback). All three new checks fail with the fix reverted (11+2 failures) and pass with it.
Code review (/code-review medium --fix): no correctness findings; added an API Explorer button 'Create(\'\') twice' (popup.html/popup.js; node --check only, not clicked). Skipped: stronger distinct-id assertion in the shared argument-form table (covered by the other two tests), a cosmetic rewrite of the empty-to-nil line.
Runtime: Debug build launched with DETOUR_DATA_DIR=DetourVerify269 via the launch script; it started and wrote its databases; killed by PID; defaults keys and data dir removed. Not verified at runtime: an actual notification (authorization for com.detourbrowser.mac is shared with the production app and is the user's decision), the API Explorer button.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
notifications.create('', options) now generates a fresh id like create(null, options) and create(options), as Chrome does for an id 'not set or empty'. ExtensionNotificationManager.create maps an empty id to nil before show(), so two such creates are two notifications and getAll never lists ''. Covered by a manager unit test, the JS-level argument-form test (promise and callback), and a real-extension-context test from the page and the worker; API Explorer gained a button. 278 tests in the three suites pass; no system notification was shown at runtime.
<!-- SECTION:FINAL_SUMMARY:END -->
