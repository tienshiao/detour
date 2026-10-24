---
id: TASK-197
title: >-
  Dev mode: tie the under-construction motif to the Detour branding (orange
  hazard border)
status: To Do
assignee: []
created_date: '2026-10-24 21:05'
updated_date: '2026-10-24 21:05'
labels:
  - dev-mode
  - branding
  - design
dependencies: []
priority: low
ordinal: 233000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24 (an idea to explore): tie dev mode's 'under construction' look more to the branding and icon. For example, the sidebar row's hazard border could be more orange than yellow.

Today (TASK-186.1, HazardBorderView): systemYellow solid stroke under a near-black dashed 1.5 pt 4/4 stroke; the dev toolbar (TASK-186.2, DevToolbarView) uses faint diagonal stripes. The icon's plate is orange rgb(255,118,0) with black, i.e. road-construction signage colours, so an orange-and-black border and stripes would echo it.

To explore: border colour (brand orange vs a slightly lighter orange for contrast on the sidebar's tint), whether the toolbar stripes pick up a faint orange, light and dark mode contrast, and selected vs unselected rows. If the app icon task changes the palette, follow it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A couple of options (e.g. brand orange, lighter orange, current yellow) compared in window captures, light and dark, selected and unselected rows
- [ ] #2 The chosen colours applied to the sidebar border and, if agreed, the toolbar stripes, defined once and shared
- [ ] #3 Checked at runtime, light and dark
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Related: TASK-196 (app icon); if it changes the palette, follow it.
<!-- SECTION:NOTES:END -->
