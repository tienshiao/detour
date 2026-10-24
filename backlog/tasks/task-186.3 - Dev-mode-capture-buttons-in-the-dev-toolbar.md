---
id: TASK-186.3
title: 'Dev mode: capture buttons in the dev toolbar'
status: To Do
assignee: []
created_date: '2026-10-24 09:13'
labels:
  - dev-mode
  - feature
dependencies:
  - TASK-186.2
parent_task_id: TASK-186
priority: low
ordinal: 211000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Third part of TASK-186. Arc's toolbar has image capture buttons (see docs/dev-mode/arc-dev-toolbar.png). Proposed: capture the visible page and capture the full page, using WKWebView.takeSnapshot (full page needs the page's scroll size, or WKSnapshotConfiguration with a rect), to the clipboard and/or a file in Downloads with a toast. Decide which captures and where they go; an area-selection capture is optional.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The chosen capture buttons produce a correct image of the visible page (and full page, if chosen), delivered where decided
- [ ] #2 Works in a split pane and on a Retina display at the right scale
<!-- AC:END -->
