---
id: TASK-309
title: 'Dock menu: Show / Hide All Quick Detour Windows'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T10:04:00Z'
updated_date: '2026-11-08T11:35:00Z'
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
- [x] #1 The Dock icon's menu has an item that hides every open Quick Detour window and, when they are hidden, shows them all again (title reflects the state); it is absent or disabled when no Quick Detour is open
- [x] #2 Hidden Quick Detours keep their pages and the idle auto-close rule agreed with the user; a newly opened Quick Detour shows normally
- [x] #3 Checked at runtime with /verify with several Quick Detours, including a Private one
- [ ] #4 The website's Quick Detour page moves it from Not in Detour to the how-to steps
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure rule (QuickDetourDockMenu.swift): each open Quick Detour (Private included, quarantine windows not) is onScreen, hiddenByDockMenu (ordered out by the item, still out) or elsewhere (minimized / app hidden). Item: Hide All while any is on screen; Show All when none is but some were hidden by the item; absent otherwise (none open, or all minimized).
2. Hide All = orderOut of the on-screen ones, flagged; Show All = orderFront of the flagged hidden ones, newest key, app activated. Windows stay open; idle auto-close unchanged (a hidden window is never frontmost, so its timer runs).
3. A new Quick Detour shows normally and does not unhide the others (conservative choice); the item then reads Hide All and hides it with the rest.
4. AppDelegate.applicationDockMenu: one call adding the item after New Private Window (separator). No main-menu counterpart.
5. Tests: QuickDetourDockMenuTests (rule, titles, no item without a Quick Detour, hide/show incl. Private, idle timer runs while hidden, new window, quarantine left alone). Runtime: several Quick Detours incl. a Private one, Dock menu driven in-process.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: hidden Quick Detours keep their idle auto-close timers running (a hidden window is treated like one behind other windows).

Implemented (Nov 8 2026, @claude):
- Detour/Browser/QuickDetour/QuickDetourDockMenu.swift: pure rule QuickDetourDockAction.action(for:) over each window's QuickDetourDockWindowState (onScreen / hiddenByDockMenu / elsewhere); hideAllFromDockMenu / showAllFromDockMenu on QuickDetourWindowController (new stored flag isOrderedOutByDockMenu); AppDelegate.addQuickDetourDockMenuItem(to:) called from applicationDockMenu (one line) after a separator. The item does what its title said when the menu was built (representedObject).
- Title: 'Hide All Quick Detour Windows' while any Quick Detour is on screen, 'Show All Quick Detour Windows' when none is and some were hidden by the item. Absent when no Quick Detour is open — and (decided here) also when every open one is minimized: there is nothing to hide and nothing hidden.
- Hide = orderOut of the on-screen ones; they stay open with their pages. Minimized ones are left alone. Show = orderFront of the ones the item hid, oldest first, the newest made key, and Detour activated.
- Private Quick Detours are included. Decided here: quarantine windows are NOT included (they are not Quick Detours on a profile and the item does not name them; conservative: the item leaves alone what it does not name). With only a quarantine open there is no item.
- Idle auto-close keeps running while hidden (user decision) with no code change: a hidden window is not visible, so QuickDetourIdleState.isFrontmost is false and the rule closes it once unused for the interval (tested).
- A newly opened Quick Detour shows normally and does NOT unhide the others (conservative option, as asked); the item then reads Hide All and hides it with the rest; the next Show All brings all back.
- No main-menu counterpart (decision).
- Tests: new QuickDetourDockMenuTests (7): the rule over states, the two titles, no item without a Quick Detour (Dock menu is exactly New Window, New Private Window), Hide All then Show All over two normal and one Private Quick Detour (windows stay open with their pages), a hidden window is not frontmost and auto-closes after the interval, a new Quick Detour shows alone and the item hides it with the rest, a quarantine is left alone. With QuickDetourWindowTests (15): 22 tests, 0 failures.
- Runtime (/verify, DETOUR_DATA_DIR=DetourB8-309-1, temporary DEBUG harness calling NSApp.delegate.applicationDockMenu(NSApp) and performing its item): none open -> Dock menu New Window, New Private Window only; two Default + one Private Quick Detour open -> 'Hide All Quick Detour Windows'; chosen -> all three not visible, still open, menu reads 'Show All ...'; a fourth opened -> shown, the others stayed hidden, menu reads 'Hide All ...'; chosen -> all four hidden; 'Show All' -> all four visible, the newest frontmost; all closed -> item gone. Full-screen captures before and after the hide confirm the windows left the screen. Not checked at runtime: minimized windows, the app hidden with Cmd-H (rule unit-tested only for minimized). Defaults keys and data dir removed; the WebKit store directories under ~/Library/WebKit/com.detourbrowser.mac/ left.
- Website facts for AC #4 (Quick Detour page: move from 'Not in Detour' to the how-to steps): Right-click (or Control-click) Detour's icon in the Dock and choose 'Hide All Quick Detour Windows' to tuck every open Quick Detour away (Private ones too); they stay open with their pages. The item then reads 'Show All Quick Detour Windows' and brings them all back. It only appears while a Quick Detour is open. A Quick Detour opened while the others are hidden shows on its own; the others stay hidden until Show All. Hidden Quick Detours still close after the idle time set in Settings > Quick Detour, as ones behind other windows do. Quarantine windows are not affected.
Website AC pending (held for release).

Website: updated Quick Detour (/features/quick-detour/: new 'Hide them all at once' how-to for Hide All / Show All Quick Detour Windows; Arc box moved from Not in Detour to Same) on website branch next-release (3e3a2cb), held for the release

Nov 8 2026 (lead): landed on main with the batch; /code-review on its branch (fixes folded in); full DetourTests on the integrated code: 3882 tests, 18 skipped, 2 failures, both pre-existing on main before the batch (TASK-310).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Dock menu gets one item, 'Hide All Quick Detour Windows' / 'Show All Quick Detour Windows', absent when no Quick Detour is open (or all are minimized). Hide orders the windows out (they stay open, idle auto-close keeps running), Private included, quarantine windows not; a new Quick Detour shows normally without unhiding the others. Pure state rule plus 7 tests; runtime-checked with three, then four Quick Detours including a Private one. Website AC #4 pending, facts in the notes.
<!-- SECTION:FINAL_SUMMARY:END -->
