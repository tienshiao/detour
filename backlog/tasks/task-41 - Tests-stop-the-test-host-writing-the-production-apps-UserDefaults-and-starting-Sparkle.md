---
id: TASK-41
title: >-
  Tests: stop the test host writing the production app's UserDefaults and
  starting Sparkle
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 04:41'
updated_date: '2026-09-13 19:00'
labels:
  - tests
  - storage
dependencies: []
priority: low
ordinal: 41000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-36 audit. The DetourTests host is Detour.app with bundle id com.detourbrowser.mac, so it shares the production app's standard UserDefaults domain. Test runs write NSWindow Frame BrowserWindow and NSSplitView Subview Frames BrowserSplitView (window frame and sidebar split autosave, which the production app restores at launch) and Sparkle's SU* keys. Sparkle's SPUStandardUpdaterController (AppDelegate, startingUpdater: true) also starts in the test host and in isolated DETOUR_DATA_DIR app runs, so tests can schedule or perform update checks and record them in the production domain. TASK-36 already moved the content blocker's keys to a per-data-dir suite. Options: set frameAutosaveName/autosaveName only in the default data dir (or use a data-dir-suffixed name elsewhere); don't start the updater under XCTest or in non-default data dirs; and have TestEnvironmentSetup snapshot and restore the production domain's window/split keys as a safety net. Keep production behaviour (window frame and split restore, update checks) unchanged in the default data dir.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A full DetourTests run leaves the production domain's NSWindow Frame BrowserWindow, NSSplitView Subview Frames BrowserSplitView and SU* keys unchanged (verified with defaults read before and after)
- [x] #2 Sparkle's updater does not start in the test host or in non-default data dir runs, and still starts in the default data dir
- [x] #3 Window frame and sidebar split autosave still work in the default data dir; tests cover the data-dir decision
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Autosave names: BrowserWindowController derives the window frame autosave name and the split view autosaveName from the data directory (a pure helper, e.g. UserDefaultsScope.autosaveName("BrowserWindow") returning the plain name in the default data dir and "BrowserWindow-<DETOUR_DATA_DIR>" otherwise; reuse WebKitStorageScope.current.isDefaultDataDirectory / detourDataDirectoryName). Production behaviour in the default dir is unchanged.
2. Updater: AppDelegate starts SPUStandardUpdaterController only when not the XCTest host (AppDelegate.isRunningUnitTests) and in the default data directory; otherwise construct with startingUpdater: false and hide/disable the Check for Updates item.
3. Safety net: TestEnvironmentSetup snapshots the production domain keys (NSWindow Frame BrowserWindow, NSSplitView Subview Frames BrowserSplitView, and every SU* key) in testBundleWillStart and restores them in testBundleDidFinish, logging any key that changed during the run.
4. Tests: the autosave-name helper (default vs isolated dir); an assertion in TestEnvironmentSetup or a dedicated test that after opening and closing a browser window in the test host the production keys are unchanged.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
UserDefaultsScope.autosaveName suffixes the window frame and split view autosave names with the data directory outside the default one; Sparkle starts only when not the XCTest host and in the default data directory (static let startsUpdater), with the Check for Updates item and its separator omitted otherwise and one log.notice. TestEnvironmentSetup snapshots the production autosave keys and SU* keys, subscribes to UserDefaults.didChangeNotification (own-process writes only) and restores only keys this run changed, leaving foreign writes alone; scoped test keys are removed at bundle end. Review: fixed the net reverting a concurrently running production app, the launch-time blind spot (pinned by testLaunchWindowUsesTheScopedAutosaveNames), scoped keys accreting across runs, and the stale unscoped guard in SidebarVisibilityStateTests. Empirical AC #1: defaults read of com.detourbrowser.mac before/after a full run differs only in the scoped test key. AC #2 default-directory start verified by code inspection only. Full suite 1007 tests, 0 failures before review; 65 targeted after.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The test host no longer writes the production window/split autosave keys or starts Sparkle; production behaviour in the default data directory is unchanged. Verified by UserDefaultsScopeTests, ProductionDefaultsIsolationTests and a defaults diff across a full run.
<!-- SECTION:FINAL_SUMMARY:END -->
