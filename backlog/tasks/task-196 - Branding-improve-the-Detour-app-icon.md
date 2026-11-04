---
id: TASK-196
title: 'Branding: improve the Detour app icon'
status: Done
assignee:
  - '@claude'
created_date: 2026-10-24 21:05
updated_date: '2026-10-29T08:40:00Z'
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
- [x] #1 Direction agreed with the user (what to keep, what to change) before the final artwork
- [x] #2 The new icon is in Detour/Detour.icon and builds into the app
- [x] #3 Checked at runtime in the default, dark, tinted and clear appearances and at small sizes (Dock, Finder, 16 pt)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Direction agreed with the user 2026-10-29 after four sketch rounds (scratchpad renders): concept G — the DETOUR plate as the whole icon: orange to the edge, black inset rounded-square border, black 90-degree bent arrow (MUTCD detour/turn arrow proportions) centred with even padding. Inspirations: the M4-10 DETOUR plate and the arrow-shaped DETOUR sign.
2. Structure the user preferred: solid black fill, orange plate as its own glass layer (so the arrow stays solid black and the plate stays orange in Dark). An automatic-gradient orange fill was tried and rejected: the translucent glass arrow shows the fill's gradient (lighter at the bottom).
3. Filled outlines only (bama app-icon rule): arrow outline with rounded head corners, border as an even-odd ring.
4. Replace Detour/Detour.icon assets, render every appearance + 16/32 pt with Icon Composer's ictool, build, check Assets.car/CFBundleIconName in the built app and the Dock/Finder at runtime.
5. Wiki: record the icon structure and the ictool specialization quirk.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Related: TASK-197 (dev-mode motif in the brand's orange and black).

Rejected on the way: full-bleed orange FILL (macOS swaps the fill for dark grey in Dark, the black arrow vanishes); arc-over-obstacle arrow (blob at 16 pt, not a real sign); orange diamond warning sign (E) — liked, but the arrow fitted for equal edge padding looks off-centre in a diamond. ictool ignores per-appearance image-name-specializations; a per-layer fill-specializations entry for dark does work.

Verification 2026-10-29 (Xcode 26, macOS 26.7):
- AC1: user chose G (the plate as the whole icon) over E after four sketch rounds; asked for the earlier G structure (black fill + orange plate layer) over the automatic-gradient fill version.
- AC2: Detour/Detour.icon replaced (detour-arrow, detour-border, detour-plate; detour-orange removed). Debug build into .derived succeeded; actool compiled Detour.icon; built app has Assets.car and Detour.icns, CFBundleIconName = Detour. iconutil-extracted Detour.icns shows the new icon at 16/32/128/256.
- AC3: ictool renders of Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark and 16/32 pt (light and dark) all show the plate, border and arrow; Tinted dark arrow is low-contrast but readable. NSWorkspace icon at 256/128/64/32/16 shows the new icon after touch + lsregister (before that the icon cache mixed old and new sizes). Debug build launched with DETOUR_DATA_DIR=DetourIconVerify: the Dock shows the new icon next to the installed build's old one; its defaults keys and data dir were removed afterwards.
- Not run: unit tests and /code-review (asset and wiki change only, no Swift code).

2026-10-29 follow-up: the user found the 34-wide border too thin at small sizes. Compared 34/50/64/80 (inner edge fixed at 167 so the arrow keeps its 100 pt gap); user chose 64. Rebuilt: ictool renders in all six appearances and 16/32 pt fine, extracted Detour.icns shows the 64 border, Dock shows it with the debug build running (defaults keys and data dir removed afterwards).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
New app icon: the US DETOUR plate as the whole icon — orange plate layer to the edge, black inset rounded-square border, black 90-degree bent (MUTCD detour) arrow centred with even padding. Black solid fill under an orange layer keeps the icon orange-on-black in Dark and keeps the glass arrow solid black. Filled outlines only. Checked in all six appearances and at 16/32 pt with ictool, in the built .icns, Finder and the Dock. Wiki: decisions/app-icon-design (design, layer structure, rejected sketches) and platform/icon-composer-ictool (rendering recipe and traps). Risk: the bent arrow is in the same family as SF Symbols' arrow.turn.up.right; it is an independent road-sign drawing.
<!-- SECTION:FINAL_SUMMARY:END -->
