---
id: TASK-27
title: 'Extensions: load extensions into a newly created profile'
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-12 23:49'
labels:
  - extensions
  - profiles
  - bug
dependencies: []
priority: medium
ordinal: 27000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-26 work. TabStore.addProfile (Detour/Browser/TabStore.swift) creates and saves a Profile but nothing calls ExtensionManager.loadExtensionsIntoProfile for it: that is only called for the profiles present at ExtensionManager.initialize. A profile created mid-session therefore has no extension contexts at all (no toolbar actions, no content scripts, no background workers) until the app is relaunched, even though Settings lists the extensions as enabled for it. The fix is to load the profile's enabled extensions when it is created (going through TASK-26's isEnabled/reconcileExtensionContext rule, so per-profile rows are respected) and to have the per-profile Settings toggles work on it immediately. The TASK-26 agent held off because calling it from addProfile would load extension contexts into every Profile the unit tests create; decide how tests opt out (e.g. load from the UI path that creates profiles, or an injectable hook) rather than slowing or destabilising the whole suite. TASK-22 note: a profile created after an install has no onInstalled ledger row, so its first worker start should deliver install; verify that once contexts load.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An extension enabled globally loads into a profile created mid-session without a relaunch: its action appears in that profile's windows and its content scripts run on pages there
- [ ] #2 A per-profile disable applied to the new profile before or after creation is respected (no context loads where the profile row is off)
- [ ] #3 The new profile's service-worker extensions receive runtime.onInstalled with reason install exactly once (TASK-22 ledger)
- [ ] #4 Tests cover the new-profile load path without making unrelated TabStore/Profile tests load extension contexts
<!-- AC:END -->
