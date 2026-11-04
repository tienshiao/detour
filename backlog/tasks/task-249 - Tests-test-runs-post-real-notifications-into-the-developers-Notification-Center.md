---
id: TASK-249
title: >-
  Tests: test runs post real notifications into the developer's Notification
  Center
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T16:33:00Z'
updated_date: '2026-11-03T19:00:00Z'
labels:
  - tests
  - extensions
dependencies: []
references:
  - DetourTests/ExtensionNotificationManagerTests.swift
priority: low
type: chore
ordinal: 293000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-238. The test host shares the app bundle id, and suites such as ExtensionPolyfillTests drive notifications.create through ExtensionNotificationManager.shared, so every run delivers real banners on the development machine (their v2 identifiers showed up in a later runtime check). Tests should use a fake ExtensionNotificationCenter (HeldNotificationCenter exists in ExtensionNotificationManagerTests).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No test posts to the real UNUserNotificationCenter: notification-creating tests use a fake center, or a test-host-wide default does
- [x] #2 The affected suites pass, and a full run leaves no new Detour notifications in Notification Center
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A test-host-wide default (option a): `ExtensionNotificationManager.installSharedForTesting(center:)` (DEBUG only) makes `shared` a manager around a fake that never becomes the system center's delegate. TestEnvironmentSetup installs `TestHostNotificationCenter.shared` (a non-holding HeldNotificationCenter) at bundle start, before any test runs. If `shared` already existed, its notifications are removed and it stops being the system delegate. Production is unchanged: the `shared` getter still builds the SystemExtensionNotificationCenter, and the new hook has no caller in the app.

Test added: ExtensionNotificationManagerTests.testTestHostSharedManagerPostsToTheTestCenter. It checks that `shared` uses the test-host center and that a create through `shared` lands there.

Tests run: ExtensionPolyfillTests, ExtensionNotificationManagerTests, ExtensionNotificationOrderingTests, ExtensionPolyfillIntegrationTests and ExtensionPolyfillProfileWiringTests, 325 tests (13 skipped), 0 failures. After the review fix: ExtensionPolyfillTests, ExtensionNotificationManagerTests and ExtensionNotificationOrderingTests, 236 tests, 0 failures.

/code-review: fixed finding 1 (a manager created before the bundle started is cleaned up). Skipped: requestPermission() bypasses the seam but has no callers; the fake keeps state for the whole run; one assertion is redundant; HeldNotificationCenter still lives in a suite file.

Not verified: no /verify worker probe was run, because the production path did not change (DEBUG-only additive hook, never called by the app). Notification Center was not inspected after a full run. AC 2 rests on the code path: every route to the system center goes through `shared`, and `shared` is now the fake.
<!-- SECTION:FINAL_SUMMARY:END -->
