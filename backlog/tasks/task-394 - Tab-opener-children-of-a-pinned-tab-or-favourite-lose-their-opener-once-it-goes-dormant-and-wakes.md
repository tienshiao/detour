---
id: TASK-394
title: >-
  Tab opener: children of a pinned tab or favourite lose their opener once it
  goes dormant and wakes
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:42:00Z'
labels:
  - tabs
  - opener
dependencies: []
references:
  - wiki/tabs/tab-opener.md
  - Detour/Browser/TabStore.swift
priority: low
type: task
ordinal: 475000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-378, out of its scope); read from code. A pinned tab or favourite that goes dormant (Cmd+W, the row's minus button, `tabs.remove`, a space moved to another profile) drops its backing tab; its wake builds a new `BrowserTab` with a new id. A child whose `parentID` named the dropped tab no longer resolves it (`Space.openerTab`), so Back, the back swipe and Cmd+W no longer return to the pinned tab or favourite from that child after the wake. TASK-378 kept the tile's own link to its opener across dormancy, not its children's link to it. The same identity rule already holds for a reopened or undone normal opener (wiki/tabs/tab-opener.md, "Identity decides the rest"), so this is a decision before it is a fix: keep the backing tab's id across dormancy (the woken tab reuses it), relink the children at wake, or accept and record it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The decision (keep the id, relink at wake, or accept) is recorded in this task and on wiki/tabs/tab-opener.md
- [ ] #2 If changed: a child of a pinned tab or favourite that went dormant and woke resolves it again (Back selects it), covered by a test
<!-- AC:END -->
