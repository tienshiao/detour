---
id: TASK-257
title: >-
  Extensions: management.uninstallSelf and
  management.getPermissionWarningsByManifest are missing
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T20:26:00Z'
updated_date: '2026-11-04T03:18:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: feature
ordinal: 301000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-251. Chrome offers management.getSelf, uninstallSelf and getPermissionWarningsByManifest without the management permission (Chromium extensions/common/api/_api_features.json: dependencies []). Detour implements only getSelf; the other two do not exist with or without the permission. uninstallSelf with showConfirmDialog needs a confirmation UI decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 management.uninstallSelf uninstalls the calling extension from its profile (with a confirmation when showConfirmDialog is true), and is available without the management permission
- [x] #2 management.getPermissionWarningsByManifest returns the warnings Detour would show for a manifest string, or the gap is recorded
- [x] #3 Real-context tests from both transports, including bad arguments; API Explorer exercises both
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Polyfill: chrome.management gains uninstallSelf(options?, cb?) and getPermissionWarningsByManifest(manifestStr, cb?) in both shapes (with and without the management permission).
2. Handler: management.getPermissionWarningsByManifest parses the string (JSON error / non-object -> 'Failed to parse manifest.', undecodable manifest -> 'Failed to create extension from manifest.', Chromium management_api_constants.h) and returns ExtensionPermissionDescriptions.warnings (the install prompt's bullets, required permissions + site access).
3. Handler: management.uninstallSelf validates options, optionally confirms through ExtensionManager.confirmUninstallSelf (NSAlert in the Settings style, test seam uninstallSelfConfirmationAnswerOverride), rejects a cancel with Chromium's 'Extension <id> uninstall canceled by user.', replies, then runs ExtensionManager.uninstall(id:) on the next main-actor turn. Detour installs are global, so this removes the extension from every profile, like Settings.
4. Tests: ExtensionPolyfillTests member lists; new real-context suite ExtensionManagementSelfTests (page + worker, promise + callback, bad JSON, bad args, uninstall without dialog, dialog cancelled/confirmed).
5. API Explorer: both calls, uninstallSelf only with the dialog behind confirm().
6. Wiki polyfill-layer/permissions/overview, /code-review, /verify, test suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: chrome.management.uninstallSelf and getPermissionWarningsByManifest in the polyfill (both shapes of the namespace, so present without the management permission), handled in ExtensionPolyfillHandler; ExtensionManager.uninstallSelf runs Settings' uninstall(id:).

Decisions and gaps:
- uninstallSelf removes the extension from EVERY profile: Detour installs once and profiles only toggle, so it follows Settings' uninstall rather than Chrome's per-profile removal. The test asserts the second profile's context is gone too and a bystander extension stays.
- Cancel rejects with Chromium's current kUninstallCanceledError, 'Extension <id> uninstall canceled by user.' (management_api_constants.h), not 'User cancelled uninstall of the extension'.
- The reply goes first; the uninstall runs on the next main-actor turn and unloads the caller, so the reply may never arrive (Chrome uninstalls first, then answers).
- No user-gesture requirement for the dialog (Chrome: kGestureNeededForUninstallError); the polyfill has no gesture signal. A second call while an alert is up is refused.
- getPermissionWarningsByManifest returns the install prompt's lines (ExtensionPermissionDescriptions.warnings: required permissions, then host_permissions), not Chrome's filtered list (Chrome drops no-warning permissions such as storage and adds content-script hosts). Malformed or non-object JSON: 'Failed to parse manifest.' (Chrome uses the JSON parser's message for malformed JSON); undecodable manifest: 'Failed to create extension from manifest.'; non-string: 'management.getPermissionWarningsByManifest: manifestStr must be a string'.

Code review (--fix): fixed a race where two back-to-back dialog calls stacked two alerts (the pending claim is now taken before the task), stopped refusing no-dialog calls while an alert is up, simplified the reply-then-uninstall scheduling, added tests for uninstallSelf(callback) and the second-dialog refusal. Skipped: a worker re-calling after every Cancel can keep the app-modal alert up (needs a product decision: gesture signal, remembering a Cancel, or a sheet; permissions.request has the same exposure); the double parse in permissionWarnings; sharing one alert helper with Settings.

Tests: ExtensionManagementSelfTests 10/10 (new), ExtensionPolyfillTests 196, ExtensionHistoryScopeTests 25, ExtensionPageRehostTests, ExtensionUpdaterTests, ExtensionPageFavoriteTests, NativeMessagingEnforcementTests, RuntimeInstalledEventTests: 321 tests, 0 failures (after the review fixes).
/verify (isolated DETOUR_DATA_DIR, seeded probe without the management permission, before the review fixes): the worker saw members getPermissionWarningsByManifest,getSelf,uninstallSelf; warnings for tabs+storage+<all_urls> were ['Read your browsing activity','Store data locally','All websites']; '{bad' gave lastError 'Failed to parse manifest.' with 0 callback args; uninstallSelf({showConfirmDialog:true}) showed the alert 'Uninstall "T257 Probe"?' / '"T257 Probe" asked to uninstall itself. This will remove the extension and all its data from every profile.' / Cancel, Uninstall (screenshot taken). Not verified at runtime: clicking Cancel or Uninstall in the real alert (Detour was not frontmost and synthetic input would have gone to the user's app); both answers are covered through the test seam.

Full-run follow-up (Nov 3 2026, after d16eacc): the full DetourTests run failed 8 background-page tests in ExtensionPolyfillProfileWiringTests deterministically (install timeouts, localStorage records reading back empty, no keep-alive heartbeat), while the suite passed alone. Cause: the one WebKit network process takes only about 190 persistent sessions over its lifetime (counted from launch, not live stores or fds); after that it logs 'Could not create a sandbox extension ... errno = 12' and EPERM on new stores' observations.db/pcm.db/AlternativeService.sqlite, and a new profile's localStorage silently keeps nothing. No single commit: the test profiles added since f597a56 (TASK-247's ExtensionNotificationEventTests and this task's ExtensionManagementSelfTests the largest, plus TASK-250/251/253/259/260/261) pushed the run past the limit before the wiring suite. Fix in the test host: TestEnvironmentSetup terminates the network process (-[WKWebsiteDataStore _terminateNetworkProcess]) between test classes once 60 new WebKit storage identifiers are recorded. Full run after the fix: 3570 tests, 18 skipped, 0 failures (load 11.5 at start, 34.8 at end). Recorded in wiki/platform/webkit-test-host-traps.md.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
chrome.management.uninstallSelf and getPermissionWarningsByManifest now exist with or without the management permission, as in Chrome. uninstallSelf runs Settings' uninstall(id:) (every profile, since Detour installs once), optionally after a Settings-style NSAlert; Cancel rejects with Chromium's 'Extension <id> uninstall canceled by user.'; the reply goes first and may never arrive. getPermissionWarningsByManifest returns the install prompt's lines (required permissions, then site access), with Chromium's parse/create errors. Tested from page and worker, promise and callback; API Explorer exercises both (uninstallSelf only with the dialog). Gaps: no user-gesture requirement, so a worker re-calling after each Cancel can keep the alert up; warnings differ from Chrome's filtered list.
<!-- SECTION:FINAL_SUMMARY:END -->
