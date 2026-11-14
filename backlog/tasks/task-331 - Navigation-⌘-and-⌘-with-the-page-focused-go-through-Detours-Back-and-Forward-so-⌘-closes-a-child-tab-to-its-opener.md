---
id: TASK-331
title: >-
  Navigation: ⌘[ and ⌘] with the page focused go through Detour's Back and
  Forward, so ⌘[ closes a child tab to its opener
status: To Do
assignee: []
created_date: '2026-11-14T23:44:00Z'
labels:
  - navigation
  - keyboard
dependencies: []
references:
  - TASK-325
  - TASK-320
  - Detour/Browser/Window/BrowserWebView.swift
  - wiki/tabs/back-swipe-to-opener.md
priority: medium
type: bug
ordinal: 405000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 during TASK-325 and again in TASK-320. Navigate > Back (⌘[) on a tab opened from another tab, with no back history, closes the child and selects its opener (navigateBackOrCloseChildTab), and so do the sidebar Back button, the back swipe (TASK-325) and the palette's Back (TASK-320). With the page focused, ⌘[ does nothing on such a tab: the item appears disabled, likely because WKWebView's own goBack:/goForward: actions sit ahead of the window controller in the responder chain and validate against WebKit's back list. Observed on the TASK-325 branch, not yet confirmed on a build without it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause is confirmed (with the page focused, on a build from before TASK-325 and on main) and recorded
- [ ] #2 ⌘[ with the page focused on a child tab with no back history closes it and selects its opener, as the Back button does; ⌘] goes forward as before
- [ ] #3 With focus in a page text field, the palette, the find bar or the sidebar, ⌘[ / ⌘] behave the same as the menu item, and WebKit's own back/forward still runs on tabs that have history
- [ ] #4 A test covers which responder handles goBack:/goForward: with the web view first responder; checked at runtime with /verify
<!-- AC:END -->
