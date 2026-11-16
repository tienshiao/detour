---
type: Concept
title: Settings window height
description: "How the Settings window sizes to its panes: the pure height rule (natural height, opening no taller than 720 pt of content or the screen's cap, list panes draggable down to 400), refits while a pane is shown or the screen changes, measured pane heights, and the resize-animation traps (bounds, superseded animations)."
tags: [settings, appkit, layout]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:14Z }
sources:
  - id: height
    resource: ../../Detour/Browser/Settings/SettingsPaneHeight.swift
    title: SettingsPaneHeight.swift (the height rule)
  - id: window
    resource: ../../Detour/Browser/Settings/SettingsWindowController.swift
    title: SettingsWindowController.swift
  - id: metrics
    resource: ../../Detour/Browser/Settings/SettingsMetrics.swift
    title: SettingsMetrics.swift
  - id: height-tests
    resource: ../../DetourTests/SettingsPaneHeightTests.swift
    title: SettingsPaneHeightTests.swift
  - id: fit-tests
    resource: ../../DetourTests/SettingsWindowFitTests.swift
    title: SettingsWindowFitTests.swift
  - id: task-189
    resource: backlog:TASK-189
    title: "Settings: fix the window's spacing and clipping"
  - id: task-211
    resource: backlog:TASK-211
    title: "Settings: keep a pane's list and details fixed; scroll only their contents (and the Quick Detour pane)"
  - id: task-338
    resource: backlog:TASK-338
    title: "Settings: System Settings–style grouped rows, with labels on the left and switches and controls aligned on the right"
  - id: task-340
    resource: backlog:TASK-340
    title: "Settings: the window can stop mid-resize when a list pane first opens on a row other than the first"
  - id: task-347
    resource: backlog:TASK-347
    title: "Settings: panes ordered by topic, and a tall pane opens at a design maximum height instead of the screen's"
---

# Summary

The [Settings window](./settings.md) is resizable in height only and sizes
itself to each pane: it opens at the pane's natural content height, but no
taller than 720 pt of content or what the screen allows, and the user can
drag it between a minimum and the full content height. The rule is a pure
function, `SettingsPaneHeight`; the window controller applies it on every
pane switch, on content changes and on screen changes. How a pane measures
its natural height is on [Settings pane container](./settings-pane-container.md).

# Rules

`SettingsPaneHeight.fit(natural:minimum:screenUsableHeight:chromeHeight:)`
returns content heights `(initial, minHeight, maxHeight)`:

- `cap` = the window's screen's `visibleFrame` height minus the title bar
  and toolbar minus 80 (`SettingsMetrics.screenMargin`), never below 200
  (`minimumCappedHeight`).
- `maxHeight = min(max(natural, minimum ?? natural), cap)`.
- `initial = min(maxHeight, max(720, minimum ?? 0))`, where 720 is
  `SettingsMetrics.designMaximumContentHeight` (TASK-347). The window opens
  at the pane's natural height but no taller than 720 pt of content (or the
  cap), so a long pane such as Shortcuts no longer opens as tall as the
  screen. Before TASK-347 `initial` was `maxHeight`: Shortcuts (about
  1,800 pt of rows) opened at the screen's cap, which the user found
  unbounded.[^task-347]
- `minHeight = min(minimum ?? natural, cap, initial)`. The user drags
  between `minHeight` and `maxHeight`, so the window can still be made as
  tall as the content or the screen allows; below the natural height the
  pane scrolls. A fixed pane taller than 720 (none today) opens at 720 and
  drags to its natural height.
- List panes (Spaces, Links, Profiles, Search, Shortcuts, Extensions) have
  a minimum of 400 (`listPaneMinimumHeight`); a list pane shorter than 400
  is fixed at 400. General, Quick Detour and Content Blocking use their
  natural height, so they are fixed.
- `refit(current:from:to:)` is for a change while the pane is shown: a
  window still at its old opening height follows to the new one, one
  dragged all the way open follows to the new maximum, and one the user
  dragged elsewhere keeps its height, clamped into the new bounds. Accepted
  in TASK-347: a window dragged back to exactly its opening height follows
  the pane like an untouched one, and a pane under 720 that grows past it
  stops at 720 and scrolls.[^task-347]
- A pane switch always re-fits (no height is stored per pane). The window
  also re-fits on `NSWindow.didChangeScreenNotification` and
  `NSApplication.didChangeScreenParametersNotification`, so moving it to a
  shorter display, a resolution change or an unplugged display never leaves
  it taller than its screen.
- `screenUsableHeightOverride` replaces the screen height in the rule; it
  is an injection point for a harness, nil in the app.

