---
id: TASK-220
title: >-
  Extensions: a popup whose content is wider than its first size stays at
  126x126 and is cut off
status: To Do
assignee: []
created_date: '2026-10-27 22:21'
labels:
  - extensions
  - bug
dependencies: []
references:
  - Detour/Extensions/UI/ExtensionPopoverController.swift
priority: low
ordinal: 256000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen during TASK-210's runtime check: the verify probe extension's popup, opened from the Quick Detour bar, stayed at 126x126 points and cut off its 220-point-wide content. The popover sizes itself from the extensionPopupResize message (ExtensionPopoverController). Find why the resize did not apply (message not sent, measured before layout, or ignored) and whether the main window's popups have the same problem.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A popup with fixed 220x300 content opens at that size from both the main window and the Quick Detour bar
- [ ] #2 A popup that changes size after load resizes the popover
- [ ] #3 Checked at runtime with a test extension, light and dark
<!-- AC:END -->
