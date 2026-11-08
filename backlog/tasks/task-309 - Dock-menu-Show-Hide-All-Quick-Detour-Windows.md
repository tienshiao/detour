---
id: TASK-309
title: 'Dock menu: Show / Hide All Quick Detour Windows'
status: To Do
assignee: []
created_date: '2026-11-08T10:04:00Z'
updated_date: '2026-11-08T10:20:00Z'
labels:
  - quick-detour
  - menus
dependencies: []
references:
  - TASK-292.8
priority: low
ordinal: 370000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Arc's Dock icon menu had "Show/Hide All Little Arc Windows" (Arc's Little Arc help article). Quick Detour windows pile up when links from other apps open in them, and today there's no one-step way to tuck them away or bring them all back: Detour's Dock menu (AppDelegate.applicationDockMenu ~640) offers only New Window and New Private Window. The website's Quick Detour page (TASK-292.8) lists it under "Not in Detour". Requested by the user, Nov 8 2026.

To settle while building it: hide means orderOut (windows stay open, idle auto-close timers keep running or pause), the item title flips between Show and Hide (or two items), behavior with no Quick Detour open (item hidden or disabled), Private Quick Detours included, and whether a main-menu counterpart (Window menu) is wanted.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The Dock icon's menu has an item that hides every open Quick Detour window and, when they are hidden, shows them all again (title reflects the state); it is absent or disabled when no Quick Detour is open
- [ ] #2 Hidden Quick Detours keep their pages and the idle auto-close rule agreed with the user; a newly opened Quick Detour shows normally
- [ ] #3 Checked at runtime with /verify with several Quick Detours, including a Private one
- [ ] #4 The website's Quick Detour page moves it from Not in Detour to the how-to steps
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: hidden Quick Detours keep their idle auto-close timers running (a hidden window is treated like one behind other windows).
<!-- SECTION:NOTES:END -->
