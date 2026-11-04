---
type: Decision
title: The app icon is a bordered DETOUR plate with a bent arrow
description: Why Detour's icon is an orange road-sign plate filling the icon, with a black inset border and a 90-degree bent arrow, how its Icon Composer layers are structured, and the designs that were tried and rejected.
resource: ../../Detour/Detour.icon
tags: [branding, icon, decision]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-29T08:22:20Z }
sources:
  - id: task-196
    resource: backlog:TASK-196
    title: "Branding: improve the Detour app icon"
  - id: icon
    resource: ../../Detour/Detour.icon
    title: Detour.icon (Icon Composer bundle)
  - id: project
    resource: ../../project.yml
    title: project.yml (ASSETCATALOG_COMPILER_APPICON_NAME)
  - id: ictool
    resource: ../platform/icon-composer-ictool.md
    title: Icon Composer's ictool
---

The icon is a US work-zone DETOUR plate (MUTCD M4-10) used as the whole
icon: brand orange to the edge, a black rounded-square border inset like the
sign's, and a black arrow that rises and turns 90° to the right, the arrow
real detour signs use. It replaced an orange plate floating in a black square
with a straight arrow.[^task-196]

# Context

The old icon read as a square inside a square, and a straight arrow does not
say "detour". The user's references were the two US detour signs: the orange
DETOUR plate with an arrow, and the arrow-shaped DETOUR sign (an orange
arrow on black).[^task-196]

# Decision

`Detour/Detour.icon` is an Icon Composer bundle that Xcode compiles itself
(`ASSETCATALOG_COMPILER_APPICON_NAME: Detour`; no `.appiconset` in
`Assets.xcassets`, which would clash). Layers, top first, all glass, on a
1024 × 1024 canvas:

| Layer | Shape |
|---|---|
| `detour-arrow.svg` | Filled outline of the bent arrow: shaft 100, centre-line bend radius 110, head 260 tall and 150 long with rounded corners, scaled 1.167 and centred so its bounding box is square and sits 100 from the border's inner edge on every side |
| `detour-border.svg` | Even-odd ring 64 thick: outer edge 103…921 (corner radius 197), inner edge 167…857 (corner radius 133) |
| `detour-plate.svg` | Full-canvas square in rgb(255, 118, 0) |

The background `fill` is solid black and never shows, because the plate
covers it. The orange is a layer, not the fill, on purpose:

* macOS replaces the fill with dark grey in the Dark appearance, so an orange
  fill turns the icon grey with a black arrow that vanishes. A layer keeps
  its colour, so the icon is orange with black in both appearances.
* With an orange `automatic-gradient` fill the glass arrow and border are
  translucent over the fill's gradient and come out visibly lighter at the
  bottom. Over a flat orange layer they stay black.

Shapes are filled outlines, not strokes, and the plate's orange is the hazard
colour [dev mode](../features/dev-mode.md) borrows.

# Alternatives rejected

| Design | Why not |
|---|---|
| Orange as the `fill`, glyph on top | Grey in Dark (see above); a dark-appearance `fill-specializations` for the glyph fixes the contrast but the user preferred the plate staying orange |
| Arrow that arcs over an obstacle and rejoins | Not a real sign, and a blob at 16 pt |
| Lane-shift "jog" arrow | Read well small, but less like a detour sign than the 90° arrow |
| Orange diamond warning sign with the bent arrow (with and without an inset border) | Liked, but an arrow placed with equal padding to the diamond's edges looks off-centre, and centring it by eye leaves its shaft close to the lower-left edge |
| The arrow-shaped sign alone, orange on black | Clearest at 16 pt, but without the sign's lettering it is a generic arrow |

The sketches were rendered with Icon Composer's `ictool` in all six looks
and at 32 and 16 pt before choosing.[^ictool]

# Consequences

* The icon looks the same in Default and Dark; tinted and clear looks come
  from the system. In Tinted dark the black arrow is low-contrast but
  readable.
* The border was first 34 thick; at 16 pt it blurred into the plate, so it grew outward to 64 (the inner edge, and the arrow's gap, unchanged). At 80 the orange outside it gets thin and the icon starts to look like a frame again.
* The bent arrow is drawn to road-sign proportions. SF Symbols has a similar
  `arrow.turn.up.right`, and Apple's licence forbids symbols in app icons;
  this one is an independent drawing of the MUTCD arrow, not the symbol.
* After a rebuild, Finder and the Dock can keep showing the old icon at
  some sizes from the icon cache; see [ictool](../platform/icon-composer-ictool.md).

# Related

* [Icon Composer's ictool](../platform/icon-composer-ictool.md) - rendering the icon from the command line and its traps.
* [Dev mode](../features/dev-mode.md) - borrows the plate's orange.

[^task-196]: TASK-196
[^ictool]: Agent session, 2026-10-29: four sketch rounds rendered with ictool (not in the repository)
