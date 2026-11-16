---
type: Feature
title: Quick Detour window and its page
description: "The Quick Detour window and its one page: size and cascading, undo, the page as a BrowserTab in no space and what every space-walking query does with it, links and windows the page opens, no session restore, a Private Quick Detour, how extensions see it as a popup window, and the teardown."
tags: [window, tabs, privacy, extensions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T07:45:00Z }
sources:
  - id: task-193-1
    resource: backlog:TASK-193.1
    title: "Quick Detour: the window, its single tab and the palette that opens it"
  - id: task-345
    resource: backlog:TASK-345
    title: "Undo and redo: a page gets ⌘Z and ⇧⌘Z first, and Edit › Undo/Redo reach the page's own undo while editing"
  - id: task-298
    resource: backlog:TASK-298
    title: "Private windows: cookies and site data survive closing the last Private window and reappear in the next one, until Detour quits"
  - id: window
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController.swift
    title: QuickDetourWindowController.swift
  - id: webkit
    resource: ../../Detour/Browser/QuickDetour/QuickDetourWindowController+WebKit.swift
    title: QuickDetourWindowController+WebKit.swift (navigation, UI, WKWebExtensionWindow)
  - id: store
    resource: ../../Detour/Browser/QuickDetour/TabStore+QuickDetour.swift
    title: TabStore+QuickDetour.swift
  - id: rules
    resource: ../../Detour/Browser/QuickDetour/QuickDetour.swift
    title: QuickDetour.swift (history scope, which profile, palette scope)
  - id: task-359
    resource: backlog:TASK-359
    title: "Content blocking: an open Quick Detour window keeps the rule lists it was created with"
  - id: webkit-windows
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIWindowsCocoa.mm
    title: WebKit, WebExtensionContextAPIWindowsCocoa.mm (windowsGetAll reads the context's own window list)
---

A Quick Detour is a small window with one web view, for looking something up without opening a tab in any space. This page is the window and the `BrowserTab` it hosts; the bar across its top is [its own page](./quick-detour-title-bar.md).

# The window

The window is a normal-level window, 900 × 640 points by default (minimum
480 × 320), centred, each later one cascading 22 points down and right of the
last. Several windows can be open at once. Its only chrome is the [title
bar](./quick-detour-title-bar.md): the traffic lights, a back button, an
address capsule (the [profile pill](./quick-detour-profile-pill.md), the
page's host, pinned extensions, Copy Link, site settings) and
[Open in <Space> ⌘O](./quick-detour-open-in.md). There is no sidebar.

Cmd+W, Cmd+F (Escape closes the find bar), zoom, Back/Forward (Cmd+[ / Cmd+],
the mouse back button), Reload, Copy URL and the Web Inspector work as in a
browser window. Clicking anywhere on the address capsule that is not one of
its buttons reopens the palette over the page, navigating it in place
(TASK-322; the host text alone before).

# Undo

Cmd+Z in a page is the page's: the [browser undo](../architecture/browser-undo.md) stack is the
browser windows' and is never reached from here (TASK-193.1). Since TASK-345
(the user's decision) Edit > Undo and Redo, and the ⌘Z / ⇧⌘Z the page
leaves, run the page's own undo while an editable element in it has focus
(its web view first responder, the window key), titled from the page
("Undo Typing") and disabled when it has nothing; with no field focused they
are disabled. The same holds in a quarantine. `QuickDetourWindowController`
answers `browserUndo:`/`browserRedo:` itself, through
`BrowserWebView.editingPage(in:)`, so the menu never falls through to a
browser window. Measured with real keys: typing in a Quick Detour's and a
quarantine's input, ⌘Z / ⇧⌘Z and Edit > Undo / Redo undid and redid it,
and the browser window's closed tabs stayed closed
([A page's key equivalents and its undo](../platform/page-key-equivalents-and-undo.md)).

# The page is a tab in no space

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
| `sleepStaleTabs`, `archiveStaleTabs` | never slept or swept: it lives as long as its window, and goes to the archive when that closes ([archive](./quick-detour-archive.md)) |
| `allLiveTabs` (the GPU process recycler's media check) | included: its audio or capture holds the recycle back |
| Now-playing bar (`nowPlayingTabs`) | not listed: no browser window can switch to it |
| Palette open-tab suggestions (`gatherTabInfos`) | never offered, and neither the launcher panel nor the window's palette offers any |
| Extension contexts | its own window, of type `popup` ([below](#extensions)) |
| `Profile.extensionPageLocations` (rehoming on a context reload, the deferred-update count) | not walked: WebKit refuses an extension page in its web view, so it never shows one ([extension pages](../extensions/extension-pages.md#where-an-extension-page-cannot-be), TASK-352) |
| History | its profile's [Quick Detour scope](./quick-detour-history.md) |

Only the Quick Detour window ever hosts its web view: no other window lists
the tab, so there is no ownership hand-off and no snapshot. The window is the
web view's navigation and UI delegate for its whole life.

The window also follows content-blocking changes: on
`.contentBlockerRulesDidChange` it replaces the page's rule lists with what
its current profile has on (`ContentBlockerManager.replaceRuleLists`), as a
browser window does for its selected panes. Before TASK-359 nothing did, and
an open page kept the lists it was created with
([attaching lists to web views](./content-blocking.md#attaching-lists-to-web-views)).[^task-359]

# Links and windows inside it

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

# Session restore

Decision 2 (user, 2026-10-25): open Quick Detour windows are not restored. The session save
holds spaces only, so nothing was needed beyond keeping the tab out of every
space. Quitting archives them instead (TASK-193.5,
[archive](./quick-detour-archive.md)): they come back from the Archived Tabs page.

# Private

Decision 3 (user, 2026-10-25): allowed. A Quick Detour opened while a Private window is
frontmost (or switched there with the [pill](./quick-detour-profile-pill.md#private)) is on the Private profile: the profile's one non-persistent store,
no history (`recordHistoryVisit` checks `quickDetourProfile.isIncognito`), a
dark window, and Open in names Private Window
([Open in](./quick-detour-open-in.md#private), TASK-193.3). The Private session's in-memory state (the
Private site settings) is dropped only when **no** Private page is left —
neither a Private space nor a Private Quick Detour
(`TabStore.hasLivePrivateSession`) — so closing the last Private window does
not take settings from a Private Quick Detour still open, and the reverse.
The data store is reset at the same moment, when no Private page of either
kind is left ([incognito](../architecture/incognito.md), TASK-298). A Private Quick Detour's
downloads are scoped to its tab id and go when it closes. With one in
flight, closing the window asks first, as a Private window does
(`windowShouldClose` with `PrivateDownloadClosePolicy` and the same alert):
Continue Downloading keeps window and download, Close Window cancels it and
removes the partial file. Quitting with no browser window open — so no
Quit Detour? alert — still cancels them (`applicationShouldTerminate`'s
windowless path), leaving no partial file.

# Extensions

Decision 4 (user, 2026-10-25): visible. The window is an `ExtensionListedWindow`:

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
- The title bar's extension buttons, and an extension chosen in its site
  settings, go through `ExtensionPopoverController` with the window's
  profile and page, so `action.onClicked` or the popup acts on the Quick
  Detour, not on the last active space.
- `tabs.remove` on the page closes the window; `tabs.update({active})`
  (`activate`) brings it forward.

API output kept its shape (`popup` is an existing window type), so the API
Explorer extension needed no change.

# Teardown

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

Suites, counts and the runtime passes are on [Quick Detour tests and runtime checks](./quick-detour-tests.md).

# Related

- [Quick Detour](./quick-detour.md) — the hub: what the window is and the list of its pages.
- [Peek](../tabs/peek.md) — the other tab in no space; a Peek hangs off a host tab, a Quick Detour off its own window.
- [Incognito](../architecture/incognito.md) — the Private session a Private Quick Detour shares.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md) — `ExtensionListedWindow` and the placement rule.
- [App shell](../architecture/app-shell.md) — the menu item, and that not every window is a browser window.
- [Quarantine](./quarantine.md) — a Quick Detour on the Private profile whose page has a throwaway store of its own (TASK-194).
- [Quick Detour tests and runtime checks](./quick-detour-tests.md) — the suites, what was written first, and the runtime passes.

[^task-359]: Content blocking: an open Quick Detour window keeps the rule lists it was created with
[^webkit-windows]: WebKit, WebExtensionContextAPIWindowsCocoa.mm (windowsGetAll reads the context's own window list)
