---
id: TASK-355
title: >-
  Back swipe: swiping forward shows a picture of the page being returned to, not
  a blank card
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
labels:
  - tabs
  - navigation
  - gestures
dependencies: []
references:
  - TASK-325
  - wiki/tabs/back-swipe-to-opener.md
priority: low
type: feature
ordinal: 435000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user's decision 2026-11-15 on TASK-325's provisional choice. After a back swipe out of a page that has a forward item, the forward swipe slides in a blank card (the window's background colour) until the forward page commits (max 1 s), because WebKit's own snapshot of the forward page is in a store Detour cannot read. The user chose the alternative: Detour takes its own picture of the page as the user leaves it going back, and slides that in on the forward swipe. The other two TASK-325 choices were confirmed as built (plain background under a split pane; a pinned tab or favourite is never swiped closed).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A forward swipe after a back swipe shows a picture of the page as it was left, not a blank card
- [ ] #2 When no picture exists (e.g. after a relaunch, or the page was never left by a swipe) the blank card is the fallback
- [ ] #3 NavigationSwipeTests cover the picture and the fallback; checked at runtime with a trackpad or the endpoint
<!-- AC:END -->
