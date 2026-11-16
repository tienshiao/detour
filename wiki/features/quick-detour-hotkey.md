---
type: Feature
title: Quick Detour global hotkey
description: "The system-wide shortcut (Opt-Cmd-N by default) that shows the Quick Detour launcher from any app: the Carbon registration and why, what conflicts it can and cannot detect (measured), where it registers, the toggle, the Settings recorder and its warnings, and the layout limits."
tags: [window, keyboard, settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:09Z }
stale_after: 2026-12-31T00:00:00Z
sources:
  - id: task-193-2
    resource: backlog:TASK-193.2
    title: "Quick Detour: a system-wide hotkey that opens it from any app"
  - id: task-335
    resource: backlog:TASK-335
    title: "Shortcuts: detect conflicts between a shifted key and its character (⇧⌘= and Zoom In ⌘+)"
  - id: task-327
    resource: backlog:TASK-327
    title: "Keyboard shortcuts: assign and customize the shortcuts of browser commands in Settings"
  - id: task-328
    resource: backlog:TASK-328
    title: "Settings: use switches instead of checkboxes on every Settings pane"
  - id: task-211
    resource: backlog:TASK-211
    title: "Settings: keep a pane's list and details fixed; scroll only their contents"
  - id: hotkey
    resource: ../../Detour/Browser/QuickDetour/QuickDetourHotKey.swift
    title: QuickDetourHotKey.swift (the wiring, the Carbon registrar)
  - id: hotkey-model
    resource: ../../Detour/Browser/QuickDetour/HotKeyShortcut.swift
    title: HotKeyShortcut.swift (the shortcut, validation, recording)
  - id: hotkey-registration
    resource: ../../Detour/Browser/QuickDetour/HotKeyRegistration.swift
    title: HotKeyRegistration.swift (the state machine, the settings)
  - id: recorder
    resource: ../../Detour/Browser/Settings/ShortcutRecorderView.swift
    title: ShortcutRecorderView.swift
  - id: harness-2
    resource: ../../docs/harness/task193-2-harness.patch
    title: TASK-193.2 runtime harness, its scratch tools and results
---

TASK-193.2. A system-wide shortcut, Opt-Cmd-N by default, shows the [launcher panel](./quick-detour-launcher.md) from any app (and from Detour), on the screen under the pointer.

# How it works

| Piece | What it does |
|---|---|
| `HotKeyShortcut` | The shortcut: virtual key code (layout independent, what is registered), modifiers, and the key's character on the layout it was recorded with. Spelled three ways: Carbon modifiers (`carbonModifiers`), the menu's key equivalent (the character, or AppKit's function-key character for F-keys, arrows, Return and the like), and the label (`displayString`, ⌃⌥⇧⌘ then the key: `⌥⌘N`, `⌃⌥⌘F12`). Stored as `{keyCode, modifiers (Carbon), character}`. |
| `HotKeyShortcutValidation` | Refuses a shortcut without ⌘, ⌥ or ⌃ (a global Shift or plain key would take a key from typing everywhere), a key with no name, one a Detour menu item uses (the main menu searched with its submenus through `MenuKeyEquivalentMatcher.item(matchingCharacters:modifiers:in:)`, the Quick Detour item itself excepted; the message names the path, "File > New Tab"; also, for a key recorded with Shift, an item on its shifted character on the current layout, TASK-335), one of Detour's shortcuts that no menu carries (Control-Tab and Shift-Control-Tab, the recent-tab switcher's event monitor, which a Carbon hotkey would pre-empt), and an enabled macOS shortcut (`CopySymbolicHotKeys`, the Fn bit ignored). |
| `HotKeyRecordingOutcome` | What a key press does in the recorder: Escape alone cancels, Delete or Forward Delete alone clears, anything else is validated and recorded or refused. |
| `HotKeyRegistration` | The state machine: `off`, `noShortcut`, `suspended`, `registered(shortcut)`, `failed(shortcut, error)`. Holds at most one registration; lets go of the old one before registering a new one (a second registration in one process is refused); a refused one keeps the user's choice and holds nothing; `retryIfFailed`; suspended while the recorder records, resuming onto the latest setting. |
| `QuickDetourHotKeySettings` | `QuickDetourHotKeyEnabled` and `QuickDetourHotKeyShortcut` in `UserDefaultsScope.defaults` (the standard domain in the default data directory, `<bundle id>.<data dir>` elsewhere). A cleared shortcut is an empty dictionary, so it is not mistaken for "never set". |
| `QuickDetourHotKey` | Wires them: applies the settings on every change (at once: off unregisters, a new shortcut re-registers), retries a refused shortcut when Detour becomes active and when the Quick Detour settings pane appears, sets the File menu item's key equivalent, and posts `stateDidChangeNotification` for Settings. |
| `CarbonHotKeyRegistrar` | `RegisterEventHotKey` with `kEventHotKeyExclusive` on the application event target, one `kEventHotKeyPressed` handler, the presses checked against its own signature and ids. |

