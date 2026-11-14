---
type: Component
title: Browser commands
description: "The command registry (TASK-320): every main-menu command defined once with a stable ID, key equivalent, parameters, availability rule and action; the main menu is built from it, and the command palette, AppleScript/Shortcuts and MCP read it."
resource: ../../Detour/Commands/BrowserCommands.swift
tags: [commands, menus, command-palette, automation, keyboard]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-14T22:30:00Z }
sources:
  - id: task-320
    resource: backlog:TASK-320
    title: "Command palette: browser commands (a shared command registry, also for AppleScript, Shortcuts and MCP)"
  - id: command
    resource: ../../Detour/Commands/BrowserCommand.swift
    title: BrowserCommand.swift (CommandID, KeyEquivalent, CommandParameter, CommandWindowKind, CommandResponder, CommandContext)
  - id: registry
    resource: ../../Detour/Commands/BrowserCommands.swift
    title: BrowserCommands.swift (the catalog, validate)
  - id: dispatch
    resource: ../../Detour/Commands/CommandDispatch.swift
    title: CommandDispatch.swift
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (setupMainMenu, add(_:to:))
  - id: registry-tests
    resource: ../../DetourTests/BrowserCommandRegistryTests.swift
    title: BrowserCommandRegistryTests.swift
  - id: menu-tests
    resource: ../../DetourTests/MainMenuCharacterizationTests.swift
    title: MainMenuCharacterizationTests.swift
---

# Role

Before TASK-320 every browser action existed only as a menu item built by
hand in `AppDelegate.setupMainMenu`, enabled by its own branch of a window
controller's `validateMenuItem`. There was no list of commands to search,
script or bind a shortcut to. `BrowserCommands` is that list: every
main-menu command, in menu order. The main menu is built from it, and the
[command palette](./command-palette.md) offers its commands. AppleScript and
Shortcuts (TASK-319), the [MCP endpoint](./automation-endpoint.md)
(TASK-228) and user shortcuts (TASK-327) are meant to read it too.

# How it works

## A command

`BrowserCommand` (`Detour/Commands/BrowserCommand.swift`):

| Field | What it is |
|---|---|
| `id: CommandID` | A dotted lowercase name such as `tab.close`, written out by hand. It is API: TASK-327 keys user bindings by it, so it is never derived from a title and never renamed. `BrowserCommandRegistryTests` pins the list. |
| `title` | The title its menu item is built with. |
| `aliases` | Other names the palette matches (`refresh` for Reload Page). |
| `symbol` | An SF Symbol for the palette row. |
| `keyEquivalent: KeyEquivalent?` | The built-in shortcut, spelled as `NSMenuItem` spells it (an uppercase key implies Shift; function keys are AppKit's private-use characters). The live item can differ: the Quick Detour item follows its hotkey setting. |
| `parameters: [CommandParameter]` | What it acts on besides its window: space, tab, profile, URL, position, extension. A command with one is never offered in the palette yet (`PalettePresence.needsParameter`). |
| `action`, `tag` | The selector its menu item sends, and the item's tag (Help's items name their page by it). |
| `responder: CommandResponder` | Who answers it, which is also how its item is targeted (below). |
| `rule`, `contextualTitle` | Its availability, and the title validation gives its item, over a `CommandContext`. |
| `palette: PalettePresence` | Offered, not offered (with the reason), or needs a parameter. |

The responders:

| `CommandResponder` | Item's target | Commands |
|---|---|---|
| `.windowController(kinds)` | nil: the responder chain finds the key window's controller | Tab, page, find, navigation, space and archive commands. `kinds` lists the window kinds whose controller implements the action. |
| `.appDelegate(explicitTarget:)` | nil, or the app delegate for Help and the extension items | New Window, Settings, Quick Detour, Help. Never disabled by a rule. |
| `.updater` | Sparkle's controller | Check for Updates… |
| `.appKit` | nil | Cut, Copy, Paste, Select All, Hide, Quit, Minimize, Zoom: AppKit's responders and validation decide. |

## Availability

`CommandContext` is a protocol of the facts rules read about a window:
`commandWindowKind` (normal, private, quickDetour, quarantine), whether a tab
is selected, has an address, is pinned, whether a Peek is up, back/forward
history, undo state, closed tabs to reopen, archived tabs, a next or
previous space, a row for Next/Previous Tab, and Cmd+O's destination. The
window controllers implement it, each fact computed only when a rule asks
for it (menu validation runs per item, and some facts read the session
database). Facts a kind of window lacks default to false, so a controller
that leaves one out has the commands needing it disabled.

