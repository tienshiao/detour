---
id: TASK-74
title: >-
  Extensions: do not load extensions in the Private profile unless the user
  allows each one (Chrome's incognito default)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-14 06:38'
updated_date: '2026-09-20 23:27'
labels:
  - extensions
  - privacy
dependencies: []
priority: high
ordinal: 74000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decision 2026-09-13 (TASK-70 follow-up): until the Private profile's extension pages can run in its ephemeral store (TASK-73), every extension enabled in Private stores its data in WebKit's default, persistent data store — 1Password's item cache, localStorage and the cookies on the extension pages' own requests survive the Private window and the app. Adopt Chrome's default: extensions are OFF in the incognito profile unless the user opts in per extension ('Allow in Private'). Mechanics: the incognito profile already has per-profile enabled state (profileExtension rows, ExtensionManager.isEnabled(extensionID:inProfile:), setEnabled(id:profileID:enabled:), enabledExtensions(for:)); make the Private profile's default state disabled for every extension (existing installs included — a one-time migration that turns Private off for all current extensions, since today's implicit 'on' is the leak), and add an 'Allow in Private' switch per extension in ExtensionsSettingsViewController that flips only the incognito profile's row. Installing or updating an extension must not turn it on in Private (TASK-63 fixed the analogous nativeMessaging-grant overwrite). Show a short note next to the switch that extensions allowed in Private keep their data outside the private session until TASK-73 lands. Files: Detour/Extensions/Runtime/ExtensionManager.swift, Detour/Browser/Settings/ExtensionsSettingsViewController.swift, Detour/Storage/Database.swift (migration), Detour/Extensions/Storage/Models/ProfileExtensionRecord.swift.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A fresh install and an upgraded install both start with every extension disabled in the Private profile; the Private profile loads no extension context at launch (no 'Context loaded' for the incognito profile) and its Extensions menu and settings popover show none as active
- [x] #2 Each extension has an 'Allow in Private' switch in Extension Settings that enables it in the incognito profile only; turning it on loads the context in Private without a relaunch, turning it off unloads it and closes its Private extension pages
- [x] #3 Installing, updating or re-enabling an extension globally leaves its Private state untouched (tests with positive and negative cases, alongside ExtensionEnabledStateTests / ExtensionPermissionRestoreTests)
- [x] #4 docs/1password-integration-plan.md and the settings note explain that extensions allowed in Private keep their storage in the default store until TASK-73
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Approach changed 2026-09-20 (agreed with the user): no migration. The live DB has no profileExtension rows for the Private profile; extensions are on there only because 'missing row = enabled'. Flip that default for the incognito profile (TabStore.incognitoProfileID): missing row = DISABLED.
1. Database.swift: one helper for the per-profile default (true, except false for the incognito profile id); use it in isExtensionEnabled, isExtensionEnabledByProfile, enabledExtensionIDs(for:) (incognito: globally enabled ∩ rows with isEnabled = true) and in toggleExtensionPinned's insert (today hard-codes isEnabled: true, which would silently enable a pinned extension in Private).
2. ExtensionsSettingsViewController: 'Allow in Private' switch per extension under 'Enabled', calling ExtensionManager.setEnabled(id:profileID:enabled:) for the incognito profile (ensureIncognitoProfile not required — row is written even with no profile object loaded); disabled while the extension is globally off; note about storage living in the default store until TASK-73. ProfilesSettingsViewController toggles for Private read the same state.
3. Tests: default-off in Private for fresh rows, install/update/global re-enable leave Private untouched (positive + negative), pin in Private does not enable, allow/disallow loads/unloads the context live, enabledExtensionIDs and isExtensionEnabled agree for both profile kinds.
4. docs/1password-integration-plan.md note.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-09-20: no migration (agreed with the user, sole user): the live browser.db had no profileExtension rows for the Private profile, so 'missing row = off in Private' is the whole behaviour change. If an install ever had Private rows with isEnabled=1 (pin or toggle before this change), they would read as an allow; one-off fix: UPDATE profileExtension SET isEnabled=0 WHERE profileID='00000000-0000-0000-0000-000000000001'.
Code review (--fix) added: context.hasAccessToPrivateData = true for contexts loaded into the incognito profile (without it WebKit hides Private windows/tabs from the context and injects no content scripts), simpler enabledExtensionIDs, the same warning as a tooltip on the Private profile's toggles in Profiles settings.
Validation: ExtensionPrivateDefaultTests (13) + ExtensionEnabledStateTests, ExtensionStartupEnabledReadsTests, ExtensionDatabaseTests green (45 tests); agent run also green on AppDatabaseTests, ExtensionPermissionRestoreTests, NewProfileExtensionLoadTests, ExtensionOriginTrackingPreventionTests, ExtensionTabLifecycleTests, ExtensionPagePersistenceTests, ExtensionPageUndoTests. Runtime (isolated DetourVerify74, probe MV3 extension, unlocked screen): no Private context/row/injection by default; switch ON loads the context live with hasAccessToPrivateData and the content script injects in existing + new Private tabs; OFF unloads and stops injecting; global off dims the switch but keeps the choice; both states survive relaunch.
Known behaviours: uninstall cascades the Private allow away (reinstall starts off; Chrome remembers); an allowed extension's Private context loads at every launch, before any Private window exists (same as every profile) — until TASK-73 its worker can write to the default store in such a session. The rule is keyed on TabStore.incognitoProfileID, not isIncognito (only one incognito profile exists in production).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Extensions are off in the built-in Private profile unless allowed per extension: missing profileExtension row = off for that profile only (AppDatabase.extensionEnabledByDefault), shared by all three enabled-state readers and the pin insert; 'Allow in Private' switch + storage note in Extension settings; Private contexts get hasAccessToPrivateData. No migration needed. Commit f39e63f; unit tests + in-app runtime verification passed.
<!-- SECTION:FINAL_SUMMARY:END -->
