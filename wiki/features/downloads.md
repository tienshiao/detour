---
type: Feature
title: Downloads
description: "How a navigation becomes a download, what DownloadManager tracks and persists, how a Private window's downloads are kept apart and cancelled when it closes, the sidebar popover and badge, the fly-to-button animation, and the CRX path that reuses the list."
tags: [downloads, webkit, navigation, persistence, incognito]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T09:48:28Z }
sources:
  - id: manager
    resource: ../../Detour/Browser/Downloads/DownloadManager.swift
    title: DownloadManager.swift (DownloadItem, DownloadManager, WKDownloadDelegate)
  - id: popover
    resource: ../../Detour/Browser/Downloads/DownloadPopoverViewController.swift
    title: DownloadPopoverViewController.swift
  - id: cell
    resource: ../../Detour/Browser/Downloads/DownloadCellView.swift
    title: DownloadCellView.swift
  - id: animation
    resource: ../../Detour/Browser/Downloads/DownloadAnimation.swift
    title: DownloadAnimation.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift (download policy, CRX interception)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (download table)
  - id: app-delegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (applicationWillTerminate flushes the pending save)
  - id: manager-tests
    resource: ../../DetourTests/DownloadManagerTests.swift
    title: DownloadManagerTests.swift
  - id: task-143
    resource: backlog:TASK-143
    title: completedAt is set once and a pending save is flushed at quit
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (removeIncognitoSpace)
  - id: task-148
    resource: backlog:TASK-148
    title: Private window downloads are not saved and are listed only in their window
  - id: close-policy
    resource: ../../Detour/Browser/Downloads/PrivateDownloadClosePolicy.swift
    title: PrivateDownloadClosePolicy.swift
  - id: task-156
    resource: backlog:TASK-156
    title: A Private window's download still running when the window closes is cancelled, after asking
  - id: transfer-tests
    resource: ../../DetourTests/PrivateDownloadTransferTests.swift
    title: PrivateDownloadTransferTests.swift (a real WKDownload against a slow loopback server)
  - id: close-tests
    resource: ../../DetourTests/PrivateDownloadClosePolicyTests.swift
    title: PrivateDownloadClosePolicyTests.swift (the rule, and the window's question)
---

# What it does

Files a page cannot display, responses sent as attachments, and links the user
chose to download are saved to `~/Downloads`. A download button in the
sidebar's bottom bar shows a badge while anything is in flight and opens a
popover listing downloads, newest first, with cancel, reveal in Finder, remove
and "clear completed". Finished and failed downloads survive a relaunch.

A [Private window](../architecture/incognito.md) has its own list: its
downloads appear only in its own popover and badge, are never saved, and leave
the list when the window closes. The files of finished downloads stay in
`~/Downloads`. A download still running when the window closes is cancelled
and its partial file removed; the window asks first.

# How it works

## What turns a navigation into a download

All of it is in `BrowserWindowController`'s navigation delegate:

| Where | Condition | Policy |
|---|---|---|
| `decidePolicyFor navigationAction` | `navigationAction.shouldPerformDownload` | `.download` |
| `decidePolicyFor navigationResponse` | `!navigationResponse.canShowMIMEType` | `.download` |
| same | `Content-Disposition` starts with `attachment` | `.download` |
| same | MIME type `application/x-chrome-extension`, or the URL's last path component ends in `.crx` | `.cancel`, then the CRX path below |

WebKit then calls `navigationAction(_:didBecome:)` or
`navigationResponse(_:didBecome:)`. Both set the `WKDownload`'s delegate to
`DownloadManager.shared`, call `handleNewDownload(_:sourceURL:scope:)` with
the window's `downloadScope` and trigger the animation.

The order inside the action policy matters. An **Option-click** on a link is
handled earlier (it opens the link in a split pane), and that branch must stay
before the `shouldPerformDownload` check: WebKit sets that flag for
Alt-clicked links, Safari's Option-click-downloads convention, which Detour
retires. The context menu's "Download Linked File" still downloads. See
[split tabs hosting](../tabs/split-tabs-hosting.md).

## DownloadManager

A singleton holding `items: [DownloadItem]`, newest first, with weak observers
through `DownloadManagerObserver` (add / update / remove), the same pattern as
`TabStoreObserver`. `items` holds every window's downloads; a window reads
its own through `items(in:)` (see [Private windows](#private-windows)). It is
also the `WKDownloadDelegate`:

- `decideDestinationUsing` picks `<downloadsDirectory>/<suggestedFilename>`
  (`downloadsDirectory` is the user's Downloads folder; a test with a real
  download points it at a temporary directory) and resolves a name clash as
  `name (1).ext`, `name (2).ext`, …; it then fills in the item's filename,
  destination and, when the response has a content length, `totalBytes`. For
  a download no listed item holds any more (cancelled, or dropped with its
  Private window, before WebKit asked) it returns nil, which cancels the
  download, so nothing untracked writes a file.
- `downloadDidFinish` and `didFailWithError` both call
  `downloadDidEnd(_:failure:)`, which sets `.completed` or `.failed(message)`.
  The `resumeData` WebKit offers is ignored: there is no resume.

`DownloadManager.shared` is built with `init(database:now:scheduler:)`: the
[session database](../architecture/session-database.md), a clock and the
function that schedules the debounced save. Tests pass an in-memory database,
a fixed clock and a scheduler they fire by hand, and end a manual item through
`downloadDidEnd` instead of a `WKDownload`.

A `DownloadItem` exposes `@Published` state, filename, byte counts and
`fractionCompleted`. For a `WKDownload` the numbers come from
`download.progress`; for a manual item they come from a `URLSessionTask`
(`observeURLSessionTask`, throttled to 100 ms). `totalBytes` is `-1` when
unknown, and the cell then shows an indeterminate bar.

## Persistence

`scheduleSave()` debounces one second, then writes every item that has ended
and whose scope is saved (`DownloadItem.isPersisted`) to the `download` table
of the [session database](../architecture/session-database.md). In-flight
downloads are never written, so there is nothing to resume after a relaunch,
and neither are a Private window's. On load, a
row whose state is anything other than `completed` or `cancelled` becomes
`.failed("Interrupted")`; a failure's own message is not persisted.
`removeDownload` and `clearCompleted(in:)` delete rows immediately.

- **Completion time.** `DownloadItem.completedAt` is set once, by
  `markCompleted(at:)`, when the download reaches `.completed`. Every save
  rewrites every finished item's row, and writes that stored time unchanged;
  `DownloadItem(record:)` loads it back. It is nil for a failed or cancelled
  download. Nothing in the UI shows it yet.
- **Quit inside the debounce.** `applicationWillTerminate` calls
  `flushPendingSave()`, which writes immediately when a debounced save is
  still waiting and does nothing otherwise. Without it a download that ended
  less than a second before quit was missing after the relaunch (TASK-143).

## Private windows

Every `DownloadItem` carries a `DownloadScope`, fixed when it is created:
`.normal`, or `.incognito(spaceID:)` for the Private window whose incognito
space has that id. The window supplies it
(`BrowserWindowController.downloadScope`) at the three places an item is
created. Three small functions on the scope hold the rules (TASK-148):

| Rule | Function | Result |
|---|---|---|
| Saved to the `download` table | `isPersisted` | `.normal` only. The debounced save and the termination flush both go through it; a Private state change does not even schedule a save. |
| Listed and badged in a window | `isListed(inWindowWith:)` | The scopes are equal. Normal windows share one list; each Private window sees only its own; a Private window does not list normal downloads. |
| Dropped when its window closes | `isOrphaned(liveIncognitoSpaceIDs:)` | A Private scope whose space no longer exists. |
| Cancelled when its window closes | `PrivateDownloadClosePolicy.cancels(downloadIn:isInFlight:closing:)` | A Private download still in flight, of the closing window, or of any Private window at quit. Never a normal download. |

`items(in:)`, `hasActiveDownloads(in:)` and `clearCompleted(in:)` apply the
listing rule, so "Clear" in one window never clears another's list, and
removing a Private item never touches the table.

**Window close.** `DownloadManager.shared` observes `TabStore.shared`
(`observeIncognitoSpaces(of:)`). `removeIncognitoSpace` sends
`tabStoreDidUpdateSpaces`, and the manager then drops every Private download
whose space is not among the store's incognito spaces
(`discardIncognitoDownloads(keeping:)`), reporting each as removed. One still
in flight is cancelled first (below).

### A download still running when the window closes

WebKit does not stop a download when the web view that started it goes away:
the `WKDownload` goes on transferring and writing for as long as something
retains it, on a non-persistent store too.[^task-156] Until TASK-156 the
manager kept such an item in an `unlistedItems` array, so a Private download
outlived its window with nothing to show it or stop it. The rule now is
Chrome's (`PrivateDownloadClosePolicy`, pure):

| Way the window goes | What happens |
|---|---|
| `performClose` (the close button, Close Window, Cmd+W with no tab selected) | `windowShouldClose` counts the window's in-flight downloads. None: it closes. Otherwise it asks "N downloads are in progress. Closing this Private window cancels them." Close Window cancels them (`cancelPrivateDownloads(closing: .window(scope))`) and closes; Continue Downloading keeps the window. |
| `close()` without the question (an extension's `windows.remove`) | Nobody is asked. `discardIncognitoDownloads` cancels what is in flight when the space goes. This is the backstop: every path that removes an incognito space ends here. |
| Quit | The quit confirmation adds "N downloads in Private windows are in progress and will be cancelled." Quit cancels them (`closing: .allWindows`) before the app terminates. |

Cancelling here also **removes the partial file**: WebKit leaves what a
cancelled `WKDownload` wrote where it wrote it.[^task-156] The file is
removed at once (at quit WebKit's reply to the cancel never arrives) and
again on that reply, for a file the network process created in between. Only
an in-flight `WKDownload` has a file to remove; a manual item (the CRX fetch)
has its `URLSessionTask` cancelled.

A normal download is never cancelled by a window closing: every normal window
lists it. The window's question is `confirmClosingWithPrivateDownloads`, a
closure whose default runs the alert, so tests answer it without a modal.

## Popover, badge, animation

- `TabSidebarViewController.downloadButton` asks the window controller to show
  `DownloadPopoverViewController` (320 × 300) anchored to the button. The
  popover is created with the window's scope and lists `items(in:)`.
- The popover and each `BrowserWindowController` observe the manager, which
  reports every window's downloads; each re-reads its own scope. The window
  only toggles the button's badge from `hasActiveDownloads(in:)`.
- The cell's single action button changes meaning with the state: cancel while
  downloading, reveal in Finder when completed, remove when failed or
  cancelled.
- `DownloadAnimation.animate(in:from:to:iconName:)` flies a 36 pt SF Symbol
  layer along a quadratic arc from the centre of the content area to the
  download button over 0.6 s, shrinking and fading. With the sidebar collapsed
  the destination is the fixed point `(20, 20)`.

## The CRX path

A `.crx` response is not a file download. `handleCRXDownload(from:)` adds a
**manual** item (`addManualItem`, with the window's scope) so the fetch is
visible in the list, fetches
the bytes itself with `URLSession` and a Chrome user agent, removes the item
when the fetch ends, and hands the data to the extension installer unless the
user cancelled the item meanwhile. Its animation uses the puzzle-piece symbol.
See [installer and CRX](../extensions/installer-and-crx.md).

# Edge cases

- **Only the window's delegate downloads.** A tab's own navigation delegate
  (the delegate of a web view no window has claimed yet) allows every action
  and implements neither the response policy nor the `didBecome` callbacks.
  Read from the code, not checked at runtime: a response that needs
  downloading in a never-shown background tab is not turned into a download
  until a window owns the tab.
- **Old `completedAt` values are save times.** Before TASK-143 every save
  wrote the current time into `completedAt` for every completed item, so a row
  written by an older build holds the time of its last save, not of the
  completion. Those values are loaded and kept as they are; the real time is
  not recoverable.
- **A download still running at quit is lost from the list.** The flush writes
  only finished, failed and cancelled items, as every save does.
- **An ordinary cancel leaves the partial file.** The popover's cancel button
  (`cancelDownload`) does not remove what was written; only the Private close
  and quit paths do.[^task-156]
- **A normal download still running at quit** is not cancelled or asked
  about: it ends with the process, its partial file stays, and it is lost
  from the list (next item).
- **An extension closing a Private window** (`windows.remove`) cancels that
  window's downloads without the question.
- **A CRX fetch from a Private window that closes** is cancelled with the
  window: it counts as a download in progress in the question, and no install
  prompt follows.
- **Cookies are another matter.** The Private profile's data store outlives a
  Private window ([incognito](../architecture/incognito.md)); only the
  download list is per window.
- **Clicking a completed row opens the file.** It is implemented in
  `tableView(_:shouldSelectRow:)`, which runs on a single click, although the
  code comment says double-click.
- **Stale destinations.** A persisted item keeps its path; reveal and open do
  not check that the file still exists.
- **The animation needs a layer-backed content view** and finite points; it
  returns silently otherwise, and when the download button has zero width.
- The destination directory is always the user's Downloads folder; there is
  no "ask where to save" setting.

# Tests

`DownloadManagerTests` covers the manager's persistence rules: the completion
time (set once, unchanged by later saves, carried across a relaunch, nil for
failed and cancelled items), the debounce (nothing written until it fires, one
save for a burst), the termination flush (writes a pending change, writes
nothing when none is pending) and that an in-flight download is never written.
For Private windows it covers the three scope rules as pure functions; that a
Private download leaves no row (debounced save, explicit save, termination
flush, relaunch) while a normal one next to it is saved; per-window lists,
badges and "Clear"; and, against a real `TabStore` on an in-memory database,
that `removeIncognitoSpace` drops the window's downloads, leaves other
windows' alone, and cancels one still in flight (a manual item's fetch
included); and which downloads `cancelPrivateDownloads` cancels for one window
and at quit.
`DownloadWindowScopeTests` checks the production wiring: a Private window's
`downloadScope`, and that closing it drops its download from
`DownloadManager.shared`.

`PrivateDownloadClosePolicyTests` covers the rule as pure functions (which
downloads a closing window or a quit cancels, when to ask, the wording), and
`PrivateDownloadCloseWindowTests` the window's `windowShouldClose` with the
question injected: no question with nothing in flight, declining keeps the
window and the download, going ahead cancels this window's downloads only, a
normal window never asks.

`PrivateDownloadTransferTests` uses a real `WKDownload` against a loopback
server that sends a large attachment slowly: WebKit keeps the download
running after its web view is gone and a cancel leaves the partial file (the
measurement), and closing a Private window stops the transfer and removes the
file.

Not covered by tests: `downloadDidFinish` and `didFailWithError` with a real
`WKDownload`, the one-line call in `applicationWillTerminate`, the quit
confirmation's cancel in `applicationShouldTerminate`, the alert itself, the
scope the CRX creation site passes, the popover, the animation and most of
the download policy branches. Unpacking and verifying a CRX have
their own suites (see [testing extensions](../extensions/testing-extensions.md));
the interception in `handleCRXDownload` does not.

# Related

- [BrowserWindowController](../architecture/browser-window-controller.md) - owns the navigation delegate that decides the policy.
- [Session database](../architecture/session-database.md) - the `download` table.
- [Incognito](../architecture/incognito.md) - what else a Private window does not keep.
- [Installer and CRX](../extensions/installer-and-crx.md) - what happens to an intercepted `.crx`.
- [Sidebar overview](../sidebar/overview.md) - the bottom bar that holds the download button.
- [External apps](./external-apps.md) - the sibling branch of the same policy function, for non-web schemes.

[^task-156]: A Private window's download still running when the window closes is cancelled, after asking
