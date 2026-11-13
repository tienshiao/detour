---
id: TASK-323
title: 'HoverButton: no hover background on a disabled button'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-13T08:41:00Z'
updated_date: '2026-11-13T09:17:00Z'
labels:
  - window
dependencies: []
priority: low
ordinal: 389000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
User decision 2026-11-13 after TASK-322: disabled HoverButtons (the sidebar's back/forward, Quick Detour's back, Copy Link with no page) still showed the hover background, unlike AppKit's own controls. HoverButton (Detour/Browser/Shared/HoverButton.swift) shows it only while the pointer is inside and the button is enabled, updating when isEnabled changes under a resting pointer.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A disabled HoverButton shows no hover background under the pointer
- [x] #2 A button disabled under the pointer loses the background at once; one enabled under the pointer gains it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. HoverButton tracks isPointerInside; the background shows only while the pointer is inside and the button is enabled; isEnabled didSet updates it under a resting pointer.
2. HoverButtonTests; real-pointer check in the TASK-322 harness; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Review (/code-review --fix): also forgets the pointer on viewDidHide / viewDidMoveToWindow (no mouseExited there), re-resolves the colour on an appearance change, and skips no-op isEnabled writes; test added. Skipped: enabling through the cell (no call site). Tests: HoverButtonTests 4/0; full suite 4010 tests, 0 failures, 18 skipped (run on the final code). Runtime (TASK-322 harness extended, light, real HID pointer moves): the sidebar's disabled Back under the pointer showed no hover; the Quick Detour Back enabled under the pointer showed it. The Quick Detour Back disabled case was not observed (the harness's idle guard skipped that move); same code, unit-tested.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A disabled HoverButton no longer shows its hover background (user's decision after TASK-322, matching AppKit's controls). The background follows the pointer and isEnabled together, appears or goes at once when the button is enabled or disabled under a resting pointer, and is forgotten on hide or window change. Affects the sidebar's Back/Forward, Quick Detour's Back and Copy Link, the Now Playing bar and the dev toolbar. Tests 4/0 new, full suite 4010/0.
<!-- SECTION:FINAL_SUMMARY:END -->
