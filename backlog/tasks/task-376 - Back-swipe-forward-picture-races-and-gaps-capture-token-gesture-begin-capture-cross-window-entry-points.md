---
id: TASK-376
title: >-
  Back swipe: forward-picture races and gaps (capture token, gesture-begin
  capture, cross-window, entry points)
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
labels:
  - tabs
  - navigation
  - gestures
dependencies: []
references:
  - wiki/tabs/back-swipe-to-opener.md
priority: low
type: task
ordinal: 457000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-355's review, left as findings. (1) The async capture has no request token: a narrow race can store a moments-old picture as unused. (2) Capturing at WebKit's gesture begin also snapshots forward and cancelled swipes; they are dropped later but can push another tab out of the 4-entry cache (_webViewWillEndNavigationGesture:withNavigationToBackForwardListItem: might be the better hook; reachability unchecked). (3) A tab moved to another window leaves its picture in the old window's cache. (4) Capture hooks sit at each back entry point, so a future back-history menu would get the plain card.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each item fixed or recorded as accepted on the back-swipe page
- [ ] #2 Tests for what changes
<!-- AC:END -->
