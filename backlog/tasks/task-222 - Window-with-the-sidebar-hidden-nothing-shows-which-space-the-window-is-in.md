---
id: TASK-222
title: 'Window: with the sidebar hidden, nothing shows which space the window is in'
status: To Do
assignee: []
created_date: '2026-10-27 22:22'
labels:
  - window
  - sidebar
  - design
  - question
dependencies: []
references:
  - wiki/sidebar/visibility-and-auto-hide.md
  - wiki/tabs/split-tabs-hosting.md
  - Detour/Browser/Window/BrowserWindowController.swift
priority: medium
ordinal: 258000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
With the sidebar hidden the web view runs edge to edge, so windows in different spaces look identical; the user cannot tell which space (or profile) a window is showing without revealing the sidebar. Today a space's colour (Space.color, from colorHex) is used only by the sidebar: BrowserWindowController sets tabSidebar.tintColor in three places, and +TabStore updates it when the colour changes. Nothing else in the window uses it.

Arc and others inset the web view a little so the space's colour shows around it as a frame. Detour already does this for a hosted split: hostedSplitFrame insets the panes by UIConstants.splitPaneInset (10 pt on Tahoe, 8 before) with rounded corners (16 / 8 pt), and goes full bleed and square in fullscreen.

No solution is decided. Options to weigh:
1. Inset the single web view like a split pane all the time, with the space colour (or the sidebar's tinted material) behind it. This is consistent with split view and Arc, but costs a few points of page.
2. Inset only while the sidebar is hidden. This keeps today's look when the sidebar shows, but the web view resizes on every toggle and during hover-reveal.
3. A thin colour edge or strip (one side, or the top) instead of a full inset.
4. A transient cue: show the space's emoji, name and colour briefly when a hidden-sidebar window switches space or becomes key.

Things any choice must handle: fullscreen (split goes full bleed there), Peek and its insets, the find bar, toasts, the dev toolbar and the docked Web Inspector, snapshot stand-ins (NSImageView) when another window owns the tab, the sidebar's hover-reveal and its animation, Private windows (no space colour of their own), and Quick Detour windows (not affected unless decided).

References: wiki/sidebar/visibility-and-auto-hide.md, wiki/tabs/split-tabs-hosting.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The approach is chosen with the user and recorded (in the task and the wiki), including what happens in fullscreen and in Private windows
- [ ] #2 With the sidebar hidden, a user can tell two windows in different spaces apart at a glance, checked at runtime in light and dark
- [ ] #3 Split view, Peek, the find bar, toasts, the dev toolbar and a docked Web Inspector still lay out correctly with the change
- [ ] #4 Showing, hiding and hover-revealing the sidebar animate without the page jumping or flashing
<!-- AC:END -->
