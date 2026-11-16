---
type: Feature
title: Quick Detour launcher panel
description: "The Spotlight-like panel that opens a Quick Detour: a non-activating borderless floating panel holding the command palette, its suggestions and undo, which profile it opens on, and how submitting activates Detour with only the new window forward."
tags: [window, palette, profiles]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
stale_after: 2026-12-31T00:00:00Z
sources:
  - id: task-193-1
    resource: backlog:TASK-193.1
    title: "Quick Detour: the window, its single tab and the palette that opens it"
  - id: task-193-2
    resource: backlog:TASK-193.2
    title: "Quick Detour: a system-wide hotkey that opens it from any app"
  - id: task-193-4
    resource: backlog:TASK-193.4
    title: "Quick Detour: a profile selector in the title bar"
  - id: task-209
    resource: backlog:TASK-209
    title: "Command palette: scope suggestions to the palette's profile"
  - id: task-346
    resource: backlog:TASK-346
    title: "Quick Detour launcher: ⌘Z in its field undoes the typing, never Detour's closed-tab list"
  - id: launcher
    resource: ../../Detour/Browser/QuickDetour/QuickDetourLauncher.swift
    title: QuickDetourLauncher.swift (the palette panel)
  - id: rules
    resource: ../../Detour/Browser/QuickDetour/QuickDetour.swift
    title: QuickDetour.swift (history scope, which profile, palette scope)
  - id: palette-scope
    resource: ../../Detour/Browser/CommandPalette/PaletteTabScope.swift
    title: PaletteTabScope.swift (historySpaceIDs)
  - id: harness
    resource: ../../docs/harness/task193-1-harness.patch
    title: TASK-193.1 runtime harness and its results
  - id: harness-2
    resource: ../../docs/harness/task193-2-harness.patch
    title: TASK-193.2 runtime harness, its scratch tools and results
---

File > New Quick Detour Window, or the [global hotkey](./quick-detour-hotkey.md), shows the **launcher panel**: the command palette alone, centred on the screen, like Spotlight, with no web view and no title bar. Submitting opens the [Quick Detour window](./quick-detour-window.md) on that page; Escape or clicking away opens nothing, so no Quick Detour window ever has an empty page (the user's change of 2026-10-25; the first build opened the window showing the palette).

# The panel

`QuickDetourLauncher.shared.show(profile:sourceSpace:)` puts a
`CommandPaletteView` in a `QuickDetourPalettePanel`:

| Property | Value | Why |
|---|---|---|
| style | `[.borderless, .nonactivatingPanel]`, `canBecomeKey` overridden to true | no chrome; it takes the keyboard without activating Detour, which the global hotkey (TASK-193.2) needs when another app is frontmost |
| `level` | `.floating`; `hidesOnDeactivate` false; joins all Spaces and full-screen apps, `.transient`, `.ignoresCycle` | above the frontmost app, like Spotlight |
| size, place | the palette's box with its full list plus a margin (560 × 321), centred on the key window's screen while Detour is active, else the screen under the pointer (`QuickDetour.panelFrame`) | |
| background | clear, no window shadow; the palette's glass tinted to the appearance (`QuickDetourPalettePanel.glassTint`, `CommandPaletteView.glassTint`) | only the palette's own glass shows. Liquid Glass takes its brightness from what is on screen behind it, and the panel has no window content of its own, so untinted it read mid grey over a light window in dark mode; Spotlight stays dark there, and so does the panel with the tint (seen 2026-10-25)[^harness] |

- **Suggestions** come from the profile the Quick Detour will use (the same
  `profileForNewWindow` rule, chosen when the panel opens): history from the
  profile's whole history, its spaces and its [Quick Detour
  scope](./quick-detour-history.md), whichever window asked
  (`PaletteTabScope.historySpaceIDs`, TASK-209; nothing for the Private
  profile); search suggestions from its engine. (Before TASK-209 the panel
  read the space it was asked from when that was the same profile's, else
  only the Quick Detour scope.)
- **No open-tab rows.** Switching to an existing tab from the panel would
  bring a browser window forward instead of opening a Quick Detour, so the
  panel's palette gets no `tabStore`.
