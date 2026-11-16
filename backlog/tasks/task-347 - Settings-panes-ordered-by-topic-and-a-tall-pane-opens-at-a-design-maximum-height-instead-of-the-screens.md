---
id: TASK-347
title: >-
  Settings: panes ordered by topic, and a tall pane opens at a design maximum
  height instead of the screen's
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T22:59:00Z'
updated_date: '2026-11-16T05:54:00Z'
labels:
  - settings
dependencies: []
references:
  - Detour/Browser/Settings/SettingsWindowController.swift
  - Detour/Browser/Settings/SettingsPaneHeight.swift
  - wiki/features/settings.md
priority: low
type: feature
ordinal: 426000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user, 2026-11-15, after clicking through Settings: (1) the Shortcuts pane opens as tall as the screen allows (every row is its natural height, about 1,800 pt), which looks unbounded; there should be a maximum. (2) The toolbar order should group related panes: Profiles next to Spaces, Links next to Quick Detour. Decided with the user: order General · Profiles · Spaces · Links · Quick Detour · Search · Extensions · Content Blocking · Shortcuts; a pane opens no taller than a design maximum (720 pt of content: tall enough that a normal profile's Profiles pane, 709, does not scroll) and scrolls past it, and the user can still drag the window taller, up to the screen's cap.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The toolbar shows General, Profiles, Spaces, Links, Quick Detour, Search, Extensions, Content Blocking, Shortcuts in that order
- [x] #2 A pane taller than the design maximum opens at it and scrolls; the window can be dragged taller up to the screen's cap and back down; panes shorter than the maximum behave as before
- [x] #3 A pane whose height changes while shown keeps the rule: a window at its opening height follows to the new opening height, one the user dragged keeps its height within the new bounds
- [x] #4 SettingsPaneHeightTests and the pane order test cover the rule and the order; checked at runtime (Shortcuts opens at the maximum and drags taller; the toolbar order)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. paneOrder: General, Profiles, Spaces, Links, Quick Detour, Search, Extensions, Content Blocking, Shortcuts; update the order test.
2. SettingsMetrics.designMaximumContentHeight = 720. SettingsPaneHeight.fit: initial = min(full, max(design, floor)); minHeight = min(floor, cap, initial); maxHeight = full (natural or minimum, capped to the screen). refit: at the old opening height follow to the new opening height; at the old maximum (dragged fully open) follow to the new maximum; otherwise clamp.
3. Tests in SettingsPaneHeightTests; wiki settings.md (height rule, pane table, order); /verify Shortcuts and the toolbar.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: SettingsWindowController.paneOrder by topic; SettingsMetrics.designMaximumContentHeight = 720; SettingsPaneHeight.fit opens at min(full, max(720, explicit minimum)) and keeps maxHeight = natural (or minimum) capped to the screen, minHeight = min(floor, cap, initial); refit follows a window at its opening height to the new opening height and one dragged fully open to the new maximum, otherwise clamps. Tests: SettingsPaneHeightTests (27, new cases for the design maximum, tall fixed and list panes, short screens and refits), SettingsWindowFitTests, SettingsPaneColumnsTests (order), SettingsSwitchRowTests, SettingsFormTests, ShortcutsSettingsPaneTests, ProfileSettingsLayoutTests, SettingsGuideLinkTests, SettingsCaptureHarnessTests: 126 run, 1 skipped, 0 failures; after the review's refactor the three height/fit/columns suites again 51/0. Runtime (DETOUR_DATA_DIR launch, endpoint open_ui): Shortcuts opened at 808 pt (720 content + 88 chrome) with its list scrolling; Profiles 808 (its natural height in that run is above 720); General 677 (natural); set_window_frame made the Settings window 1108 pt tall and it stayed. The toolbar order was not seen at runtime (the endpoint's screenshot is the content view only); covered by the order test. Review (medium --fix): no correctness bugs; renamed a test helper, reused floorHeight, wiki lists Search and Shortcuts among the 400 pt panes. Accepted: a window the user dragged back to exactly its opening height follows the pane like an untouched one; a pane under 720 that grows past it now stops at 720 and scrolls.

2026-11-15, the user's decision: keep the 720 pt opening maximum and accept that the Profiles pane (~1008 pt natural on the TASK-338 grouped form) opens at the cap and scrolls. The code comment on designMaximumContentHeight is corrected under TASK-353.
<!-- SECTION:NOTES:END -->
