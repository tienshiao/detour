---
id: TASK-193.2
title: 'Quick Detour: a system-wide hotkey that opens it from any app'
status: To Do
assignee: []
created_date: '2026-10-24 10:11'
updated_date: '2026-10-24 10:21'
labels:
  - window
  - feature
dependencies:
  - TASK-193.1
parent_task_id: TASK-193
priority: medium
ordinal: 226000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Second part of TASK-193. A global hotkey (default Opt-Cmd-N, configurable, can be turned off in Settings) opens a new quick window from any app and brings Detour forward with only that window, not every Detour window. Proposed API: Carbon `RegisterEventHotKey` (needs no Accessibility permission, unlike an event tap); record the choice. A global shortcut takes the key from every other app, so the default must be easy to change or disable, and registration failure (another app owns it) is shown in Settings.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The hotkey opens a quick window from another app, activating Detour with that window in front and leaving other Detour windows where they were
- [ ] #2 The shortcut can be changed and turned off in Settings; a registration conflict is reported
- [ ] #3 The API choice and its permission needs are recorded in the wiki
<!-- AC:END -->
