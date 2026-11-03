---
id: TASK-251
title: >-
  Extensions: the history and management namespaces exist for extensions without
  the permission
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T16:52:00Z'
updated_date: '2026-11-03T20:25:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: bug
ordinal: 295000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-239. The polyfill installs chrome.history and chrome.management for every extension ("Always install"); only the native handler refuses calls. Feature detection (if (chrome.history)) is therefore wrong for extensions without the permission, unlike Chrome. management.getSelf (and getPermissionWarningsByManifest) need no permission in Chrome and must stay available.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 chrome.history / browser.history are undefined without the history permission
- [x] #2 Without the management permission only the permission-free management methods are present
- [x] #3 JS-level and real-context tests cover presence with and absence without each permission
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Gate historyJS on __detourManifestPermissions() (TASK-239 pattern); diag reports 'absent'.
2. managementJS: without the management permission install only getSelf (Chromium extensions/common/api/_api_features.json: management depends on permission:management; getSelf, uninstallSelf, getPermissionWarningsByManifest have empty dependencies; Detour implements getSelf only).
3. Tests: ExtensionPolyfillTests presence/absence; ExtensionHistoryScopeTests page+worker gate (namespaces, browser alias, direct requests refused).
4. Wiki polyfill-layer + permissions; API Explorer already declares both permissions (no change).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: historyJS returns early unless __detourManifestPermissions() includes 'history' (diag reports 'absent'). managementJS without 'management' defines chrome.management = { getSelf } only: Chromium extensions/common/api/_api_features.json gives 'management' dependencies [permission:management] and default_parent, but management.getSelf, management.uninstallSelf and management.getPermissionWarningsByManifest have empty dependencies. Detour implements only getSelf of those (uninstallSelf/getPermissionWarningsByManifest are unimplemented with or without the permission). Handlers unchanged (already gated). WebKit vends neither namespace: with neither permission, chrome.history is undefined and chrome.management holds only Detour's getSelf, from page and worker. API Explorer declares history and management (no change); Vimium declares history.

Tests: ExtensionPolyfillTests: testHistoryNamespaceExists, testHistoryAbsentWithoutPermission, testManagementNamespaceExists (full member list), testManagementHasOnlyGetSelfWithoutPermission (members == [getSelf], getSelf answers). A plain WKWebView's browser is a separate {} so the alias is checked only in real contexts. ExtensionHistoryScopeTests (real context, page + worker): the no-permission test now checks the namespace is absent under both names plus a direct history.search refused; new testWithoutTheManagementPermissionOnlyGetSelfIsThere and testDeclaredPermissionsInstallBothNamespaces (direct requests refused/served).

Runs after review fixes: ExtensionPolyfillTests 187/187, ExtensionHistoryScopeTests 19/19, ExtensionPolyfillProfileWiringTests 63 (13 env-gated skips) 0 failures, ExtensionPolyfillIntegrationTests 26: 1 failure in testStorageManagedInRealExtensionContextSurvivesGarbageCollection ('no collection observed', the known GC flake), 26/26 rerun alone.

/code-review --fix: fixed a vacuous browser.history assertion in the plain-webview test, unused browser keys and a duplicated comment. Skipped: optional_permissions grants never install these namespaces (both gates read manifest.permissions only, same as notifications; an optionally-granted history caller now gets a TypeError rather than a rejection, broken either way); the integration fixture's chrome.management check now passes via the getSelf stub; a shared JS helper for the six inline permission checks.

/verify (Debug build in .derived, DETOUR_DATA_DIR=DetourVerify251, -ExtensionConsoleLogPublic YES, API Explorer + a probe declaring only storage seeded with a probe appended to the workers): probe worker: history/browser.history undefined, management/browser.management object with members [getSelf], getSelf resolved its id, direct history.search and management.getAll rejected 'History/Management permission not declared'. API Explorer worker: both namespaces whole, history.search array, management.getAll count 2, direct requests served. Not checked: extension page and popup UI at runtime (covered by the page-transport tests). Data dir and defaults keys removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
chrome.history is installed only for extensions that declare the history permission. Without the management permission, chrome.management holds getSelf alone, the one permission-free management method Detour implements (Chromium _api_features.json). Feature detection is now truthful, as in Chrome. The native handlers were already gated and are unchanged. Covered by JS-level and real-context tests (page and worker, positive and negative) and a seeded runtime probe. Follow-ups: honour granted optional permissions in the bundle and handler gates; uninstallSelf and getPermissionWarningsByManifest are not implemented.
<!-- SECTION:FINAL_SUMMARY:END -->
