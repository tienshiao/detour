---
id: TASK-186.2
title: 'Dev mode: an under-construction toolbar above the page with the URL'
status: To Do
assignee: []
created_date: '2026-10-24 09:13'
updated_date: '2026-10-24 17:02'
labels:
  - dev-mode
  - ui
  - feature
dependencies:
  - TASK-186.1
parent_task_id: TASK-186
priority: medium
ordinal: 210000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Second part of TASK-186. Reference: docs/dev-mode/arc-dev-toolbar.png.

While the selected tab (or a split pane) is in dev mode, a toolbar sits across the top of that tab's web content: an "under construction" motif (Arc: faint diagonal stripes on a light bar), an info button, the page's URL, and a copy-link button on the right; the capture and inspector buttons are added by the sibling subtasks. The web view is laid out below it (not overlaid), per pane in a split.

Decide: whether clicking the URL opens the command palette in place (like the sidebar's faux address bar; recommended) or edits inline; what the info button shows (Arc: site info); behaviour with a Peek open, in fullscreen and when the docked Web Inspector is attached (WKWebView layout is frame-based because Auto Layout breaks the docked inspector — see wiki/tabs/split-tabs-hosting.md).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A dev-mode tab shows the toolbar above its web content and the page is laid out below it; a non-local tab has no toolbar
- [ ] #2 The toolbar shows the current URL, follows navigation, and the copy button copies it
- [ ] #3 Works per pane in a split, with a Peek open and with the docked Web Inspector; decisions recorded
- [ ] #4 Checked at runtime (window capture), light and dark
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-24): (defaults taken) clicking the URL opens the command palette in place, like the faux address bar; the info button opens the site popover (TASK-186.5); no toolbar inside a Peek panel (the host's toolbar stays).
<!-- SECTION:NOTES:END -->
