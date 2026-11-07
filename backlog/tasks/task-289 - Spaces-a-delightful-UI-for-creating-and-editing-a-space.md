---
id: TASK-289
title: 'Spaces: a delightful UI for creating and editing a space'
status: To Do
assignee: []
created_date: '2026-11-07T10:12:00Z'
labels:
  - spaces
  - ui
  - design
dependencies: []
references:
  - Detour/Browser/Settings/SpacesSettingsViewController.swift
  - Detour/Browser/Sidebar/TabSidebarViewController.swift
  - Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
priority: medium
type: feature
ordinal: 336000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user on 2026-11-07: the current UI is functional but "very boring and uninspired", "lacks whimsy and doesn't impress".

Today, as of 2026-11-07:
- **Starting a space:** the sidebar's + (`addSpaceClicked` → `tabSidebarDidRequestAddSpace`) and a space's "Edit Space…" menu item both just open Settings > Spaces (`SettingsWindowController.showSpacesPane`). You leave the window you were in to make or change a space.
- **Adding:** the pane's + immediately creates a space named "Space" with ⭐️, the first preset color and the first profile (`SpacesSettingsViewController.addSpaceClicked`). There is no moment of choosing anything before it exists.
- **Editing:** a plain label/field grid: a Name field, an Emoji button that opens the system character picker, a Profile pop-up and an expanded `NSColorWell`. Nothing shows what the space will look like (its tint, its header, its icon in the space switcher) while you change it.

A space is the most personal object in the browser (its name, emoji and color tint the whole sidebar), so creating one should feel like an occasion. References worth looking at: Arc's space creation (theme picker with live gradient, emoji grid), macOS Focus mode and Home app room setup, Apple's Freeform and Journal onboarding moments.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Before building, two or three design directions (sketches or mockups) are shown to the user and one is chosen; the choice and the rejected directions are recorded in the task
- [ ] #2 Creating a space starts from the sidebar in the current window and lets the user pick name, emoji, color and profile before the space exists; cancelling creates nothing
- [ ] #3 Editing a space from the sidebar happens in the same window, and every change previews live on the real sidebar (tint, header, switcher icon) before or as it is applied; undo still undoes the edit as one action
- [ ] #4 Emoji and color are chosen from curated, good-looking options (with a way to reach any emoji and any color), not only the system picker and a raw color well
- [ ] #5 The flow has at least one moment of delight (for example the new space arriving with an animation, or the sidebar re-tinting as colors are tried), and honours Reduce Motion
- [ ] #6 Fully usable from the keyboard and with VoiceOver; looks right in light and dark mode
- [ ] #7 Settings > Spaces stays consistent with the new flow (shares its controls or opens it) rather than keeping a second, older editor
- [ ] #8 Rule logic (defaults for a new space, name validation, preset lists) has tests; the UI is checked at runtime with /verify in light and dark, with captures attached to the task notes
<!-- AC:END -->
