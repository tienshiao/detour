---
id: TASK-340
title: >-
  Settings: the window can stop mid-resize when a list pane first opens on a row
  other than the first
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T05:14:00Z'
updated_date: '2026-11-15T05:31:00Z'
labels:
  - settings
  - ui
dependencies: []
references:
  - TASK-338
  - Detour/Browser/Settings/SettingsWindowController.swift
  - Detour/Browser/Settings/SettingsPaneHeight.swift
  - wiki/features/settings.md
priority: low
type: bug
ordinal: 415000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-338 (and present before it): opening a list + detail pane (Profiles, Spaces, Extensions, Links) for the first time with a row other than row 0 selected can leave the Settings window stuck at a height partway through its resize animation; the unconverted Profiles pane was left at 671 pt, short of its natural height. Likely two refits racing: the pane's first layout and the selection's detail rebuild.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The cause is found and recorded
- [x] #2 Opening each list pane on any row, first time or later, ends at the pane's natural height (within the screen cap), with or without animation
- [x] #3 A test reproduces the race (fails before, passes after); checked at runtime
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Find which refit leaves the window mid-resize (fitWindow's completion bookkeeping). 2. Make the animator injectable and write a test that ends animations in the problem order (fails before). 3. Fix with a fit generation; keep the dragged-height behaviour. 4. Runtime: first opens of Profiles and Spaces on rows 1 and 2.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Cause (AC1): a refit mid-animation starts a new animation; the animation it replaces still calls its completion. When both head to the same height (a list pane opened on another row refits as its rows and wrapping labels settle, often to the height it is already going to), fitWindow's completion matched on the fit and the target height and took the old completion for the newer one's: it cleared animationTargetHeight and applied the bounds while the window was mid-resize; the next refit read the intermediate height as one the user had dragged to and kept it. Seen on the pre-TASK-338 Profiles pane (671 pt of content where the profile needed about 709) and by TASK-338's subagent (431 to 463 pt). Fix: each fit takes a generation number; only the newest fit's completion clears the target and applies the bounds. SettingsWindowController.animateFrame is the animator, replaceable in tests; animationTargetHeight is readable for them. Tests: SettingsWindowFitTests (2, new): a superseded completion arriving while the newer animation runs leaves its target in place and the window ends at the pane's height (failed before the fix: target nil), and a height the user dragged to is still kept. With SettingsPaneHeightTests, SettingsPaneColumnsTests, AutomationWindowKindsTests and the Settings form suites: 193 tests, 0 failures. Runtime (DetourVerify-340-*, removed): Profiles first opened on row 1, then row 2, ends at its natural 1008 pt; Spaces on rows 2 and 1 at its 400 pt minimum. Review: no findings on the fix (a newer fit always wins, every path still ends in finish).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Settings window no longer stops mid-resize when a list pane opens on another row: a replaced resize animation's completion could take itself for the newer one's (same height) and drop the target, and the next refit kept the mid-animation height. Fits now carry a generation and only the newest one's completion applies. A test that ends animations in that order failed before and passes; checked at runtime on Profiles and Spaces.
<!-- SECTION:FINAL_SUMMARY:END -->
