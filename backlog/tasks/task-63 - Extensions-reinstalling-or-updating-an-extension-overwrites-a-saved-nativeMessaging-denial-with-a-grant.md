---
id: TASK-63
title: >-
  Extensions: reinstalling or updating an extension overwrites a saved
  nativeMessaging denial with a grant
status: To Do
assignee: []
created_date: '2026-09-13 20:03'
labels:
  - bug
  - extensions
  - 1password
dependencies: []
priority: medium
ordinal: 63000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-44 review. ExtensionManager.install(from:) (ExtensionManager.swift ~885-932) writes every manifest permissions entry as an ExtensionPermissionRecord with status granted and hands them to AppDatabase.savePermissions, which upserts on the (extensionID, permissionKey, permissionType) primary key. A user who turned nativeMessaging off in Settings (enforced since TASK-25, and now a real decision after TASK-44 cleared the pre-enforcement rows) loses that denial the next time the extension is installed again or updated: Settings > Install, a dropped .crx (BrowserWindowController+Navigation ~195, ExtensionsSettingsViewController ~573, AppDelegate ~145) all reach install(from:). After the upsert permissionStatus returns granted, nativeHostAccess returns allowed, and the desktop-app unlock is back on with no prompt or log line, which is exactly the silent re-grant TASK-44 was written to perform once. The same upsert may also clobber other saved apiPermission or matchPattern denials made after TASK-25; check the optional host permission rows too.

Fix shape: install must not overwrite an existing saved decision. Either insert only rows that have no saved decision yet (keep denied rows and user-revoked rows), or split "manifest-declared" from "user-decided" so the manifest write never touches a user row. Decide what an update that adds a NEW permission should do (grant, as today, is reasonable for required permissions). Note the second savePermissions site (~1646, the prompt path) is a user decision and must keep overwriting.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A nativeMessaging denial saved in Settings survives reinstalling and updating the extension: permissionStatus still reads denied and nativeHostAccess yields deniedByUser afterwards
- [ ] #2 Other saved denials (apiPermission and matchPattern, including optional host permissions) survive reinstall/update the same way; a newly declared permission on update is still recorded as granted
- [ ] #3 Tests cover both positive and negative cases (a denial survives; a fresh install still grants declared permissions) in NativeMessagingEnforcementTests or ExtensionPermissionTests
- [ ] #4 docs/1password-integration-plan.md decision notes for TASK-25/TASK-44 mention that install no longer resets user decisions
<!-- AC:END -->
