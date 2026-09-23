---
id: TASK-108
title: 'Tabs: Control+Tab MRU switcher with an overlay (Control+Shift+Tab reverses)'
status: To Do
assignee: []
created_date: '2026-09-23 06:22'
labels:
  - tabs
  - keyboard
dependencies: []
priority: medium
ordinal: 108000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Cmd+Tab-style most-recently-used tab switching: holding Control and pressing Tab shows an overlay of recent tabs (thumbnails/icons and titles), each press advances, Shift reverses, releasing Control commits; overlay items are mouse clickable. Needs a per-window MRU order. Follows the Cmd+Option+Up/Down task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Control+Tab shows an overlay of recent tabs and advances the highlight; releasing Control switches to the highlighted tab
- [ ] #2 Control+Shift+Tab moves the highlight backwards
- [ ] #3 Overlay items show a preview and title and can be clicked to switch
- [ ] #4 MRU order is tracked per window and survives tab close / space switches sensibly
<!-- AC:END -->
