---
id: TASK-338
title: >-
  Settings: System Settings–style grouped rows, with labels on the left and
  switches and controls aligned on the right
status: To Do
assignee: []
created_date: '2026-11-15T02:08:00Z'
labels:
  - settings
  - ui
dependencies: []
references:
  - TASK-328
  - TASK-336
  - TASK-292.11
  - Detour/Browser/Settings/SettingsPaneViewController.swift
  - Detour/Browser/Settings/SettingsMetrics.swift
  - Detour/Browser/Settings/ProfileSettingsLayout.swift
  - wiki/features/settings.md
priority: medium
type: feature
ordinal: 413000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14 by the user after TASK-328, with a screenshot of macOS System Settings (Apple Intelligence & Siri) as the reference: "the alignment of the switches and organization of some of the settings can still be improved ... rows and the toggles being placed on the right side".

The reference layout: a bold section header above a rounded, inset group box. Inside it, one row per setting, separated by hairlines; the setting's name sits on the left and its control on the right (switch, pop-up, value plus button). Explanatory text sits under the name inside the row, in secondary text, with "Learn more…" style links. A footnote can close the group, and buttons that act on the whole group sit below it on the right.

Today (after TASK-328) General and Quick Detour put a sentence-length label and then a switch right after it, so the switches do not line up across rows. Help text sits outside any group. Profiles uses a right-aligned label column with controls after it, plus bordered boxes for filter lists and extensions. The panes do not share one form layout.

The toolbar-tab Settings window stays; only the pane content changes. TASK-336's accessibility naming (the label names its control, read once) and every accessibility identifier must survive. So must TASK-292.11's Learn more links and the automation endpoint's restrictions on the General pane's Automation section (TASK-228.7). The user's reference screenshot is in the lead's scratchpad (not committed: it shows the user's account).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A reusable grouped-form component (section header, inset group, rows with label left and control right, row help text, separators, footnote, trailing buttons) is used by every pane's settings, and pane-specific layout code for those rows is removed
- [ ] #2 General, Quick Detour, Search, Links (default browser and routes options), Content Blocking, Shortcuts, Profiles (detail side) and Extensions (detail side) use it; list + detail panes keep their list and use the form on the detail side
- [ ] #3 Controls in a group share one right edge; labels share one left edge; long labels and help text wrap without overlapping the control, at the minimum and maximum pane widths
- [ ] #4 Light and dark appearance, Increase Contrast and Reduce Transparency look right (captured and checked)
- [ ] #5 Accessibility names and identifiers are unchanged (TASK-336 tests pass), Learn more links still open their guide pages, pane heights still fit (SettingsPaneHeight), and the automation endpoint still refuses the Automation section
- [ ] #6 Before/after captures of every pane are attached to the task notes for the user to review
<!-- AC:END -->