**Why Carbon `RegisterEventHotKey`.** It needs no permission: no
Accessibility, no Input Monitoring, no prompt. The alternatives that see
keys pressed in other apps (a `CGEventTap`, `NSEvent.addGlobalMonitorForEvents`)
need Input Monitoring or Accessibility, and a global monitor cannot consume
the key, so the frontmost app would get it too. The Carbon calls compile
without a deprecation warning against the macOS 26 SDK.

**What it can detect: conflicts**, probed on macOS 26.7 with two scratch
processes registering Ctrl-Opt-Cmd-F12 and a key posted at the HID event
tap:[^harness-2]

| First registrant | Second | Second's status | Who gets the press |
|---|---|---|---|
| plain | plain, another process | `noErr` | **both** |
| plain | plain, same process | `eventHotKeyExistsErr` (-9878) | the first |
| exclusive | plain | `noErr` | the exclusive one only |
| exclusive | exclusive | `eventHotKeyExistsErr` | the first |
| plain | exclusive | `noErr` | the exclusive one only (it takes the key) |

- So Detour registers exclusively: one press never opens a panel in two
  apps (a Debug build and the installed app share the shortcut otherwise),
  and Settings can report a conflict. The report means another app (or
  another Detour) holds the shortcut **exclusively**. An app holding it
  without the option is not seen, and loses the key to Detour.
- Cmd-Tab was refused (-9878: the system holds it exclusively); Cmd-Space
  and Shift-Cmd-3 were accepted although macOS handles them itself, which
  is why the recorder checks `CopySymbolicHotKeys` (Spotlight is Cmd-Space,
  `keyCode 49`, modifiers 256 there).
- While another app holds a shortcut exclusively, the recorder cannot even
  record it: that app's hotkey takes the press first.
- The registration goes with the process: after Detour exited, an
  exclusive registration of the same shortcut from another process
  succeeded.

