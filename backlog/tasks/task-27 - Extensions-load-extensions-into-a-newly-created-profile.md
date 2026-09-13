---
id: TASK-27
title: 'Extensions: load extensions into a newly created profile'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 23:49'
updated_date: '2026-09-13 00:26'
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
- [x] #1 An extension enabled globally loads into a profile created mid-session without a relaunch: its action appears in that profile's windows and its content scripts run on pages there
- [x] #2 A per-profile disable applied to the new profile before or after creation is respected (no context loads where the profile row is off)
- [x] #3 The new profile's service-worker extensions receive runtime.onInstalled with reason install exactly once (TASK-22 ledger)
- [x] #4 Tests cover the new-profile load path without making unrelated TabStore/Profile tests load extension contexts
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. TabStoreObserver gains tabStoreDidAddProfile(_:) (default no-op). TabStore notifies it from every mid-session creation path: addProfile, ensureIncognitoProfile (creates the Private profile on first launch without a saved session, when the first private window opens) and ensureDefaultProfile. restoreSession's bulk load is not notified: it runs before contexts load and the launch loop covers it.
2. ExtensionTabObserver (already registered on TabStore.shared by ExtensionManager.initialize) forwards to ExtensionManager.profileWasAdded(_:), which calls loadExtensionsIntoProfile (TASK-26 reconcile rule, TASK-22 wake, TASK-24 resolve). Skipped until loadInstalledExtensions has reached its per-profile loop (profiles added before are loaded by that loop), and skipped when the test opt-out switch is off.
3. Test opt-out: ExtensionManager.loadsExtensionsIntoAddedProfiles (default true); TestEnvironmentSetup turns it off at bundle start because the test host runs AppDelegate and therefore ExtensionManager.initialize. Separate TabStore instances never reach ExtensionManager at all.
4. Tests: new NewProfileExtensionLoadTests (real Profiles via TabStore.shared.addProfile with the switch on): global enable loads + content script runs on a page in the new profile; global disable before creation loads nothing then enable loads; per-profile disable/enable after creation; opt-out off loads nothing; real service worker gets install exactly once (ledger + second worker start gets nothing). TabStoreTests: observer callback fires once per created profile incl. incognito.
5. Check deleteProfile and other paths; note findings. Run targeted classes, then full DetourTests.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Seam: TabStoreObserver.tabStoreDidAddProfile(_:) (default no-op), sent by TabStore.addProfile, ensureIncognitoProfile and ensureDefaultProfile when they create a profile. ExtensionTabObserver (registered on TabStore.shared by ExtensionManager.initialize) forwards to ExtensionManager.profileWasAdded, which runs loadExtensionsIntoProfile: TASK-26 reconcile rule, TASK-22 wake, TASK-24 resolve. TabStore does not depend on ExtensionManager.

Why a switch as well: the test host is the app, so AppDelegate runs ExtensionManager.initialize and the observer is live in every test. Observing only after initialize is therefore no opt-out. Eight test classes call TabStore.shared.addProfile and then wire contexts by hand (e.g. WKExtensionIntegrationTests puts its own context into extensionContexts). ExtensionManager.loadsExtensionsIntoAddedProfiles (default true) is turned off once in TestEnvironmentSetup.testBundleWillStart, and NewProfileExtensionLoadTests turns it back on per test. TabStore instances other than .shared (TabStoreTests, SplitTabTests, PinnedTabMoveTests, ExtensionPagePersistenceTests) never reach ExtensionManager at all. An explicit call from ProfilesSettingsViewController was rejected because it would miss the Private-profile path and any future creation path, and the wiring would be untestable.

Launch race: profileWasAdded waits for hasLoadedInstalledExtensions, set just before loadInstalledExtensions' per-profile loop. Profiles created at launch (restoreSession's Private, ensureDefaultSpace's Default) are notified before the async load, and that loop covers them. A partial extensions list is never loaded.

Other paths:
- ensureIncognitoProfile had the same bug. On a first launch with no saved session, restoreSession returns before creating the Private profile, so the first private window created it with no extensions until relaunch. Covered.
- ensureDefaultProfile only runs at launch. Covered anyway.
- restoreSession's saved profiles are not notified (launch loop).
- No undo or restore re-adds a deleted profile: Settings delete has no undo, and nothing else appends to profiles.
- deleteProfile already unloads every context. Its profileExtension and extensionInstalledEvent rows stay behind as orphans (no FK, and AppDatabase.deleteProfile does not remove them). This is harmless because profile ids are fresh UUIDs, but it is not cleaned up. Not changed here.

AC2 'before creation': addProfile mints the id, so no per-profile row can exist before creation. The only earlier state is the global flag (tested). The load reads the rows at call time through reconcile.

Tests: NewProfileExtensionLoadTests (6) and TabStoreTests +2 (observer fires once per created profile, including Private and Default). Mutation check with profileWasAdded made a no-op: 3 of the 6 new tests fail (load, per-profile toggle, worker install). The worker test uses a real classic service worker with the polyfill prepended. It checks that the ledger advances to 1.0.0, that the worker saw exactly [install] with mode detour and claimCount 1, and that after a per-profile off/on the fresh worker claimed once and got nothing. The new class passed 5 iterations in a row. No migration added. Not verified in the running app: no live UI check of the toolbar action in a new profile's window.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A profile created mid-session now gets its enabled extensions straight away. TabStore tells observers when it creates a profile (addProfile, plus the Private and Default profiles created on demand). ExtensionManager's existing TabStore observer then runs loadExtensionsIntoProfile, so the new profile follows TASK-26's per-profile rule, has TASK-22's onInstalled install delivered once, and gets TASK-24's page resolution. The per-profile Settings toggles work on it immediately. The load waits for launch's installed-extension load. Tests opt out through ExtensionManager.loadsExtensionsIntoAddedProfiles, turned off in TestEnvironmentSetup, because the test host runs ExtensionManager.initialize. Also fixed: the Private profile created by the first private window on a launch with no saved session had no extensions. Verified with NewProfileExtensionLoadTests (6, including a real service worker getting install exactly once), 2 new TabStoreTests, a mutation check, and the full DetourTests target: 796 tests, 0 failures.
<!-- SECTION:FINAL_SUMMARY:END -->
