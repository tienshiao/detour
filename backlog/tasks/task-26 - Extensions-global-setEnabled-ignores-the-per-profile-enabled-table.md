---
id: TASK-26
title: 'Extensions: global setEnabled ignores the per-profile enabled table'
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
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
- [ ] #1 Global enable loads the extension only into profiles whose per-profile row is enabled or absent
- [ ] #2 Per-profile enable while the extension is globally disabled does not load it, and the Settings UI reflects both states
- [ ] #3 Tests cover both toggles in combination
<!-- AC:END -->
