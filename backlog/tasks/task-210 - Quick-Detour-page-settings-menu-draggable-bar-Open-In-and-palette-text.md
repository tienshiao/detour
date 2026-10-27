---
id: TASK-210
title: 'Quick Detour: page settings menu, draggable bar, Open In and palette text'
status: To Do
assignee: []
created_date: '2026-10-27 02:17'
updated_date: '2026-10-27 02:17'
labels:
  - window
  - feature
dependencies: []
priority: low
ordinal: 246000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Feedback after TASK-193 (user, 2026-10-26). Four changes to the Quick Detour window (Detour/Browser/QuickDetour/):

1. Page settings menu. The main window's address bar opens SettingsPopoverViewController (showSiteSettingsPopover in BrowserWindowController+TabSidebar.swift): per-site content blocking with the blocked count, Picture in Picture, Dev Mode, and the profile's extensions with pin toggles and Extension Settings…. Quick Detour's bar (QuickDetourTitleBar) only has an extensions button (puzzle piece) that lists extensions. Replace that button with the same page settings menu, acting on the Quick Detour page and its profile, so extensions stay reachable from it as in the main window. The pinned extension buttons stay in the bar.
2. Dragging. Only the bar's background moves the window (mouseDownCanMoveWindow); the URL (host button) and the Open In button take every press, which leaves little to grab. A press on either that moves past the drag threshold drags the window instead; a plain click still opens the palette or the Open In menu.
3. Open In menu: remove the 'Reloads the page' subtitle on other-space items (QuickDetourWindowController.swift, menuItem.subtitle).
4. Palette prompt: Quick Detour's palette has no browser around it, so its placeholder becomes 'Search or enter a URL'. The main window's palette keeps 'Where do you want to go?' (CommandPaletteView.swift).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Quick Detour's bar opens the main window's page settings menu (content blocking with count, Picture in Picture, Dev Mode, extensions with pin toggles) in place of the extensions-only button, and its switches act on the Quick Detour page's site and profile
- [ ] #2 Toggling content blocking from the menu reloads the Quick Detour page, as it does in the main window
- [ ] #3 Pressing and dragging on the URL or the Open In button moves the window; a click without movement still opens the palette or the Open In menu
- [ ] #4 The Open In menu's other-space items no longer show 'Reloads the page'
- [ ] #5 Quick Detour's palette shows 'Search or enter a URL'; the main window's palette text is unchanged
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Queued (user, 2026-10-26): ahead of TASK-194 (order: 210, 211, 194, 201, 202, 209).
<!-- SECTION:NOTES:END -->
