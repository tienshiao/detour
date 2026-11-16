---
id: TASK-374
title: >-
  Shortcuts: Restore Defaults can put a default onto the Quick Detour hotkey's
  key without a warning
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - keyboard
  - shortcuts
dependencies: []
references:
  - wiki/features/keyboard-shortcuts.md
priority: low
type: bug
ordinal: 455000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-350's agent. TASK-350 made Reset and saved shortcuts check the Quick Detour hotkey and menu items no command is; Restore Defaults does not run those checks.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Restore Defaults warns about (or marks) a default that collides with the Quick Detour hotkey or an outside holder
- [ ] #2 A test covers it
<!-- AC:END -->
