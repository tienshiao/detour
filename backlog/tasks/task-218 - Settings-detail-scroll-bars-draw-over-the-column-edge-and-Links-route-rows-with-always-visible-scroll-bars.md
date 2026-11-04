---
id: TASK-218
title: >-
  Settings: detail scroll bars draw over the column edge, and Links route rows
  with always-visible scroll bars
status: To Do
assignee: []
created_date: '2026-10-27 22:21'
labels:
  - settings
  - ui
dependencies: []
priority: low
ordinal: 254000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-ups from TASK-211 (Settings list panes scroll on their own). 1) In Spaces, Profiles and Extensions the details column's overlay scroll bar draws over the column's right edge while scrolling; it could sit in the window margin instead. 2) Not checked in TASK-211: the Links pane's route rows with System Settings > Appearance > Show scroll bars set to Always (row heights and the trailing controls may be squeezed by the legacy scroll bar).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The details scroll bar no longer overlaps the column's content or edge (light and dark)
- [ ] #2 With Show scroll bars set to Always, every Settings list pane (Spaces, Profiles, Extensions, Links) lays out without clipped or squeezed rows, checked at runtime
<!-- AC:END -->
