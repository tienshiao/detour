---
id: TASK-177
title: >-
  Favourites: a selected favourite shows no load progress, and nothing tells the
  user a page has stopped responding
status: To Do
assignee: []
created_date: '2026-10-12 23:34'
labels:
  - sidebar
  - favorites
dependencies: []
priority: low
ordinal: 200000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found with TASK-175. Load progress is drawn only on sidebar rows (TabCellView.updateProgress). A favourite has no row, so while it is selected the Reload/Stop button is the only sign that a load is in flight. Separately, no surface tells the user that a page's web process has stopped responding (TASK-176 recovers on Reload, but a frozen page the user is only looking at gives no hint). Decide what, if anything, to show: progress on the favourite tile, a window-level bar, a toast or an overlay for an unresponsive page.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A selected favourite that is loading shows progress somewhere the user can see
- [ ] #2 A decision is recorded on whether and how an unresponsive page is announced
<!-- AC:END -->
