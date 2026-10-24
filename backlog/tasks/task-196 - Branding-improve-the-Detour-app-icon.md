---
id: TASK-196
title: 'Branding: improve the Detour app icon'
status: To Do
assignee: []
created_date: '2026-10-24 21:05'
updated_date: '2026-10-24 21:05'
labels:
  - branding
  - icon
  - design
dependencies: []
priority: medium
ordinal: 232000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24: improve the Detour icon.

Current icon: Icon Composer bundle Detour/Detour.icon (project.yml ASSETCATALOG_COMPILER_APPICON_NAME: Detour). Two SVG layers, both glass: detour-orange.svg, an orange rounded-square plate (rgb(255,118,0)) like a road detour sign, and detour-arrow.svg, a black straight right arrow; the icon background fill is solid black. Rendered, it reads as an orange square inside a black square with a generic arrow.

Observations to discuss with the user before designing (not decisions): the black outer fill makes it look like a square in a square; a straight arrow does not say 'detour' (real detour signs bend the route); how it looks in the dark, tinted and clear macOS 26 icon appearances and at small sizes (Dock, Finder list, 16 pt) has not been checked.

Related: the dev-mode 'under construction' motif may borrow the icon's orange and black (see the dev-mode branding task); if this task changes the palette, that one follows.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Direction agreed with the user (what to keep, what to change) before the final artwork
- [ ] #2 The new icon is in Detour/Detour.icon and builds into the app
- [ ] #3 Checked at runtime in the default, dark, tinted and clear appearances and at small sizes (Dock, Finder, 16 pt)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Related: TASK-197 (dev-mode motif in the brand's orange and black).
<!-- SECTION:NOTES:END -->
