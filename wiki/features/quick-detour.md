---
type: Feature
title: Quick Detour
description: "A small window with one page for a quick lookup, opened from a Spotlight-like palette panel (File > New Quick Detour Window, or a system-wide hotkey, Opt-Cmd-N by default, from any app): the panel, the global hotkey (Carbon, no permission; what conflicts it can and cannot detect; activating with only the new window forward; the Settings control), the tab in no space, history under a per-profile scope labelled on the History page, Private, extensions seeing a popup window, what is not restored, and Open in <Space> (Cmd+O): the default space, the dropdown grouped by profile, the same tab and web view handed to a space of the same profile, a reload in another profile's, Private into a Private window, and the teardown order; and the profile pill (TASK-193.4): its menu, switching reloading the address in a new page on the other profile in the same window (a close and an open for extensions, the new profile's history scope, into and out of Private with the download question), and Open in following; and TASK-193.5's other entry points and archive: Opt-Cmd-click on a link (any frame, in a Peek, a Private page's into Private; never routed) or on a sidebar tab (a copy of its address: normal, sleeping, a split row's clicked pane, pinned, favourite), links from other apps through Air Traffic Control's Quick Detour target (the frontmost window's profile, never Private), the archive (closed-tab rows under the profile's Quick Detour scope, no migration; closed, at quit, and auto-closed; restore reopens a window with the back/forward list; Private never; profile deletion), the idle auto-close (a pure wall-clock rule, what counts as use, a periodic and wake check, a Debug override) and the Settings controls."
tags: [window, tabs, history, privacy, extensions, palette]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-26T19:00:00Z }
stale_after: 2026-12-31T00:00:00Z
sources:
  - id: task-193
    resource: backlog:TASK-193
    title: "Quick Detour: a minimal one-page window opened by a global hotkey"
  - id: task-193-1
    resource: backlog:TASK-193.1
    title: "Quick Detour: the window, its single tab and the palette that opens it"
  - id: rules
    resource: ../../Detour/Browser/QuickDetour/QuickDetour.swift
    title: QuickDetour.swift (history scope, which profile, palette scope)
  - id: store
    resource: ../../Detour/Browser/QuickDetour/TabStore+QuickDetour.swift
    title: TabStore+QuickDetour.swift
  - id: window
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift
  - id: webkit
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController+WebKit.swift
    title: QuickDetourWindowController+WebKit.swift (navigation, UI, WKWebExtensionWindow)
  - id: title-bar
    resource: ../../Detour/Browser/QuickDetour/QuickDetourTitleBar.swift
    title: QuickDetourTitleBar.swift
  - id: launcher
    resource: ../../Detour/Browser/QuickDetour/QuickDetourLauncher.swift
    title: QuickDetourLauncher.swift (the palette panel)
  - id: task-193-2
    resource: backlog:TASK-193.2
    title: "Quick Detour: a system-wide hotkey that opens it from any app"
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
  - id: task-193-3
    resource: backlog:TASK-193.3
    title: "Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)"
  - id: open-in
    resource: ../../Detour/Browser/QuickDetour/QuickDetourOpenIn.swift
    title: QuickDetourOpenIn.swift (the default space, the menu model)
  - id: harness-3
    resource: ../../docs/harness/task193-3-harness.patch
    title: TASK-193.3 runtime harness and its results
  - id: task-193-4
    resource: backlog:TASK-193.4
    title: "Quick Detour: a profile selector in the title bar"
  - id: profile-switch
    resource: ../../Detour/Browser/QuickDetour/QuickDetourProfileSwitch.swift
    title: QuickDetourProfileSwitch.swift (the pill's menu, the switch decision)
  - id: harness-4
    resource: ../../docs/harness/task193-4-harness.patch
    title: TASK-193.4 runtime harness and its results
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
  - id: entry-points
    resource: ../../Detour/Browser/QuickDetour/QuickDetourEntryPoints.swift
    title: QuickDetourEntryPoints.swift (the settings, the Opt-Cmd click, the routed link's profile, the idle rule)
  - id: idle-monitor
    resource: ../../Detour/Browser/QuickDetour/QuickDetourIdleMonitor.swift
    title: QuickDetourIdleMonitor.swift
  - id: harness-5
    resource: ../../docs/harness/task193-5-harness.patch
    title: TASK-193.5 runtime harness and its results
  - id: reference
    resource: ../../docs/little-window/arc-little-arc.png
    title: Arc's Little Arc, the visual reference
  - id: harness
    resource: ../../docs/harness/task193-1-harness.patch
    title: TASK-193.1 runtime harness and its results
  - id: webkit-windows
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIWindowsCocoa.mm
    title: WebKit, WebExtensionContextAPIWindowsCocoa.mm (windowsGetAll reads the context's own window list)
---

# What it does

A Quick Detour is a small window with one web view, for looking something
up without opening a tab in any space (after Arc's Little Arc; the name is
the user's choice, TASK-193). File > New Quick Detour Window, or the
**global hotkey** (Opt-Cmd-N by default, pressed in any app; below), shows
the **launcher panel**: the command palette
alone, centred on the screen, like Spotlight, with no web view and no title
bar. Entering a URL or search, or choosing a suggestion, closes the panel and
opens the Quick Detour window loading that page. Escape on the empty field,
or clicking away (the panel resigning key), closes the panel and opens
nothing. So no Quick Detour window ever has an empty page (the user's change
of 2026-10-25; the first build opened the window showing the palette).
Clicking the host in the window's title bar reopens the palette over the
page, navigating it in place. Several windows can be open at once. Cmd+W,
Cmd+F (Escape closes the find bar), zoom, Back/Forward (Cmd+[ / Cmd+], the
mouse back button), Reload, Copy URL and the Web Inspector work as in a
browser window. Cmd+Z in a page is the page's: the browser undo stack is the
browser windows' (`BrowserWebView.performKeyEquivalent`).

The window is a normal-level window, 900 × 640 points by default (minimum
480 × 320), centred, each later one cascading 22 points down and right of the
last. Its title bar, after the reference image, holds the traffic lights, an
address capsule with the **profile pill**, the page's host in the centre, the
extension buttons (pinned ones, and a puzzle button listing every extension
of the profile) and Copy Link, then **Open in <Space> ⌘O** at the right.
There is no sidebar.

**Open in <Space> ⌘O** moves the page into a tab of a space and closes
the window ([below](#open-in-space), TASK-193.3). The **profile pill** names
the window's profile and switches it ([below](#the-profile-pill),
TASK-193.4). TASK-193.5 added the other ways in — **Opt-Cmd-click** on a
link or a sidebar tab, and **links from other apps** through Air Traffic
Control ([below](#other-entry-points)) — and the **archive**: a closed
Quick Detour goes to the sidebar's Archived Tabs page, labelled "Quick
Detour", and so does every open one at quit and one left unused for the
configured time, "auto-closed" ([below](#the-archive),
[idle auto-close](#idle-auto-close)).

# How it works

## The launcher panel

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
  space it was asked from when that is the same profile's, else the
  profile's Quick Detour scope; search suggestions from its engine.
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
  [activation](#activating-with-only-the-new-window-forward)). A typed URL
  is a typed visit.
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

## The global hotkey

TASK-193.2. A system-wide shortcut, Opt-Cmd-N by default, shows the
launcher from any app (and from Detour), on the screen under the pointer.

| Piece | What it does |
|---|---|
| `HotKeyShortcut` | The shortcut: virtual key code (layout independent, what is registered), modifiers, and the key's character on the layout it was recorded with. Spelled three ways: Carbon modifiers (`carbonModifiers`), the menu's key equivalent (the character, or AppKit's function-key character for F-keys, arrows, Return and the like), and the label (`displayString`, ⌃⌥⇧⌘ then the key: `⌥⌘N`, `⌃⌥⌘F12`). Stored as `{keyCode, modifiers (Carbon), character}`. |
| `HotKeyShortcutValidation` | Refuses a shortcut without ⌘, ⌥ or ⌃ (a global Shift or plain key would take a key from typing everywhere), a key with no name, one a Detour menu item uses (the main menu searched with its submenus through `MenuKeyEquivalentMatcher.item(matchingCharacters:modifiers:in:)`, the Quick Detour item itself excepted; the message names the path, "File > New Tab"), one of Detour's shortcuts that no menu carries (Control-Tab and Shift-Control-Tab, the recent-tab switcher's event monitor, which a Carbon hotkey would pre-empt), and an enabled macOS shortcut (`CopySymbolicHotKeys`, the Fn bit ignored). |
| `HotKeyRecordingOutcome` | What a key press does in the recorder: Escape alone cancels, Delete or Forward Delete alone clears, anything else is validated and recorded or refused. |
| `HotKeyRegistration` | The state machine: `off`, `noShortcut`, `suspended`, `registered(shortcut)`, `failed(shortcut, error)`. Holds at most one registration; lets go of the old one before registering a new one (a second registration in one process is refused); a refused one keeps the user's choice and holds nothing; `retryIfFailed`; suspended while the recorder records, resuming onto the latest setting. |
| `QuickDetourHotKeySettings` | `QuickDetourHotKeyEnabled` and `QuickDetourHotKeyShortcut` in `UserDefaultsScope.defaults` (the standard domain in the default data directory, `<bundle id>.<data dir>` elsewhere). A cleared shortcut is an empty dictionary, so it is not mistaken for "never set". |
| `QuickDetourHotKey` | Wires them: applies the settings on every change (at once: off unregisters, a new shortcut re-registers), retries a refused shortcut when Detour becomes active and when the Links pane appears, sets the File menu item's key equivalent, and posts `stateDidChangeNotification` for Settings. |
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

### Activating with only the new window forward

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

### The Settings control

Settings > Links > **Quick Detour**: "[✓] Open Quick Detour from any app
with [⌃⌥⌘F12]", a warning line under the row, and help text saying the
launcher opens over the app in front and that the same shortcut is File >
New Quick Detour Window while Detour is in front, also when the hotkey is
off. TASK-193.5 added the rest of the section
([below](#the-settings-section)).

- `ShortcutRecorderView`: a click starts recording ("Type Shortcut", accent
  border, the held modifiers shown live) and suspends the registration; the
  next press with ⌘, ⌥ or ⌃ is recorded (Cmd and Ctrl combinations are
  taken in `performKeyEquivalent`, before the menus); Escape cancels,
  Delete clears ("Record Shortcut"); a refused shortcut beeps, shows why on
  the warning line and keeps recording; a mouse-down anywhere outside it (a
  local event monitor installed only while recording: another control,
  empty space, the toolbar, another window), losing focus, the window
  resigning key or the pane disappearing cancels it (so the hotkey never
  stays suspended while the user is elsewhere). A click on the checkbox
  ends recording and then does the checkbox's own action. The new
  shortcut is saved before recording ends, so the registration resumes
  straight onto it.
- The warning line shows, in order: the recorder's refusal while recording;
  in a process that does not register (a Debug build without the opt-in),
  why; for an enabled hotkey, "Another app is using ⌃⌥⌘F12. Choose another
  shortcut, or change it in that app." (`eventHotKeyExistsErr`), "⌃⌥⌘F12
  could not be set up as a shortcut for every app (error N)." (any other
  status), or "No shortcut: click the field and type one.". The setting
  keeps the user's choice in every case.
- The checkbox and a recorded shortcut take effect at once.

### Known limits

- **A menu shortcut on a shifted character is not seen as a conflict.** The
  check compares the recorded key's unshifted character with each item's
  key equivalent, so View > Zoom In ("+" with ⌘, typed as ⇧= on a US
  layout) does not match a recorded ⇧⌘=. AppKit would match the menu by
  the typed character; nothing models layouts here.
- **The default ⌥⌘N is a fixed key code** (`kVK_ANSI_N`). On a layout that
  puts another letter there (Dvorak's B), the hotkey is the key in the N
  position while the label and the menu still say N. A recorded shortcut
  takes its label from the layout it was recorded with, and its menu key
  equivalent likewise; the menu item then follows the character, the
  hotkey the key code, which agree only on the layout of the recording.

## The page is a tab in no space

`TabStore.openQuickDetourTab(profile:)` builds a `BrowserTab` from
`Space.makeWebViewConfiguration(for: profile)` (the profile's data store,
extension controller, content rules) and appends it to
`TabStore.quickDetourTabs`; `closeQuickDetourTab` removes it, drops its
subscriptions and calls `teardown()`. The tab has no `spaceID`; its
`quickDetourProfile` (weak) names the profile for the user agent, a rebuilt
web view and `owningProfile`. The window (`QuickDetourWindowController`)
resolves its page by id through the store, so the store is the one owner.

What "no space" means for each query that walks spaces:

| Query | A Quick Detour tab |
|---|---|
| `TabStore.tab(hosting:)` (internal-page sender check, opener lookup) | found |
| `tab(hosting:in:)`, `Space.displayableTab`, `tab(hostingPeek:)`, `favorite(backedBy:)`, `isPinned` | not found: it is in no space, not a Peek, not a favourite, not pinned |
| `BrowserWindowController.tab(owning:)` | not found; a browser window never delegates for it |
| Session save (`makeSessionSnapshot`) | never saved, so **never restored** at launch |
| `sleepStaleTabs`, `archiveStaleTabs` | never slept or swept: it lives as long as its window, and goes to the archive when that closes ([below](#the-archive)) |
| `allLiveTabs` (the GPU process recycler's media check) | included: its audio or capture holds the recycle back |
| Now-playing bar (`nowPlayingTabs`) | not listed: no browser window can switch to it |
| Palette open-tab suggestions (`gatherTabInfos`) | never offered, and neither the launcher panel nor the window's palette offers any |
| Extension contexts | its own window, of type `popup` (below) |
| History | its profile's Quick Detour scope (below) |

Only the Quick Detour window ever hosts its web view: no other window lists
the tab, so there is no ownership hand-off and no snapshot. The window is the
web view's navigation and UI delegate for its whole life.

## Which profile

`QuickDetour.profileForNewWindow`: the profile of the frontmost window — a
browser window's active space's, which is the Private profile for a Private
window, or a Quick Detour's own (after a switch with its pill, the profile it
switched to) — else the first profile that is neither Private nor deleted.
From another app (the global hotkey) the frontmost window is the last Detour
window used. The user's decision in TASK-193.4 (2026-10-26); rejected: the
last profile used in a Quick Detour, and a fixed profile setting.

The launcher panel has **no pill**: it is a Spotlight-like field, and its
suggestions come from the profile chosen when it opens (above). Another
profile is one click away in the window once the page is open.

## Links and windows inside it

The page navigates in place: there is no space for a background tab, no Peek
and no split. Cmd+click opens the link in another Quick Detour on the same
profile. A window the page opens (`target=_blank`, `window.open`, Open Link in
New Window) becomes another Quick Detour holding the web view WebKit asked
for, so it keeps `window.opener` (a sign-in popup can hand its result back);
`window.close()` closes it. The link menu keeps WebKit's own Open Link and
Open Link in New Window (a browser window replaces them with its tab items).
Internal pages are armed only by typed input, external-app links are asked
about (`BrowserWindowController.handleExternalAppNavigation`, shared), HTTP
sign-in uses the shared `HTTPAuthenticationPrompt`, and an extension package
(`.crx`) is offered for install through the browser window's own path
(`BrowserWindowController.isCRXResponse` and `downloadAndOfferCRX`, shared),
not downloaded.

## History: a per-profile scope that is no space

Decision 1 (user, 2026-10-25): visits are recorded under the window's
profile with no space, labelled "Quick Detour" on the History page,
searchable like any visit, and no space's history is touched.

`historyVisit.spaceID` is `TEXT NOT NULL` and every reader scopes by it, so a
Quick Detour visit is filed under `QuickDetour.historySpaceID(forProfileID:)`,
the profile id XORed with a fixed mask: deterministic, needing no storage,
and never any space's id. `BrowserTab.historySpaceID` (`spaceID ?? that
scope`) is what the recorder, the same-document recorder and the late-title
correction read. `HistoryPageBridge.scope(forProfile:)` adds the scope, so
the History page and `chrome.history.search` include these visits; the
History page marks each with `quickDetour: true`, rendered as a small "Quick
Detour" label. The launch sweep keeps each live profile's scope and sweeps a
deleted profile's with its spaces'. The scopes are a keep-list only: they
never count as proof that the space table is intact, so a session that failed
to restore still stops the sweep (`deleteVisits(notInSpaceIDs:alsoKeeping:)`). Details on
[history recording and search](./history-recording-and-search.md).

**Rejected:** a migration making `spaceID` nullable plus a `profileID`
column. Every query and index is keyed by space id
(`historyVisit_spaceID_visitTime`, `historyTitle`'s unique key and its
triggers); a nullable column would need each of them changed for one kind of
visit, where a sentinel id rides them unchanged. Also rejected in the task:
filing under the profile's first space (it would touch a space's history),
and recording nothing.

The launcher's palette and the window's suggest from the space the Quick
Detour was asked from when that is the same profile's, else from the Quick
Detour scope; they only read there.

## Session restore

Decision 2: open Quick Detour windows are not restored. The session save
holds spaces only, so nothing was needed beyond keeping the tab out of every
space. Quitting archives them instead (TASK-193.5,
[below](#the-archive)): they come back from the Archived Tabs page.

## Private

Decision 3: allowed. A Quick Detour opened while a Private window is
frontmost is on the Private profile: the profile's one non-persistent store,
no history (`recordHistoryVisit` checks `quickDetourProfile.isIncognito`), a
dark window, no Open in button. The Private session's in-memory state (the
Private site settings) is dropped only when **no** Private page is left —
neither a Private space nor a Private Quick Detour
(`TabStore.hasLivePrivateSession`) — so closing the last Private window does
not take settings from a Private Quick Detour still open, and the reverse.
The data store itself is never torn down by either; it lives until quit
([incognito](../architecture/incognito.md)). A Private Quick Detour's
downloads are scoped to its tab id and go when it closes. With one in
flight, closing the window asks first, as a Private window does
(`windowShouldClose` with `PrivateDownloadClosePolicy` and the same alert):
Continue Downloading keeps window and download, Close Window cancels it and
removes the partial file. Quitting with no browser window open — so no
Quit Detour? alert — still cancels them (`applicationShouldTerminate`'s
windowless path), leaving no partial file.

## Extensions

Decision 4: visible. The window is an `ExtensionListedWindow`:

- `windowType` `.popup`, one tab (the page) which is also the active tab,
  `isPrivate` the profile's, listed only to its own profile's contexts
  (`extensionProfileID`).
- The tab is reported open by entering `quickDetourTabs` (the placement rule
  of the [tab and window bridge](../extensions/tab-and-window-bridge.md)),
  so content scripts reach their worker with a `sender.tab` — what a
  password manager's fill needs.
- WebKit lists only windows it was told about (`windowsGetAll` reads the
  context's own window list), so the window sends `didOpenWindow` to its
  profile's loaded contexts before its tab is placed, and `didCloseWindow`
  after the tab is closed; a context that loads later learns of it through
  `openWindowsFor` and `notifyExistingTabs`.[^webkit-windows]
- The title bar's extension buttons go through `ExtensionPopoverController`
  with the window's profile and page, so `action.onClicked` or the popup
  acts on the Quick Detour, not on the last active space.
- `tabs.remove` on the page closes the window; `tabs.update({active})`
  (`activate`) brings it forward.

API output kept its shape (`popup` is an existing window type), so the API
Explorer extension needed no change.

## Open in <Space>

TASK-193.3, the user's decisions of 2026-10-26. The capsule at the right of
the title bar: its main part, **Open in 💼 Work ⌘O**, moves the page to the
space it names; its chevron opens the dropdown. File > Open Quick Detour in
Space (⌘O) does what the main part does while a Quick Detour is key, its
title then naming the target ("Open in 💼 Work"; `validateMenuItem`, put
back to the general title when the window resigns key); with any other
window key nothing answers it and it is disabled.

### Which space the button names

`QuickDetour.openInDefaultSpace` (decision 1): the space of the browser
window in front when the Quick Detour was opened (`sourceSpaceID`, which the
launcher already passed), while it still exists and is the window's
profile's; otherwise **the profile's most recently used space**:

- `TabStore.spaceUseOrder`, most recent first: a normal space is *used* when
  a browser window switches to it (`setActiveSpace`) or a window showing it
  becomes key (`windowDidBecomeKey`), through `noteSpaceUsed`. Private and
  unknown spaces are never recorded. In memory only, seeded at launch with
  the restored last active space (and by `ensureDefaultSpace`); deleted
  spaces are skipped when read, not pruned.
- `QuickDetour.mostRecentlyUsedSpace(ofProfile:)`: the first of that order
  that is a normal space of the profile, else the profile's first space in
  sidebar order.
- A profile with no space at all (possible: the first normal profile is
  used when no browser window is in front) names the most recently used
  space of any profile, which then reloads (the button's tooltip says so).
  No normal space anywhere: the capsule is hidden.

It is computed live (`openInMenu`), refreshed when the spaces change and
when the window becomes key: a deleted source space falls back at once.
A window the page opens and a Cmd+click Quick Detour inherit the source
space, so they name the same space.

### The dropdown

`QuickDetour.openInMenu` (decision 2): every normal space of every live
profile, one section per profile with spaces, **the window's own profile
first** (its spaces keep the page) and the others in profile order, spaces
in sidebar order, each "emoji name". Section headers
(`NSMenuItem.sectionHeader`, the profile's name) only when more than one
profile has spaces. Another profile's spaces carry the subtitle **"Reloads
the page"** and a tooltip naming what changes (that profile's cookies and
sign-ins, no back/forward history): the subtle mark the decision asked for.
The default item shows ⌘O as its key equivalent. Private and deleted
profiles' spaces never appear.

### The same profile: the page moves intact

`QuickDetourWindowController.handOver`, the same idea as
`expandPeekToNewTab` ([Peek](../tabs/peek.md)) but without a second object:
**the Quick Detour's own `BrowserTab` moves**, so its id, its web view, its
back/forward list, scroll position, typed form text, `window.opener`, a load
in flight and its extension registration all survive.

| Step | Who | What |
|---|---|---|
| 1 | Quick Detour | `releasePage`: palette and find bar (matches cleared) closed, popovers closed, link status hidden, its subscriptions on the page dropped, its delegates and script handlers taken off the web view, the web view's container removed from its content view |
| 2 | `AppDelegate.placeTab` | Air Traffic Control's placement (`linkPlacement`): a window showing the space, else the most recent normal window switched to it, else a new window on it |
| 3 | `makeTab` → `TabStore.moveQuickDetourTab(_:into:announcingMove: false)` | out of `quickDetourTabs`, unsubscribed, `quickDetourProfile` cleared, `insertTab` at the new-tab position (no parent: the top of the list), subscribed as a space's tab (saved with the session from now on); observers get `tabStoreDidInsertTab` then `tabStoreDidMoveQuickDetour`, **never** `tabStoreDidCloseQuickDetour` |
| 4 | the browser window | `selectTab`: the container has no superview, so it claims the web view at once (delegates, its own script handlers) rather than showing a snapshot |
| 5 | `didSelect`, inside `holdingExtensionActivation` | `ExtensionTabLifecycle.didMove(tab, fromIndex: 0, in: quickDetour)`, then the window's own `didActivate` |
| 6 | the browser window | `makeKeyAndOrderFront` |
| 7 | Quick Detour | `window.close()` → `tearDown`: `tab` no longer resolves (it is not in `quickDetourTabs`), so it closes nothing in the store and lists no tab; `didCloseWindow` sends only `windows.onRemoved`; it leaves `openControllers` and is released |

The order is the risky part. Step 1 before step 4 is what lets the browser
window claim the web view instead of snapshotting a page still parented in
the Quick Detour. Step 7 last, and keyed on the store, is what keeps the
close from tearing the page down. Checked by a leak test: the controller is
released, the web view is not, and lives in the browser window. Should no
window take the page (a space gone meanwhile), the Quick Detour hosts it
again and stays open.

**Refused** (nothing changes): across the Private boundary either way, into
a space that is no longer in the store, a tab that is not an open Quick
Detour's, a page without a web view (`canMoveQuickDetourTab`).

**Not while a sheet is up.** `open(in:)` does nothing while the window has
an attached sheet, and `validateMenuItem` disables Cmd+O then (found in the
code review). The page's `alert()`/`confirm()`/`prompt()`, a file panel, a
camera or microphone question and HTTP sign-in all run as sheets on the
Quick Detour window, whose completion WebKit (or the page's process) is
waiting on; moving the page from under one, then closing the window, left
the sheet's completion running against a torn-down window — a crash.
Dismiss it first, and Cmd+O works again (tested with a sheet and with a
real page alert, both failing with the guard removed; checked at runtime).
Cmd+O is also disabled when the target is another profile's space and the
page has no URL to reopen. And a link routed to Private never falls back to
the most recent normal space when it could not be placed (`openLink`).

### Another profile: the address reloads there

`reopen`: a new tab of that space on `tab.url` (an internal page the user
had opened is opened as one, never through `addTab(in:url:)`), placed by the
same rule; then the window closes as on Cmd+W, taking its page and web view
down. That profile's data store, so its cookies; the back/forward history is
lost (decision 2; rejected: listing the same profile's spaces only).

### Private

Decision 3: **Open in Private Window ⌘O**, no dropdown (the only
destination; a one-item menu would add nothing). The page moves intact,
as above, into the most recent Private window, else a new one
(`placeInNewPrivateWindow`: a Private window holding only the page, no empty
tab of its own). The same Private store, no reload; the Private session
stays live throughout (`hasLivePrivateSession`).

### History

The visits recorded while it was a Quick Detour stay under the profile's
Quick Detour scope; from the move on `historySpaceID` is the space's
(`spaceID` set, `quickDetourProfile` cleared), so later visits are the
space's. A load in flight when the page moves finishes in the space and its
visit is the space's.

### Extensions

Within one profile it is a **move of the same tab** (WebKit's
`didMoveTab`): `tabs.onDetached` from the popup window (`oldPosition` 0),
`tabs.onAttached` to the browser window with its position, then
`tabs.onActivated` there, then `windows.onRemoved` for the popup. No
`tabs.onRemoved`, no second `tabs.onCreated`; `tabs.get(id)` now names the
browser window. The move is announced once the receiving window has the tab
selected: WebKit lists a window's tabs only while one is selected, and
announced earlier the attach arrived with `newPosition: null`
(see [tab and window bridge](../extensions/tab-and-window-bridge.md)).
Another profile's extensions hear nothing. Across profiles it is a close
and a create: `tabs.onRemoved` and `windows.onRemoved` for the Quick
Detour's profile, `tabs.onCreated` for the other's.

### Edge cases decided

| Case | Decision |
|---|---|
| The source space was deleted | the button falls back at once (the profile's most recent) |
| The page is mid-load | moved as it is; the load finishes in the space, its visit the space's |
| Find bar or palette open | closed by `releasePage`; the find matches cleared |
| A Peek | a Quick Detour has none; one over the receiving window's selected tab is put away as on any tab switch |
| A download in flight | normal: `.normal`, listed in every normal window already, untouched. Private: **its scope moves with the page** (`DownloadManager.moveIncognitoDownloads`, from `tabStoreDidMoveQuickDetour`): listed in the receiving Private window and cancelled, after asking, when that window closes, as the Private download rules do for a window's own |
| The profile was deleted | its Quick Detours close with it (unchanged); a target space of a deleted profile is never listed |
| A page-opened Quick Detour (`window.opener`) | the same web view moves, so the opener relationship is kept both ways; a reload in another profile loses it |

## The profile pill

TASK-193.4. The pill at the left of the address capsule shows the window's
profile: a person symbol (eyeglasses for Private) and the profile's name —
profiles have no icon, emoji or colour of their own — with a small
up-and-down chevron saying it is a menu. It follows a rename
(`TabStore.updateProfile`'s notification). Pressed, it opens its menu at
once, as a pop-up button does (`QuickDetourProfilePill`: the menu tracks the
rest of the click, and the pill never drags the window as the title bar
around it does; accessibility role pop-up button). It shows itself pressed
(a stronger fill) while its menu is open, reported to the title bar through
`onHighlightChange`.

### The menu

`QuickDetour.profileMenu`: every live normal profile in the store's order,
then **Private last, after a separator**; deleted profiles left out; the
window's own profile checked. With only one profile it lists that one and
Private. Each other profile's item has a tooltip saying what a switch does:
"Reload this page in Work: its cookies and sign-ins, without this page's
back and forward history" — the subtle mark of the reload (decided: a
tooltip only; a subtitle on every item, as Open in's "Reloads the page",
would mark every row the same).

### Switching: a new page in the same window

`QuickDetourWindowController.switchProfile(to:)` reloads the page's address
on the chosen profile in a **new web view**, in the **same window**.

**Why a new `BrowserTab` rather than swapping the web view inside the old
one.** A web view's data store is fixed when it is made, so another profile
always means another web view. Replacing the whole tab
(`TabStore.replaceQuickDetourTab`) makes every consequence the one a close and
a new Quick Detour already have: the old tab's `teardown` reports its close
to its own profile's extensions, its history scope and Private-session
membership go with it, and the new tab is built and subscribed exactly as
`openQuickDetourTab` builds one. Swapping the web view inside one tab would
have kept a tab id across two profiles' extension contexts (WebKit maps a
tab to a web view and a context; `didCreateWebView` re-announces within one
profile only), and left `quickDetourProfile`, the history subscription and
the Private bookkeeping to be changed in place. **Why the same window, not a
new one:** the window keeps its frame, its place among the windows, its
full-screen or zoomed state and its source space; only the page changes.

| Step | Who | What |
|---|---|---|
| 1 | Quick Detour | refused while a sheet is up, for the same profile or a deleted one; leaving Private with Private downloads running asks first (below) |
| 2 | Quick Detour | `releasePage`: palette, find bar, popovers and link status closed, its subscriptions and delegates on the old web view dropped, the container out of the content view |
| 3 | `replaceQuickDetourTab` | the old tab out of `quickDetourTabs`, unsubscribed and torn down: `tabs.onRemoved` for the old profile's contexts |
| 4 | the hook, between the pages | `didCloseWindow` to the old profile's contexts (`windows.onRemoved`; the window lists no tab now), the window takes the new profile, a new tab id and the palette's history scope for it, `didOpenWindow` to the new profile's contexts (`windows.onCreated`, a `popup`) |
| 5 | `replaceQuickDetourTab` | a new tab on the new profile's configuration enters `quickDetourTabs` (`tabs.onCreated` in that popup); the Private session ends if the old page was its last user; observers hear `tabStoreDidReplaceQuickDetour`, **never** `tabStoreDidCloseQuickDetour` (which would close the window) |
| 6 | Quick Detour | the pill, the window's appearance (dark for Private), Open in and the extension buttons follow the profile; the new web view is hosted and loads the address (`loadRecordedURL`) |

**The address** is the old tab's `url`: the page's own, also while a load is
in flight (the URL being loaded) or an error page is showing (the URL that
failed). An internal page the user had opened (the History page) is reopened
as one, now on the new profile. The load is not a typed visit.

**What is lost**, decided and acceptable for a quick lookup: the
back/forward history, text typed into a form, the scroll position, the zoom
level, and `window.opener` both ways (a page-opened Quick Detour's opener
stays on the old profile's page, which is gone). A Quick Detour the page had
opened keeps its own profile.

### Consequences

| | Old profile | New profile |
|---|---|---|
| Extensions | `tabs.onRemoved` for the page, then `windows.onRemoved` for the popup; both refused by id afterwards | `windows.onCreated` (`popup`, `incognito` for Private), then `tabs.onCreated` in it; listed by `windows.getAll`; the active tab announced |
| History | the visits so far stay under its Quick Detour scope | from the switch on, its Quick Detour scope; **nothing** for Private |
| Open in | — | follows at once: the button and the dropdown are the new profile's (the source space no longer matches unless it is the same profile's, so the button names the new profile's most recently used space; switching back names the source space again); Private: Open in Private Window, no dropdown |
| Palette | — | suggests from the new profile's Quick Detour scope (the source space only when it is the new profile's) |

A third profile's extensions hear nothing. Switching back is a new popup
window for the first profile's contexts, not the one they were told closed
(WebKit forgets a closed window, `forgetWindow`, so the same controller
reported open again gets a new window id).

### Private

- **Into Private** it is a Private Quick Detour from then on: the profile's
  non-persistent store, no history, a dark window, Private downloads scoped
  to the new tab's id, and a user of the Private session
  (`hasLivePrivateSession`), with the Private site settings' lifetime.
- **Out of Private**, with Private downloads still running in the window,
  the switch asks first, as closing it would (`QuickDetour.profileSwitchDecision`):
  "Switch to Work?" / "1 download is in progress. Leaving Private browsing
  cancels it." with **Switch Profile** (cancels them, removing the partial
  files, and switches) and **Continue Downloading** (Escape: nothing
  changes). Decided over moving them to the new page: a Private download
  must not be listed, or keep running, under a normal profile. Ended Private
  downloads go with the old page, unasked. The Private session then ends if
  this was its last page.

### Edge cases decided

| Case | Decision |
|---|---|
| The same profile chosen | nothing |
| The page is mid-load | the address being loaded reloads on the new profile |
| A form with typed text | lost with the old page |
| A sheet is up (alert, file panel, permission or sign-in prompt) | refused, and the pill opens no menu: its completion would outlive its web view |
| The profile is deleted while its Quick Detour is open | the window closes, as before; after a switch that is the profile switched to (`closeQuickDetourTabs(of:)` matches the new tab) |
| The chosen profile is deleted, or a sheet is put up, while the question is up | nothing switches and the downloads keep running: they are cancelled only once the switch is certain (found in the code review) |
| Only one profile | the menu shows it and Private |

## Other entry points

TASK-193.5, the user's decisions of 2026-10-26.

### Opt-Cmd-click on a link

Opt-Cmd-click on a link in a browser window's page opens it in a **new
Quick Detour on the page's profile** (`tab(owning:)?.owningProfile`, else
the window's space's): a Private page's in a Private Quick Detour. Any
frame (an iframe's link too), a `target=_blank` link too (the policy sees it
first), and inside a Peek (the Peek's page is the window's space's
profile). Its Open in names the window's space. It is a branch of the
navigation policy before Cmd's, since Opt-Cmd contains Cmd:

| Modifiers | Before 193.5 | Now |
|---|---|---|
| Opt-Cmd | Cmd: a background tab (or where a route sends it) | **Quick Detour**, never routed |
| Opt-Cmd-Shift | Cmd | Quick Detour (Shift does not matter once Cmd and Option are held) |
| Opt-Cmd, setting off, or to a non-web URL (`mailto:`) | Cmd | Cmd, as before |
| Cmd, Cmd-Shift | background tab / route | unchanged |
| Shift, Shift-Option | Peek | unchanged |
| Option | split | unchanged |

`inPageLinkClickBranch(_:target:quickDetourClickEnabled:)` is that table,
pure; the policy and the routing rule (`linkRoutingEligibility`, which now
answers `.notRouted(.quickDetourClick)`) both read it, so Air Traffic
Control never moves an Opt-Cmd-click: the user chose where it opens.
Synthetic clicks carry no modifiers, so a page cannot fake one (as for
Cmd+click). **Inside a Quick Detour** Cmd+click already opened another
Quick Detour on the same profile; Opt-Cmd is a Cmd+click there, so it does
the same. **Not added**: a link-menu item ("Open Link in Quick Detour"), and
Opt-Cmd on a script's `window.open` (not a link; WebKit's policy never sees
it).

### Opt-Cmd-click on a sidebar tab: a copy

Opt-Cmd-click on a tab in the sidebar opens **a copy**: the tab's address in
a new Quick Detour on the sidebar's profile (the active space's; the
Private profile in a Private window). The tab is not selected, moved, woken
or changed (decision 2). `DraggableTableView.mouseDown` takes the click
before the table's own handling (`onQuickDetourClick`, row and point), so
the selection never moves; the sidebar resolves the row
(`TabSidebarViewController.quickDetourCopyURL(forRow:at:)`):

| Row | Address copied |
|---|---|
| A normal tab, live | where it is now (`tab.url`) |
| A sleeping tab | its stored address (a sleeping tab's `url`), without waking it |
| A split row | the pane clicked: the left or right half of the row (`QuickDetour.splitRowPane`) |
| A pinned entry | its tab's address while live, else the saved `pinnedURL` |
| A pinned split | the pane clicked, as above |
| A favourite tile (`FavoriteTileView.mouseDown`) | its tab's address while live, else the favourite's URL; a dormant tile stays dormant |
| A folder, New Tab, the separator | nothing: the click does what it always did |

An internal page (the History page) opens as one (armed, as typed). The
rule is `QuickDetour.sidebarCopyURL(liveURL:storedURL:)`; with the setting
off the click is the table's (and the tile's) own.

### Links from other apps: Air Traffic Control's Quick Detour target

No switch of its own (decision 1): **Quick Detour** is a visible Open in
target in Settings > Links, for routes and the Default
([link routing](./link-routing.md#links-from-other-apps)). The resolver
keeps it to links from other apps: a typed URL or a clicked link whose
route or Default names Quick Detour stays where it is (unchanged since
TASK-191.1). `linkPlacement` answers `.openInQuickDetour` whatever windows
are open, and `AppDelegate.openLink` opens a new Quick Detour with the link
instead of a tab (the Most Recent Space fallback TASK-191.2 left for it is
gone). "Links from Slack open in Quick Detour" is an app-only route (Any
URL, From app Slack, Open in Quick Detour).

**Which profile** (decided here): `QuickDetour.profileForRoutedLink` — the
profile of the frontmost Detour window (a browser window's active space's,
a Quick Detour's own; front to back, then windows not in the window list),
as the launcher's rule (TASK-193.4) — **but never Private**: a Private
window in front is passed over for the next window's profile, else the
first normal profile. A link from another app enters Private only through
a Private Window target (or Quarantine, TASK-194, whose whole point is a
Private Quick Detour); a Quick Detour route that sometimes opened Private
would overlap it by accident of which window was in front. Its Open in
names the most recent normal window's space when it is the same profile's.
The window is ordered front of Detour's windows, as a placed tab's window
is; Detour is not activated by the placement itself (the sender's
`NSWorkspace.open` does that).

## The archive

Decisions 3 and 4 of 2026-10-26: a Quick Detour closed by hand, at quit or
by the idle timer goes to the sidebar's Archived Tabs page (all spaces),
labelled; restoring one reopens a Quick Detour window on that profile.

### Storage: a closed-tab row under the profile's Quick Detour scope

A closed Quick Detour is a `closedTab` row like a closed tab's
([closed tabs and the archive](../tabs/closed-tabs-and-archive.md)), with
`spaceID` = the profile's Quick Detour scope
(`QuickDetour.historySpaceID(forProfileID:)`, the id its visits are filed
under). **No migration.** Every existing query is keyed by a space id and
no space has that id, so each stays correct unchanged: Reopen Closed Tab
(the active space's records) never offers one, a space's deletion and its
undo never touch them, the session save (no foreign key on `closedTab`)
keeps them. Only the archive page's listing, its "has records" check and
Clear needed to know the scopes. `archivedAt` marks the idle timer's
close, as it marks the archive sweep's for a tab; a close by hand or at
quit is a plain close (`archivedAt` nil). `tabID`, `url`, `title`,
`faviconURL`, `interactionState` (the back/forward list) and `extensionID`
are captured as for a tab; `sortOrder` is 0. Rejected: a `kind` or
`profileID` column (a migration, and every closed-tab query would have had
to learn to skip the new rows); filing under a space of the profile (it
would be reopened by Cmd+Shift+T there and deleted with that space).

| When | Record |
|---|---|
| Closed by hand (Cmd+W, the close button), or by an extension's `tabs.remove` | a plain close: "Quick Detour" |
| Auto-closed by the idle timer | `archivedAt` set: "Quick Detour · auto-closed" |
| Quitting (`applicationWillTerminate` → `TabStore.archiveOpenQuickDetours`) | a plain close for every open one; their windows stay until the app exits, and `quickDetourTabIDsArchivedAtQuit` keeps a later close from writing a second |
| Moved by Open in (same profile: handed over; another profile: reloaded there) | nothing: the page lives on in the space |
| Replaced by the profile pill | nothing: a switch, not a close |
| Its profile deleted | nothing, and its archived ones are deleted with the profile (`deleteProfile`) |
| A Private Quick Detour | never, whatever closes it, as Private tabs never write a record |
| A page with no address | nothing |

`TabStore.closeQuickDetourTab(_:disposition:)` takes
`QuickDetourCloseDisposition` (`.archive(autoClosed:)`, the default, or
`.discard`), and writes the record before the teardown releases the web
view the back/forward list is read from. The window passes its
`closeDisposition` from `tearDown`.

### The archive page

`archiveEntries()` lists, beside the spaces' records, those under the Quick
Detour scope of a live normal profile, as `ArchiveEntry.kind =
.quickDetour(profileID:autoClosed:)` (a scope of a profile no longer there
is not listed). The row's second line is `archiveEntrySubtitle`: "Quick
Detour · example.com/page", or "Quick Detour · auto-closed · …". No space
badge. A space filter hides them (they are no space's); with no filter
Clear Archive… and Navigate > Clear Archived Tabs… cover them
(`archiveClearScope`, `TabStore.quickDetourArchiveScopeIDs`). Retention is
the archive's: none — they stay until deleted or cleared.

### Restoring

A click (Return, the context menu) on a Quick Detour entry calls
`BrowserWindowController.restoreArchivedTab`, which sees
`isQuickDetourArchiveRecord` and calls `QuickDetourWindowController.restore(recordID:sourceSpace:)`:
`TabStore.takeQuickDetourArchiveRecord` consumes the record and returns
its page (`QuickDetourArchivedPage`), and a new window opens on that
profile, its tab built by `openQuickDetourTab(profile:restoring:)` —
`BrowserTab.restoreArchivedPage`, the closed-tab rebuild factored out:
the back/forward list (else the address), the archived title (until the
page reports its own) and favicon. Its Open in names the restoring
window's space when it is the same profile's. The sidebar leaves the
archive page. An extension's page comes back on its live origin without
its back/forward list; a disabled extension's is not restorable (listed
dimmed); an uninstalled one's record is purged — the closed-tab rules.

## Idle auto-close

A Quick Detour not used for the configured time closes into the archive as
auto-closed. Settings > Links > Quick Detour: Never, 1 hour, **6 hours**
(the default, as Arc's), 12 hours, 1 day.

**The rule** is pure, `QuickDetour.shouldAutoClose(_:now:interval:)` over
`QuickDetourIdleState`: it closes once `now - lastUsedAt >= interval`, on
the wall clock, and **never** while the window is frontmost (the key
window, or the front one of Detour's browser and Quick Detour windows,
visible and not minimized — Detour may be in the background with it on
screen), while its page plays sound (`BrowserTab.isAudible`: playing and
not muted), while a sheet is up (a page's dialog or a file panel, whose
completion would outlive the window), or when it is **Private** (decided
here: nothing would be archived, so the timer would simply lose it). A
clock set back never closes one.

**What counts as use** (`QuickDetourWindowController.noteUse`): opening or
restoring the window; becoming key, and ceasing to be key (key until then);
a key press, a mouse-down (any button), a scroll, a magnify or swipe in it
(`QuickDetourWindow.sendEvent` — a scroll reaches a window that is not
key, so reading one beside another app counts); and its page starting or
stopping sound. **Navigation alone does not**: a page can reload or
navigate itself, and one the user starts follows input in the window.

**Timing** (`QuickDetourIdleMonitor`): a repeating check every 60 s (10 %
tolerance, `.common` mode) and one on `NSWorkspace.didWakeNotification`,
each asking the rule about every open window, rather than one long timer
per window: a timer does not fire while the Mac sleeps, and the rule is on
the wall clock, so **time asleep counts as time unused** — a Mac asleep
overnight closes the Quick Detours left behind on wake (except the
frontmost). Not started in the XCTest host, whose tests drive `check()` on
an injected clock (`now`) and settings. **Debug override**:
`DETOUR_QUICK_DETOUR_IDLE_SECONDS=<n>` replaces the interval of any setting
but Never and checks every n/4 seconds (at least 1, at most 60); read in
Debug builds only.

## The Settings section

Settings > Links > Quick Detour, after the hotkey row and its help:

- **[✓] Open links and sidebar tabs in Quick Detour with ⌥⌘-click**
  (`QuickDetourOptionCommandClickEnabled`, on by default), with "A sidebar
  tab opens as a copy; the tab stays where it is." Off, Opt-Cmd is a
  Cmd+click again, on links and in the sidebar.
- **Close Quick Detour windows not used for [6 hours ▾]**
  (`QuickDetourIdleTimeout`, the raw value; anything unreadable is 6
  hours), with "They go to the archive, marked auto-closed, and reopen from
  there. The window in front, one playing sound and Private ones stay
  open."
- A caption: "To open links from other apps in Quick Detour, choose Quick
  Detour as a route's Open in, or as the Default, above." — no switch.

`QuickDetourSettings` keeps them in `UserDefaultsScope.defaults` beside the
hotkey's and posts `didChangeNotification`; both take effect at the next
click or check.

## Teardown

Closing the window (Cmd+W, the close button, an extension's `tabs.remove`,
the profile deleted, Open in, the idle timer) runs `tearDown()` once — a
profile switch closes the old page but never the window:
palette and popovers closed, subscriptions and the weakly held script
handlers removed, delegates cleared, `closeQuickDetourTab` (out of the list,
web view released, extension registration closed, Private session checked,
observers told; archived first unless `closeDisposition` says otherwise),
`didCloseWindow` to the contexts, and the controller
leaves `openControllers`, which was all that held it. `deleteProfile`
closes the profile's Quick Detours before it releases the profile.

# Edge cases

- Dismissing the window's palette (Escape, a click outside it) returns focus
  to the page; it never closes the window.
- **Clicking the title bar while the window's palette is up** does not
  dismiss it: the palette covers the content area only, so the window can
  still be dragged.
- A Quick Detour of a profile that is deleted closes with it.
- The window has no downloads button; a download shows a toast and is listed
  in a browser window's downloads (normal profile) or nowhere once the
  Private Quick Detour closes.

# Tests

| Suite | Covers |
|---|---|
| `QuickDetourTests` (28) | the rules (history scope, which profile, palette scope); the tab in no space: creation from the profile's store and controller, adoption, close and its idempotence, observers, several at once, every space-walking lookup, never slept/archived/saved, profile deletion; history: recorded under the scope (real load), Private records nothing, the profile scope, the launch sweep, the page payload, `spaceID` on listed and searched rows; the Private session both ways; Private downloads |
| `QuickDetourLauncherTests` (11) | the panel (non-activating, borderless, floating, can become key, the palette's profile, history scope and no tabs), no window or tab before submit; submit (URL, search, suggestion) closing it and opening the window; Escape and clicking away opening nothing; one panel; the centring rule; the real window opening on its page |
| `QuickDetourWindowTests` (15) | opening on its page with no palette, loading in the one web view, the host palette (profile, no tabs, history scope), dismissing it keeping the window, a search from it, navigating in place, back/forward/zoom/find, Cmd+Z not undoing a browser action, Copy Link, Cmd+W, two windows, closing from the store, a page-opened window, the extension window lookups, no leaks |
| `HotKeyShortcutTests` (27) | the shortcut (default, narrowing, equality), Carbon modifier bits both ways for all 16 combinations, state bits ignored, key equivalents (letters, F-keys, arrows, Space, Return, Forward Delete, a layout's character), the label and key names, the defaults round trip and malformed values; validation (a modifier needed, an unnamed key, Detour's menu items by path including submenus, function-key items and an uppercase key equivalent meaning Shift, the Quick Detour item excepted, Control-Tab, macOS shortcuts with and without the Fn bit, the real main menu), the messages; recording (Escape, Delete, with a modifier, refused) |
| `HotKeyRegistrationTests` (20) | the state machine against a fake registrar: off, on, idempotent, off unregisters, a change unregisters first, cleared, refused keeps the choice and holds nothing, changing away from a refusal, retry, suspend and resume, `isConflict`; the settings (defaults per data directory, persistence and notification, cleared stays cleared, malformed) |
| `QuickDetourHotKeyTests` (22) | the wiring with a fake registrar: never started in the test host, the press callback handed to the registrar, settings followed at once, the menu item mirroring the shortcut also when off and cleared, recording, a refusal reported and retried (also on becoming active), the messages; the hotkey toggling the launcher, the menu item not toggling it, the real File item attached; the recorder (records, a Cmd key taken before the menus, refused and still recording, Escape, Delete, stops when its window resigns key, saves before it stops); where it may register (the test host never, Debug only with the opt-in, Release yes, the Settings line); the menu item following the setting where nothing registers; a mouse-down outside the recorder ending it (the pure rule, and a real event through `nextEvent`/`sendEvent` reaching the monitor) |
| `UserDefaultsScopeTests` | the preferences suite per data directory |
| `QuickDetourExtensionTests` (11) | real contexts: a `popup` window from an extension page and the worker (promise and callback forms), another profile seeing nothing (also for a context loaded after the window opened), no URL without `tabs`, a content script's `sender.tab`, the toolbar button's `onClicked`, by-id lookups refused after close, a Private Quick Detour as an incognito popup |
| `InternalPageIntegrationTests` | the History page's "Quick Detour" label |
| `QuickDetourOpenInTests` (30) | Open in's rules: the most recently used space (use order, other profiles, deleted and Private spaces skipped, the first space with none used), the default target (the source space, another profile's or deleted source falling back, Private never, a profile with no space), the menu (grouped by profile with the window's first, sidebar order, reload marks, the default item, headers only for several profiles, Private and deleted profiles left out, no target at all), Private (Private Window, no dropdown); `noteSpaceUsed`; the store's move (the same tab and web view at the new-tab position, observers told of a move not a close, saved with the session, refused for another profile, the Private boundary, a non-Quick-Detour tab and a gone space; Private into a Private space), the extension seam (one move from the popup window, no close; none when the caller announces), the history scope switching at the move (real loads), a Private download moving with the page and a normal one untouched |
| `QuickDetourOpenInWindowTests` (17) | in real windows: a sheet and a page `alert()` blocking Cmd+O until they end, the button naming the source space and following a deletion, the File menu's ⌘O item, Cmd+O and the button moving the page into the window showing the space (front, selected, same web view hosted with the window's delegates, back list and typed form text kept), the most recent window switching, the dropdown, the palette and find bar closed, the controller released while the web view lives on, another profile's space reloading (its store, the Quick Detour and its web view released), the dropdown's headers, subtitles and ⌘O item, Private into the most recent Private window and into a new one holding only the page, both boundaries refused, a space switch noting its use |
| `QuickDetourProfileSwitchTests` (23) | the pill's rules: the menu (normal profiles in order, Private last after a separator, the window's own checked, one profile plus Private, deleted left out, no separator without Private), the decision (same profile and a gone or deleted one stay; another or Private switches at once; leaving Private asks with one or more downloads running, never otherwise; a normal page never asks); the store's replacement (a new tab on the other profile's store with the given id, the old torn down, the hook between the pages with neither listed, observers told of a replacement not a close, refusals, deleting the new profile closing it), Private (into it: its store, the session live, its download scope; out of it: the session ending, or kept for a Private window; its downloads dropped), history (visits after the switch under the new profile's scope, real loads; Private records nothing) |
| `QuickDetourProfileSwitchWindowTests` (17) | in real windows: the pill names the profile; the menu (order, Private last after a separator, the checkmark) and its item switching; the address reloading under the other profile's cookies (a loopback page titled by a cookie the other profile set; the same window, a new tab and web view hosted with the window's delegates, no back history, the old web view released) and back; the same profile a no-op; a sheet refusing; a page mid-load reloading its address; the History page reopened as an internal page; palette and find bar closed; Open in following the profile both ways; into Private (store, dark, Open in Private Window, scope) and out (appearance, scope, Open in); the download question (no keeps everything, yes cancels and drops it; a target deleted, or a sheet put up, while it is asked refuses the switch and keeps the download); the window closing cleanly after a switch |
| `QuickDetourExtensionTests` (+4) | the pill in real contexts: a close for the old profile (`tabs.onRemoved`, `windows.onRemoved`, both refused by id, promise and callback) and an open for the new (`windows.onCreated` popup, `tabs.onCreated` in it, `windows.getAll` from the page, `tabs.get` from the worker); switching back a new window and tab id; a third profile hearing nothing; into Private an incognito popup |
| `QuickDetourExtensionTests` (+3) | Open in in real contexts: the same tab id detached from the popup and attached to the browser window (with its position), no remove and no second create, `tabs.get`/`windows.get` from the page and the worker, the popup refused by id (promise and callback); another profile hearing nothing; a reload in another profile removing the tab here and creating one there |
| `QuickDetourEntryPointsTests` (21) | TASK-193.5's pure rules: the settings (defaults, persistence and notification, an unreadable timeout), the timeouts and titles, the Opt-Cmd click, a split row's pane, a sidebar tab's copy, the routed link's profile (the front window's, never Private, none open, deleted), the idle rule (the interval, Never, frontmost, sound, Private, a sheet, time asleep, a clock set back), the Debug override and the check interval, the archive label |
| `QuickDetourArchiveTests` (17) | the store: a close archived under the scope (plain or auto-closed), Private never, no address, discard, the back/forward list captured; quit archiving each normal one once; the listing (labelled kinds, alone, a gone profile's not listed), Reopen Closed Tab never taking one, surviving a session save; taking a record (consumed, a space's refused), a restored tab (profile, address, title, store); Clear covering the scopes; profile deletion deleting only its own |
| `QuickDetourArchiveWindowTests` (11) | in real windows: Cmd+W archiving, Private not, a profile switch not; a restore reopening on the profile and only once, a space's record refused; the monitor on an injected clock: the unused one closing as auto-closed while the frontmost stays, Never, the setting read at each check, a key press and key changes counting as use, a sheet, Private |
| `QuickDetourSidebarCopyTests` (6) | Opt-Cmd mouse-downs handed to the sidebar's table: a normal tab copied and left unselected, a sleeping tab's stored address without waking it, each pane of a split row, a pinned entry, a dormant favourite (not woken) |
| `ExternalLinkRoutingTests` (+4), `LinkRoutingEligibilityTests` (+5), `LinkPlacementTests`, `LinkRouteEditorTests`, `ArchiveListLayoutTests` (+3), `QuickDetourOpenInWindowTests` (2 assertions) | a Quick Detour route, a from-app route and the Default opening a Quick Detour on the front window's profile (never Private); the Opt-Cmd branch and its exclusion from routing; `.openInQuickDetour`; the target offered; the subtitle and the clear scope; Open in (both kinds) archiving nothing |

`QuickDetourTests` was written first: 26 of 28 failed against stubs, two
(the negative cases) passed. For TASK-193.2, `HotKeyShortcutTests` (23 of
26 failed against stubs), `HotKeyRegistrationTests` (17 of 20) and the two
new `UserDefaultsScopeTests` (2 of 2) were written first; the three that
passed against stubs were negative cases. `QuickDetourHotKeyTests` came
after the code, except the review follow-up's: 6 of its 7 availability and
click-elsewhere tests failed against stubs (the Release case passed), the
menu-mirror test failed before its fix, and disabling the monitor failed
the event-loop test. `QuickDetourLauncherTests` too: 10 of 11
failed against a stub launcher. The window and extension suites came after
the code; mutation checks (window type `.normal`, `openWindowsFor`
unfiltered, no `didOpenWindow`) each failed them. For TASK-193.3 the three
Open in suites were written first, against stubs returning nothing: 23 of
`QuickDetourOpenInTests`' 29 failed (one by indexing an empty list, which
crashed the host; that test no longer subscripts), 14 of
`QuickDetourOpenInWindowTests`' 15 and 2 of the 3 extension tests; the ones
that passed were the refusals and the negative cases. For TASK-193.4 the two
profile-switch suites and the four extension tests were written first,
against stubs returning nothing (an empty menu, `.stay`, a store replacement
returning nil, a switch doing nothing): 36 of the 42 failed (20 of 23, 12 of
15, 4 of 4); the six that passed were the refusals, the no-op and the pill's
name, which 193.1 already showed. The first green run left two: a store test
reading a web view's release synchronously (dropped: the window test checks
it after the run loop turns) and a mid-load test switching before the first
request had reached the server. The first green run
of the extension test then caught `newPosition: null` (the move announced
before the receiving window had a selection), fixed by announcing it after
selecting (`holdingExtensionActivation`); the deferred-announcement store
test came with that fix. For TASK-193.5, 68 new or changed tests were
written first against stubs returning empty values (no rule, an empty
store, `.none` branches): 44 failed (15 of 21 entry-point rules, 12 of 17
store archive tests, 5 of 11 window tests, 4 of 4 external-link tests, 3 of
4 editor, 2 of 6 eligibility, 2 of 3 layout, 1 of 2 placement); the 24 that
passed were negative cases (Never, Private, a sheet, a clock set back, a
space's record, discard). The first green run left two: a restored tab
showing its address as its title (the load's placeholder; the archived
title is now set after it) and a sheet test whose other window lost
frontmost to the sheet (the test, not the rule). The Open in tests' new
assertion then failed for the cross-profile reload (archived as a close)
until `reopen` discards. `QuickDetourSidebarCopyTests` came after the code
(UI hand-off; the rule under it is pure and tested first).

# Runtime check

In the Debug build with an isolated data directory, a loopback fixture
server and real posted input, 2026-10-25, light and dark
([harness](../../docs/harness/task193-1-harness.patch), which lists every
step and result):[^harness]

- Opt-Cmd-N and the menu item showed the panel, key with the field first
  responder, and no window until Return; Return closed the panel and the
  window opened on the page; Escape on the empty panel, and a click on the
  browser window behind it, closed it with nothing opened.
- The host click, navigating in place, back and forward, reload, zoom, find,
  two windows, Cmd+W tearing one down.
- An installed test extension saw both Quick Detours as `popup` windows
  with their tabs, its content script reached the worker from the page, and
  the pinned button's `onClicked` got the Quick Detour's tab.
- The visits were all under the Quick Detour scope and the History page
  labelled them; a Private Quick Detour (opened from a Private window)
  recorded none and kept the Private session through its window's close.
- After a relaunch nothing was restored, and the launch sweep kept every
  Quick Detour visit.
- Second pass, after the code review: the panel dark over a dark window and
  over a white one with its tint (mid grey over the white one without);
  a Private Quick Detour's download in flight asked on Cmd+W, kept
  everything on Continue Downloading, and was cancelled with no partial
  file on Close Window; quitting with only that window open cancelled it
  with no partial file; a `.crx` link was offered for install (the unsigned
  fixture was refused by the gate); deleting a profile the launcher had
  been opened on released the profile, with no "still retained" logged.

TASK-193.2, 2026-10-25, macOS 26.7, real input posted at the HID event tap
from scratch tools (the hotkey, typing, clicks), a scratch app frontmost, the
test shortcut Ctrl-Opt-Cmd-F12 ([harness](../../docs/harness/task193-2-harness.patch),
with the tools' sources):[^harness-2] the panel over the other app, key, taking
typing; Return activating Detour with only the Quick Detour window forward;
Escape and a click away leaving the other app frontmost and key; the toggle;
one panel with Detour frontmost; the menu key equivalent with the hotkey
off; Settings off, on, a new shortcut (the old one then did nothing), a
refused Cmd-T, a conflict with an exclusive holder reported and retried
after it exited, cleared; the registration gone after exit. Review
follow-up (run3.sh): a Debug run without the opt-in registered nothing and
said so in Settings, with the menu item on the set shortcut; with the
opt-in, posted clicks on the checkbox, on empty pane space and on the
General toolbar item each ended recording and the hotkey was registered
again (the checkbox then turned it off, as clicked). Not checked: a
key pressed by a person, the default Opt-Cmd-N itself, several displays,
full-screen apps.

TASK-193.3, 2026-10-26, macOS 26.7, real input posted in the app, light and
dark ([harness](../../docs/harness/task193-3-harness.patch), which lists
every step and result):[^harness-3] the button named the source space
(Work); the dropdown showed Default (🏠 Home, 💼 Work ⌘O) and Second (🎮
Play, "Reloads the page"); Cmd+O with another browser window in front
brought the window on Work forward with the page selected — the same tab
and web view, scrollY, typed field text and Back intact — and the Quick
Detour's controller was released; the extension saw `onDetached` (popup,
position 0), `onAttached` (the browser window, position 0), `onActivated`,
`windows.onRemoved`, and the same tab id afterwards; the earlier visits
stayed under the Quick Detour scope and the next one was Work's. Down and
Return in the dropdown chose Play: the most recent window switched to it
and the page reloaded on the Second profile without the default profile's
cookie. The button with a page mid-load moved it; it finished in Work.
Private: into the most recent Private window, then into a new one holding
only the page, with a download in flight moving to its scope. Not checked:
Cmd+O typed by a person, several displays, 1Password across a move, an
extension's content-script port across a move.

TASK-193.4, 2026-10-26, macOS 26.7, real input posted in the app (a click
on the pill, Down/Return/Escape in its menu and in the question), light and
dark ([harness](../../docs/harness/task193-4-harness.patch), which lists
every step and result):[^harness-4] the pill named Default; its menu listed
"✓ Default, Second, —, Private" with the reload tooltips; choosing Second
kept the window and reloaded a cookie-reading page on a new tab and web view
on Second's store ("Not logged in" where Default's read "Logged in"), the
old web view released, Open in naming Second's 🎮 Play; Default's Quick
Detour scope kept the earlier visit and Second's got the next; the extension
in Default heard `tabs.onRemoved` and `windows.onRemoved`, the one in Second
`windows.onCreated` (popup) then `tabs.onCreated` in it; back to Default gave
its extension a new window id. Into Private: the non-persistent store, a
dark window, Open in Private Window, nothing recorded, an incognito popup
for the Private profile's extension. Out of Private with a download running:
the question; Escape kept everything, Return switched, cancelled the download
and left no partial file, and the Private session ended. The History page
reopened as the History page on Second. After the code review (phases 3
and 4, light and dark): the pill pressed while its menu was open, one
switch, and leaving Private with a download still asking first. Not checked: a person's own click,
VoiceOver, a page mid-load and a profile deleted or renamed while open (unit
tests only), several displays.

TASK-193.5, 2026-10-26, macOS 26.7, real input posted in the app, light and
dark ([harness](../../docs/harness/task193-5-harness.patch), which lists
every step and result):[^harness-5] links from other apps were delivered by
calling `openExternalURLs(_:sourceApp:)` in the process (no LaunchServices,
no Apple Event). A Contains route, an app-only route (from
`com.example.chat`) and the Default each opened a Quick Detour on the front
window's profile with no tab in any space; another app's link took the Most
Recent Space path. Opt-Cmd-click on a link that a route sends to Work opened
a Quick Detour and left Work alone, while the same link Cmd-clicked was
routed there; Opt-Cmd in an iframe and in a Private window's page (a
Private, dark Quick Detour) worked; Opt-Cmd on an unselected sidebar tab
opened a copy and left the selection. The Settings checkbox turned
Opt-Cmd off (a background tab, as Cmd, and nothing from the sidebar) and on.
Closed ones were listed as "Quick Detour · …"; clicking one reopened it, the
record consumed; a Private one wrote nothing; quitting through the Quit
alert archived the two normal ones and not the Private one, listed after the
relaunch. With a 15 s override, a scroll in a background Quick Detour
restarted its time and it closed 15.1 s later as "auto-closed", while the
frontmost and a Private one stayed. Not checked: a person's own clicks, a
real app's link, sleep and wake, sound keeping one open, several displays.

Not checked at runtime (TASK-193.1): Cmd+click and page-opened windows, a normal
Quick Detour's downloads, HTTP sign-in, the external-app prompt, a signed
`.crx` installing, 1Password itself.

# Related

- [Peek](../tabs/peek.md) — the other tab in no space list; a Peek hangs off a host tab, a Quick Detour off its own window.
- [History recording and search](./history-recording-and-search.md) — the scope the visits are filed under.
- [History page](./history-page.md) — the label.
- [Incognito](../architecture/incognito.md) — the Private session a Private Quick Detour shares.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md) — `ExtensionListedWindow` and the placement rule.
- [Command palette](./command-palette.md) — the palette the window opens with.
- [App shell](../architecture/app-shell.md) — the menu item, and that not every window is a browser window.
- [Closed tabs and the archive](../tabs/closed-tabs-and-archive.md) — the records closed Quick Detours share.
- [Link routing](./link-routing.md) — the Quick Detour target, and Opt-Cmd's place in the click rule.

[^webkit-windows]: WebKit, WebExtensionContextAPIWindowsCocoa.mm (windowsGetAll reads the context's own window list)
[^harness]: TASK-193.1 runtime harness and its results
[^harness-2]: TASK-193.2 runtime harness, its scratch tools and results
[^harness-3]: TASK-193.3 runtime harness and its results
[^harness-4]: TASK-193.4 runtime harness and its results
[^harness-5]: TASK-193.5 runtime harness and its results
