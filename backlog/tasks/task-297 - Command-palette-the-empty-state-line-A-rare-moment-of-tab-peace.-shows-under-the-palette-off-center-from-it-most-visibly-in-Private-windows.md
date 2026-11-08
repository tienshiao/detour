---
id: TASK-297
title: >-
  Command palette: the empty-state line ('A rare moment of tab peace.') shows
  under the palette, off-center from it, most visibly in Private windows
status: Done
assignee:
  - '@claude'
created_date: '2026-11-08T08:30:00Z'
updated_date: '2026-11-08T10:32:00Z'
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
- [x] #1 The approach is agreed with the user (default: hide the empty-state label while the palette is open)
- [x] #2 While the palette is open in a window with no selected tab, the empty-state label is not visible, in new-tab (⌘T), navigate-in-place (⌘L) and address-bar-anchored modes
- [x] #3 Dismissing the palette without opening anything shows the label again; opening a page leaves it hidden as today
- [x] #4 No visible jump or flash when the palette opens and closes
- [x] #5 Checked at runtime with /verify in a normal window and a Private window, with the sidebar shown and hidden
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. BrowserWindowController: track isShowingEmptyState (set in deselectAllTabs, cleared in removeContentViews) and derive the label's visibility from it and commandPaletteView != nil.
2. showCommandPalette/dismissCommandPalette re-evaluate it; the palette shows and hides without animation, so the label toggles in the same transaction (no flash).
3. EmptyStatePaletteTests: Cmd+T, Cmd+L, anchored, open-a-page, deselect-while-open.
4. /verify in a normal and a Private window, sidebar shown and hidden.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: default approach confirmed: hide the empty-state label while the palette is open.

Implemented: BrowserWindowController derives the empty-state label's visibility from isShowingEmptyState (set by deselectAllTabs, cleared by removeContentViews) and commandPaletteView != nil (updateEmptyStateLabelVisibility, re-run in showCommandPalette and dismissCommandPalette). The palette has no show/hide animation, so the label toggles in the same transaction as the palette's addSubview/removeFromSuperview; a commit that opens a page dismisses and selects in the same main-actor turn, so no frame shows the label (no flash by construction).

Tests: EmptyStatePaletteTests (5: Cmd+T + Esc, Cmd+L + Cmd+T-closes, anchored, commit leaves it hidden, deselect under an open palette) + CommandPaletteFocusTests (4): 9/9 pass.

Runtime (Nov 8, isolated DETOUR_DATA_DIR DetourB8-297-2, temporary harness, screencapture per state): normal window with sidebar shown (Cmd+T, Cmd+L, anchored from the faux address bar) and hidden (Cmd+T, Cmd+L), then a Private window (its initial Cmd+T palette, then the same passes with sidebar shown and hidden): labelVisible=false in every palette state, true after each dismiss, false after a commit opened a page. Captures checked: palette alone over the empty content, label back after dismiss. Not checked: frame-by-frame recording of the transition (no animation exists to flash). WebKit store dirs for DetourB8-297-1/-2 left under ~/Library/WebKit/com.detourbrowser.mac (per rules).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
With no tab selected, the empty-state line is now hidden while the command palette is open (Cmd+T, Cmd+L, address-bar-anchored), shown again when the palette is dismissed without opening anything, and stays hidden when a page opens. Visibility is derived from the empty state and the palette's presence in one helper, toggled in the same transaction as the (unanimated) palette, so there is no flash. Tests: EmptyStatePaletteTests (5) + CommandPaletteFocusTests (4) pass. Runtime-checked in a normal and a Private window, sidebar shown and hidden. Wiki: command-palette.md, browser-window-controller.md.
<!-- SECTION:FINAL_SUMMARY:END -->
