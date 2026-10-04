---
type: Feature
title: Extension command shortcuts
description: How an extension's manifest commands fire — WebKit keeps the commands and raises commands.onCommand, but Detour has to notice the key press and hand it over; the order in which the page, Detour's menu and the extensions get a key, and why a shortcut counts as a user gesture.
tags: [extensions, commands, keyboard, window, side-panel]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T19:22:07Z }
sources:
  - id: dispatch
    resource: ../../Detour/Extensions/Runtime/ExtensionCommandDispatch.swift
    title: ExtensionCommandDispatch.swift
  - id: browser-window
    resource: ../../Detour/Browser/Window/AutomationParking.swift
    title: AutomationParking.swift (BrowserWindow.performKeyEquivalent)
  - id: panel
    resource: ../../Detour/Extensions/Runtime/ExtensionSidePanel.swift
    title: ExtensionSidePanel.swift (noteUserGesture)
  - id: docs-extensions
    resource: ../../docs/extensions.md
    title: docs/extensions.md, "Command shortcuts"
  - id: task-132-8
    resource: backlog:TASK-132.8
    title: Host an extension's per-tab side panel beside the tab's content
  - id: integration-tests
    resource: ../../DetourTests/ExtensionSidePanelTests.swift
    title: ExtensionSidePanelTests (testTheCommandShortcutReachesTheExtension)
  - id: contexts-tests
    resource: ../../DetourTests/ExtensionRuntimeGetContextsTests.swift
    title: ExtensionRuntimeGetContextsTests (testTheShortcutOpensThePanelAndPressedAgainClosesIt)
  - id: runtime-check
    resource: "Runtime check, 2026-10-04 (isolated profile, harness in .claude/task132.8-harness.patch; not in the repository)"
    title: Runtime check of Cmd+E with the real Claude extension, signed out
---

An extension's manifest `commands` are keyboard shortcuts. WebKit keeps them
and fires `commands.onCommand`, but only when the host tells it a shortcut was
pressed. Detour does that from the browser
window's key-equivalent handling. Before this, nothing in Detour called
`WKWebExtensionContext.performCommand(for:)`, so no extension shortcut ever
fired.

# What it does

Pressing a key combination that a loaded extension declares as a command
fires that extension's `commands.onCommand` in the window's profile. The
Claude extension's Cmd+E (`toggle-side-panel`) is the case it was built for:
it opens the extension's [side panel](./side-panel.md).

# How it works

`BrowserWindow` (the `NSWindow` subclass in
[AutomationParking.swift](../../Detour/Browser/Window/AutomationParking.swift))
overrides `performKeyEquivalent(with:)`. It calls `super` first, and offers
the event to `ExtensionCommandDispatch.perform(_:in:)` only when nothing in
the window's view tree took it.

Who gets a key, in order:

1. **The page.** A web view with focus is in the view tree, and WebKit sends
   a Command-key press to the page before anything else; only an event the
   page declined comes back to the window.
2. **Detour's own menu.** When some extension has a command for the key,
   `perform` first asks `NSApp.mainMenu.performKeyEquivalent`. If the menu
   takes it, the extension does not get it, so an extension cannot take over
   Cmd+T or Cmd+W. AppKit would ask the menu next anyway; asking here only
   settles who wins when both claim the key.
3. **The extensions** loaded in the profile of the window's active space, in
   extension id order. The first whose context has a command for the event
   (`context.command(for:)`) gets `performCommand(for:)`. No other extension
   is tried.

When no loaded extension has a command for the key, `perform` returns false
without touching the menu, and the event is AppKit's to route as before.

The contexts are snapshotted before the search, because performing a command
can load or unload a context. A performed command is logged in the
`ext-commands` category.

## A shortcut is a user gesture

Before performing the command, `perform` calls
`profile.sidePanels.noteUserGesture(extensionID:)`. A `sidePanel.open` the
extension makes within 5 seconds may then take keyboard focus, the same as
after a click on its toolbar action. See the focus rule on
[side panel](./side-panel.md).

# Edge cases

- The page-first leg is WebKit's behaviour, not code in this repository. It
  is consistent with the earlier finding that a posted Cmd+key reaches the
  page's `keydown` before the main menu
  ([in-process UI automation](../playbooks/in-process-ui-automation.md)), and
  in the runtime check a posted Cmd+E with a page focused reached the
  extension.[^runtime-check] A page that consumes the key keeping it from the
  extension has not been tested.
- Only events AppKit routes through `performKeyEquivalent` get here. The
  runtime check covered Cmd+E and a shortcut without Command or Control:
  API Explorer's Option+Shift+E, posted with a page focused, reached
  `performCommand` and fired `commands.onCommand` in the
  worker.[^runtime-check] The key goes to the page first and comes back up
  the responder chain when the page declines it.
- A window showing a space of another profile dispatches to that profile's
  extensions only.
- **The Claude toggle's closing half depends on the extension being signed
  in.** Pressed with the panel open, Cmd+E makes the worker send the panel
  page a `close_side_panel` message; the listener that acts on it is not
  mounted on the signed-out screen, so the panel stays
  open.[^runtime-check] Details and the stand-in are on
  [side panel](./side-panel.md) and in the
  [side panel runtime check](../playbooks/side-panel-runtime-check.md).

# Tests

- `ExtensionSidePanelTests.testTheCommandShortcutReachesTheExtension`:
  WebKit knows the manifest's shortcut; `perform` fires `commands.onCommand`;
  the panel the extension then opens takes focus; a menu item claiming the
  same key wins and the extension's command does not run; a key no extension
  has a command for returns false.
- `ExtensionRuntimeGetContextsTests.testTheShortcutOpensThePanelAndPressedAgainClosesIt`:
  the whole toggle with a test extension whose handler mirrors the Claude
  handler call for call ([runtime.getContexts](./runtime-get-contexts.md)).
  Its panel page has the `close_side_panel` listener, which is why this
  passes while the real extension, signed out, does not close.

Both call `ExtensionCommandDispatch.perform` directly. Nothing in the suite
goes through `BrowserWindow.performKeyEquivalent` or a focused page; that
path is checked in the running app.

# Related

- [Side panel](./side-panel.md) — what the shortcut opens, and the focus rule.
- [runtime.getContexts](./runtime-get-contexts.md) — how the handler learns the panel is open.
- [AppKit gotchas](../platform/appkit-gotchas.md) — key equivalents, menus and declined keys.
- [App shell](../architecture/app-shell.md) — Detour's main menu, which outranks extensions.
- [Web Extension support](./overview.md) — `commands` is otherwise WebKit's.

[^runtime-check]: Runtime check of Cmd+E with the real Claude extension, signed out
