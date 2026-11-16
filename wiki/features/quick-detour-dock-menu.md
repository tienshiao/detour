---
type: Feature
title: Quick Detour Dock menu
description: "The Dock menu's Hide All / Show All Quick Detour Windows item (TASK-309): which windows it covers, the pure state rule, what hide and show do, and the idle timer and new windows while hidden."
tags: [window, dock]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
sources:
  - id: task-309
    resource: backlog:TASK-309
    title: "Dock menu: Show / Hide All Quick Detour Windows"
  - id: dock-menu
    resource: ../../Detour/Browser/QuickDetour/QuickDetourDockMenu.swift
    title: QuickDetourDockMenu.swift
---

Detour's Dock menu carries one Quick Detour item that hides or shows every Quick Detour window at once.

# What it does

TASK-309 (user decisions, Nov 8 2026), after Arc's "Show/Hide All Little Arc
Windows". Detour's Dock menu (`AppDelegate.applicationDockMenu`: New Window,
New Private Window) gets one more item after a separator, whose title flips
between **Hide All Quick Detour Windows** and **Show All Quick Detour
Windows** ([QuickDetourDockMenu.swift](../../Detour/Browser/QuickDetour/QuickDetourDockMenu.swift)).
No main-menu counterpart.

- **Which windows**: every open Quick Detour, Private ones included;
  quarantine windows are not (decided here: they are not Quick Detours on
  a profile, and the item does not name them).
- **The rule** is pure, `QuickDetourDockAction.action(for:)` over each
  window's `QuickDetourDockWindowState`: `onScreen` (visible, not
  minimized), `hiddenByDockMenu` (ordered out by the item and still out:
  `isOrderedOutByDockMenu` and not visible) or `elsewhere` (minimized, or
  out with the app hidden). Hide All while any is on screen; Show All when
  none is but some were hidden by the item; **no item** when no Quick
  Detour is open, or when every one is minimized (nothing to hide, nothing
  hidden). The title is computed each time macOS asks for the Dock menu.
- **Hide** orders the on-screen ones out (`orderOut`): they stay open with
  their pages. **Show** orders the hidden ones front, oldest first, the
  newest key, and activates Detour. Minimized windows are left alone.
- **Idle auto-close keeps running while hidden** (user decision): a hidden
  window is not visible, so never frontmost, so the rule closes it once it
  has gone unused for the interval, as one behind other windows would be.
- **A new Quick Detour shows normally and does not unhide the others**
  (decided here, the conservative option): the item then reads Hide All
  (one is on screen) and hides it with the rest; the next Show All brings
  them all back.

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [App shell](../architecture/app-shell.md) — the Dock menu.
- [Quick Detour archive and idle auto-close](./quick-detour-archive.md) — the idle rule that keeps running while hidden.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.
