---
id: TASK-235
title: >-
  Tests: SettingsPaneColumnsTests depends on the shared DetourTests data
  directory being empty of link routes
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T03:00:00Z'
updated_date: '2026-11-03T05:17:00Z'
labels:
  - tests
dependencies: []
references:
  - DetourTests/SettingsPaneColumnsTests.swift
  - Detour/Browser/Settings/LinksSettingsViewController.swift
priority: low
type: bug
ordinal: 279000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen during TASK-231.1: testTheLinksPaneDoesNotNeedMoreThanTheListMinimum failed (natural height 1287 > 400) because ~/Library/Application Support/DetourTests/browser.db held 9 link routes left by an earlier harness or test run, and the test reads the shared LinkRouteStore expecting an empty list. It passed with the rows deleted. Any test that builds a settings pane over the shared store has the same weakness.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The Links pane tests build the pane over a store they own (in-memory or a fresh database), so rows in the shared test data directory do not change their result
- [x] #2 A test that seeds the shared store with routes before building the pane still passes
- [x] #3 Other settings pane tests that read shared stores are checked for the same dependency and fixed or listed in the task
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. LinksSettingsViewController gets init(linkRoutes: LinkRouteStore = TabStore.shared.linkRoutes); the editor is built over it. No other change.
2. SettingsPaneColumnsTests: the Links pane test builds the pane over a LinkRouteStore on an in-memory AppDatabase; the column-structure test does the same for its Links pane.
3. New test: seeds LinkRouteStore.shared with routes, builds the pane over its own store, asserts it still fits the minimum; removes the seeded routes in a defer/teardown.
4. Audit the other settings-pane tests (SettingsPaneHeightTests, ProfileSettingsLayoutTests, the rest of SettingsPaneColumnsTests) for shared-store reads; fix or list them in the notes.
5. /code-review --fix, /verify (isolated DETOUR_DATA_DIR, Settings > Links shows its routes), SettingsPane* + LinkRoute* suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Seam: LinksSettingsViewController.init(linkRoutes: LinkRouteStore = TabStore.shared.linkRoutes); the editor is built over it. Nothing else in the pane changed (space options and the TabStoreObserver still read TabStore.shared; a store on its own has no spaceContext, so space targets go unchecked, as in LinkRouteStoreTests).

Tests (SettingsPaneColumnsTests): the Links pane is built over LinkRouteStore(database: AppDatabase(dbQueue: DatabaseQueue())) in testTheLinksPaneDoesNotNeedMoreThanTheListMinimum and in the Links entry of testPanesWithAListScrollTheirColumnsAndTheOthersScrollAsOneBody. New testTheLinksPaneIgnoresRoutesInTheSharedStore adds 9 routes to TabStore.shared.linkRoutes (control: a pane over the shared store then exceeds the 400 pt minimum), builds the pane over its own store and checks it fits; each seeded route is removed in a teardown block. Also checked by hand: with 9 rows inserted into ~/Library/Application Support/DetourTests/browser.db before the run, SettingsPaneColumnsTests passed 22/22; the rows were deleted afterwards (linkRoute count 0).

AC #3 audit of the other settings-pane tests:
- SettingsPaneHeightTests, ProfileSettingsLayoutTests: pure functions over value inputs; no store reads.
- SettingsPaneColumnsTests fixtures (ListPane, WholePane, FooterPane): no stores.
- testPanesWithAListScrollTheirColumnsAndTheOthersScrollAsOneBody still builds General, QuickDetour, ContentBlocker, Spaces, Profiles and Extensions over the shared singletons (TabStore.shared, ExtensionManager.shared, AppDatabase.shared, ContentBlockerManager.shared). It asserts only structure (scrollView nil or not, minimumContentHeight), which does not depend on their contents, so left as is.
- testTheQuickDetourPaneFitsItsControls reads QuickDetourHotKey.shared / QuickDetourSettings.shared (UserDefaultsScope.defaults of the test host). Its natural height can change with stored state (a refused-shortcut warning line), but the assertion is a 150..<400 band that one extra line stays within. Left as is; would need the same kind of seam (settings/hotKey init parameters) if it ever flakes.

Review (/code-review --fix): fixed: the seeding test first removes task235-* routes a killed run left behind. Skipped: the leak's root cause sits in ExternalLinkRoutingTests (9 routes in setUp, removed only in tearDown, matching the 9 seen) and InPageLinkRoutingTests (3); out of scope, listed as a follow-up. Skipped: a shared sizing helper for makeLinksPane/makeListPane (minor).

Tests: SettingsPaneColumnsTests 22, SettingsPaneHeightTests 20, ProfileSettingsLayoutTests 15, LinkRouteStoreTests 39, LinkRouteEditorTests 15: 111 tests, 0 failures (before and after the review fix). SettingsPaneColumnsTests 22/22 also with 9 link routes inserted into the shared DetourTests browser.db first. Shared linkRoute table empty after each run.

/verify: Debug build in .derived; launched with DETOUR_DATA_DIR=DetourVerify235, quit, seeded 3 routes (a space target, Private Window, Mail -> Quarantine) into its browser.db, relaunched, opened Settings (Cmd+, posted to the PID) and clicked Links (HID click): the pane showed all three routes with their kinds, apps and targets, and the Default. Data dir and its two defaults keys removed afterwards. Not verified: nothing beyond the Links pane (the seam does not change other panes).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
LinksSettingsViewController takes its LinkRouteStore through init(linkRoutes:), defaulting to TabStore.shared.linkRoutes, so the Settings window is unchanged. SettingsPaneColumnsTests builds the Links pane over a store on an in-memory database; a new test seeds 9 routes into the shared store (control: a pane over it then exceeds the 400 pt minimum) and checks a pane over its own store still fits, removing the seeds in teardown. The other settings-pane tests were audited (notes): the rest read no shared store, or assert only structure. 111 tests pass; /verify showed the pane listing seeded routes in an isolated data directory. Follow-up: ExternalLinkRoutingTests/InPageLinkRoutingTests leave routes in the shared test database when the host dies before tearDown.
<!-- SECTION:FINAL_SUMMARY:END -->
