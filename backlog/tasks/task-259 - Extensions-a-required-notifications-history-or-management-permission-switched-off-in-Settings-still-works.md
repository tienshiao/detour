---
id: TASK-259
title: >-
  Extensions: a required notifications, history or management permission
  switched off in Settings still works
status: Done
assignee: []
created_date: '2026-11-03T20:54:00Z'
updated_date: '2026-11-03T22:12:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: medium
type: bug
ordinal: 303000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-250 (pre-existing). The polyfill-gated APIs treat a permission in the manifest's required permissions list as always active (permissionIsActive), so when the user turns that permission off in Settings the API keeps working. The Settings switch should mean what it shows.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Whether Settings lets the user switch off required permissions is recorded; if it does, a switched-off required notifications, history or management permission refuses calls until switched on again
- [x] #2 Positive and negative real-context tests from both transports
- [x] #3 An open Extensions Settings pane reflects a permission row that changes while it is shown (an extension's permissions.remove since TASK-258, or a permissions.request prompt answer)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Settings: confirm a required permission can be switched off and what it writes. 2. permissionIsActive: a context denial refuses first (WebKit's permissionState order), required included. 3. Restore: polyfillGatedDeclaredPermissions (both manifest lists) so a required history/management denial is re-applied at load; TASK-258 rule still skips required keys. 4. ExtensionManager.permissionDecisionsDidChangeNotification posted by setPermissionDecision, handlePermissionPrompt and contextDidLoseGrants; Extensions pane rebuilds the shown extension's detail. 5. Tests (real contexts, both transports; rule; pane), review, verify, wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Findings: the Extensions pane lists every manifest permission with a switch and lets the user turn a required one off after a 'Revoke Permission?' alert; that calls ExtensionManager.setPermissionDecision(granted: false), which saves a denied extensionPermission row and sets .deniedExplicitly on every loaded context. WebKit's WebExtensionContext::permissionState checks denied before granted, and an undecided requested permission is 'requested' (not active) until a prompt; Detour keeps an undecided required polyfill-gated permission active, because WebKit never prompts for history/management and install records required permissions as granted. permissionIsActive now refuses on an unexpired context denial first, required included. WebKit drops history/management from requestedPermissions too, so restorablePermissions now adds the polyfill-gated names from both manifest lists (polyfillGatedDeclaredPermissions); savedGrantsRevoked still skips required keys (testRemovalRuleKeepsARequiredPolyfillGatedRow). New ExtensionManager.permissionDecisionsDidChangeNotification (userInfo extensionID) from setPermissionDecision, handlePermissionPrompt and contextDidLoseGrants; the Extensions pane rebuilds the shown extension's detail (keeping keyboard focus on the same row's switch, a review fix).

Tests: new ExtensionHistoryScopeTests.testRequiredHistoryAndManagementFollowTheSettingsSwitch / testSavedDenialOfRequiredHistoryIsRefusedInANewContext, ExtensionNotificationOrderingTests.testRequiredNotificationsFollowTheSettingsSwitch (page + worker, promise; callback form for history; off/on/off + context reload), ExtensionPermissionRestoreTests.testSavedDenialOfARequiredPolyfillGatedPermissionIsRestoredAndRefused / testRemovalRuleKeepsARequiredPolyfillGatedRow / testPermissionDecisionChangesArePostedAndTheOpenPaneFollowsThem (real prompt, real permissions.remove, Settings call; pane switches read). Ran ExtensionPermissionRestoreTests 57, ExtensionPermissionTests 43, ExtensionHistoryScopeTests 24, ExtensionNotificationOrderingTests 19, ExtensionPolyfillTests 188, SettingsPaneColumnsTests 15, SettingsPaneHeightTests 22, ProfileSettingsLayoutTests 20, WebKitDelegateReachabilityTests 1: 389 tests, 0 failures (after the review fixes).

Review (/code-review --fix): fixed focus loss when a keyboard toggle rebuilds the detail, a redundant contentHeightDidChange, a stale Profile restore comment, the pane test's observer filtered to its own extension. Skipped: an undecided required permission reads OFF in the pane while served (install always records required rows; changing it needs a decision); no context reads as active for a required permission (handler tests call without a context; a call cannot come from a profile without the context); a mixed permissions.remove posts twice (two rebuilds, cheap).

/verify (docs/harness/task259-harness.patch, DetourVerify2590, cleaned up): installed an unpacked extension with required history; page and worker history.search ok; clicked the history switch in Settings > Extensions and answered 'Revoke Permission?': row denied, pane OFF, page 'history permission not declared', worker refused; a permissions.request prompt answer turned the open pane's notifications switch ON and permissions.remove turned it OFF without reselecting; switched history on: ok from both; off + disable/enable (context reload): row denied, pane OFF, refused from both. Capture of the pane after the switch-off checked. Not verified: a signed build; WebKit-implemented required permissions (tabs, cookies) switched off were not exercised (WebKit enforces those itself).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings lets the user switch off a required permission (after a 'Revoke Permission?' alert), which saves a denied row and denies it on every loaded context, but the polyfill gate treated required notifications/history/management as always active. permissionIsActive now refuses on an unexpired context denial first (WebKit's permissionState order), required included; the restore re-applies a required history/management denial (polyfillGatedDeclaredPermissions), and TASK-258's rule still never deletes required rows. Saved-decision writes post ExtensionManager.permissionDecisionsDidChangeNotification and an open Extensions pane rebuilds its rows. Real-context tests from page and worker, a rule test and a pane test; 389 tests across the affected suites pass; /verify drove the Settings switch in the running app.
<!-- SECTION:FINAL_SUMMARY:END -->
