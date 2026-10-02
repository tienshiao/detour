---
id: TASK-128
title: >-
  Window: on launch the sidebar's hidden 'Search Archive…' field holds keyboard
  focus instead of the page
status: To Do
assignee: []
created_date: '2026-10-02 01:47'
labels:
  - window
  - sidebar
  - bug
dependencies: []
priority: medium
ordinal: 128000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while runtime-verifying TASK-78 (2026-10-01): when a browser window first appears, first responder is the archive page's search field (Detour/Browser/Sidebar/ArchivePageView.swift, placeholder 'Search Archive…') even though the archive page is not the visible sidebar page. Observed via the Accessibility API (focused element = AXTextField with that placeholder) in a signed debug build on an isolated profile, in three launches: an empty profile (no tabs, 'A rare moment of tab peace.' showing), a restored single tab, and a restored split. Consequences: keys typed right after launch go into the off-screen field (a space and a URL typed without opening the palette ended up as its value) and the restored page gets no keyboard input — space does not scroll, page shortcuts do nothing — until the user clicks the page or opens and dismisses the command palette (which now restores page focus, TASK-78). Likely cause, unconfirmed: nothing sets the window's initial first responder (no initialFirstResponder / makeFirstResponder on the launch path — AppDelegate showWindow, BrowserWindowController.selectTab at restore), so AppKit picks the first key-view-eligible control in the content view, which is that text field. Fix direction: on first show, focus the selected tab's web view via BrowserWindowController.restoreWebContentFocus() (peek / focused split pane aware), or nothing focusable in the sidebar when no tab is selected; and keep the archive field out of the key loop while its page is off-screen. Check new windows (Cmd+N), incognito windows and windows restored at launch, and that scrolling to the archive page still lets the field take focus when clicked or when search is invoked there.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After launch with a restored tab, the page receives keyboard input without a click (space scrolls it) and the window's first responder is the selected tab's web view — the focused pane for a split, the peek when one is presented
- [ ] #2 After launch with no tabs, and in a new or incognito window, the archive search field is not first responder and typing does not change its value
- [ ] #3 The archive search field still takes focus when the archive page is showing and the user clicks it or clears the search
- [ ] #4 A unit test on BrowserWindowController covers the first responder after a window is shown with a selected tab and with none
<!-- AC:END -->
