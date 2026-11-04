---
id: TASK-261
title: >-
  Extensions: management.getSelf and getAll leave out permissions granted at
  runtime
status: Done
assignee: []
created_date: '2026-11-03T20:54:00Z'
updated_date: '2026-11-04T00:42:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: low
type: bug
ordinal: 305000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-250. The ExtensionInfo permissions and hostPermissions lists that management.getSelf / getAll return are built from the manifest, so optional permissions granted at runtime are missing, unlike Chrome.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 getSelf and getAll list active permissions, including runtime grants, and drop revoked ones
- [x] #2 Real-context tests cover a grant and a revoke
<!-- AC:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
management.getSelf / getAll now build ExtensionInfo.permissions and hostPermissions from the asking profile's context for each extension, as Chromium's CreateExtensionInfo lists active_permissions() (GetAPIsAsStrings, explicit_hosts; management_api.cc). permissions: both manifest lists filtered by permissionIsActive, MV2 origin entries excluded. hostPermissions (previously not returned): unexpired granted patterns a manifest host pattern covers, minus those an unexpired denial covers and activeTab content-script grants; with no context, the declared required hosts.

Tests: ExtensionHistoryScopeTests section 8 - getSelf from page and worker through a Settings grant/revoke of optional history, notifications and an optional origin plus a required permission switched off; through permissions.request/remove; getAll showing another extension's grants; the pure host rule (denied, expired, broader denial, content-script); MV2 origins. Runs: ExtensionHistoryScopeTests 36/36, ExtensionManagementSelfTests 10/10, ExtensionPermissionRestoreTests 58/58, all passing.

/code-review --fix: fixed content-script grants covered by a manifest pattern, MV2 origins in permissions, broader denials (exact-string match only before); kept the no-context fallback (documented). Skipped: re-bridging the context dictionaries per permission in getAll (minor).

/verify: seeded worker probe in an isolated DETOUR_DATA_DIR printed getSelf {p:[storage,management],h:[https://example.com/*]} before, and with history and https://example.org/* granted {p:[storage,management,history],h:[https://example.com/*,https://example.org/*]}. Not verified: a live grant in the running app (covered by the tests).
<!-- SECTION:FINAL_SUMMARY:END -->
