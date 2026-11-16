---
type: Feature
title: Keyboard shortcuts
description: "Where Detour's shortcuts are defined (the command registry's defaults), how a user's own shortcuts from Settings > Shortcuts are stored (overrides only, per data directory) and applied (the live menu items, so every window, the palette column and the TASK-56 fast path follow), which keys are refused and how the holder is named, how macOS App Shortcuts (NSUserKeyEquivalents) win and what AppKit was measured to do with them, which keys are not bindable, and the known layout limits."
resource: ../../Detour/Commands/ShortcutBindings.swift
tags: [keyboard, menus, settings, commands]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:59:43Z }
stale_after: 2027-06-01T00:00:00Z
sources:
  - id: task-345
    resource: backlog:TASK-345
    title: "Undo and redo: a page gets ⌘Z and ⇧⌘Z first, and Edit › Undo/Redo reach the page's own undo while editing"
  - id: task-333
    resource: backlog:TASK-333
    title: "Pages: Shift+Cmd+Z (Redo) in a page is never matched by BrowserWebView's interception"
  - id: task-327
    resource: backlog:TASK-327
    title: "Keyboard shortcuts: assign and customize the shortcuts of browser commands in Settings"
  - id: bindings
    resource: ../../Detour/Commands/ShortcutBindings.swift
    title: ShortcutBindings.swift (bindability, the store, the resolver, applying to the menu)
  - id: pane
    resource: ../../Detour/Browser/Settings/ShortcutsSettingsViewController.swift
    title: ShortcutsSettingsViewController.swift (the list, row states, the pane)
  - id: validation
    resource: ../../Detour/Browser/QuickDetour/HotKeyShortcut.swift
    title: HotKeyShortcut.swift (HotKeyShortcutValidation and its rules)
  - id: recorder
    resource: ../../Detour/Browser/Settings/ShortcutRecorderView.swift
    title: ShortcutRecorderView.swift
  - id: task-295
    resource: backlog:TASK-295
    title: "Spaces: keyboard shortcuts that jump straight to a space by its position (first through ninth)"
  - id: task-334
    resource: backlog:TASK-334
    title: "Menus: give the top-level menu items titles so App Shortcuts written as a menu path apply"
  - id: task-335
    resource: backlog:TASK-335
    title: "Shortcuts: detect conflicts between a shifted key and its character (⇧⌘= and Zoom In ⌘+)"
  - id: task-343
    resource: backlog:TASK-343
    title: "Shortcuts: Reset and saved bindings are checked for shifted-key conflicts too"
  - id: spike-335
    resource: ../../docs/harness/task335
    title: "TASK-335 spikes: AppKit's matching of shifted-character items from real CGEvents, UCKeyTranslate on installed layouts (macOS 26, 2026-11-14)"
  - id: spike
    resource: ../../docs/harness/task327
    title: "TASK-327 spikes (standalone AppKit programs building a menu in code, run with -NSUserKeyEquivalents as a launch argument; menu matching from real CGEvents; macOS 26, 2026-11-14) and the Accessibility helper for driving Settings"
---

# What it does

Every command of the main menu has a built-in shortcut, or none, in the
[command registry](./browser-commands.md) (`BrowserCommand.keyEquivalent`).
Settings > **Shortcuts** lists the commands grouped by menu, lets the user
record a new shortcut for one, clear it, give one to a command that has none,
reset one row, or Restore Defaults for all. A change applies at once in
every window and persists. macOS's own App Shortcuts (System Settings >
Keyboard > Keyboard Shortcuts > App Shortcuts) still win over Detour's.

The Quick Detour hotkey stays on its own pane: it is system-wide, and its
shortcut is also File > New Quick Detour Window's
([Quick Detour](./quick-detour-hotkey.md)).

# How it works

## Where a shortcut comes from

| Layer | Where | Wins over |
|---|---|---|
| Built-in | `BrowserCommand.keyEquivalent` in `BrowserCommands` | nothing |
| The user's (Detour) | `ShortcutBindingStore`, applied to the live items | the built-in one |
| Quick Detour's item | `QuickDetourHotKey.updateMenuItem` from its setting | (that item only; the store never writes it) |
| macOS App Shortcut | `NSUserKeyEquivalents`, applied by AppKit by title | everything |

