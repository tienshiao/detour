---
id: TASK-258
title: >-
  Extensions: permissions.remove is not saved, so the revoked permission comes
  back at the next launch
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T20:53:00Z'
updated_date: '2026-11-03T21:54:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Browser/Profile.swift
priority: medium
type: bug
ordinal: 302000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-250, confirmed in the running app: when an extension calls chrome.permissions.remove for an optional permission, WebKit revokes it in the context, but Detour's stored decision row stays granted. At the next launch the decision restore (TASK-19/25) grants it again, and Settings still shows the switch ON. Affects every optional permission and host permission WebKit handles, not only the polyfill-gated ones.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An extension's permissions.remove of an optional permission or origin updates the stored decision, so the permission stays revoked after a relaunch and Settings shows it off
- [x] #2 A later permissions.request grant is stored again
- [x] #3 Tests cover remove then relaunch (context reload) for an API permission and a host permission
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ExtensionManager observes WKWebExtensionContext.grantedPermissionsWereRemoved / grantedPermissionMatchPatternsWereRemoved for every context (registered once in init).
2. The handler is state-based, not flag-based (WebKit posts these async, so a suppression flag around Detour's own writes would not line up): a saved GRANTED row for a removed key is deleted only when the context, at delivery, neither grants nor denies it, the key is askable (same gate as the restore) and not required (WebKit's own permissions.remove rule). Detour's restore and Settings writes leave the key granted or denied, so they never trigger a delete; no feedback loop.
3. Delete (absent) rather than save denied: a saved denial is restored as deniedExplicitly and WebKit then never prompts again, so a later permissions.request would be silently refused. Absent = Chrome's state after remove (OFF in Settings, request prompts again; the prompt saves the new grant).
4. Apply the cleared row to the extension's contexts in other profiles through the same path as setPermissionDecision (refactor into one apply function).
5. Test seam for the modal prompt so tests can drive a real permissions.request.
6. Tests in ExtensionPermissionRestoreTests with a real page: API (notifications) and host (optional origin) remove -> row gone -> reload still revoked -> request grant stored again; Detour's own denials/restore subsumption keep rows; required pattern survives a broad remove; other profile's context loses the grant.
7. Wiki permissions.md, log; code review, verify, suites.

8. (Review) Fall back to context.uniqueIdentifier for a post after unload; one clear-and-restore pass per context; WebExtension.restorablePermissions shared with the restore; re-run the restore on the removing context too (puts back required grants WebKit's broad sweep took); applySavedHostAccessDecisions skips a pattern already held (WebKit otherwise adds a duplicate entry).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented. ExtensionManager observes WKWebExtensionContext.grantedPermissionsWereRemovedNotification and grantedPermissionMatchPatternsWereRemovedNotification (object nil, registered in init) and deletes the saved granted rows a removal revoked (savedGrantsRevoked). Rule on state at delivery, because WebKit posts these async (dispatch_async to main) for Detour's own writes too: delete only when the context neither grants nor denies the key and no denied pattern covers it (permissionStatus(for:) of a pattern under a broader denial does not read as denied, found by testDetoursOwnWritesKeepTheSavedRows), the key is restorable (manifest gate) and not required, never nativeMessaging. Deleted, not saved as denied: WebKit never prompts for deniedExplicitly, so a later permissions.request would be refused silently. Cleared rows are re-applied to every loaded context of the extension (applySavedDecisions, shared with setPermissionDecision). WebKit quirk found at runtime: setting a pattern already held with the same status adds a duplicate entry (permissions.getAll listed https://a.example/* twice; the Swift dictionary hides it), also on the existing Settings toggle path; applySavedHostAccessDecisions now skips a held pattern. Test seam: ExtensionManager.permissionPromptAnswerOverride answers the modal prompt, so tests drive a real permissions.request (callAsyncJavaScript counts as a user gesture). No WebKitDelegateReachabilityTests row: these are typed notification constants, not delegate methods.
Tests (real contexts, extension page): ExtensionPermissionRestoreTests +9 (API notifications remove -> row gone -> reload revoked, not denied -> request prompts and is saved -> restored; optional origin, same, plus getAll has no duplicate; .url row under a removed origin; Detour's own writes keep rows; required row under a broad removal is kept and restored at once; other profile's context; isolation from another extension; post after unload; rule gates); ExtensionNotificationOrderingTests testOptionalNotificationsFollowTheGrantAndPermissionsRemove extended to the reload (polyfill gate, page + worker). The duplicate assertion was checked to fail with the skip disabled.
Runs: ExtensionPermissionRestoreTests 54, ExtensionPermissionTests 43, ExtensionHistoryScopeTests 22, ExtensionNotificationOrderingTests 18, NativeMessagingEnforcementTests 18, ExtensionPolyfillIntegrationTests 26, ExtensionPolyfillProfileWiringTests 63 (13 skipped, env-gated), WebKitDelegateReachabilityTests 1: 245 run, 0 failures.
/code-review: fixed post-after-unload drop, per-key restore passes, duplicated restore gate (WebExtension.restorablePermissions), added isolation test; then fixed finding 6 (removing context keeps swept required grants lost until next load) by re-running the restore there. Skipped: service-worker transport in the restore suite (the native handler is transport-independent; covered by the notification ordering worker leg and /verify, which removed from the worker); a DB read per removal notification (cheap, no prefilter without the DB); an open Settings pane is not live-refreshed (reads rows when the extension is selected again; the prompt-grant path has the same gap).
/verify: Debug build, DETOUR_DATA_DIR=Detour258Verify, seeded probe extension (storage, optional notifications, host a.example, optional opt.example, rows granted). The worker called permissions.remove({permissions:[notifications], origins:[opt.example]}) -> true; the log showed both rows cleared, the DB kept only storage and a.example. Relaunch: getAll {origins:[a.example], permissions:[storage,nativeMessaging]}, contains(notifications) false, contains(opt.example) false. The getAll duplicate was seen before the skip fix and gone after it. Not checked at runtime: the Settings pane itself (it reads the rows, and an absent optional row reads OFF in apiPermissionIsOn / savedPatterns lookup). Defaults keys and data dir removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
An extension's own chrome.permissions.remove now updates Detour's saved decisions. ExtensionManager listens for WebKit's grant-removal notifications and deletes the saved granted rows the removal revoked. The rule is on state at delivery: WebKit posts these asynchronously for Detour's own writes too, and those always leave the key granted or denied. Rows are deleted rather than saved as denied, because WebKit never prompts for an explicit denial: with no row, Settings reads OFF after a relaunch and a later permissions.request prompts again, and its answer is saved. Required keys and rows outside the manifest gate are kept. The cleared state is applied to every loaded context of the extension, which also restores the required grants a broad removal swept. A WebKit quirk found on the way: setting a held pattern again duplicated it in permissions.getAll (this also happened on Settings toggles); the host restore now skips held patterns. Tests run in real contexts (245 run, 0 failures), and /verify checked a worker removal, the DB and the relaunch. Follow-ups: live refresh of an open Settings pane; service-worker leg in the restore suite.
<!-- SECTION:FINAL_SUMMARY:END -->
