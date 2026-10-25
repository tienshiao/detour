---
type: Concept
title: Tab lifecycle
description: How a tab comes into being, navigates, closes and comes back, which object is its navigation delegate at each point, and when each step reaches the database.
tags: [tabs, lifecycle, navigation, persistence]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T22:00:00Z }
sources:
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift
  - id: browsertab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift
  - id: uidelegate
    resource: ../../Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
    title: BrowserWindowController+WKUIDelegate.swift
  - id: store-observer
    resource: ../../Detour/Browser/Window/BrowserWindowController+TabStore.swift
    title: BrowserWindowController+TabStore.swift
  - id: appdelegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift
  - id: lifecycle-doc
    resource: ../../docs/tab-lifecycle.md
    title: docs/tab-lifecycle.md
  - id: task-79
    resource: backlog:TASK-79
    title: Closing a tab with a playing video starts picture-in-picture that vanishes mid-transition
  - id: task-167
    resource: backlog:TASK-167
    title: window.open() hands the page no window back, so an xterm.js terminal link opens an empty tab
  - id: task-168
    resource: backlog:TASK-168
    title: A sign-in popup cannot reach the page that opened it or close itself
  - id: task-85
    resource: backlog:TASK-85
    title: target=_blank links in a pinned tab or favourite open in a Peek
  - id: task-119
    resource: backlog:TASK-119
    title: Archived Tabs page; close undos skip consumed records
  - id: task-185
    resource: backlog:TASK-185
    title: "Peek: add an Open in Split View button; splitting from a favourite or pinned tab opens the split in the normal section"
---

# Summary

