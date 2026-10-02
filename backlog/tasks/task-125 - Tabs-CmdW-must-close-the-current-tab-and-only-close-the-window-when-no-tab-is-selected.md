---
id: TASK-125
title: >-
  Tabs: Cmd+W must close the current tab and only close the window when no tab
  is selected
status: To Do
assignee: []
created_date: '2026-10-02 01:27'
updated_date: '2026-10-02 01:40'
labels:
  - tabs
  - bug
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController.swift
  - Detour/App/AppDelegate.swift
priority: low
ordinal: 125000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Cmd+W (File > Close Tab) should close the currently selected tab. It should close the window only when no tab is selected in that window — normally after every tab has been closed.

Reported: Cmd+W closes the window when it should have closed a tab. The exact repro was not given, so the first step is to find which situations close the window while a tab is still selected (or deselect prematurely).

Code reading at the time of filing: `BrowserWindowController.closeCurrentTab(_:)` already falls through to `window?.performClose` only when `selectedTabID` is nil, and it is the only Cmd+W binding (AppDelegate File menu). So the fault is probably in one of:
- the action not reaching `closeCurrentTab` (responder chain / key-equivalent routing when focus is in the web view, an extension popup, a popover, or another panel), so something else handles Cmd+W;
- selection being nil while a tab is visibly shown (e.g. after closing a pinned tab or a favourite, which deselect rather than advancing to another tab, so the next Cmd+W closes the window even though tabs remain);
- split panes, a presented Peek, or the Archived Tabs page.
These are hypotheses, not confirmed causes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With a tab selected, Cmd+W closes that tab and the window stays open, wherever keyboard focus is (page content, sidebar, command palette, find bar)
- [ ] #2 Cmd+W closes the window only when the window has no selected tab
- [ ] #3 Closing the last normal tab with Cmd+W leaves the window open with no tab selected; a further Cmd+W then closes the window
- [ ] #4 Behaviour is defined and verified for pinned tabs, favourite-backed tabs, split panes and a presented Peek (Peek still dismisses first)
- [ ] #5 The cause of the reported window close is identified and recorded in the task notes
- [ ] #6 Tests cover the close-tab versus close-window decision
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-01: reporter retried shortly after filing and could not reproduce the window closing. No known repro. Before spending time here, get a repro; the leading guess from code reading is Cmd+W on a pinned tab or favourite (both deselect instead of advancing to another tab), which makes the next Cmd+W close the window while other tabs remain.
<!-- SECTION:NOTES:END -->
