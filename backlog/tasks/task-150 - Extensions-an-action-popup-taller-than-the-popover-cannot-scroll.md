---
id: TASK-150
title: 'Extensions: an action popup taller than the popover cannot scroll'
status: To Do
assignee: []
created_date: '2026-10-04 02:35'
labels:
  - bug
  - extensions
dependencies: []
priority: medium
ordinal: 173000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-03 while exercising the API Explorer popup in the running app for TASK-132.4. ExtensionPopoverController measures the popup's content and clamps the popover to 100...800 x 100...600. WebKit builds an action's popup web view in a size-to-content mode (private _sizeToContentAutoSizeMaximumSize, 800 x 600) in which the page never scrolls, because the host is expected to give the view the content's size. With 3456 pt of content in the 600 pt popover: window.scrollTo is a no-op, a wheel does nothing, and everything below the fold cannot be reached or clicked. Giving the view the full content height does not help: WebKit keeps a 600 pt viewport and hit-tests nothing below it. Chrome's popup scrolls at its own 800 x 600 limit.

A fix was started on the epic-claude-extension branch (uncommitted at the time of filing): once the measured content overflows, switch the size-to-content mode off (set the maximum size to zero through the private setter, guarded by responds(to:)) so the view keeps the popover's size and the page scrolls inside it; leave the mode on for a popup that fits, since WebKit's shrink-to-fit layout gives a popup without an explicit width its width. It is to be committed on that branch as its own commit so it can be cherry-picked to main.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A popup whose content is taller than 600 pt scrolls inside the popover with the wheel and with window.scrollTo, and controls below the fold can be clicked — verified in the running app
- [ ] #2 A popup that fits keeps its measured size and does not gain a scroll bar; a popup without an explicit width keeps the width WebKit's shrink-to-fit gives it
- [ ] #3 A popup that grows past 600 pt after opening becomes scrollable; one that shrinks back is sized to its content again
- [ ] #4 On a WebKit without the private setter the popup behaves as before and a log line says why
- [ ] #5 Tests cover the size/overflow decision; 1Password's popup is checked for no regression (size, no stray scroll bar)
<!-- AC:END -->
