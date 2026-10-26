---
type: Feature
title: Quick Detour
description: "A small window with one page for a quick lookup, opened from a Spotlight-like palette panel (File > New Quick Detour Window, Opt-Cmd-N): the panel, the tab in no space, history under a per-profile scope labelled on the History page, Private, extensions seeing a popup window, and what is not restored."
tags: [window, tabs, history, privacy, extensions, palette]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-26T04:15:00Z }
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
the user's choice, TASK-193). File > New Quick Detour Window, or Opt-Cmd-N
while Detour is active, shows the **launcher panel**: the command palette
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
| Global hotkey | none: Opt-Cmd-N is a menu shortcut, only while Detour is active | TASK-193.2 |
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
- **One panel.** Asking again while it is up brings it forward; for another
  profile it is rebuilt.
- **Submit** closes the panel, activates Detour (`NSApp.activate`), then
  opens `QuickDetourWindowController.open(profile:sourceSpace:url:typed:)`,
  which makes the window key and loads the page. A typed URL is a typed visit.
- **Escape** follows the palette's own steps: it clears typed text first, and
  closes the panel on an empty field. **Clicking away** closes it through
  `NSWindow.didResignKeyNotification` on the panel.

Learned for TASK-193.2: a borderless panel is never key unless
`canBecomeKey` says so; with it, `makeKeyAndOrderFront` makes it key and the
palette's field first responder at once (seen at runtime while Detour was
active). Typing into it while **another app** stays active, which is what
`.nonactivatingPanel` is for, was not exercised: the harness posts its
events into Detour's own queue, which says nothing about the hotkey path.

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
| `QuickDetourExtensionTests` (8) | real contexts: a `popup` window from an extension page and the worker (promise and callback forms), another profile seeing nothing (also for a context loaded after the window opened), no URL without `tabs`, a content script's `sender.tab`, the toolbar button's `onClicked`, by-id lookups refused after close, a Private Quick Detour as an incognito popup |
| `InternalPageIntegrationTests` | the History page's "Quick Detour" label |

`QuickDetourTests` was written first: 26 of 28 failed against stubs, two
(the negative cases) passed. `QuickDetourLauncherTests` too: 10 of 11
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

Not checked at runtime: the panel taking typing while another app is
active (TASK-193.2's case), Cmd+click and page-opened windows, a normal
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