**The 720 pt figure and the Profiles pane.** TASK-347 chose 720 so that a
normal profile's Profiles pane (709 pt of content) opens whole, and the
code's comment on `designMaximumContentHeight` still says so. That 709 is a
pre-TASK-338 measurement: on the grouped form the pane is taller (it opened
at its natural 1008 pt in TASK-338's final captures, with another profile
selected), and in TASK-347's own runtime run Profiles opened at the 720
maximum (an 808 pt window) and scrolled.[^task-338][^task-347]

# Measured heights

Content heights (the window less its 88 pt title bar and toolbar), with the
date and build each was measured on. Heights from before TASK-338
(2026-11-14) predate the grouped form, which made rows taller.

| Pane | Content height |
|---|---|
| General | 589 (a 677 pt window), its natural height, in TASK-347's runtime run, 2026-11-15[^task-347]; it changes with the automation rows shown |
| Profiles | above 720 since TASK-338: opens at the 720 maximum and scrolls (TASK-347's run; 1008 natural in TASK-338's captures). Before: 630 (Private) / 709 (a normal profile) to 1218 (custom UA, warning, 15 extensions); 1047 for Private with 14 extensions (2026-10-27) |
| Spaces | 400 minimum; 628 with 19 spaces (2026-10-24) |
| Links | 400 minimum (no routes); 743 with 5 routes (measured before the Quick Detour section came and went); capped (1242 on a 1410 pt screen) with 12 routes, then the route list scrolls (177 pt of list at 400, 129 pt at a 352 pt cap, 2026-10-27)[^task-211] |
| Quick Detour | 457, fixed (the grouped form with a Debug build's warning line and the Learn more link, 2026-11-14; 317 with TASK-328's rows) |
| Search | 400 minimum |
| Extensions | 400 (none, or one small extension) to 1092 (22 permissions, 4 hosts, 6 optional) (2026-10-24) |
| Content Blocking | 554, fixed (the grouped form: four list rows, the footnote, the buttons, Tracking Parameters, 2026-11-14; 379 with the old table and TASK-337's section) |
| Shortcuts | 400 minimum; every row is about 1,800 pt, so it opens at the 720 maximum and its list scrolls (at the screen's cap before TASK-347); it can be dragged taller up to the cap. Seen at runtime: an 808 pt window (720 + 88)[^task-347] |

# Applying a fit

- **Bounds and animation.** Setting `contentMaxSize` below the window's
  current height (or `contentMinSize` above it) resizes the window at once.
  `fitWindow` widens the bounds to cover the current height, animates, and
  sets the pane's bounds in the completion. A pane's own refit can land
  mid-animation (Profiles reports from `viewWillAppear`); it must start
  from the animation's target height, not the window's intermediate one,
  or the window stops at the 400 minimum.[^task-189]
- **A replaced animation still completes (TASK-340).** A refit
  mid-animation starts a new animation; the one it replaces still calls its
  completion. When both head to the same height (a list pane opened on
  another row refits as its rows and labels settle, often to the height it
  is already going to), the completion matched on the fit and the height,
  took itself for the newer one's and cleared the target while the window
  was mid-resize; the next refit read the intermediate height as one the
  user dragged to and kept it, and the window stopped short (671 pt of
  content on the pre-TASK-338 Profiles pane, whose normal profile needed
  about 709). Each fit now takes a generation number and only the newest
  fit's completion applies the bounds and clears the target. The animator
  is `SettingsWindowController.animateFrame`, which tests replace to end
  the animations in a chosen order (the race test failed before the fix:
  the target was gone). Checked at runtime: Profiles opened first on rows 1
  and 2 ends at its natural 1008 pt.[^task-340]
- **A required equality to a scrolling body's bottom caps the window.** If
  a scrolling body's content is pinned to the bottom with `==` and nothing
  in it can stretch, the scroll area gets a maximum height, and AppKit
  snaps the window to it the moment the pane is swapped in, with no
  animation (Content Blocking did this when shrinking onto it). Pin with
  `<=` plus a low-priority `==` (`bottomHug`), or let something stretch (a
  list column).[^task-189] A column scroll view's document has no such tie
  to the window, so a column's content pins its bottom with `==`.[^task-211]

# Tests

`SettingsPaneHeightTests` (27 cases) covers the rule: the cap, the minimum,
short laptop screens where the 400 minimum comes down to the cap, the 720
design maximum against tall fixed and list panes, and refits.
`SettingsWindowFitTests` drives `animateFrame` to end superseded animations
in a chosen order, and checks that a dragged height is still kept.
`SettingsPaneColumnsTests` checks that the natural height comes from the
content and never from the window, and that Links fits the 400 pt minimum.

# Related

- [Settings window](./settings.md) - the window and its panes.
- [Settings pane container](./settings-pane-container.md) - how a pane measures its natural height and reports changes.
- [Settings layout traps and runtime checks](./settings-layout-traps.md) - driving and sampling a resize at runtime.

[^task-189]: TASK-189
[^task-211]: TASK-211
[^task-338]: TASK-338
[^task-340]: TASK-340
[^task-347]: TASK-347
