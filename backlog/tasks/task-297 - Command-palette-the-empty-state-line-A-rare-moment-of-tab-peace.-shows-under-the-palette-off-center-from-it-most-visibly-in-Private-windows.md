---
id: TASK-297
title: >-
  Command palette: the empty-state line ('A rare moment of tab peace.') shows
  under the palette, off-center from it, most visibly in Private windows
status: To Do
assignee: []
created_date: '2026-11-08T08:30:00Z'
updated_date: '2026-11-08T10:20:00Z'
labels:
  - command-palette
  - ui
dependencies: []
priority: low
ordinal: 358000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
With no tab selected, the content area shows "A rare moment of tab peace." (or "Where to next?" when the space has tabs). Opening the command palette ("Where do you want to go?") puts two centered things on screen that don't line up:
- The palette centers on the whole window, sidebar included: CommandPaletteView.show(in: window.contentView) with glassContainer.centerX on its safe area (CommandPaletteView.swift ~239, 285-340).
- The empty-state label centers in the content area to the right of the sidebar: emptyStateLabel center constraints on contentContainerView (BrowserWindowController.swift ~717-720, text set in deselectAllTabs ~2628).
So they sit half a sidebar width apart. Usually the palette's suggestion list (open tabs, history) covers the label; in a Private window there's no history, the list stays short, and both are visible (inferred from the code, not yet seen at runtime). With no tab selected the content scrim isn't added either (showCommandPalette adds it only when selectedTabID != nil), so the label isn't dimmed.

The user's proposed fix: hide the empty-state label while the palette is visible. Open to other ideas, for example:
- Center the palette over the content area instead of the window, so it lines up with the label and the page it will open into (changes its position everywhere, including the sidebar-hidden case; the anchored mode from the faux address bar is unaffected).
- Dim the label like the page behind it (add the content scrim in the empty state too); this alone doesn't fix the misalignment.
- Make the empty state a hint the palette replaces in place (the palette opens where the label is).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The approach is agreed with the user (default: hide the empty-state label while the palette is open)
- [ ] #2 While the palette is open in a window with no selected tab, the empty-state label is not visible, in new-tab (⌘T), navigate-in-place (⌘L) and address-bar-anchored modes
- [ ] #3 Dismissing the palette without opening anything shows the label again; opening a page leaves it hidden as today
- [ ] #4 No visible jump or flash when the palette opens and closes
- [ ] #5 Checked at runtime with /verify in a normal window and a Private window, with the sidebar shown and hidden
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: default approach confirmed: hide the empty-state label while the palette is open.
<!-- SECTION:NOTES:END -->
