---
id: TASK-207
title: >-
  Extensions: tell other profiles' contexts when focus moves to a window they
  don't know
status: To Do
assignee: []
created_date: '2026-10-26 04:22'
labels:
  - extensions
  - bug
dependencies: []
priority: low
ordinal: 243000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-193.1 review. ExtensionManager.windowDidBecomeKey forwards didFocusWindow for a listed window to every profile's controller, and windowDidResignKey sends no 'no window focused' to the others. When a window of profile A (a Quick Detour, or a browser window on another profile) becomes key while profile B's browser window was focused, B's contexts ignore the unknown window, never receive WINDOW_ID_NONE, keep a stale focused window, and windows.onFocusChanged(WINDOW_ID_NONE) never fires for B. Pre-existing for browser windows; affects all window kinds.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 When focus moves to a window another profile's contexts do not list, those contexts receive focus-changed to WINDOW_ID_NONE
- [ ] #2 Tests in a real extension context (ExtensionPolyfillProfileWiringTests style) for browser windows across profiles and Quick Detour windows
<!-- AC:END -->