`BrowserCommand.isAvailable(in:)` is the one rule: a window-controller
command is available when the context's kind is among its `kinds` and its
`rule` holds; an app delegate or updater command always is; AppKit's never
is decided here. Both controllers' `validateMenuItem` are now one line,
`BrowserCommands.validate(menuItem, in: self)`: find the command (by the
item's identifier, else by its action, so a context menu's item with a
command's action is validated as that command), retitle the item, answer the
rule. An item that is no command is enabled, as before.

The rules reproduce what the controllers answered item by item, quirks
included:

- The same action can have a different rule per window kind. Back is always
  enabled in a browser window (its Back may close the tab to its opener,
  TASK-325); a Quick Detour's needs history. Copy URL, Reload, zoom, Find
  and Web Inspector are always enabled in a browser window and need an
  address in a Quick Detour.
- A command whose action a controller does not implement is not answered in
  its windows at all (New Tab, Toggle Sidebar, Show All History in a Quick
  Detour). The registry says so through `kinds`;
  `BrowserCommandRegistryTests.testEachCommandIsAnsweredByTheRespondersItDeclares`
  checks `kinds` against `instancesRespond(to:)`.
- Next Tab and Previous Tab are both enabled by `tabNavigationTarget(…,
  offset: 1)`; the stops wrap, so that is whether there is another row.
- Pin/Unpin Tab is retitled only when a tab is selected outside a Private
  window; otherwise the item keeps whatever title it last had.

## The menu

`AppDelegate.setupMainMenu` lays the menus out (order, separators, which
have a delegate) and adds each item with `add(_:to:)`, which builds it from
the command (`makeMenuItem()`: title, key equivalent and mask, action, tag,
and `identifier` = the command's ID) and sets the target its responder
calls for. Selectors and nil targets are kept: `run_menu_item` resolves an
item in a window that need not be key, `HotKeyShortcutValidation` skips the
Quick Detour item by its action, `updateSpacesMenu` finds Manage Spaces… by
action, and Cut, Copy and Paste need the responder chain.

The dynamic items (one per space, the extension submenus, Develop's inspect
and reload items) keep their builders and tags and carry no identifier;
their actions come from the parameterised commands `space.switch`,
`extension.show-popup`, `extension.options`, `extension.inspect-offscreen`
and `extension.reload-unpacked`. The TASK-56 `menuHasKeyEquivalent` fast
path is unchanged.

## Running a command in a window

`CommandDispatch` is how a command or menu item runs in a given window the
way AppKit runs a menu item for the key window: `responderTarget(for:in:)`
(first responder up to the window, the window's delegate, the application,
its delegate), `isEnabled(_:autoenables:target:)` (AppKit's tiered decision:
`validateMenuItem`, else `validateUserInterfaceItem`, else enabled; the
item's own `isEnabled` without autoenabling), and `perform(_:in:menu:)`,
which sends the action from the command's **live** menu item (found by
identifier) so the action gets the sender, tag and target a click gives it.
The key-equivalent fast path and `AutomationMenus.resolve` (`run_menu_item`)
use the same two helpers; before, each had its own copy.

# Invariants

- Every item the main menu builds is a registry command and carries its ID
  as `identifier`; every command without a parameter has an item (Check for
  Updates… only in a run that starts Sparkle).
- An ID, once shipped, is never renamed or reused.
- A command's `kinds` are exactly the controllers that implement its action.
- The registry's `isAvailable(in:)` for a window's controller is what the
  real menu item resolves to in that window
  (`testTheRegistrysRuleIsWhatTheMenuResolvesInEveryKindOfWindow`).

# Gotchas

- Titles that validation sets (Pin/Unpin Tab, Undo/Redo, Cmd+O) live on the
  shared main-menu items, so what an item says depends on the last window
  that validated it. Tests key items by action, not title.
- Back and Forward with the page focused reach `WKWebView`'s own `goBack:`
  and `goForward:` first (they are in the responder chain ahead of the
  controller), as found in TASK-325. The registry's rule is the
  controller's; the characterization and agreement tests resolve from the
  window itself as first responder for that reason.
- AppKit adds items of its own to the Edit menu (Writing Tools, AutoFill,
  Start Dictation…, Emoji & Symbols) and the Window menu; they are not
  commands, and the tests leave them out.

# Tests

- `BrowserCommandRegistryTests`: the shipped ID list, ID format and
  uniqueness; every main-menu item is a command with its key equivalent,
  mask, tag and title; every parameterless command has an item; each
  command's responder agrees with `instancesRespond(to:)`; parameterised
  commands are kept out of the palette; the availability rules and
  contextual titles over a fake context for every window kind; a context
  that leaves facts out fails closed; key equivalents shown as menus show
  them; validation of an item the registry did not build.
- `MainMenuCharacterizationTests`: written against the menu as it was built
  item by item (commit 0b52c8c) and unchanged since: the whole menu's
  structure, the enablement and retitles of every item Detour answers in a
  normal window with a page, one with nothing selected, a Private window, a
  Quick Detour and a quarantine; the registry's rule equal to the real
  menu's resolution in each (and for a pinned tab after an undoable close);
  every item carrying its command's identifier.

# Related

- [App shell](../architecture/app-shell.md) - the menu bar, the key-equivalent fast path.
- [Command palette](./command-palette.md) - the palette.
- [Automation endpoint (MCP)](./automation-endpoint.md) - `run_menu_item`.
- [Quick Detour](./quick-detour.md) - its window's commands, and the hotkey that sets the item's key equivalent.