- **One panel.** Choosing the menu item while it is up brings it forward;
  for another profile it is rebuilt. **Pressing the shortcut** while it is
  up closes it, as Spotlight's does: the global hotkey, and the menu's key
  equivalent when the hotkey is off (`newQuickDetourWindow` checks for a
  key-down as the current event).
- **Submit** closes the panel, opens
  `QuickDetourWindowController.open(profile:sourceSpace:url:typed:)`, which
  makes the window key and loads the page, then activates Detour
  (`QuickDetourLauncher.defaultOpenWindow`; see
  [activation](#activating-with-only-the-new-window-forward), below). A typed URL
  is a typed visit.
- **Undo** (TASK-346): Edit > Undo and Redo (⌘Z, ⇧⌘Z) undo and redo the
  field's typing, titled "Undo Typing" and disabled with nothing typed; the
  panel answers `browserUndo:`/`browserRedo:` itself, so they no longer fall
  through to the main browser window's
  [undo](../architecture/browser-undo.md) and reopen a closed tab there
  ([A page's key equivalents and its undo](../platform/page-key-equivalents-and-undo.md)).
- **Escape** follows the palette's own steps: it clears typed text first, and
  closes the panel on an empty field. **Clicking away** closes it through
  `NSWindow.didResignKeyNotification` on the panel.

A borderless panel is never key unless `canBecomeKey` says so; with it,
`makeKeyAndOrderFront` makes it key and the palette's field first responder
at once, also while **another app** is frontmost: the window server gives
the non-activating panel the key focus, the other app keeps the menu bar
and stays `NSWorkspace.frontmostApplication`, its window resigns key and
gets it back when the panel closes, and keys typed go to the palette
(TASK-193.2, keys posted at the HID event tap).[^harness-2] While the panel is
key, `NSApp.isActive` is **true** although Detour is not the frontmost app.

# Which profile

`QuickDetour.profileForNewWindow`: the profile of the frontmost window — a
browser window's active space's, which is the Private profile for a Private
window, or a Quick Detour's own (after a switch with its pill, the profile it
switched to) — else the first profile that is neither Private nor deleted.
From another app (the global hotkey) the frontmost window is the last Detour
window used. The user's decision in TASK-193.4 (2026-10-26); rejected: the
last profile used in a Quick Detour, and a fixed profile setting.

The launcher panel has **no pill**: it is a Spotlight-like field, and its
suggestions come from the profile chosen when it opens (above). Another
profile is one click away in the window once the page is open (the
[profile pill](./quick-detour-profile-pill.md)).

# Activating with only the new window forward

`NSApp.activate()` brings forward the app's key and main windows, not all of
them (`NSRunningApplication.activate(options:)` without
`.activateAllWindows`). Submitting from the panel over another app opens
the Quick Detour window first (key and main) and then calls
`NSApp.activate()`. Measured with the window server's order (front to back)
over a scratch app, with a browser window that had been Detour's key and
main window:[^harness-2]

| Step | `CGWindowList` order |
|---|---|
| other app in front | other, browser, browser |
| hotkey | panel (level 3), other, browser, browser |
| Return | quick, other, browser, browser (Detour active, the Quick Detour key and main) |
| Escape or click away instead | other, browser, browser (unchanged) |

The same order came from the cooperative `NSApp.activate()`,
`NSRunningApplication.current.activate(options: [])` and the deprecated
`activate(ignoringOtherApps:)` called after opening, and from TASK-193.1's
activate-then-open: activation is asynchronous, and by the time AppKit
orders windows the new one is key and main. The request is honoured
although activation is cooperative since macOS 14: Detour holds the key
focus (the panel) when Return is pressed in it.

**Trap: do not guard on `NSApp.isActive`.** It is true while the panel is
key, so a first build's `if !NSApp.isActive { NSApp.activate() }` never
activated, and the window opened behind the other app (other, quick,
browser, browser).[^harness-2]

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Quick Detour hotkey](./quick-detour-hotkey.md) — what shows the panel from any app, and the toggle.
- [Command palette](./command-palette.md) — the palette the panel holds.
- [Suggestion pipeline](./suggestion-pipeline.md) — the profile-scoped history it suggests from.
- [A page's key equivalents and its undo](../platform/page-key-equivalents-and-undo.md) — the panel's Undo and Redo.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.

[^harness]: TASK-193.1 runtime harness and its results
[^harness-2]: TASK-193.2 runtime harness, its scratch tools and results
