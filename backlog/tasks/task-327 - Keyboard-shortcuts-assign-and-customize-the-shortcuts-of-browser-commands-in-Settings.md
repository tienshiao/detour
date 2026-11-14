---
id: TASK-327
title: >-
  Keyboard shortcuts: assign and customize the shortcuts of browser commands in
  Settings
status: To Do
assignee: []
created_date: '2026-11-14T19:47:00Z'
labels:
  - keyboard
  - menus
  - settings
dependencies: []
references:
  - TASK-320
  - TASK-295
  - TASK-193.2
  - TASK-125
  - Detour/App/AppDelegate.swift
  - Detour/App/MenuKeyEquivalentMatcher.swift
  - Detour/Browser/Settings/ShortcutRecorderView.swift
  - Detour/Browser/QuickDetour/HotKeyShortcut.swift
  - wiki/features/quick-detour.md
  - wiki/features/settings.md
priority: medium
type: feature
ordinal: 401000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14 by the user: let people assign shortcuts to commands that have none and change the ones that exist ("hot keys").

Today every shortcut is fixed in code. About 57 menu items in AppDelegate.setupMainMenu carry a literal keyEquivalent, and some keys are handled outside menus altogether: the Control+Tab Recent Tabs switcher, ⌘Z / ⇧⌘Z interception in BrowserWebView, Escape for Peek, and the find bar. Users coming from Arc or Chrome expect their own muscle memory (TASK-295 already has to pick between ⌃1–9 and ⌘1–9 for space jumps, and TASK-125 is about what ⌘W does). The only shortcut that can be changed today is the Quick Detour global hotkey (TASK-193.2), in Settings > Links.

Existing pieces to build on: ShortcutRecorderView + HotKeyShortcut / HotKeyRecordingOutcome / HotKeyShortcutValidation (recording, Escape cancels, Delete clears, refusing taken keys with the menu path) and MenuKeyEquivalentMatcher (fast menuHasKeyEquivalent path, layout-dependent limits written down in its doc comment). macOS already lets users rebind menu items by title in System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts (NSUserKeyEquivalents). Detour's own setting has to coexist with that: decide which one wins and how Settings shows a system override.

Overlap with TASK-320: a shared command registry (identifier, title, availability, action) is the natural list of what can be bound. Decide whether this task waits for it, builds the minimum registry itself, or starts from the menu items only.

Open questions for the user:
- Scope: menu commands only, or also the non-menu keys (Recent Tabs switcher, in-page keys) and commands that have no menu item?
- Whether a shortcut can be a key with no ⌘/⌥/⌃ (single-key shortcuts conflict with typing in pages).
- Conflicts: refuse a key that is already taken, or let the user reassign it and clear the old binding.
- Whether shortcuts can be global (system-wide like Quick Detour) or app-only; the expectation is app-only except the existing Quick Detour hotkey.
- Where the list lives: a new Settings pane ("Shortcuts") or a section of an existing one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The scope (which commands can be bound), the storage format and how it interacts with macOS App Shortcuts (NSUserKeyEquivalents) are decided with the user and recorded in the task, with rejected alternatives
- [ ] #2 Settings lists the bindable commands with their current shortcuts; the user can record a new shortcut, clear one, and assign one to a command that has none
- [ ] #3 A changed shortcut takes effect at once in every window, menus show it, and it persists across relaunch
- [ ] #4 A shortcut already used by another command, by the Quick Detour hotkey, or reserved by macOS is refused or reassigned as decided, and the user is told which command or system shortcut holds it
- [ ] #5 Restore Defaults resets one command or all of them to the built-in shortcuts
- [ ] #6 Tests cover the binding store (defaults, overrides, clearing, persistence) and conflict detection; the runtime check (/verify) records a shortcut in Settings and fires it in a browser window
- [ ] #7 The wiki gets a page on keyboard shortcuts (where they are defined, how overrides apply, known layout limits), and the website keyboard-shortcuts page notes that shortcuts can be customized when this ships
<!-- AC:END -->
