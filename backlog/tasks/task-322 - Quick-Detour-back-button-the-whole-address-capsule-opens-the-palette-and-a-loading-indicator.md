---
id: TASK-322
title: >-
  Quick Detour: back button, the whole address capsule opens the palette, and a
  loading indicator
status: Done
assignee:
  - '@claude'
created_date: '2026-11-13T08:02:00Z'
updated_date: '2026-11-13T08:38:00Z'
labels:
  - window
  - feature
dependencies: []
priority: low
ordinal: 388000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Feedback on Quick Detour (user, 2026-11-13). Three changes to the Quick Detour window's title bar (Detour/Browser/QuickDetour/QuickDetourTitleBar.swift, QuickDetourWindowController.swift):

1. Back button. There is none (only Cmd+[ and the mouse button). Add one to the right of the traffic lights and left of the address capsule, enabled only when the page can go back.
2. The address capsule. Only the host text (hostButton) opens the palette; the rest of the capsule does nothing. A click anywhere on the capsule that is not one of its own controls (profile pill, extension buttons, Copy Link, Site Settings) opens the palette, navigating in place, and a press there that moves drags the window as the host does (TASK-210's rule).
3. Loading indicator. Nothing shows a page is loading. The capsule fills with the load's progress, as the sidebar row does (TabCellView.updateProgress), and clears when the load ends.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A back button sits between the traffic lights and the address capsule; it is disabled on the first page and goes back when clicked
- [x] #2 A click on the capsule's empty space, or on the lock, opens the palette prefilled with the page's URL; the pill, extension, Copy Link and Site Settings buttons keep their own clicks
- [x] #3 A press on the capsule that moves past the drag threshold drags the window instead of opening the palette
- [x] #4 While the page loads the capsule shows its progress; it clears when the load finishes or stops
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. QuickDetourTitleBar: a HoverButton back button (chevron.left) at x 76, the capsule after it; enabled and tinted from tab.canGoBack.
2. QuickDetourAddressCapsule: hitTest hands every hit outside its buttons and the pill to the host button; the host's clickArea is the capsule, so a release anywhere on it clicks (palette) and a move past 3 pt drags the window (TASK-210 rule); hover lightens it.
3. Load progress: an accent fill behind the capsule's content, width = estimatedProgress (floor 0.1 while loading, none otherwise; pure displayedProgress), fade-out on end with a generation guard.
4. Window controller binds canGoBack and isLoading+estimatedProgress; onBack → goBack.
5. Tests in QuickDetourTitleBarTests; runtime harness light/dark (docs/harness/task322-harness.patch); wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (uncommitted). Tests: QuickDetourTitleBarTests 16/0 (8 new: back enable/go back, back placement vs traffic lights, capsule hit routing incl. a hovered button, empty-space click opens the palette, clickArea release, displayedProgress rule, capsule follows the tab's load); QuickDetourTitleBar+QuickDetourWindow+QuarantineWindow+AddressBarIconOrder suites 58/0 before the hit-test fix. Runtime (harness, light and dark, real HID clicks): back disabled on the first page and dimmed, enabled after a second page, HID click went back; capsule filled to 0.5 (299/597 pt) mid-load and cleared after; hover lightens; HID clicks on the empty space and beside the host opened the palette. The first dark run found a HID click on Copy Link opening the palette (hit landed on HoverButton's hover background subview) — fixed by walking ancestors, test added (fails without the fix), light rerun: Copy Link copied, no palette. Not verified: dragging the window from the capsule's empty space by hand (same code path as the host drag, unit-tested); VoiceOver. Not yet run: /code-review --fix and the full suite (owed before commit).

Review (/code-review --fix): fixed a fade-out race (a new load during the previous load's fade now drops the fade and grows the fill from the leading edge), the capsule no longer removes other tracking areas (one lazy .inVisibleRect area), doc rewrap; I set the back button's hover square to 22 pt to match its frame. Not fixed: HoverButton shows its hover background while disabled (app-wide, sidebar back/forward too; proposed to the user as a follow-up, not filed); the progress fill duplicates TabCellView's (refactor out of scope). Full suite after the review: 4006 tests, 0 failures, 18 skipped. Harness rerun (light) after the review fixes: back, progress fill/clear, hover, capsule clicks and back click as before; the Copy Link step was skipped by the harness's idle guard (unchanged code path, passed in the run before).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Quick Detour's title bar gets a back button between the traffic lights and the address capsule (follows canGoBack, dimmed by tint when disabled); the whole capsule outside its own buttons opens the palette prefilled with the URL, and drags the window after 3 pt like the host (QuickDetourAddressCapsule.hitTest routes to the host, whose clickArea is the capsule; hits inside any button, including a HoverButton's hover background, stay with the button); the capsule fills with load progress in the accent colour (displayedProgress: 0.1 floor while loading, none otherwise; fade-out on end). Tests: QuickDetourTitleBarTests 16/0 (8 new); full suite 4006/0 (18 skipped). Runtime: light and dark harness with real HID clicks (docs/harness/task322-harness.patch), which caught a Copy Link click opening the palette (fixed, test added). Follow-up proposed: disabled HoverButtons still show hover. Not verified: dragging from the capsule's empty space by hand, VoiceOver.
<!-- SECTION:FINAL_SUMMARY:END -->