**Toggle.** The hotkey shows the panel, and pressed while it is up closes
it, as Spotlight's does (decided in TASK-193.2). Escape on the empty field,
or a click outside it, also closes it; the app that was frontmost stays
frontmost and its window is key again; no Detour window comes forward.
Submitting brings forward only the new Quick Detour window
([activation](./quick-detour-launcher.md#activating-with-only-the-new-window-forward)).

**Exactly one panel while Detour is frontmost.** The Carbon hotkey consumes
the key before the menu sees it: with Detour active, one press logged one
"hotkey pressed" and the panel stayed up (had the menu's key equivalent
also fired, its toggle would have closed it). With the hotkey off, the same
keys reach File > New Quick Detour Window, whose key equivalent mirrors the
configured shortcut; turning the hotkey off keeps that shortcut, cleared
removes it.[^harness-2]

**Where it registers.** `QuickDetourHotKeyAvailability.decide(isDebugBuild:isTestHost:environment:)`,
a pure rule, decides whether `start` may register anything in the process:

| Process | Registers |
|---|---|
| XCTest host | never, even with the opt-in |
| Debug build | only with `DETOUR_GLOBAL_HOTKEY=1` (any other value, or none, is no) |
| Release build | yes, as set in Settings |

Why Debug needs the opt-in (code review, 2026-10-25): a Debug build
launched from Xcode has no `DETOUR_DATA_DIR`, so it counts as the default
data directory, starts with the hotkey on, and would register ⌥⌘N
exclusively at launch; the installed app started later would be refused
and retry only when activated. Without the opt-in, Settings says "Debug
builds don't register the global shortcut (DETOUR_GLOBAL_HOTKEY=1 turns it
on)." on the warning line, and the File menu item still follows the
setting. Separately, a data directory other than the default starts with
the hotkey off (`enabledByDefault` is
`WebKitStorageScope.currentIsDefaultDataDirectory`); a harness sets the
opt-in and enables a test shortcut. The settings of each data directory
are their own.

The menu item follows the settings whether or not anything registers: the
settings observer lives as long as `QuickDetourHotKey`, and `start` only
adds the registration. (The first build observed them in `start` only, so
in a Debug run without the opt-in the menu kept ⌥⌘N after the shortcut
changed; found at runtime.)[^harness-2]

# The Settings control

Settings > **Quick Detour** (a pane of its own since TASK-211; before, a section of the Links pane; a grouped form since TASK-338), section Opening: "Open Quick Detour from any app
[switch]" with help saying the launcher opens over the app in front, then
the row "Shortcut [⌃⌥⌘F12]" (one sentence with a checkbox, "[✓] Open Quick
Detour from any app with [⌃⌥⌘F12]", until TASK-328; see
[Settings](./settings-panes.md#quick-detour)) with help saying the same shortcut
is File > New Quick Detour Window while Detour is in front, also when the
switch above is off, and the row's warning line. TASK-193.5 added the rest
([Quick Detour settings](./quick-detour-settings.md)).

- `ShortcutRecorderView`: a click starts recording ("Type Shortcut", accent
  border, the held modifiers shown live) and suspends the registration; the
  next press with ⌘, ⌥ or ⌃ is recorded (Cmd and Ctrl combinations are
  taken in `performKeyEquivalent`, before the menus); Escape cancels,
  Delete clears ("Record Shortcut"); a refused shortcut beeps, shows why on
  the warning line and keeps recording; a mouse-down anywhere outside it (a
  local event monitor installed only while recording: another control,
  empty space, the toolbar, another window), losing focus, the window
  resigning key or the pane disappearing cancels it (so the hotkey never
  stays suspended while the user is elsewhere). A click on the switch
  ends recording and then does the switch's own action (checked with real
  clicks for the switch, TASK-328). The new
  shortcut is saved before recording ends, so the registration resumes
  straight onto it.
- The warning line shows, in order: the recorder's refusal while recording;
  in a process that does not register (a Debug build without the opt-in),
  why; for an enabled hotkey, "Another app is using ⌃⌥⌘F12. Choose another
  shortcut, or change it in that app." (`eventHotKeyExistsErr`), "⌃⌥⌘F12
  could not be set up as a shortcut for every app (error N)." (any other
  status), or "No shortcut: click the field and type one.". The setting
  keeps the user's choice in every case.
- The switch and a recorded shortcut take effect at once.
- The menu search sees the user's own shortcuts (Settings > Shortcuts,
  TASK-327): they are on the live items, so a key one of them holds is
  refused like a built-in one. Settings > Shortcuts lists File > New Quick
  Detour Window read-only with a link to this pane, refuses this shortcut
  for any command ("⌥⌘N is the Quick Detour shortcut (Settings > Quick
  Detour)."), and suspends the hotkey while one of its recorders records
  ([keyboard shortcuts](./keyboard-shortcuts.md)). Both recorders use one
  validator, `HotKeyShortcutValidation`, with `.globalHotKey` rules here.

# Known limits

- **A menu shortcut on a shifted character** is a conflict since TASK-335:
  a recorded ⇧⌘= is refused for View > Zoom In ("+" with ⌘), the shifted
  character read from the current keyboard layout with `UCKeyTranslate`
  ([keyboard shortcuts](./keyboard-shortcuts.md#a-shifted-key-and-its-character),
  which has the measurements and the layout limits).
- **The default ⌥⌘N is a fixed key code** (`kVK_ANSI_N`). On a layout that
  puts another letter there (Dvorak's B), the hotkey is the key in the N
  position while the label and the menu still say N. A recorded shortcut
  takes its label from the layout it was recorded with, and its menu key
  equivalent likewise; the menu item then follows the character, the
  hotkey the key code, which agree only on the layout of the recording.

# Tests

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Quick Detour launcher panel](./quick-detour-launcher.md) — what the hotkey shows, and the activation measured with it.
- [Keyboard shortcuts](./keyboard-shortcuts.md) — the app shortcuts that share the validator and recorder.
- [Global hotkey testing](../playbooks/global-hotkey-testing.md) — posting real keys at the HID event tap.
- [Quick Detour settings](./quick-detour-settings.md) — the rest of the pane.
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.

[^harness-2]: TASK-193.2 runtime harness, its scratch tools and results
