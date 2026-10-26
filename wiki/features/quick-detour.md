---
type: Feature
title: Quick Detour
description: "A small window with one page for a quick lookup, opened from a Spotlight-like palette panel (File > New Quick Detour Window, or a system-wide hotkey, Opt-Cmd-N by default, from any app): the panel, the global hotkey (Carbon, no permission; what conflicts it can and cannot detect; activating with only the new window forward; the Settings control), the tab in no space, history under a per-profile scope labelled on the History page, Private, extensions seeing a popup window, and what is not restored."
tags: [window, tabs, history, privacy, extensions, palette]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-26T05:45:00Z }
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

Placeholders until their subtasks:

| Control | Now | Owner |
|---|---|---|
| Profile pill | shows the profile's name (a person symbol, eyeglasses for Private); no menu | TASK-193.4 |
| Open in <Space> ⌘O | shown **disabled**, naming the space it will offer: the space the window was opened from if it is the same profile's, else the profile's first; hidden for a Private Quick Detour | TASK-193.3 |
| Archive on close or quit | none: a closed Quick Detour is gone | TASK-193.5 |

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

Settings > Links > **Quick Detour** (TASK-193.5 adds its other entry points
there): "[✓] Open Quick Detour from any app with [⌃⌥⌘F12]", a warning line
under the row, and help text saying the launcher opens over the app in
front and that the same shortcut is File > New Quick Detour Window while
Detour is in front, also when the hotkey is off.

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
| `sleepStaleTabs`, `archiveStaleTabs` | never slept or archived: it lives as long as its window |
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
window, or a Quick Detour's own — else the first profile that is neither
Private nor deleted. TASK-193.4 decides the long-term default.

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
space. Archiving them on close and quit is TASK-193.5.

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

## Teardown

Closing the window (Cmd+W, the close button, an extension's `tabs.remove`,
the profile deleted) runs `tearDown()` once:
palette and popovers closed, subscriptions and the weakly held script
handlers removed, delegates cleared, `closeQuickDetourTab` (out of the list,
web view released, extension registration closed, Private session checked,
observers told), `didCloseWindow` to the contexts, and the controller
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
| `QuickDetourExtensionTests` (8) | real contexts: a `popup` window from an extension page and the worker (promise and callback forms), another profile seeing nothing (also for a context loaded after the window opened), no URL without `tabs`, a content script's `sender.tab`, the toolbar button's `onClicked`, by-id lookups refused after close, a Private Quick Detour as an incognito popup |
| `InternalPageIntegrationTests` | the History page's "Quick Detour" label |

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
unfiltered, no `didOpenWindow`) each failed them.

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

[^webkit-windows]: WebKit, WebExtensionContextAPIWindowsCocoa.mm (windowsGetAll reads the context's own window list)
[^harness]: TASK-193.1 runtime harness and its results
[^harness-2]: TASK-193.2 runtime harness, its scratch tools and results