A tab is a `BrowserTab` that sits in exactly one of four places: `space.tabs`
(a normal tab), `PinnedEntry.tab` (a [pinned entry's](./pinned-tabs-and-folders.md)
backing tab), `Favorite.tab` (a [favourite's](./favorites.md) backing tab) or
another tab's `peekTab` (a [Peek](./peek.md)). It is live (has a `WKWebView`) or
[asleep](./sleeping-and-archiving.md). Every structural change goes through
[`TabStore`](../architecture/tabstore.md), which follows one shape: mutate,
register undo, notify observers, `scheduleSave()`.

This page covers normal tabs. The per-section rules are on the pages linked
above; the web view side (who hosts it) is
[web view ownership](../architecture/webview-ownership.md).

# Rules

## Creation

Every path that adds a normal tab ends in the private `TabStore.insertTab`,
which sets `spaceID` and `parentID`, computes the index
([insertion rule](./tab-insertion-and-close-selection.md)), inserts, subscribes
to the tab's published properties, notifies `tabStoreDidInsertTab` and
schedules a save. Entering `space.tabs` is also what reports the tab to the
extension contexts (the list's `didSet`, see
[tab and window bridge](../extensions/tab-and-window-bridge.md)).

| Trigger | Store call | Selected afterwards |
|---|---|---|
| Submitting the [command palette](../features/command-palette.md) in new-tab mode | `addTab(in:)`, then `tab.load(url, typed:)`; a URL a route sends to another space opens there instead ([link routing](../features/link-routing.md#typed-urls-and-links-clicked-in-a-page)) | yes |
| Cmd+click on a link | `addTab(in:url:parentID:)` with the selected tab as parent | no (a toast says so when the sidebar is collapsed) |
| Context menu "Open Link in New Tab" | sets `contextMenuLinkAction`, replays WebKit's own item, lands in `createWebViewWith` → `addTab(in:url:parentID:)` | no |
| `window.open` or a `_blank` link in a normal tab | `createWebViewWith` → `addTab(in:openedWith:parentID:)`, with the opener as parent, in the opener's space; the tab's web view is returned to WebKit, which loads the URL | yes, unless the opener is in a space the window is not showing |
| Option+click on a link, or "Open Link in Split View" | `addTabInSplit(with:url:in:)`, or from a favourite or lone pinned tab `addSplitInNormalSection(copying:rightPane:in:)`, which adds two tabs ([split](./split-tabs.md#opening-a-split-from-a-tab))[^task-185] | yes (the right pane) |
| Expanding a Peek | `addTab(in:webView:parentID:)`, adopting the Peek's web view | yes |
| A Peek's Open in Split View | `addTabInSplit(with:webView:in:)` or `addSplitInNormalSection(copying:rightPane: .webView)`, adopting the Peek's web view | yes (the right pane) |
| An extension page | `addExtensionTab(in:url:configuration:)`, built from the context's configuration | caller decides |
| An [internal page](../features/internal-pages.md) (Cmd+Y) | `addTab(in:internalPage:)` | yes |
| Reopen Closed Tab, undo of a close, restore from the archive | `restoredTab(...)`, then a direct insert at the saved index | yes |

Things that follow from the code and are easy to assume wrong:

- **Cmd+T creates nothing.** It only opens the palette; the tab is created on
  submit.
- **A page's new window is a WebKit child.** `createWebViewWith` builds the
  tab from the configuration WebKit supplies and returns its web view, so the
  page gets a window back and keeps the opener link; the tab never calls
  `load` — WebKit navigates it, and the tab learns its URL from the web view.
  Until TASK-167 it returned nil and loaded the URL into a tab of its own,
  which left `window.open()` returning null. It still returns nil for the
  context menu's actions, for a [Peek](./peek.md), for the internal-page
  and `data:` refusals, and for a window an **extension page** opens: WebKit
  supplies the extension context's configuration there, which a web page must
  not load in, so that window is still a tab the app loads itself.[^task-167]
- **Such a tab shares its opener's data store and web process, not its user
  content controller.** The supplied configuration carries the opener's
  controller; the store replaces it with one of the space's own
  (`Space.makeUserContentController()`), because a window adds and removes its
  message handlers on the controller of the web view it hosts. When the tab
  later sleeps and wakes it is rebuilt from the space's configuration and the
  opener link is gone.[^task-167]
- **A tab that never called `load` has no `lastAttemptedURL` to blame.** When
  such a window's first load fails, the URL for the error page comes from the
  error itself (`NSURLErrorFailingURLErrorKey`); the web view only ever
  reported `about:blank`.[^task-167]
- **Such a tab gets its user agent from the store.** `init` applies the
  profile's user agent before the tab has a space, and `load` applies it
  again; a tab that never calls `load` is given it by
  `addTab(in:openedWith:)` once placed.[^task-167]
- **`addTab(in:url:)` cannot open an internal page.** Its callers include web
  content and extensions; `addTab(in:internalPage:)` is the only store-level
  way in.
- **A restored tab gets a fresh UUID.** Reopen and the close undos build a new
  `BrowserTab`; nothing may key on the old id except the closed-tab record's
  `tabID`.
- Session restore rebuilds the space's selected tab live and every other tab
  asleep, from the same `TabRecord` (see
  [persistence](../architecture/persistence.md)).

## Navigation

`BrowserTab.load(_:typed:)` wakes a sleeping tab, sets `url` and
`lastAttemptedURL` at once (so the sidebar shows the target before anything
commits), marks `navigationPending`, and shows the scheme-stripped URL as the
title until the commit. It refuses `detour://` URLs unless the call is armed
(`loadInternalPage`, `loadRecordedURL`). A history visit is recorded when
`isLoading` falls to false, by `TabStore`'s per-tab subscription, not by the
tab ([history recording](../features/history-recording-and-search.md)).

**Who is the navigation delegate.**

- A web view no window has claimed is its tab's own delegate (the
  `BrowserTab: WKNavigationDelegate` extension): the content-blocker
  preferences, the commit, the provisional failure and the events of the
  unresponsive-load rule, nothing else
  ([BrowserTab](../architecture/browser-tab.md#its-own-navigation-delegate)
  has the list). A failure after commit is handled by neither delegate
  ([error pages](../features/error-pages.md#failures-after-commit)).
- When a window claims the web view (`wireOwnedWebView`) the window becomes
  delegate and UI delegate. **Nothing clears that on a tab switch.** Callbacks
  keep arriving for tabs the window no longer shows, including tabs of spaces it
  switched away from. Every callback must resolve its tab with
  `tab(owning: webView)`, never `selectedTab`.
- The reference is weak. `windowWillClose` hands every web view it was delegate
  of back to its tab (`handBackNavigationDelegates`); otherwise those pages
  would load with no delegate at all until another window claimed them.

**Link policy order** (`decidePolicy(for:in:)`). The order is load-bearing:

1. An internal URL: allowed only when the owning tab authorises it, else cancel.
2. Cmd+click: background tab, unless [Air Traffic Control](../features/link-routing.md#typed-urls-and-links-clicked-in-a-page)
   routes it to another space or a Private window (TASK-191.4).
3. Shift+click: [Peek](./peek.md).
4. Option+click: [split](./split-tabs-hosting.md). This must precede step 7,
   because WebKit sets `shouldPerformDownload` for Option-clicked links.
5. Back/forward into an error page: reload the original URL instead.
6. A non-web scheme: [external app](../features/external-apps.md) confirmation.
7. `shouldPerformDownload`: download.
8. Air Traffic Control: a `_blank` link or a plain click to another host
   that a route sends elsewhere opens there and the tab stays
   (`linkRoutingEligibility`, TASK-191.4). It wins over step 9
   (`inPageLinkOutcome`).
9. The pinned/favourite Peek intercept.
10. Allow, after applying the per-host user agent to the *navigating* tab.

`createWebViewWith` asks the same rule for a tab-style `window.open` before
its own Peek intercept; a popup-style one is never routed.

## Closing

Cmd+W (`closeCurrentTab`) is a dispatcher, in this order: a presented Peek is
dismissed and nothing else happens; with no selection the window closes; a
pinned entry's tab goes dormant; a favourite's tab is deactivated; otherwise
the normal tab closes.

For a normal tab the window **settles selection first, then removes**:

1. `settleSelectionLeaving(tabAt:in:)` picks the next tab
   ([close selection rule](./tab-insertion-and-close-selection.md)) and selects
   it, inside `settlingSelectionForClose` so `selectTab` does not start
   picture-in-picture for a tab that is about to be torn down.[^task-79]
2. `TabStore.closeTab` captures the interaction state, pushes a
   [closed-tab record](./closed-tabs-and-archive.md) (not for incognito),
   removes the tab, calls `teardown()`, dissolves its split group, registers the
   undo and notifies `tabStoreDidRemoveTab`.

A page's `window.close()` arrives as `webViewDidClose` on the window that
hosts the tab. WebKit has already decided the script may close it (a window a
script opened, or one with nothing to go back to). The tab closes like one the
user closed, with one difference in what is selected next: the tab that opened
it (`parentID`), ahead of the close rule's siblings, since a window that
closes itself is done and its opener is where the result went. A split pane
keeps the split rule. Only normal tabs are handled: a `window.close()` from a
Peek, a pinned tab or a favourite is ignored (TASK-171).[^task-168]

A removal that did *not* go through the window's own close (an extension's
`tabs.remove`, an undo) reaches the window with its selection still on the
removed tab. `tabStoreDidRemoveTab` then picks the tab now at the same index,
a blunter choice than the close rule.

`closeTab` has three knobs: `undoable: false` writes no record and no undo (a
page that could never be reopened); `registersUndo: false` writes the record
but no undo (the archive sweep); `archivedAt` only stamps the record.

`BrowserTab.teardown()` is the single close point for every kind of tab: it
tears down the Peek, tells the extension contexts, pauses media and releases
the web view. A list removal that is not a close (`detachTab`, a move to
another space) deliberately does not call it.

## Reopening and undo

- **Reopen Closed Tab** (Cmd+Shift+T) takes the newest plain-close record of
  the active space, deletes it and inserts the rebuilt tab at
  `min(sortOrder, count)`, snapped out of any split that now spans that index.
- **Undo** (Cmd+Z) is `TabStore.undoManager`, shared by all windows. A web view
  routes Cmd+Z to the browser undo unless the page has an editable element
  focused (`BrowserWebView.performKeyEquivalent`, fed by the
  `editableFieldFocus` script message).
- An undone close posts `.tabRestoredByUndo`; windows on that space select the
  tab. It rejoins its split if the partner is still an ungrouped normal tab.
- A close undo does nothing once its record is gone (restored from the archive
  page, reopened, deleted or cleared). Without that check an undo after
  Cmd+Shift+T produced a duplicate tab.[^task-119]

## Persistence timing

| Event | Effect |
|---|---|
| Any structural mutation; a tab's `url` or `favicon` changing | `scheduleSave()`: one `saveNow()` 1 s after the last call |
| Closing a tab | the `closedTab` row is written immediately, outside `saveNow()` |
| Window close | `saveNow()` |
| App termination | undo stack cleared, then `saveNow()` |
| Deleting a profile | `saveNow()` first, so no space row still references it |
| The 5-minute sweep | sleeps and archives, then `scheduleSave()` |

`saveNow()` writes `space.tabs` with `sortOrder` = index, pinned backing tabs
with `sortOrder` -1 and favourite backing tabs with -2. Incognito spaces are
skipped.

# Where it lives

- [TabStore.swift](../../Detour/Browser/TabStore.swift): `insertTab`, the
  `addTab` family, `closeTab`, `reopenClosedTab`, `restoredTab`, `saveNow`.
- [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift): `load`, `wake`,
  `sleep`, `teardown`, and the tab's own delegate methods.
- [BrowserWindowController.swift](../../Detour/Browser/Window/BrowserWindowController.swift):
  `selectTab`, `closeCurrentTab`, `settleSelectionLeaving`.
- [BrowserWindowController+Navigation.swift](../../Detour/Browser/Window/BrowserWindowController+Navigation.swift):
  the policy order and `tab(owning:)`.
- [BrowserWindowController+WKUIDelegate.swift](../../Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift):
  `createWebViewWith`, `webViewDidClose`.

# Tests

`TabStoreTests`, `TabInsertionTests`, `TabCloseSelectionTests`,
`ArchivedTabRestoreTests`, `BrowserTabWakeTests`,
`BrowserTabUnclaimedNavigationTests`, `BackgroundTabTitleTests`,
`MoveTabToSpaceTests`, `UndoAfterDeleteSpaceTests`.

# Related

- [Tab insertion and close selection](./tab-insertion-and-close-selection.md): the two pure rules used above.
- [Sleeping and archiving](./sleeping-and-archiving.md): what happens to a tab nobody looks at.
- [Closed tabs and the archive](./closed-tabs-and-archive.md): where a closed tab goes.
- [Closed tabs are read from the database only](../decisions/closed-tabs-database-only.md): no closed-tab stack is loaded at launch.
- [BrowserTab](../architecture/browser-tab.md): the object itself.
- [Web view ownership](../architecture/webview-ownership.md): which window hosts the web view.
- [WKWebView delegate order](../platform/wkwebview-delegate-order.md): why `_blank` and `window.open` take different paths.
- [Media and picture-in-picture](../platform/media-and-pip.md): the close-time PiP problem.

[^task-79]: Closing a tab with a playing video starts picture-in-picture that vanishes mid-transition
[^task-167]: window.open() hands the page no window back, so an xterm.js terminal link opens an empty tab
[^task-168]: A sign-in popup cannot reach the page that opened it or close itself
[^task-85]: target=_blank links in a pinned tab or favourite open in a Peek
[^task-119]: Archived Tabs page; close undos skip consumed records
[^task-185]: Peek: add an Open in Split View button; splitting from a favourite or pinned tab opens the split in the normal section
