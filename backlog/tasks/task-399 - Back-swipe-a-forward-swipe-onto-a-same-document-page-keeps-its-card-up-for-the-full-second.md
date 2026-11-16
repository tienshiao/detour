---
id: TASK-399
title: >-
  Back swipe: a forward swipe onto a same-document page keeps its card up for
  the full second
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:43:00Z'
labels:
  - navigation
  - gestures
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+NavigationSwipe.swift
  - wiki/tabs/back-swipe-to-opener.md
priority: low
type: bug
ordinal: 480000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-376); read from code, not measured. After a completed forward swipe the veneer (the card carrying Detour's picture of the forward page) stays over the pane until the web view's main-frame load commits or fails (`navigationSwipeMainFrameNavigationDidEnd(in:)`, called from the commit and failure callbacks) or `coverTimeout`, 1 s (`BrowserWindowController+NavigationSwipe.swift`, where the swipe completes). A forward move onto a same-document entry (a page 2 made by `pushState`) has no main-frame commit, so the card stays the full second over a page that has already changed. TASK-376 measured the same-document back case for the picture (it gets the plain card); the forward cover timing was not checked. Wiki: wiki/tabs/back-swipe-to-opener.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A forward swipe onto a same-document entry fades its card once the move has happened, not after the 1 s timeout
- [ ] #2 A cross-document forward swipe still keeps the card until the commit; a test covers both
<!-- AC:END -->
