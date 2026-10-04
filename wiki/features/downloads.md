---
type: Feature
title: Downloads
description: "How a navigation becomes a download, what DownloadManager tracks and persists, the sidebar popover and badge, the fly-to-button animation, and the CRX path that reuses the list."
tags: [downloads, webkit, navigation, persistence]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:42:36Z }
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
---

# What it does

Files a page cannot display, responses sent as attachments, and links the user
chose to download are saved to `~/Downloads`. A download button in the
sidebar's bottom bar shows a badge while anything is in flight and opens a
popover listing downloads, newest first, with cancel, reveal in Finder, remove
and "clear completed". Finished and failed downloads survive a relaunch.

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
`DownloadManager.shared`, call `handleNewDownload(_:sourceURL:)` and trigger
the animation.

The order inside the action policy matters. An **Option-click** on a link is
handled earlier (it opens the link in a split pane), and that branch must stay
before the `shouldPerformDownload` check: WebKit sets that flag for
Alt-clicked links, Safari's Option-click-downloads convention, which Detour
retires. The context menu's "Download Linked File" still downloads. See
[split tabs hosting](../tabs/split-tabs-hosting.md).

## DownloadManager

A singleton holding `items: [DownloadItem]`, newest first, with weak observers
through `DownloadManagerObserver` (add / update / remove), the same pattern as
`TabStoreObserver`. It is also the `WKDownloadDelegate`:

- `decideDestinationUsing` picks `~/Downloads/<suggestedFilename>` and resolves
  a name clash as `name (1).ext`, `name (2).ext`, …; it then fills in the
  item's filename, destination and, when the response has a content length,
  `totalBytes`.
- `downloadDidFinish` sets `.completed`; `didFailWithError` sets
  `.failed(message)`. The `resumeData` WebKit offers is ignored: there is no
  resume.

A `DownloadItem` exposes `@Published` state, filename, byte counts and
`fractionCompleted`. For a `WKDownload` the numbers come from
`download.progress`; for a manual item they come from a `URLSessionTask`
(`observeURLSessionTask`, throttled to 100 ms). `totalBytes` is `-1` when
unknown, and the cell then shows an indeterminate bar.

## Persistence

`scheduleSave()` debounces one second, then writes every item that is **not**
downloading to the `download` table of the
[session database](../architecture/session-database.md). In-flight downloads
are never written, so there is nothing to resume after a relaunch. On load, a
row whose state is anything other than `completed` or `cancelled` becomes
`.failed("Interrupted")`; a failure's own message is not persisted.
`removeDownload` and `clearCompleted` delete rows immediately.

## Popover, badge, animation

- `TabSidebarViewController.downloadButton` asks the window controller to show
  `DownloadPopoverViewController` (320 × 300) anchored to the button.
- The popover and each `BrowserWindowController` observe the manager. The
  window only toggles the button's badge from `hasActiveDownloads`.
- The cell's single action button changes meaning with the state: cancel while
  downloading, reveal in Finder when completed, remove when failed or
  cancelled.
- `DownloadAnimation.animate(in:from:to:iconName:)` flies a 36 pt SF Symbol
  layer along a quadratic arc from the centre of the content area to the
  download button over 0.6 s, shrinking and fading. With the sidebar collapsed
  the destination is the fixed point `(20, 20)`.

## The CRX path

A `.crx` response is not a file download. `handleCRXDownload(from:)` adds a
**manual** item (`addManualItem`) so the fetch is visible in the list, fetches
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
- **`completedAt` is not a completion time.** `saveNow` writes `Date()` into
  `completedAt` for every completed item on every save, so the column holds
  the time of the last save. Nothing reads it.
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

There are no unit tests for `DownloadManager`, the popover, the animation or
the download policy branches. Unpacking and verifying a CRX have their own
suites (see [testing extensions](../extensions/testing-extensions.md)); the
interception in `handleCRXDownload` does not.

# Related

- [BrowserWindowController](../architecture/browser-window-controller.md) - owns the navigation delegate that decides the policy.
- [Session database](../architecture/session-database.md) - the `download` table.
- [Installer and CRX](../extensions/installer-and-crx.md) - what happens to an intercepted `.crx`.
- [Sidebar overview](../sidebar/overview.md) - the bottom bar that holds the download button.
- [External apps](./external-apps.md) - the sibling branch of the same policy function, for non-web schemes.
