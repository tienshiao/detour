---
type: Reference
title: Quick Detour tests and runtime checks
description: "The Quick Detour test suites and what each covers, which tests were written first against stubs and what they caught, and every runtime pass (TASK-193.1 to .5, 210, 213) with what was and was not checked."
tags: [window, tests]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T07:22:00Z }
sources:
  - id: tests-dir
    resource: ../../DetourTests
    title: DetourTests (the Quick Detour, HotKey and Open in Quick Detour suites)
  - id: harness
    resource: ../../docs/harness/task193-1-harness.patch
    title: TASK-193.1 runtime harness and its results
  - id: harness-2
    resource: ../../docs/harness/task193-2-harness.patch
    title: TASK-193.2 runtime harness, its scratch tools and results
  - id: harness-3
    resource: ../../docs/harness/task193-3-harness.patch
    title: TASK-193.3 runtime harness and its results
  - id: harness-4
    resource: ../../docs/harness/task193-4-harness.patch
    title: TASK-193.4 runtime harness and its results
  - id: harness-5
    resource: ../../docs/harness/task193-5-harness.patch
    title: TASK-193.5 runtime harness and its results
  - id: harness-210
    resource: ../../docs/harness/task210-harness.patch
    title: TASK-210 runtime harness and its results
  - id: harness-213
    resource: ../../docs/harness/task213-harness.patch
    title: TASK-213 runtime harness and its results
---

The tests and runtime checks behind the [Quick Detour](./quick-detour.md) pages, kept together because the history of what was written first spans every sub-task.

# Test suites

Counts are the `func test` methods in each file on 2026-11-15 (a `+N` row is
what a later sub-task added to a suite listed above it).

