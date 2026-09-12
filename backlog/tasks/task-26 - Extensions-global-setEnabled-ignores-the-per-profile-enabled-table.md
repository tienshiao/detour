---
id: TASK-26
title: 'Extensions: global setEnabled ignores the per-profile enabled table'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
updated_date: '2026-09-12 22:50'
labels:
  - extensions
  - bug
dependencies: []
priority: low
ordinal: 26000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-14 code review. ExtensionManager.setEnabled(id:enabled:) loads or unloads the extension in every profile, ignoring the per-profile rows written by setEnabled(id:profileID:enabled:). Re-enabling an extension globally therefore loads it into a profile where the user had disabled it, and disabling globally then re-enabling loses the per-profile state. Make the global toggle respect the per-profile table (load only where the profile row is enabled or absent), and make the per-profile path consistent when the global flag is off. Cover with tests on ExtensionManager against real Profiles.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Global enable loads the extension only into profiles whose per-profile row is enabled or absent
- [x] #2 Per-profile enable while the extension is globally disabled does not load it, and the Settings UI reflects both states
- [x] #3 Tests cover both toggles in combination
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add one rule helper ExtensionManager.isEnabled(extensionID:inProfile:) = global flag AND (per-profile row enabled or absent), backed by AppDatabase.isExtensionEnabled.
2. Add a reconcile helper that loads/unloads a profile's context to match the rule (idempotent, reads persisted flags at call time); route launch (loadExtensionsIntoProfile), install, both setEnabled overloads, enabledExtensions(for:) and pinnedExtensions(for:) through it.
3. Global setEnabled writes only the global flag (per-profile rows preserved); per-profile setEnabled writes only the row. Unloads close pages only in the profile that unloaded (TASK-14 closeExtensionPages); loads announce windows/tabs to the new context only.
4. Profiles settings pane: list every installed extension; per-profile switch shows the saved row value, disabled and dimmed while the extension is globally off.
5. New ExtensionEnabledStateTests against real Profiles: combinations of both toggles, launch path, per-profile page closing. Run with Extension*/WK* classes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Rule helper: ExtensionManager.isEnabled(extensionID:inProfile:) (backed by AppDatabase.isExtensionEnabled) = global flag AND (per-profile row on or absent). reconcileExtensionContext(_:in:) loads/unloads one profile's context to match it, reading saved flags at call time (idempotent). Launch (loadExtensionsIntoProfile), install, both setEnabled overloads, enabledExtensions(for:) and pinnedExtensions(for:) all use the rule; DB enabledExtensionIDs(for:) is no longer called by app code. Both setEnabled overloads are now @MainActor and reconcile synchronously (previously a Task hop) - all callers are main-actor settings view controllers / tests. A load announces windows/tabs only to the new context; an unload closes pages only in the profile that unloaded (TASK-14 closeExtensionPages). Removed Profile.loadExtension (unused wrapper that bypassed the rule). Settings > Profiles now lists every installed extension; the switch shows the profile's saved choice (new AppDatabase.isExtensionEnabledByProfile) and is disabled with a dimmed name + tooltip while the extension is globally off. ExtensionsSettingsViewController unchanged. Finding (not fixed, out of scope): TabStore.addProfile never loads extensions into a newly created profile (they appear only after relaunch); wiring it to loadExtensionsIntoProfile would load contexts into every test-created profile, so left for a follow-up.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Global and per-profile extension toggles now share one rule: enabled in a profile iff enabled globally AND not turned off for that profile. Each toggle writes only its own flag, so a global disable keeps per-profile choices and a global re-enable restores them; a per-profile enable while globally off is saved but does not load. All load paths (launch, install, both toggles) reconcile through ExtensionManager.reconcileExtensionContext, and unloading closes extension pages only in the affected profile. Settings > Profiles shows every installed extension's per-profile switch, disabled and dimmed while the extension is globally off. New ExtensionEnabledStateTests (8 tests, real Profiles) cover toggle combinations, the launch path, per-profile page closing and pinned icons; all Extension*/WK* classes pass (318 tests, 0 failures). Follow-up candidate: TabStore.addProfile does not load extensions into a new profile until relaunch.
<!-- SECTION:FINAL_SUMMARY:END -->
