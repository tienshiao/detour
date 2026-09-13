---
id: TASK-44
title: >-
  Extensions: nativeMessaging denials saved before TASK-25 become enforced on
  upgrade with no migration
status: To Do
assignee: []
created_date: '2026-09-13 05:14'
labels:
  - extensions
  - bug
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - Detour/Storage/Database.swift
priority: low
ordinal: 44000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the review of the TASK-25 commit (5d036c1). Before TASK-25 the Extensions settings listed nativeMessaging as an ordinary required-permission toggle whose OFF position (after the Revoke Permission? alert) wrote an extensionPermission row with status denied, while ExtensionManager.nativeHostAccess ignored the saved decision (it only checked the manifest), so flipping it off was a visible no-op. TASK-25 now enforces that row at host dispatch (ExtensionManager.nativeHostAccess returns .deniedByUser), and AppDatabase.permissionStatus also maps an unrecognised raw status to denied. A user who flipped the switch off before the upgrade gets 'Access to the specified native messaging host is forbidden' for every real host (e.g. the 1Password desktop-app unlock) after upgrading, with no migration and no prompt; the switch does show OFF in Settings (apiPermissionIsOn), so it is discoverable and reversible, but silent. Decide whether pre-TASK-25 denials should be honoured: if not, add a one-time migration that deletes nativeMessaging denied rows written before the schema bump (or stamps rows with the schema version they were written under and ignores older ones); if yes, record the decision in docs/1password-integration-plan.md and consider a one-time notice.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Decision recorded; if denials are cleared, a migration test shows a pre-existing nativeMessaging denied row no longer blocks native hosts after upgrade while a post-upgrade denial still does (NativeMessagingEnforcementTests)
- [ ] #2 If denials are honoured, the plan doc states it and the Settings switch tooltip explains that native hosts are blocked while it is off
<!-- AC:END -->
