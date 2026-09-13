---
id: TASK-41
title: >-
  Tests: stop the test host writing the production app's UserDefaults and
  starting Sparkle
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 04:41'
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
- [ ] #1 A full DetourTests run leaves the production domain's NSWindow Frame BrowserWindow, NSSplitView Subview Frames BrowserSplitView and SU* keys unchanged (verified with defaults read before and after)
- [ ] #2 Sparkle's updater does not start in the test host or in non-default data dir runs, and still starts in the default data dir
- [ ] #3 Window frame and sidebar split autosave still work in the default data dir; tests cover the data-dir decision
<!-- AC:END -->