## Storage

`ShortcutBindingStore.shared` keeps only what the user changed, in
`UserDefaultsScope.defaults` (the standard domain in the default data
directory, `<bundle id>.<data dir>` elsewhere), as Peek's and the Quick
Detour hotkey's settings are, so a `DETOUR_DATA_DIR` run or the test host
never writes the production app's. One key, `CommandShortcuts`:

```
{ "page.reload": { "key": "e", "modifiers": 1572864 },   // ⌥⌘E (NSEvent raw bits)
  "tab.close":   { } }                                     // no shortcut
```

- A missing ID is the built-in shortcut, so a later change to a default
  reaches everyone who never changed that command. Recording the built-in
  shortcut again removes the entry.
- Keys are stored normalized (`KeyEquivalent.normalized`: lowercased, Shift
  in the mask), so "Z" with ⌘ and "z" with ⇧⌘ are one shortcut.
- IDs this build does not know (a newer version's command) and values it
  cannot read are ignored, and kept: every write rewrites the dictionary it
  read. Restore Defaults removes the whole key, unknown IDs included, so
  nothing comes back after an upgrade.
- `ShortcutResolution.effectiveKeys` resolves: overrides first (of two on
  one key, the first command's in menu order wins), then defaults whose key
  no override took. A new default landing on a key the user already gave
  another command is therefore unassigned rather than doubled (TASK-295's
  ⌃1–⌃9 for the Spaces menu's position commands were added this way).
- Commands are keyed by `CommandID`, which is why the IDs are never renamed.

## Applying

`ShortcutBindingStore.apply(to:)` walks a menu and gives every item whose
identifier is a bindable command its effective shortcut (an item with none
keeps NSMenuItem's default ⌘ mask, as one built with none has). It runs in
`setupMainMenu` before the bar is installed, and on every
`didChangeNotification` of the shared store (`AppDelegate` observes it). The
main menu is the app's one menu bar, so that is every window. What reads the
live items follows with no code of its own:

- the command palette's shortcut column (`CommandDispatch.keyEquivalentLabel`);
- the TASK-56 fast path, `AppDelegate.menuHasKeyEquivalent` with
  `MenuKeyEquivalentMatcher`, for the delegate-driven Spaces and Extensions
  menus: a user can put a letter on Manage Spaces… or Add Extensions…,
  which the matcher answers (a press it does not model is a miss, and
  AppKit then matches the item itself);
- `run_menu_item key=` on the automation endpoint;
- the Quick Detour hotkey's own recorder, which searches the live menu, so
  it refuses a key a user binding holds.

Hints outside the main menu read the live item too
(`NSMenuItem.showShortcut(ofCommand:)`, `keyEquivalentLabel`): the sidebar
tab menu's Copy URL, Quick Detour's Open in dropdown and the ⌘O in its title
bar's Open in capsule (that capsule is redrawn when its destination changes,
not on a binding change).

## What can be bound

`BrowserCommand.bindability`:

| Commands | Bindability |
|---|---|
| Every parameterless main-menu command, AppKit's application and window items included (Hide, Quit, Minimize, Zoom) | `bindable` |
| New Quick Detour Window | `quickDetourPane`: listed read-only, with a link to that pane |
| Undo, Redo, Cut, Copy, Paste, Select All | `fixed`: listed read-only, the reason as tooltip (Undo and Redo: the user's decision, 2026-11-15, TASK-345; Cut, Copy, Paste and Select All stay fixed too, like Undo and Redo: the user's decision, 2026-11-15[^task-327]. The comment on `BrowserCommands.fixedShortcuts` records both decisions) |
| Parameterised commands (a space, an extension) | `notListed` |
| Check for Updates… | listed only in a run that starts Sparkle |

Not bindable at all, because no menu item carries them: the Control+Tab
recent-tab switcher (an event monitor), Escape for Peek, the find bar's
keys, the sidebar's and page's context menus, the Dock menu. ⌘Z and ⇧⌘Z go to
a page first and, when it leaves them, to Edit > Undo and Redo, which stay on
them (`fixed`): those items undo the page's typing as well as the browser's
actions, so moving them would take text undo from pages (TASK-345; until then
`BrowserWebView` took the keys before the page).

## Which keys are refused

`HotKeyShortcutValidation.problem(for:rules:menu:isOwnItem:quickDetourShortcut:systemHotKeys:)`,
one validator with two rule sets: `.globalHotKey` (the Quick Detour hotkey,
unchanged) and `.appShortcut` (a command). In order:

1. **No ⌘ or ⌃** and not a function key (F1-F20): refused. A plain or
   Shift key would take typing from pages, and with ⌥ alone a page's text
   field types the character instead of the item firing (measured, below).
   ⌥ and ⇧ may join ⌘ or ⌃; a function key alone or with any modifier is
   allowed. The global hotkey keeps its own rule: ⌘, ⌥ or ⌃, always.
2. **A key with no name**.
3. **The live main menu** (with its submenus, matched as AppKit matches):
   any item holding it, the row's own item and the Quick Detour item
   excepted. Because the items carry the user's bindings and any App
   Shortcut, this covers other commands, AppKit's own items (Emoji &
   Symbols, Start Dictation…) and System Settings' overrides. The message
   names the path: "⌘T is the shortcut of File > New Tab." (the application
   menu by the app's name). Then, for a key recorded with Shift, the item
   on the key's **shifted character** with the other modifiers, which the
   same press fires (TASK-335, [below](#a-shifted-key-and-its-character)):
   "⇧⌘= is ⌘+ on this keyboard, the shortcut of View > Zoom In."
4. **The Quick Detour hotkey's setting** (on or off: the File item carries
   it either way): "⌥⌘N is the Quick Detour shortcut (Settings > Quick
   Detour)."
5. **Detour's keys outside menus**: Control-Tab and Shift-Control-Tab.
   ⌘Z and ⇧⌘Z were held here too ("undoing/redoing in a page") while
   `BrowserWebView` took them before any menu (⇧⌘Z only after TASK-333
   fixed its matching); since TASK-345 a page gets them first and then the
   menu, so nothing outside the menu holds them and rule 3 names Edit > Undo
   and Redo.
6. **macOS's that no symbolic hotkey lists** (commands only): ⌘Tab, ⇧⌘Tab,
   ⌥⌘⎋ (Force Quit), ⌃⌘Q (Lock Screen), ⇧⌘Q and ⌥⇧⌘Q (Log Out).
7. **Enabled macOS shortcuts** (`CopySymbolicHotKeys`, the Fn bit ignored).

A refused key beeps, the reason shows on the line under the list, and the
recorder keeps recording: a taken key is refused with its holder named, never
reassigned (the user's decision, 2026-11-14[^task-327]).

## A shifted key and its character

AppKit matches a menu item against the typed character with the Shift that
produced it implied. Measured with real CGEvents on a US layout
(macOS 26, 2026-11-14):[^spike-335]

| Press | Fired |
|---|---|
| ⇧⌘= ("+") | an item on ⌘+ (Zoom In) |
| ⇧⌘[ / ⇧⌘1 / ⇧⌘0 / ⇧⌘; | items on ⌘{ / ⌘! / ⌘) / ⌘: |
| ⌘ with the keypad's + | ⌘+ |
| ⌘= | nothing (⌘+ is not ⌘=) |
| ⌥⇧⌘= | nothing (the other modifiers must match) |
| ⇧⌘= with both "=" + ⇧⌘ and ⌘+ in one menu | the exact "=" + ⇧⌘, in either order |
| ⇧⌘/ ("?") | neither ⌘? nor ⇧⌘? (this Mac has macOS's Show Help menu, ⇧⌘/, enabled; not separated further) |

So both recorders (`HotKeyShortcutValidation`, either rule set) refuse a
key recorded with Shift when the menu has an item on the key's **shifted
character** with the other modifiers (`HotKeyShortcut.shiftedKeyEquivalent`),
searched after the whole menu found no item on the key itself, since AppKit
fires an exact item first. Letters are left out (their shifted character is
the same shortcut), and so are keys named by their code.

The shifted character comes from the **current keyboard layout**
(`KeyboardLayout`: `TISCopyCurrentKeyboardLayoutInputSource`'s Unicode
layout data through `UCKeyTranslate`, Shift only, dead keys giving their own
character; injected in tests, which use the installed US and French layouts
through `KeyboardLayout.installed(id:)` whatever the Mac uses). Shift only,
not ⌘: the US layout's ⌘ table gives "=" for ⇧⌘=, while AppKit's
`charactersIgnoringModifiers` gave "+".

Limits:

- A layout with no Unicode layout data gives no shifted character, and
  only the key itself is compared.
- The layout at the time of the check is used; a shortcut recorded on one
  layout is not re-checked when the user switches.
- Other layouts were read, not pressed (switching the user's input source
  was out of bounds): French AZERTY types "+" with Shift on the key in the
  US "/" place and the digits with Shift; German types "=" as ⇧0. That
  AppKit's shifted matching works there as on US is assumed, not measured.
- A layout whose ⌘ table differs from its plain one (Dvorak – QWERTY ⌘,
  where ⌘ gives the QWERTY character) reads the plain Shift character, so
  the check may name the wrong item there; not handled (code review).
- Non-Latin layouts (Russian): the layout's ⌘ table gives a Latin "c"
  where it types "с" with no modifier, and the recording reads the
  unmodified character; what AppKit matches there was not measured, and
  neither recorder models it.
- Saved shortcuts are checked too (TASK-343).[^task-343] A saved shortcut
  names a character, not a key, so `KeyboardLayout.keyCodes(typing:)` finds
  the keys that type it with no modifier and
  `KeyEquivalent.shiftedKeyEquivalents(on:)` asks the recorders' rule
  (`HotKeyShortcut.shiftedKeyEquivalent`) for each: one mapping for a
  recorded keystroke and a saved key equivalent. ⇧⌘= is ⌘+'s keystroke on
  US and French (different keys); ⇧⌘à is Actual Size's ⌘0 on French and
  no keystroke on US; ⇧⌘/ is ⌘?'s on US, none on French (it types "/"
  with Shift).
  - A row's reset (`reset(_:)`) is refused, with both shortcuts and the
    holder named ("⌘+ and ⇧⌘= are one keystroke on this keyboard, and ⇧⌘=
    is now Reload Page's shortcut. Change that one first."), when the
    built-in shortcut and another command's binding are one keystroke in
    either direction (`ShortcutBindingStore.command(sharingKeystrokeWith:)`),
    after the exact-holder check.
  - Two saved shortcuts on one keystroke (`ShortcutResolution
    .sameKeystrokeConflicts`, over the effective keys) keep both: the
    resolver drops nothing for them, AppKit fires the Shift-held, exact one
    and the other only from a key typing its character alone (the keypad's
    "+"; TASK-335's measurement). They are logged at launch and on every
    input source change (`AppDelegate`, category `shortcuts`, through the
    distributed `kTISNotifySelectedKeyboardInputSourceChanged`,
    `KeyboardLayout.selectionDidChangeNotification`), and the pane reloads
    on that notification and marks both rows (below). Before, a pair saved
    before TASK-335 or colliding only on a layout chosen since was never
    re-checked.

## The pane

`ShortcutsSettingsViewController` (toolbar item "Shortcuts", symbol
`keyboard`, the last pane since TASK-347's order; it came after Search
before): description, a search field and Restore Defaults,
then one list drawn as a form group (TASK-338; a column pane: the list fills the pane and scrolls
on its own, 400 pt minimum), then the warning line.

- `ShortcutList.items` (pure): menu headings as floating group rows, each
  menu's listed commands in menu order. Search: every typed word starts a
  word of the title, an alias or the menu's title ("file new").
- `ShortcutRowState.make` (pure): `editable(overridden:)`, `systemSettings`
  ("Set in System Settings", recorder disabled, showing macOS's shortcut),
  `quickDetour` (disabled, "Change in Quick Detour Settings" link),
  `fixed(reason)` (disabled, the reason as tooltip).
- A row whose effective shortcut an enabled macOS shortcut holds says
  "Used by macOS" in orange, with a tooltip naming System Settings >
  Keyboard > Keyboard Shortcuts (and Mission Control's Switch to Desktop for
  ⌃1–⌃9); its recorder stays enabled (TASK-295). The pane reads
  `CopySymbolicHotKeys` once per reload and turns each key code into the
  menu keys it takes with the current layout's characters
  (`SystemHotKey.menuKeyEquivalents(character:shiftedCharacter:)`:
  `layoutCharacter(forKeyCode:)` through a synthesized key event, nothing
  posted, and for one held with Shift also its shifted character, so a
  macOS ⇧⌘= marks Zoom In's ⌘+, TASK-335); all are injected in tests. Before, the list was only consulted when recording, so a built-in
  shortcut macOS held looked like any other.
- A row whose shortcut is one keystroke with another command's on this
  layout (TASK-343) says "Same key as <other>" in orange, the "Used by
  macOS" note's look, with a tooltip naming both shortcuts and the command
  the keystroke runs ("⌘+ and Reload Page's ⇧⌘= are one keystroke on this
  keyboard, which runs Reload Page. Record another shortcut for one of
  them."); both rows of the pair are marked, and macOS's note wins when a
  row has both. The row note, rather than a line under the list or a
  dialog, is the user's choice (confirmed 2026-11-15).[^task-343]
- The warning line under the list (a refused recording or reset) sits on
  the pane's bottom and the list takes the rest. Until TASK-343 the line
  was only held above the bottom and nothing gave the list a height, so the
  list collapsed to nothing while a refusal showed (seen at runtime on the
  reset refusal; the TASK-327 exact-holder refusal did the same).
- A row: title, the note, `ShortcutRecorderView` (placeholder "None"; a
  disabled one shows its shortcut as dimmed text with no box), and a reset
  button shown once the shortcut differs from the built-in one. A reset
  onto a built-in key another command's override now holds is refused
  (beep, "⌘W is now Reload Page's shortcut. Change that one first.";
  `ShortcutBindingStore.command(holding:except:)`): the resolver would
  otherwise leave the row silently without a shortcut.
- The search reloads only when the query changed (the field's action and
  `controlTextDidChange` both report an edit).
- While a recorder records, the pane does not rebuild rows (a change
  reloads when recording ends), and the Quick Detour hotkey is suspended, as
  its own pane does, so pressing ⌥⌘N reaches the recorder and is refused
  instead of opening the launcher.
- Accessibility identifiers: `shortcut.<command id>` (recorder),
  `shortcutReset.<command id>`, `shortcutsSearch`,
  `shortcutsRestoreDefaults`, `shortcutsWarning`.

# macOS App Shortcuts

Measured with standalone AppKit programs that build their menu in code, run
with `-NSUserKeyEquivalents '{…}'` as a launch argument (the argument domain,
so nothing is written to the app's real defaults), on macOS 26:[^spike]

- AppKit applies an entry **when the item enters a menu and whenever it is
  retitled** (Pin Tab retitled to Unpin Tab picked up "Unpin Tab"'s entry).
  The item's `keyEquivalent` and `keyEquivalentModifierMask` getters then
  return the App Shortcut's, `userKeyEquivalent` returns its key (empty
  when none applies), and `NSMenu.performKeyEquivalent` fires the item on
  that key only.
- **Code writes are kept underneath**: a key set in code while an entry
  applies changes nothing visible, and becomes the item's again once its
  title has no entry (retitled away). So Detour writes its bindings once per
  change and never has to re-apply after validation retitles an item.
- **The menu-path form** (System Settings' "File->Close Tab", stored as
  `"\u{1b}File\u{1b}Close Tab"`) is matched against the **parent items'
  titles**, not the submenus' titles, and wins over a plain-title entry.
  An entry applies when its item's submenu is attached to a titled parent,
  or once the parent is titled, even after the items were added.
  Detour's menu-bar items were `NSMenuItem()`, titled "NSMenuItem" (the bar
  shows the submenu's title), so path-form entries never applied to Detour
  until TASK-334 titled every bar item as its menu, the application menu's
  by the app's name ("Detour->Settings…").[^task-334] Measured in the real
  app (Debug build, launched with
  `-NSUserKeyEquivalents '{ "\033File\033Close Tab" = "@~w"; "\033Detour\033Settings…" = "@~,"; "\033View\033Zoom In" = "@~="; "Show All History" = "@~y"; }'`):
  before, only the plain-title entry applied; after, all four did (read
  through Accessibility, `run_menu_item key=cmd+opt+w` ran File > Close Tab
  and `cmd+w` found nothing), and Settings > Shortcuts said "Set in System
  Settings" on all four rows. The bar's titles read through Accessibility
  were the same before and after.
- AppKit reads the entries **once**: one put in the argument domain from
  inside the running app (the test host) did not apply on a retitle, so a
  test cannot add one; an entry has to be in place at launch (System
  Settings' own, or a launch argument).[^task-334]

The spikes and `axdrive.swift` (Accessibility press and read by identifier
in the Settings window, key events posted to the process) are in
[docs/harness/task327](../../docs/harness/task327), with the fixture page
used for the runtime checks. On a locked screen Accessibility returns no
windows.

What Detour does with it: a row whose live item has a non-empty
`userKeyEquivalent` shows macOS's shortcut and "Set in System Settings",
with the recorder off, and nothing is written. The conflict check sees the
App Shortcut through the item's getters. Entries live in the bundle-id
domain, shared by every data directory, which is right: macOS's setting is
for the app. To try one at runtime, pass it as a launch argument; never
`defaults write` it (that domain is the production app's).

# Edge cases and known limits

- **Shifted characters.** A recording stores the key's unshifted character
  plus Shift (⇧⌘= for the key labelled "+" on a US layout). AppKit fires
  such an item on the real press: a CGEvent ⇧⌘1, whose
  `charactersIgnoringModifiers` is "!", fired an item "1" + ⇧⌘, and ⇧⌘=
  ("+") fired "=" + ⇧⌘ (spike, 2026-11-14).[^spike] The TASK-56 matcher
  compares "!" with "1" and misses, which is its fallback path. The same
  press also fires an item spelled with the shifted character; since
  TASK-335 the recorders see that (next section).
- **Function keys and ⌥.** In the same spike AppKit's menu matching fired
  an F6 item with no modifier (matched by key code: the event's characters
  were empty), a ⌥E item, and a ⌃⌥K item.[^spike]
- **The recording's layout.** A shortcut is a character, recorded on the
  layout in use; on another layout AppKit matches the character, which may
  sit elsewhere, and `allowsAutomaticKeyEquivalentLocalization` (on for
  apps linked against the macOS 12 SDK or later) may remap a key
  equivalent the layout cannot type.
- **Which keys win over a page's text field** (Debug build, 2026-11-14,
  key events posted to the process while a browser window was key and the
  fixture page's `<input>` had focus):[^task-327]

  | Shortcut on Reload Page / Import from Arc… | Text field focused | Page body or sidebar focused |
  |---|---|---|
  | ⌥⌘E, ⌃U | fires | fires |
  | ⌥R | the field types "®", nothing fires | fires |
  | F6 (no modifier) | fires (the page also sees the keydown) | fires |

  So ⌥ alone is refused for a command; the Quick Detour hotkey, a Carbon
  hotkey that takes the key before any app, still allows it.
- **⌃1–⌃9 and Mission Control** (TASK-295). Mission Control's "Switch to
  Desktop N" takes ⌃N before any app when it is turned on in System
  Settings. On the user's Mac `CopySymbolicHotKeys` reported ⌃1–⌃6 enabled
  and ⌃7–⌃9 disabled (2026-11-14), and the pane marked rows 1–6 "Used by
  macOS".[^task-295] Key events posted to Detour's pid
  (`CGEventPostToPid`) skip the system's hotkeys, so ⌃2 posted that way
  switched spaces in the runtime check; what a physical press of ⌃1–⌃6 does
  there was not tried (it may switch the desktop). The digits are layout
  characters: on a layout that types them shifted (French AZERTY),
  `MenuKeyEquivalentMatcher` misses and AppKit's own matching decides (not
  measured). The "Used by macOS" mark compares the layout's characters for
  the system shortcut's key code with the row's key, while the recorder's
  refusal compares key codes, so on such a layout the two can disagree.
  TASK-335's Shift-level mapping does not settle it: Mission Control's ⌃1
  is held without Shift, so on AZERTY it maps to "&" + ⌃ only and the
  default "1" + ⌃ row stays unmarked. In Detour's model that is
  consistent (the row's "1" is typed ⇧⌃ on that key, which the system
  shortcut does not hold), but whether AppKit's key-equivalent
  localization moves "1" + ⌃ onto the unshifted key there is not measured
  (it needs the user's input source switched). UCKeyTranslate on the
  installed French layout gives "1" for that key with ⌃ held, a hint that
  ⌃ may reach the digit there.
- **Space names as titles.** The Spaces menu titles its position items with
  the space's emoji and name when it opens, so an App Shortcut written for
  "Switch to Space 1" applies only until then, and one written for a space's
  name follows that name to whatever position it is at.
- **One title for two commands.** The row "Open Quick Detour in Space" is
  the registry's title for Cmd+O, which is also Open Peek in New Tab in a
  browser window: one item, one shortcut.
- **Titles that change.** Pin/Unpin Tab, Undo/Redo and Cmd+O are retitled
  by validation, so an App Shortcut on one of their titles applies only
  while the item has it, and the row reflects the last validation.

# Tests

- `ShortcutBindingStoreTests`: defaults with nothing stored, overrides,
  giving a shortcut to a command with none, clearing (an empty dictionary),
  the default dropping the override, normalized storage, non-bindable
  commands never stored, reset and Restore Defaults, persistence across a
  new store over the same suite, the shared store's scoped suite, unknown
  IDs ignored and kept, unreadable values, the resolver's collisions,
  property lists and key names.
- `ShortcutConflictTests`: the modifier rule and function keys, another
  command's path, the own item, AppKit's items, the Quick Detour setting,
  Detour's keys outside menus, macOS's (symbolic and reserved), the real
  menu bar, the pane's check; a shifted key and its character (TASK-335):
  the US and French layouts' characters through `UCKeyTranslate`, ⇧⌘=
  refused for ⌘+ and ⇧⌘/ for ⌘?, ⌘=, ⌘/, ⌥⇧⌘= and ⇧⌘T not, the exact
  item named first, the French layout's "+", the Quick Detour recorder's
  rules, the real menu's Zoom In; saved shortcuts (TASK-343): a saved key
  equivalent's shifted equivalents on US and French (the keypad-only "+",
  ⇧⌘à, ⇧⌘/ on French, ⌥⇧⌘=, letters, no layout), a saved ⇧⌘= found with
  Zoom In on both layouts and both kept, ⇧⌘à on French only, both rows
  marked and macOS's note first, the marks following a posted input source
  change, Zoom In's and Actual Size's resets refused (US and French; US
  lets Actual Size's through), the holder found in either direction.
  The layout-change test posts on a center of its own
  (`layoutChangeCenter`), not the system's distributed one.
  `ShortcutsSettingsPaneTests.testTheListKeepsItsHeightWhileARefusalShows`:
  the list keeps its height under a refusal's line.
- `ShortcutMenuTests` (the real menu bar and the shared store, restored):
  a binding reaches the item and AppKit's matching, clearing, a shortcut
  for a command with none and Restore Defaults, reset, the Quick Detour
  item untouched, the palette column, a context menu hint, the fast path
  answering a binding in the Extensions and Spaces menus, the registry's
  menus equal to the bar's.
- `SpaceJumpTests` (TASK-295): a rebinding of a position command reaches
  its item and the Spaces menu's matching, and reset gives ⌃N back.
- `ShortcutsSettingsPaneTests`: grouping, parameterised commands left out,
  Check for Updates…, search; row states; recording, refusing with the
  holder named, clearing, a function key alone, reset, Restore Defaults,
  disabled rows, an empty search; a macOS shortcut turned into the menu key
  it takes, the "Used by macOS" row state and note (TASK-295); a macOS
  shortcut held with Shift marking the row on its shifted character
  (TASK-335).

# Related

- [Browser commands](./browser-commands.md) - the registry the defaults and IDs come from.
- [Settings window](./settings.md) - the window and its panes.
- [Quick Detour](./quick-detour.md) - the global hotkey, its recorder and validation.
- [App shell](../architecture/app-shell.md) - the menu bar and the key-equivalent fast path.
- [Command palette](./command-palette.md) - the shortcut column.

[^task-327]: TASK-327
[^task-295]: TASK-295
[^task-334]: TASK-334
[^spike-335]: TASK-335 spikes
[^task-343]: TASK-343
[^spike]: NSUserKeyEquivalents spikes
