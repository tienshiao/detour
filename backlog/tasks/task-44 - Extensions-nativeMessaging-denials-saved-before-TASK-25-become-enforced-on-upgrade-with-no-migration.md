---
id: TASK-44
title: >-
  Extensions: nativeMessaging denials saved before TASK-25 become enforced on
  upgrade with no migration
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 05:14'
updated_date: '2026-09-13 18:30'
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
- [x] #1 Decision recorded; if denials are cleared, a migration test shows a pre-existing nativeMessaging denied row no longer blocks native hosts after upgrade while a post-upgrade denial still does (NativeMessagingEnforcementTests)
- [ ] #2 If denials are honoured, the plan doc states it and the Settings switch tooltip explains that native hosts are blocked while it is off
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Decision: do not honour pre-TASK-25 denials. Before TASK-25 the OFF position was a visible no-op, so the saved row never reflected an enforced choice; silently blocking 1Password after an upgrade is worse than asking again.
2. Add migration v13 in Database.migrator deleting extensionPermission rows where permissionType is the apiPermission raw value, permissionKey is nativeMessaging, and status is denied. Rows written after v13 (real TASK-25 denials) are untouched by later launches because the migration runs once.
3. Test (NativeMessagingEnforcementTests or ExtensionDatabaseTests): migrate a fresh DB to v12 via the internal migrator, insert a denied nativeMessaging row plus an allowed row and a denied row for another key, migrate to latest, assert only the nativeMessaging denied row is gone; then assert a denial written after full migration is still enforced by ExtensionManager.nativeHostAccess (.deniedByUser).
4. Record the decision in docs/1password-integration-plan.md next to the TASK-25 decision line.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision: pre-TASK-25 denials are not honoured. Verified against 5d036c1^: the old toggle saved the row, showed the switch OFF on every relaunch, and pushed deniedExplicitly onto the loaded contexts for that session (breaking the polyfill bridge until relaunch), but native-host dispatch never read it, so the row is not a decision to lose native messaging. Migration v13 deletes every non-granted nativeMessaging apiPermission row (status <> granted, matching the fail-closed reader that maps unknown statuses to denied) so an upgrade cannot start silently refusing the 1Password unlock. Review pass: fixtures go through ExtensionPermissionRecord so a renumbered enum breaks the test; a post-migration denial is asserted enforced and to survive a second AppDatabase over the same queue (v13 runs once); rationale de-triplicated. AC #2 not applicable (denials not honoured). Follow-up surfaced by the review, not filed: ExtensionManager.install(from:) saves every manifest permission as granted, so a reinstall or update overwrites a saved nativeMessaging denial (pre-existing TASK-25 gap). Tests: ExtensionDatabaseTests 27 + NativeMessagingEnforcementTests 8, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Migration v13 clears nativeMessaging denials saved before TASK-25 enforced them, so upgrading does not silently block 1Password; the decision and its rationale are in docs/1password-integration-plan.md. Verified by ExtensionDatabaseTests (part-way migration to v12, seeded rows, only non-granted nativeMessaging rows removed, post-upgrade denial still deniedByUser and stable across a re-migration) and NativeMessagingEnforcementTests.
<!-- SECTION:FINAL_SUMMARY:END -->
