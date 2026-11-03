---
id: TASK-250
title: >-
  Extensions: notifications, history and management ignore permissions granted
  at runtime through optional_permissions
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T16:52:00Z'
updated_date: '2026-11-03T20:52:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: low
type: bug
ordinal: 294000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-239. The polyfill namespace gates and the native hasPermission checks for notifications, history and management read only the manifest's permissions list. An extension that lists one of them under optional_permissions and is granted it at runtime (permissions.request) never gets the API, until it is moved to required permissions. Chrome makes the API available as soon as the grant is made. Revocation should take it away again.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After a runtime grant of an optional notifications, history or management permission, the API works in the extension's contexts (newly created ones at least; existing ones if Chrome does so); after revocation it is refused
- [x] #2 Positive and negative tests in a real extension context for grant and revoke
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Findings: WebKit parses notifications (in WebExtension::supportedPermissions) but not history/management: permissions.request/contains/remove({permissions:['history'|'management']}) are refused in the web process ('is not a valid permission') before Detour sees them, and permissionState() answers Unknown for them. The context still stores any name given to setPermissionStatus (grantedPermissions dictionary) and fires permissions.onAdded/onRemoved for it. Chrome: Dispatcher::UpdatePermissions -> UpdateBindingsForExtension re-runs bindings in every running context (pages and workers), so a granted API appears without reload; removed APIs are not deleted (TODO in NativeExtensionBindingsSystem::UpdateBindingsForContext), calls are refused by the access checker.
2. Native gate (ExtensionPolyfillHandler.hasPermission): manifest permissions -> allowed; manifest optional_permissions -> allowed only while this profile's context grants it (context.grantedPermissions, unexpired). Revocation through permissions.remove (notifications) or Settings refuses at once.
3. Restore (Profile.loadExtensionContext): also apply saved .apiPermission rows for the polyfill-gated optional names WebKit does not parse (history, management), so a new context holds the grant and the Settings toggle stays the source of truth.
4. JS gate: install notifications/history/full management when declared in permissions OR optional_permissions; the handler decides per call (namespaces are built at injection and a worker restart must see them synchronously; Chrome keeps a revoked namespace too). Deviation recorded: present before the first grant.
5. Tests in real contexts, page + worker: optional not granted refused; granted in a new context (saved row); granted live in an existing context (setPermissionDecision, the Settings path); revoked (setPermissionDecision deny; permissions.remove for notifications) refused. Add management to ExtensionPolyfillIntegrationTests fixture.
6. Wiki permissions + polyfill pages, log; review, verify, suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
From TASK-251: the history and management namespace gates (bundle) and hasPermission (handler) read only the manifest permissions; a runtime grant should install them. Also add management to the ExtensionPolyfillIntegrationTests fixture permissions so testAllPolyfillNamespacesExist checks the full namespace, not the getSelf-only stub.

Implemented (plan steps 2-5). Choice recorded: namespaces install for a permission in either manifest list (__detourDeclaresPermission) and the handler decides each call from the profile context's grant dictionary (ExtensionPolyfillHandler.permissionIsActive). This is closest to Chrome after a grant (works in the running page and worker, no reload) and after revocation (namespace stays, calls refused). The one deviation: the namespace is present before the first grant. Install-on-onAdded or install after an async getAll was rejected because a restarted worker's top-level addListener would throw first. Required permissions stay manifest-only, as before.
Grant paths: notifications go through WebKit's permissions.request prompt or the Settings switch. history/management can only be granted through the Settings switch (setPermissionDecision), because WebKit's web process refuses permissions.request/contains/remove for names outside WebExtension::supportedPermissions(). The restore now applies saved rows for polyfillGatedOptionalPermissions, which WebKit drops from optionalPermissions.
Tests (real contexts, page + worker): ExtensionHistoryScopeTests testOptionalHistoryAndManagementFollowTheLiveGrant (refused, live grant via setPermissionDecision, revoked; plus page promise and callback lastError forms, added in review), testSavedOptionalGrantIsRestoredIntoANewContext, testSavedOptionalDenialIsRefusedInANewContext (plus profile isolation). ExtensionNotificationOrderingTests testOptionalNotificationsFollowTheGrantAndPermissionsRemove (grant, then the extension's own permissions.remove), testSavedOptionalNotificationsDecisionIsAppliedToANewContext (grant and denial). ExtensionPermissionRestoreTests: two rule/restore tests. ExtensionPolyfillTests testOptionalPermissionsInstallTheirNamespaces. The ExtensionPolyfillIntegrationTests fixture declares management, and testAllPolyfillNamespacesExist checks management.getAll.
Runs: ExtensionHistoryScopeTests 22, ExtensionNotificationManagerTests 49, ExtensionNotificationOrderingTests 18, ExtensionPermissionRestoreTests 45, ExtensionPermissionTests 43, ExtensionPolyfillIntegrationTests 26, ExtensionPolyfillProfileWiringTests 63 (13 skipped, env-gated), ExtensionPolyfillTests 188, NativeMessagingEnforcementTests 18: 472 run, 0 failures.
/code-review: fixed a compile error (.notifications is not a WKWebExtension.Permission member), added the public-API promise/lastError checks, corrected the permissionIsActive doc, removed a blank line. Skipped as follow-ups: a required history/management/notifications switched off in Settings still works (pre-existing, manifest-only rule); permissions.remove is not persisted (the row stays granted, so the next launch restores it; this affects every WebKit optional permission, and was confirmed in the running app); permissions.request/contains/remove for history/management need a Detour chrome.permissions wrapper; the API Explorer declares these permissions as required only; the 'permission not declared' wording; management getSelf/getAll permissions list omits runtime grants.
/verify: Debug build, isolated DETOUR_DATA_DIR, seeded probe extension (permissions [storage], optional [history, notifications, management]), worker log via -ExtensionConsoleLogPublic. Without saved rows: namespaces present (full management), history.search, management.getAll and notifications.getAll refused. With granted rows: all three served, permissions.getAll lists history/management/notifications, and after permissions.remove(notifications) notifications.getAll is refused in the same worker. Not exercised in the running app: the live Settings switch (covered by the tests). Defaults keys and data dir removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
An optional notifications, history or management permission now works once the profile's context holds the grant, and is refused again after a revocation. The native gate (ExtensionPolyfillHandler.permissionIsActive) reads context.grantedPermissions for permissions listed only under optional_permissions. The restore applies saved history/management decisions, which WebKit drops from its own optional set. The polyfill installs the namespaces for either manifest list, and the handler decides each call. This matches Chrome after a grant and after revocation; the one difference is that the namespace is present before the first grant. history and management can only be granted through the Settings switch, because WebKit refuses permissions.request for them. Tests run in real contexts from the page and the worker (472 run, 0 failures), and /verify checked the restored grant, the refusal and permissions.remove in the running app. Follow-ups: persist permissions.remove; a Detour chrome.permissions wrapper for history/management; required permissions switched off in Settings; getSelf permissions list; API Explorer coverage.
<!-- SECTION:FINAL_SUMMARY:END -->