| Suite | Covers |
|---|---|
| `QuickDetourTests` (27) | the rules (history scope, which profile); the tab in no space: creation from the profile's store and controller, adoption, close and its idempotence, observers, several at once, every space-walking lookup, never slept/archived/saved, profile deletion; history: recorded under the scope (real load), Private records nothing, the profile scope, the launch sweep, the page payload, `spaceID` on listed and searched rows; the Private session both ways; Private downloads |
| `QuickDetourLauncherTests` (14) | the panel (non-activating, borderless, floating, can become key, the palette's profile, the profile's whole history whichever window asked (TASK-209), none for Private, and no tabs), no window or tab before submit; submit (URL, search, suggestion) closing it and opening the window; Escape and clicking away opening nothing; one panel; the centring rule; the real window opening on its page; Undo/Redo answered by the panel with its field's typing, never `TabStore`'s list (TASK-346) |
| `QuickDetourWindowTests` (16) | opening on its page with no palette, loading in the one web view, the host palette (profile, no tabs, history scope), dismissing it keeping the window, a search from it, navigating in place, back/forward/zoom/find, Cmd+Z not undoing a browser action, Copy Link, Cmd+W, two windows, closing from the store, a page-opened window, the extension window lookups, no leaks |
| `HotKeyShortcutTests` (27) | the shortcut (default, narrowing, equality), Carbon modifier bits both ways for all 16 combinations, state bits ignored, key equivalents (letters, F-keys, arrows, Space, Return, Forward Delete, a layout's character), the label and key names, the defaults round trip and malformed values; validation (a modifier needed, an unnamed key, Detour's menu items by path including submenus, function-key items and an uppercase key equivalent meaning Shift, the Quick Detour item excepted, Control-Tab, macOS shortcuts with and without the Fn bit, the real main menu), the messages; recording (Escape, Delete, with a modifier, refused) |
| `HotKeyRegistrationTests` (20) | the state machine against a fake registrar: off, on, idempotent, off unregisters, a change unregisters first, cleared, refused keeps the choice and holds nothing, changing away from a refusal, retry, suspend and resume, `isConflict`; the settings (defaults per data directory, persistence and notification, cleared stays cleared, malformed) |
| `QuickDetourHotKeyTests` (22) | the wiring with a fake registrar: never started in the test host, the press callback handed to the registrar, settings followed at once, the menu item mirroring the shortcut also when off and cleared, recording, a refusal reported and retried (also on becoming active), the messages; the hotkey toggling the launcher, the menu item not toggling it, the real File item attached; the recorder (records, a Cmd key taken before the menus, refused and still recording, Escape, Delete, stops when its window resigns key, saves before it stops); where it may register (the test host never, Debug only with the opt-in, Release yes, the Settings line); the menu item following the setting where nothing registers; a mouse-down outside the recorder ending it (the pure rule, and a real event through `nextEvent`/`sendEvent` reaching the monitor) |
| `UserDefaultsScopeTests` | the preferences suite per data directory |
| `QuickDetourTitleBarTests` (16) | TASK-210: the site settings for the page and its profile (TASK-213: only the content blocking switch, while the main window's builder keeps picture in picture and dev mode); content blocking off in its profile only, the page reloading; the palette's prompt and the main window's; the bar button — a press released in place clicks, one moving 3 points drags from the press and does not click, one released off the button does nothing, a first press on a background window does not click but drags (events handed to the tracking loop directly: posted mouse events come back with their locations moved through screen coordinates); TASK-322: the back button (enabled only with a page to go back to, placed between the traffic lights and the capsule), the capsule handing presses its controls do not take to the host, a click on its empty space opening the palette, a release in the click area outside the host button counting as a click, the progress fill shown only while a load is in flight and following the page's load |
| `QuickDetourExtensionTests` (11) | real contexts: a `popup` window from an extension page and the worker (promise and callback forms), another profile seeing nothing (also for a context loaded after the window opened), no URL without `tabs`, a content script's `sender.tab`, the toolbar button's `onClicked` (and an extension chosen in the site settings, TASK-210), by-id lookups refused after close, a Private Quick Detour as an incognito popup |
| `InternalPageIntegrationTests` | the History page's "Quick Detour" label |
| `QuickDetourOpenInTests` (30) | Open in's rules: the most recently used space (use order, other profiles, deleted and Private spaces skipped, the first space with none used), the default target (the source space, another profile's or deleted source falling back, Private never, a profile with no space), the menu (grouped by profile with the window's first, sidebar order, reload marks, the default item, headers only for several profiles, Private and deleted profiles left out, no target at all), Private (Private Window, no dropdown); `noteSpaceUsed`; the store's move (the same tab and web view at the new-tab position, observers told of a move not a close, saved with the session, refused for another profile, the Private boundary, a non-Quick-Detour tab and a gone space; Private into a Private space), the extension seam (one move from the popup window, no close; none when the caller announces), the history scope switching at the move (real loads), a Private download moving with the page and a normal one untouched |
| `QuickDetourOpenInWindowTests` (17) | in real windows: a sheet and a page `alert()` blocking Cmd+O until they end, the button naming the source space and following a deletion, the File menu's ⌘O item, Cmd+O and the button moving the page into the window showing the space (front, selected, same web view hosted with the window's delegates, back list and typed form text kept), the most recent window switching, the dropdown, the palette and find bar closed, the controller released while the web view lives on, another profile's space reloading (its store, the Quick Detour and its web view released), the dropdown's headers, tooltips (no subtitles) and ⌘O item, Private into the most recent Private window and into a new one holding only the page, both boundaries refused, a space switch noting its use |
| `QuickDetourProfileSwitchTests` (23) | the pill's rules: the menu (normal profiles in order, Private last after a separator, the window's own checked, one profile plus Private, deleted left out, no separator without Private), the decision (same profile and a gone or deleted one stay; another or Private switches at once; leaving Private asks with one or more downloads running, never otherwise; a normal page never asks); the store's replacement (a new tab on the other profile's store with the given id, the old torn down, the hook between the pages with neither listed, observers told of a replacement not a close, refusals, deleting the new profile closing it), Private (into it: its store, the session live, its download scope; out of it: the session ending, or kept for a Private window; its downloads dropped), history (visits after the switch under the new profile's scope, real loads; Private records nothing) |
| `QuickDetourProfileSwitchWindowTests` (17) | in real windows: the pill names the profile; the menu (order, Private last after a separator, the checkmark) and its item switching; the address reloading under the other profile's cookies (a loopback page titled by a cookie the other profile set; the same window, a new tab and web view hosted with the window's delegates, no back history, the old web view released) and back; the same profile a no-op; a sheet refusing; a page mid-load reloading its address; the History page reopened as an internal page; palette and find bar closed; Open in following the profile both ways; into Private (store, dark, Open in Private Window, scope) and out (appearance, scope, Open in); the download question (no keeps everything, yes cancels and drops it; a target deleted, or a sheet put up, while it is asked refuses the switch and keeps the download); the window closing cleanly after a switch |
| `QuickDetourExtensionTests` (+4) | the pill in real contexts: a close for the old profile (`tabs.onRemoved`, `windows.onRemoved`, both refused by id, promise and callback) and an open for the new (`windows.onCreated` popup, `tabs.onCreated` in it, `windows.getAll` from the page, `tabs.get` from the worker); switching back a new window and tab id; a third profile hearing nothing; into Private an incognito popup |
| `QuickDetourExtensionTests` (+3) | Open in in real contexts: the same tab id detached from the popup and attached to the browser window (with its position), no remove and no second create, `tabs.get`/`windows.get` from the page and the worker, the popup refused by id (promise and callback); another profile hearing nothing; a reload in another profile removing the tab here and creating one there |
| `QuickDetourEntryPointsTests` (21) | TASK-193.5's pure rules: the settings (defaults, persistence and notification, an unreadable timeout), the timeouts and titles, the Opt-Cmd click, a split row's pane, a sidebar tab's copy, the routed link's profile (the front window's, never Private, none open, deleted), the idle rule (the interval, Never, frontmost, sound, Private, a sheet, time asleep, a clock set back), the Debug override and the check interval, the archive label |
| `QuickDetourArchiveTests` (17) | the store: a close archived under the scope (plain or auto-closed), Private never, no address, discard, the back/forward list captured; quit archiving each normal one once; the listing (labelled kinds, alone, a gone profile's not listed), Reopen Closed Tab never taking one, surviving a session save; taking a record (consumed, a space's refused), a restored tab (profile, address, title, store); Clear covering the scopes; profile deletion deleting only its own |
| `QuickDetourArchiveWindowTests` (11) | in real windows: Cmd+W archiving, Private not, a profile switch not; a restore reopening on the profile and only once, a space's record refused; the monitor on an injected clock: the unused one closing as auto-closed while the frontmost stays, Never, the setting read at each check, a key press and key changes counting as use, a sheet, Private |
| `QuickDetourSidebarCopyTests` (6) | Opt-Cmd mouse-downs handed to the sidebar's table: a normal tab copied and left unselected, a sleeping tab's stored address without waking it, each pane of a split row, a pinned entry, a dormant favourite (not woken) |
| `OpenInQuickDetourMenuTests` (11) | TASK-300: the link menu's Open Link in Quick Detour after the other Open Link items, offered with the ⌥⌘-click setting off and inside a Peek, running WebKit's item for the Quick Detour action, a web link opening on the page's profile (Private in a Private window), a non-web link opening a background tab as Opt-Cmd-click does; the sidebar tab menu's Open in Quick Detour copying the tab, a split row's pane under the pointer, a Private window's tab into a Private Quick Detour |
| `QuickDetourContentBlockingTests` (3) | TASK-359, in real windows with a private rule store: after a rules change an open Quick Detour's page stops blocking with a list switched off and blocks with a recompiled list's new rule, not its old one; a quarantine's page follows the Private profile's switches. All three failed before the fix |
| `QuickDetourDockMenuTests` (7) | TASK-309: the item following the windows' states, the titles, no item without a Quick Detour, Hide All then Show All with Private ones included, a hidden window never frontmost so its idle timer runs, a new Quick Detour shown alone and hidden with the rest, a quarantine left alone |
| `ExternalLinkRoutingTests` (+4), `LinkRoutingEligibilityTests` (+5), `LinkPlacementTests`, `LinkRouteEditorTests`, `ArchiveListLayoutTests` (+3), `QuickDetourOpenInWindowTests` (2 assertions) | a Quick Detour route, a from-app route and the Default opening a Quick Detour on the front window's profile (never Private); the Opt-Cmd branch and its exclusion from routing; `.openInQuickDetour`; the target offered; the subtitle and the clear scope; Open in (both kinds) archiving nothing |

# Written first

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

# Runtime checks

Each pass is a record of what was seen on its date; later changes are noted
in brackets.

## TASK-193.1: the window, the launcher, extensions, history, Private

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

Not checked at runtime (TASK-193.1): Cmd+click and page-opened windows, a normal
Quick Detour's downloads, HTTP sign-in, the external-app prompt, a signed
`.crx` installing, 1Password itself.

## TASK-193.2: the global hotkey

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
opt-in, posted clicks on the checkbox (a switch since TASK-328), on empty pane space and on the
General toolbar item each ended recording and the hotkey was registered
again (the checkbox then turned it off, as clicked). Not checked: a
key pressed by a person, the default Opt-Cmd-N itself, several displays,
full-screen apps.

## TASK-193.3: Open in <Space>

TASK-193.3, 2026-10-26, macOS 26.7, real input posted in the app, light and
dark ([harness](../../docs/harness/task193-3-harness.patch), which lists
every step and result):[^harness-3] the button named the source space
(Work); the dropdown showed Default (🏠 Home, 💼 Work ⌘O) and Second (🎮
Play, "Reloads the page" [a subtitle since dropped, TASK-210]); Cmd+O with another browser window in front
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

## TASK-193.4: the profile pill

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

## TASK-193.5: entry points, links from other apps, the archive, idle auto-close

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
opened a copy and left the selection. The Settings checkbox (a switch since TASK-328) turned
Opt-Cmd off (a background tab, as Cmd, and nothing from the sidebar) and on.
Closed ones were listed as "Quick Detour · …"; clicking one reopened it, the
record consumed; a Private one wrote nothing; quitting through the Quit
alert archived the two normal ones and not the Private one, listed after the
relaunch. With a 15 s override, a scroll in a background Quick Detour
restarted its time and it closed 15.1 s later as "auto-closed", while the
frontmost and a Private one stayed. Not checked: a person's own clicks, a
real app's link, sleep and wake, sound keeping one open, several displays.

## TASK-210: the bar's site settings and handles

TASK-210, light and dark, 2026-10-26
([harness](../../docs/harness/task210-harness.patch)):[^harness-210] the
bar's site settings opened below the button with the page's host, the
switches and a pinned probe extension; its blocking switch whitelisted the
site in Default only and reloaded the page, and again back; the probe's
name opened its popup below its pinned button; the palette showed "Search
or enter a URL" (the main window's "Where do you want to go?"); the
dropdown had no subtitles. Real HID drags of 80 × 40 points from the host
and from Open in moved the window without opening the palette or moving the
page; a HID click on the host opened the palette; with the main window key,
a first click on Open in only brought the Quick Detour forward and a first
drag moved it. The main window's popover, now from the shared builder,
listed the same and its switch reloaded the tab. Not checked: a page with
blocked resources, several displays.

## TASK-213: the site settings popover's layout

TASK-213, light and dark, 2026-10-26
([harness](../../docs/harness/task213-harness.patch)):[^harness-213] a
Quick Detour's popover, opened by a click on the bar, was the host, a
divider, Content Blocking with its one switch, a divider and the extensions
(280 × 234, two dividers); the main window's had picture in picture and dev
mode between two dividers below the blocking switch (280 × 315). A long host
truncated in the middle; seven blocked resources showed on the shield's
badge and in the count line; with no page the header read "No site loaded"
and the two site switches were disabled. Every label, switch and divider
was logged with its frame: no overlaps, nothing outside the popover. The
review then found the picture in picture label (188 points) one gap short of
the 248-point content beside a 54-point switch, which squeezed the switch 2
points out of line; with a 6-point gap a second pass had all three switches
aligned and the label whole.

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Build and test](../playbooks/build-and-test.md) — building and launching in an isolated data directory.
- [Global hotkey testing](../playbooks/global-hotkey-testing.md) — the HID-tap tools of the TASK-193.2 pass.

[^harness]: TASK-193.1 runtime harness and its results
[^harness-2]: TASK-193.2 runtime harness, its scratch tools and results
[^harness-3]: TASK-193.3 runtime harness and its results
[^harness-4]: TASK-193.4 runtime harness and its results
[^harness-5]: TASK-193.5 runtime harness and its results
[^harness-210]: TASK-210 runtime harness and its results
[^harness-213]: TASK-213 runtime harness and its results
