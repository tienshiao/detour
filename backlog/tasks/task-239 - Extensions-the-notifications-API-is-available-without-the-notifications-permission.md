---
id: TASK-239
title: >-
  Extensions: the notifications API is available without the notifications
  permission
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T16:51:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: medium
type: bug
ordinal: 283000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-234 (pre-existing). The native notifications handlers do no permission check, so an extension that does not declare "notifications" can still create, update, clear and list system notifications through the polyfill. Chrome exposes chrome.notifications only to extensions with the permission. CLAUDE.md requires permission work to carry positive and negative tests.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An extension without the notifications permission gets no chrome.notifications / browser.notifications API, and native requests from it are refused
- [x] #2 An extension with the permission keeps working unchanged
- [x] #3 Positive and negative tests in a real extension context, from both the service worker and an extension page; JS-level tests where the polyfill gates the namespace
- [x] #4 The API Explorer extension still declares and exercises the permission
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Polyfill: notificationsJS installs only when __detourManifestPermissions() includes 'notifications' (the privacy/webRequest pattern; history/management JS are in fact installed unconditionally). Diag reports 'absent'.
2. Native: every notifications.* case refuses with 'notifications permission not declared' unless hasPermission('notifications'), checked first (the history/management pattern).
3. Tests: ExtensionPolyfillTests default fixture gains the permission; namespace absent/present; native refusal (handler level) and promise + callback lastError through the polyfill. Real context (ExtensionNotificationOrderingTests): page + worker, with and without the permission. Existing profile-gone test registers its extension with the permission.
4. API Explorer already declares notifications; /verify that create still works there and that an extension without it has no chrome.notifications.
5. Wiki polyfill-layer per-request gates + log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: notificationsJS returns early unless __detourManifestPermissions() includes 'notifications' (the privacy/webRequest pattern; diag reports 'absent'). Note: history/management are NOT gated in the bundle (their JS is installed for every extension); only their handlers gate, so the notifications polyfill gate copies privacy/webRequest, the native gate copies history/management. Native: notificationsPermitted(_:orRefuse:) runs first in all four notifications.* cases and refuses with 'notifications permission not declared'.

Tests: ExtensionPolyfillTests (suite fixture now declares notifications): namespace present/absent, all four calls refused in callback (lastError) and promise form, getAll callback positive (held center), handler-level allowed/denied (registered ext without the permission and an unregistered id, all four types). ExtensionNotificationOrderingTests: testWithoutThePermissionThereIsNoNotificationsAPI / testWithThePermissionTheNotificationsAPIIsThere from page and worker (typeof chrome/browser.notifications, diag, a direct __detourPolyfillRequest refused/served); the profile-gone test now uses an extension with the permission.

Runs after review fixes: ExtensionNotificationManagerTests 30/30, ExtensionNotificationOrderingTests 12/12, ExtensionPolyfillTests 185/185, ExtensionPolyfillProfileWiringTests 62 (13 skipped, env-gated) 0 failures, ExtensionPolyfillIntegrationTests 26 with 1 failure in testStorageManagedInRealExtensionContextSurvivesGarbageCollection ('no collection observed', the known GC-precondition flake also seen in TASK-234), 3 reruns alone: 1 same flake, 2 clean.

/code-review --fix: fixed duplicated guard (helper), stale hasPermission doc comment, positive callback test on the system center (now a held center). Skipped: optional_permissions 'notifications' granted at runtime never gets the API (both gates read manifest.permissions only, same as history/management; follow-up), and caching the manifest read in the preamble (negligible).

/verify (Debug build, isolated DETOUR_DATA_DIR, API Explorer + a probe without the permission seeded, probe appended to the seeded copies' workers, -ExtensionConsoleLogPublic YES): API Explorer worker: chrome/browser.notifications object, create -> 'task239-probe', getAll lists it, clear true, direct request resolved. Probe without the permission: chrome/browser.notifications undefined, direct notifications.getAll rejected 'Invalid call to runtime.sendNativeMessage(). Notifications permission not declared.' Not checked: API Explorer's popup UI path (no UI driving); whether a banner is actually displayed (authorization is never requested).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
chrome.notifications is now gated on the notifications permission on both sides, as in Chrome: the polyfill installs the namespace only when the manifest declares it, and the handler refuses every notifications.* request from an extension that does not. Positive and negative tests at JS, handler and real-context (page + worker) level; API Explorer (declares the permission) still creates/lists/clears at runtime, and a seeded extension without it has no namespace and is refused. Follow-up: optional_permissions grants are not honoured by this or the history/management gates.
<!-- SECTION:FINAL_SUMMARY:END -->
