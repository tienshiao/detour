---
type: Component
title: Browser commands
description: "The command registry (TASK-320): every main-menu command defined once with a stable ID, key equivalent, parameters, availability rule and action; the main menu is built from it, and the command palette, AppleScript/Shortcuts and MCP read it."
resource: ../../Detour/Commands/BrowserCommands.swift
tags: [commands, menus, command-palette, automation, keyboard]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:01:12Z }
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
  - id: palette-commands
    resource: ../../Detour/Browser/CommandPalette/PaletteCommands.swift
    title: PaletteCommands.swift
  - id: command-choices
    resource: ../../Detour/Commands/CommandChoices.swift
    title: CommandChoices.swift (the choices of parameterised commands, TASK-320 AC #3)
  - id: extension-menu-items
    resource: ../../Detour/Extensions/UI/ExtensionMenuItems.swift
    title: ExtensionMenuItems.swift (the Extensions menu's live items, shared with the palette)
  - id: web-view
    resource: ../../Detour/Browser/Window/BrowserWebView.swift
    title: "BrowserWebView.swift (goBack: and goForward: handed to the controller, TASK-331)"
  - id: back-forward-tests
    resource: ../../DetourTests/BackForwardResponderTests.swift
    title: BackForwardResponderTests.swift
  - id: task-331
    resource: backlog:TASK-331
    title: "Navigation: Cmd+[ and Cmd+] with the page focused go through Detour's Back and Forward"
  - id: task-327
    resource: backlog:TASK-327
    title: "Keyboard shortcuts: assign and customize the shortcuts of browser commands in Settings"
  - id: task-295
    resource: backlog:TASK-295
    title: "Spaces: keyboard shortcuts that jump straight to a space by its position (first through ninth)"
  - id: space-jump
    resource: ../../Detour/Browser/SpaceJump.swift
    title: SpaceJump.swift (position to space)
  - id: space-jump-tests
    resource: ../../DetourTests/SpaceJumpTests.swift
    title: SpaceJumpTests.swift
---

# Role

Before TASK-320 every browser action existed only as a menu item built by
hand in `AppDelegate.setupMainMenu`, enabled by its own branch of a window
controller's `validateMenuItem`. There was no list of commands to search,
script or bind a shortcut to. `BrowserCommands` is that list: every
main-menu command, in menu order. The main menu is built from it, and the
[command palette](./command-palette.md) offers its commands. AppleScript and
Shortcuts (TASK-319), the [MCP endpoint](./automation-endpoint.md)
(TASK-228) are meant to read it too, and [keyboard shortcuts](./keyboard-shortcuts.md)
(TASK-327) do: Settings > Shortcuts lists its commands by menu, and the
user's shortcuts are stored by command ID over its defaults.

# How it works

## A command

`BrowserCommand` (`Detour/Commands/BrowserCommand.swift`):

| Field | What it is |
|---|---|
| `id: CommandID` | A dotted lowercase name such as `tab.close`, written out by hand. It is API: TASK-327 keys user bindings by it, so it is never derived from a title and never renamed. `BrowserCommandRegistryTests` pins the list. |
| `title` | The title its menu item is built with. |
| `aliases` | Other names the palette matches (`refresh` for Reload Page). |
| `symbol` | An SF Symbol for the palette row. |
| `keyEquivalent: KeyEquivalent?` | The built-in shortcut, spelled as `NSMenuItem` spells it (an uppercase key implies Shift; function keys are AppKit's private-use characters). The live item can differ: the Quick Detour item follows its hotkey setting, the others the user's shortcut (`ShortcutBindingStore`, TASK-327), and any item a System Settings App Shortcut names shows macOS's ([keyboard shortcuts](./keyboard-shortcuts.md)). |
| `parameters: [CommandParameter]` | What it acts on besides its window: space, tab, profile, URL, position, extension. One with a list to choose from (space, tab, profile, extension: `hasChoiceList`) is asked for in the palette with a chip (TASK-320 AC #3, [command palette](./command-palette.md#a-commands-chip)); a URL or a position cannot be, and such a command stays out (`PalettePresence.needsParameter`; none is declared). |
| `paletteTitle` | The palette's title when the menu's says too little outside its submenu ("Show Extension Popup" for the submenu's "Show Popup"); `titleInPalette` is it or `title`. |
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
is selected, has an address, is pinned, is in a split, whether a Peek is up, back/forward
history, undo state, closed tabs to reopen, archived tabs, a next or
previous space, a row for Next/Previous Tab, and Cmd+O's destination; and
`commandChoices(for:)`, the values a parameterised command can run on in
the window (`CommandChoices`, default none). The
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
  enabled in a browser window (its Back may close the tab to its
  [opener](../tabs/tab-opener.md),
  TASK-325); a Quick Detour's needs history. Copy URL, Reload, zoom, Find
  and Web Inspector are always enabled in a browser window and need an
  address in a Quick Detour.
- A command whose action a controller does not implement is not answered in
  its windows at all (New Tab, Toggle Sidebar, Show All History in a Quick
  Detour). The registry says so through `kinds`;
  `BrowserCommandRegistryTests.testEachCommandIsAnsweredByTheRespondersItDeclares`
  checks `kinds` against `instancesRespond(to:)`.
- Move Tab to Space needs a normal window, a selected tab, and no split
  (the sidebar has no Move to on a split row; a pinned entry moves). Split
  with Tab needs a selected unpinned tab in no split, in a normal or Private
  window. Switch to Space needs a normal window, as its Spaces menu items.
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

The dynamic items (one per space after the ninth, the extension submenus,
Develop's inspect and reload items) keep their builders and tags and carry
no identifier; their actions come from the parameterised commands
`space.switch`, `extension.show-popup`, `extension.options`,
`extension.inspect-offscreen` and `extension.reload-unpacked`. The TASK-56
`menuHasKeyEquivalent` fast path matches the live items, so it sees the
user's shortcuts, which can put a letter on a static item of the Spaces or
Extensions menu.

## Spaces by position (TASK-295)

The first nine spaces are reached by nine parameterless commands,
`space.jump-1` to `space.jump-9` ("Switch to Space 1" …, ⌃1–⌃9 by default,
Arc's keys, the user's decision of 2026-11-14 over ⌘1–⌘9[^task-295]), not
by the parameterised `space.switch`. Their
items are static: `setupMainMenu` adds them after Previous Space's
separator, so their shortcuts work before the Spaces menu is first opened
(a dynamic item would only exist after that). When the menu opens,
`updateSpacesMenu` titles item N with the emoji and name of the space now at
position N in Settings › Spaces order (`TabStore.nonIncognitoSpaces`), puts
the key window's checkmark on it, and hides it when there is no space
there; spaces after the ninth get the dynamic `space.switch` items.

- **Resolved when it runs.** `BrowserWindowController.jumpToSpace(position:)`
  asks `SpaceJump.target(ofPosition:in:)` (pure) for the space at that
  position now, so adding, deleting or reordering spaces changes what a
  shortcut opens with no rebuild; the menu's titles catch up when it opens.
- **One action per position** (`jumpToSpace1:` … `jumpToSpace9:`), not a
  shared action with the position on the item's tag: a hit on the fast path
  is sent with the menu, not the item, as sender (measured, see
  [AppKit gotchas](../platform/appkit-gotchas.md)).
- **The rule is only the window kind** (`commandWindowKind == .normal`), not
  "a space exists at N". A key equivalent matched by a disabled item is not
  handled (measured), so the key goes on to the first responder and can
  beep; an enabled command with nothing to do swallows it. Empty positions
  are hidden with `allowsKeyEquivalentWhenHidden`, so AppKit still fires
  them (measured) and `MenuKeyEquivalentMatcher` matches them too.
- **Private windows** answer the actions but the rule disables them (as
  Next/Previous Space); **Quick Detour and quarantine** windows do not
  implement them (they have no spaces sidebar), so the items are disabled
  there.
- **Not in the palette**: the title names a position, not a space.
- Listed and bindable in Settings › Shortcuts like any parameterless
  command; a row whose key macOS holds says "Used by macOS"
  ([keyboard shortcuts](./keyboard-shortcuts.md)).

`BrowserCommands.menus` lists the commands under the title of the bar menu
that holds their item (the application menu as "Detour"); `all` is their
concatenation, in the same order as before. Settings > Shortcuts groups its
rows by it, and `ShortcutMenuTests` holds it to the real menu bar. After the
bar is built, `ShortcutBindingStore.shared.apply(to:)` gives every bindable
command's item its effective shortcut, and again on every change.

## Running a command in a window

`CommandDispatch` is how a command or menu item runs in a given window the
way AppKit runs a menu item for the key window: `responderTarget(for:in:)`
(first responder up to the window, the window's delegate, the application,
its delegate), `isEnabled(_:autoenables:target:)` (AppKit's tiered decision:
`validateMenuItem`, else `validateUserInterfaceItem`, else enabled; the
item's own `isEnabled` without autoenabling), and `perform(_:in:menu:)`,
which sends the action from the command's **live** menu item (found by
identifier) so the action gets the sender, tag and target a click gives it.
Given a `controller`, a window-controller command it implements is sent to
it rather than resolved along the chain; the palette passes its owner.
`perform(_:argument:in:controller:)` runs a parameterised command on a value
(TASK-320 AC #3): an item built from the command with the value as
`representedObject`, as the menu items that run it carry it (a Spaces menu
item, the sidebar's Move to submenu, an extension's submenu), sent to the
controller (or the app delegate for an explicit target) and validated
there. `performFromPalette` is what both palette owners call: a choice is
first checked against the window's `commandChoices(for:)` now (the chip read
them when it opened), and a gone one is refused, which the owner answers
with a beep.
The key-equivalent fast path and `AutomationMenus.resolve` (`run_menu_item`)
use the same two helpers; before, each had its own copy.

## In the command palette

A palette over a browser window or a Quick Detour gets
`PaletteCommands.source(for: controller)`: the commands with
`palette == .offered` that the window's kind answers, resolved one at a
time when typed text matches them, by `PaletteCommands.resolve`:
`isAvailable(in:)` (the menu item's rule), `title(in:)` and the live item's
shortcut (`CommandDispatch.keyEquivalentLabel`); the updater's only while
Sparkle's own validation enables its live item. A parameterised command is
offered only when its rule holds and `commandChoices(for:)` has a value;
its row has no shortcut, and choosing it puts its chip in the field
([command palette](./command-palette.md#a-commands-chip)). Running one is
`CommandDispatch.perform(…, controller:)` from the window after the palette
is dismissed: a window controller's command goes to that controller, whose
rule offered it, not to whatever answers first along the chain (below).
How rows are matched, ranked and placed, and the `>` list, are on
[command palette](./command-palette.md#browser-commands).

## How the other consumers are meant to use it

Recorded for TASK-319 and TASK-228 (not built here):

- **AppleScript and App Intents (TASK-319)**: one script command or intent
  per command ID, its parameters from `parameters`, run with
  `CommandDispatch.perform` against the window the script names (resolving
  through that window's responder chain works whether or not it is key,
  as `run_menu_item` already does); `isAvailable(in:)` with that window's
  controller says whether it may run, so a script cannot do in a Private
  window what its menu cannot.
- **MCP (TASK-228)**: a `run_command` tool by ID (and a `list_commands`
  listing IDs, titles and availability for a window) beside the existing
  `run_menu_item`, which keeps working by menu path or key equivalent.
- **User shortcuts (TASK-327, built)**: bindings keyed by `CommandID`,
  applied to the live items (the palette shows the live item's shortcut, so
  it follows); defaults are `keyEquivalent`. See
  [keyboard shortcuts](./keyboard-shortcuts.md).

## Why this shape

- **Commands keep their selectors and the responder chain**, rather than an
  action closure per command. The menu, `run_menu_item`, the key-equivalent
  fast path, `HotKeyShortcutValidation` and AppKit's own items all work by
  selector and target, and a closure would have had to find the window
  itself: the responder chain already does, for the key window and, through
  `CommandDispatch`, for a given one.
- **Availability is a rule over a lazy context**, not an eager snapshot
  struct of every fact (some facts query the database and validation runs
  per item and on every key equivalent), and not "ask `validateMenuItem`"
  for the palette (while the palette is open its field editor is first
  responder; the rule over the window controller is what its menu item
  answers once the palette is gone).
- **Which kinds of window answer a command is declared**, not only left to
  the responder chain, so the palette and scripts can tell without
  resolving, and a test holds the declaration to `instancesRespond(to:)`.
- **IDs are written out**, never derived from titles (titles change with
  validation and with wording; bindings must not).
- **The menu layout stays in code** (`setupMainMenu`), not as registry
  data: separators, conditional items (Check for Updates…), delegates and
  dynamic sections are layout, and moving them would have changed more than
  the move needed.
- **Dynamic items stay with their builders** for now: their availability is
  per parameter (an extension with no popup has a nil action), which the
  registry's rules do not express yet.

## What is not on the registry yet

The sidebar's context menus (tab, folder, space, pinned and favourite
menus in `TabSidebarViewController`, the favourites bar, the archive page),
the page's context menu additions (`BrowserWebView.willOpenMenu`), the Quick
Detour title bar's menus, the Dock menu, and keys handled outside menus
(the Control+Tab switcher, Escape for Peek, the find bar). ⌘Z and ⇧⌘Z are
no longer among them: since TASK-345 `BrowserWebView` no longer takes them
before the page, and those the page leaves reach Edit > Undo and Redo
([a page's key equivalents and its undo](../platform/page-key-equivalents-and-undo.md)). Two commands have no menu item and are
reached from the palette only (TASK-320 AC #3): `tab.move-to-space` (Move
Tab to Space, the sidebar's Move to path for the selected tab) and
`tab.split-with` (Split with Tab, the sidebar's create-split path); they sit
in `menus` under Spaces and File, and Settings > Shortcuts leaves them out
as parameterised. Others with no menu item at all (duplicate, mute, sleep,
separate a split, new or rename space) do not exist as commands yet. No
command takes a profile; `CommandChoices.profiles` is ready for one.

# Invariants

- Every item the main menu builds is a registry command and carries its ID
  as `identifier`; every command without a parameter has an item (Check for
  Updates… only in a run that starts Sparkle).
- An ID, once shipped, is never renamed or reused: user shortcuts are
  stored by it (TASK-327).
- No two commands share an action where a key equivalent can reach them
  through the fast path (the Spaces menu's nine position commands each have
  their own).
- `BrowserCommands.menus` lists each command under the bar menu that holds
  its item (`ShortcutMenuTests.testTheRegistrysMenusAreTheMenuBarsMenus`).
- A command's `kinds` are exactly the controllers that implement its action.
- The registry's `isAvailable(in:)` for a window's controller is what the
  real menu item resolves to in that window
  (`testTheRegistrysRuleIsWhatTheMenuResolvesInEveryKindOfWindow`).

# Gotchas

- The palette resolves a window's commands once per showing; one refused
  when Return runs it (the window changed meanwhile) beeps.

- Titles that validation sets (Pin/Unpin Tab, Undo/Redo, Cmd+O) live on the
  shared main-menu items, so what an item says depends on the last window
  that validated it. Tests key items by action, not title.
- Back and Forward with the page focused resolve to `WKWebView`'s own
  `goBack:` and `goForward:` (WKWebView.h's `WKIBActions`, enabled by
  WebKit's back list), which are in the responder chain ahead of the
  controller (found in TASK-325, confirmed on a build from before it in
  TASK-331). Until TASK-331 that made Navigate › Back, by Cmd+[, any key a
  user bound or a click, disabled on a child tab with no back item while
  the page had the keys. `BrowserWebView` now overrides both actions and
  their `validateUserInterfaceItem` in a browser window and hands them to
  the controller (its rule, its focused pane or Peek); a Quick Detour
  keeps WebKit's (`BackForwardResponderTests`). Any other `WKWebView`
  action a command shares would need the same: `reload:` does not, since
  Reload Page's action is `reloadPage:`. `NSWindow` also declares
  `selectNextTab:`/`selectPreviousTab:` (window tabbing); a Detour window
  was not seen to take them (the menu's resolution from the window follows
  the controller's rule). The registry's rule is the controller's: the
  characterization and agreement tests resolve from the window itself as
  first responder, and the palette sends window-controller commands to the
  controller.
- AppKit adds items of its own to the Edit menu (Writing Tools, AutoFill,
  Start Dictation…, Emoji & Symbols) and the Window menu; they are not
  commands, and the tests leave them out.

# Tests

- `BrowserCommandRegistryTests`: the shipped ID list, ID format and
  uniqueness; every main-menu item is a command with its key equivalent,
  mask, tag and title; every parameterless command has an item; each
  command's responder agrees with `instancesRespond(to:)`; parameterised
  commands with a list are offered (the Develop menu's per-extension ones
  are not, a URL one could not be), and the chip commands' rules; the availability rules and
  contextual titles over a fake context for every window kind; a context
  that leaves facts out fails closed; key equivalents shown as menus show
  them; validation of an item the registry did not build.
- `SpaceJumpTests` (TASK-295): the position mapping (fewer than nine, more
  than nine, exactly nine, a reorder, positions outside 1–9), the nine
  commands, the real Spaces menu (static items, titles, hidden empty
  positions still matched, spaces after the ninth), adds, a reorder and a
  delete changing what a press opens with no rebuild, only the window it
  runs in switching, Private windows, a rebinding.
- `MainMenuCharacterizationTests`: written against the menu as it was built
  item by item (commit 0b52c8c), changed since only by TASK-295's nine
  Spaces items (whose titles the menu sets when it opens): the whole menu's
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
- [Keyboard shortcuts](./keyboard-shortcuts.md) - the user's shortcuts over the registry's defaults, Settings > Shortcuts.

[^task-295]: TASK-295
