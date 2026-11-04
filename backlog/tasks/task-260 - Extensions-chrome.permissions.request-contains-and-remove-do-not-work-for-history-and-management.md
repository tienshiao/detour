---
id: TASK-260
title: >-
  Extensions: chrome.permissions.request, contains and remove do not work for
  history and management
status: Done
assignee: []
created_date: '2026-11-03T20:54:00Z'
updated_date: '2026-11-04T00:32:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: feature
ordinal: 304000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-250. WebKit's web process refuses permissions.request/contains/remove for permission names it does not implement ("'history' is not a valid permission") before Detour sees the call, so an extension can only get optional history or management through the Settings switch. A Detour wrapper around chrome.permissions could handle those names (prompt, store the decision, answer contains). Also: the refusal text "permission not declared" is misleading for an optional permission that is declared but not granted, and the API Explorer declares these permissions as required only, so it cannot exercise the optional path.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 permissions.request for optional history or management shows Detour's permission prompt and grants on approval; contains and remove answer and act correctly
- [x] #2 A call refused because an optional permission is not granted says so, distinct from a permission not declared at all
- [x] #3 The API Explorer can exercise an optional grant; real-context tests cover request, contains and remove
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design: the polyfill's chrome/browser.permissions wrappers (permissionsOriginPortJS) take history and management (WebExtension.permissionsOutsideWebKit) out of details.permissions; the handler answers contains (permissionIsActive), request (Chrome's manifest rule in permissionRequestPlan; Detour's prompt via promptUserForPermission, answer saved through setPermissionDecision; denied or switched-off names answer false without a prompt; pending-prompt guard) and remove (Chrome's refusals; saved grant deleted, not denied). Measured: WebKit requires a user gesture for its own permissions.request (refused from a worker and after an await), so a mixed request calls WebKit first inside the gesture and the wrapper takes WebKit's grant back (remove of the items contains said were not held) when Detour's prompt is denied. Refusals now distinguish 'not declared', 'denied by the user' and 'is optional and has not been granted'; asserted texts updated in ExtensionHistoryScopeTests and ExtensionNotificationOrderingTests. API Explorer: history moved to optional_permissions with Request/Remove History and Request History + Cookies buttons.

User gesture: Detour does not require one for history/management: the handler gets no gesture signal, a worker has none, and a polyfill check would be the extension's own code. The prompt is the guard.

Tests: ExtensionPermissionRestoreTests + ExtensionPermissionTests + ExtensionHistoryScopeTests + ExtensionNotificationOrderingTests + ExtensionPolyfillTests: 349 tests, 0 failures (after /code-review --fix). New: ExtensionHistoryScopeTests section 7 (request granted/denied from page and worker, both forms; contains before/after; remove then relaunch keeps it revoked and the next request prompts; mixed request with notifications all-or-nothing incl. mixed remove and the worker gesture refusal; non-manifest names refused; pending prompt refused), testOutsideWebKitPermissionRequestPlan, testPermissionsNamesOutsideWebKitAreAnsweredByDetour.

/code-review --fix: 9 findings, 8 fixed (plan checks all names before answering, malformed origins go to WebKit, mixed-remove test, shared clearRemovedGrants, contains handler lookup, comments). Skipped: a mixed request whose Detour half is already denied still shows WebKit's prompt and then takes the grant back (knowing first would spend the gesture); recorded in the wiki Gaps.

/verify (data dir DetourVerify2600, temporary harness not committed, docs-free): seeded probe (optional history + notifications). Before: page and worker history.search refused with 'is optional and has not been granted', contains false. permissions.request(['history']) showed the real Detour alert (screenshot: '"TASK-260 Probe" is requesting additional permissions / • Read and modify browsing history', Deny/Allow), Allow clicked by the harness: request true, row granted, search ok from page and worker, contains true, Settings history switch ON. remove: true, row none, refused again, switch OFF. Mixed ['history','notifications'] through the override: prompts in order notifications then history, both rows granted. Disable/enable reload: search ok, contains true. Defaults keys and data dir removed. Not verified: a real NSAlert for WebKit's half of a mixed request (override used).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
permissions.request/contains/remove now work for optional history and management: the polyfill's permissions wrappers route those names to Detour's handler (Detour's prompt, saved like the Settings switch; remove deletes the saved grant), and pass the rest to WebKit. Mixed requests are all-or-nothing: WebKit first inside the user gesture it requires, then Detour, with WebKit's grant taken back on a Detour denial. Refusals now say not declared / denied by the user / optional and not granted. API Explorer has optional history with request/remove buttons. 349 tests pass; /verify showed the real prompt and the full grant/remove/reload cycle in an isolated profile. Follow-up candidate: avoid WebKit's prompt when Detour's half is already denied.
<!-- SECTION:FINAL_SUMMARY:END -->
