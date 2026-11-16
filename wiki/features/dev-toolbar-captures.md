---
type: Feature
title: Dev toolbar captures
description: "The dev toolbar's two capture buttons (TASK-186.3): the visible area and the full page as a PNG on the clipboard (with a TIFF made on demand) or, with Option, saved to Downloads under a never-overwriting name; the 16384 px edge and 2^26 px caps, the choice between WebKit's whole-document snapshot and a rasterised PDF, busy and failure states, the test seams, and the toast moving below the toolbar."
tags: [dev-mode, capture, webkit, clipboard]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:39:04Z }
sources:
  - id: capture-group
    resource: ../../Detour/Browser/DevMode/DevToolbarCaptureGroup.swift
    title: DevToolbarCaptureGroup.swift
  - id: page-capture
    resource: ../../Detour/Browser/DevMode/PageCapture.swift
    title: PageCapture.swift (PageCapture, CaptureImage, CaptureDelivery)
  - id: capture-geometry
    resource: ../../Detour/Browser/DevMode/PageCaptureGeometry.swift
    title: PageCaptureGeometry.swift (CaptureGeometry, CaptureFileName)
  - id: window-toolbar
    resource: ../../Detour/Browser/Window/BrowserWindowController+DevToolbar.swift
    title: BrowserWindowController+DevToolbar.swift (capturePage, the toasts)
  - id: capture-tests
    resource: ../../DetourTests/PageCaptureTests.swift
    title: PageCaptureTests.swift
  - id: harness-1863
    resource: ../../docs/harness/task186-3-harness.patch
    title: TASK-186.3 runtime harness
  - id: task-186-3
    resource: backlog:TASK-186.3
    title: "Dev mode: capture buttons in the dev toolbar"
  - resource: ../platform/wkwebview-snapshots.md
    title: WKWebView snapshots on macOS (the methods and their limits)
  - resource: ./dev-toolbar.md
    title: Dev toolbar (the bar the buttons sit in)
---

The [dev toolbar](./dev-toolbar.md)'s capture group has two buttons:
Capture Visible Area (`camera`) and Capture Full Page
(`rectangle.expand.vertical`).[^capture-group] Each takes a picture of its
own pane's page at device pixels and puts it on the clipboard, or saves it
to Downloads.

# What it does

TASK-186.3.[^task-186-3] Decisions (user): two buttons, the visible area and
the full page; a click puts a PNG on the clipboard with a toast
("Screenshot copied", "Full-page screenshot copied"); an Option-click saves
it to Downloads instead, with a toast naming the file; no area selection.
The toast has no action, so there is no "Show in Finder". In a split the
buttons focus their pane but capture their own pane's web view either way.

| | Visible area | Full page |
|---|---|---|
| What | `takeSnapshot` of the pane's web view `bounds`: the page only, never the toolbar or a docked inspector (siblings in the container) | The whole document, wherever it is scrolled; the page is not scrolled |
| How | Public API | WebKit's private whole-document snapshot (`_usesContentsRect`) while the raw image is at most 2^26 px, then scaled down to the caps; above that, or when this WebKit lacks the private snapshot, `createPDF` rasterised at the capped size |
| Size | Web view points x the device scale (1172 x 830 pt at 2x → 2344 x 1660 px) | Document points x the device scale, scaled down to at most 16384 px on the long edge and 2^26 px in all; the toast then says "(scaled down)" |

Why the full page cannot be a big snapshot rect, what each method does with
fixed, sticky, filtered and GPU content, and how device pixels are read out
of the snapshot are on [WKWebView snapshots](../platform/wkwebview-snapshots.md).[^page-capture]

# How it works

- **Pixel math** is the pure `CaptureGeometry` (`pixelSize(points:scale:)`
  with the caps, `fullPageMethod`, `documentPoints`, `dpi`).[^capture-geometry]
  The scale comes from the page: `devicePixelRatio / pageZoom`. The PNG
  records 72 dpi per pixel per point (144 at 2x), so it previews at the
  page's size. 16384 px is the texture limit of most GPUs and about the
  largest image paste targets accept unshrunk; 2^26 px is 256 MB of RGBA,
  which the page's process paints and the app copies and encodes. PNG
  encoding, scaling and PDF rasterising run off the main thread.
- **Clipboard:** a pasteboard item with `public.png`, plus `public.tiff`
  made on demand (from the PNG, LZW, same DPI) by an
  `NSPasteboardItemDataProvider`, for apps that read only TIFF; a TIFF of a
  tall page is tens of MB, so it is not made unless asked for.
- **File:** `CaptureFileName.make`: "Screenshot localhost-3000 2026-10-24 at
  21.05.03.png", "... (full page).png" (the host line with `:` and `/` as
  `-`, since Finder shows a colon as a slash; no host, no host part); the
  time is the click's, not the end of a slow capture. Then
  `unique`, which adds " (2)", " (3)" so nothing is overwritten (two captures
  in one second), and the write is `.withoutOverwriting`, on one serial
  queue off the main thread. The folder is
  `DownloadManager.shared.downloadsDirectory` (the user's Downloads; no
  setting chooses another). The toast names the file and the folder.
- **Busy and failure:** both buttons of the pane are disabled while its
  capture is in flight (a visible capture takes under 0.1 s, a 5320 pt page
  at 2x about 2.5 s with encoding). A web view with no page, a failed
  snapshot or PDF, or no answer within 60 s shows "Couldn't capture the
  page"; a failed write "Couldn't save the screenshot".[^window-toolbar]
- **Seams:** the window's `capturePasteboard` and `captureSaveDirectory`, and
  the group's `modifierFlags`, so tests and the harness never touch the
  user's clipboard or Downloads.
- **The toast moves below the toolbar.** It sits at the content area's top
  right, over the capture buttons when the pane there shows a toolbar; the
  window's `toastTopInset()` puts it 30 pt lower then (the same geometric
  test as the find bar, see [dev toolbar](./dev-toolbar.md#snapshots-the-find-bar-and-the-toast)),
  so it never covers the button just pressed.

# Tests

`PageCaptureGeometryTests` (pure), `PageCaptureImageTests` (PNG, PDF,
pasteboard, files), `PageCaptureWebViewTests` (real web views at 2x through
`_overrideDeviceScaleFactor`: visible, full page by both methods, no page)
and `DevToolbarCaptureGroupTests`, 37 tests in all.[^capture-tests] Runtime:
on a 2x virtual display, single tab, split, docked inspector, light and
dark.[^harness-1863]

# Related

- [Dev toolbar](./dev-toolbar.md) — the bar the buttons sit in, and its other controls.
- [WKWebView snapshots on macOS](../platform/wkwebview-snapshots.md) — the snapshot and PDF methods, and their limits.
- [Dev mode](./dev-mode.md) — which pages get the toolbar; the host line the file name reuses.
- [Downloads](./downloads.md) — `DownloadManager`, whose folder a saved capture goes to.

[^capture-group]: DevToolbarCaptureGroup.swift
[^task-186-3]: Dev mode: capture buttons in the dev toolbar
[^page-capture]: PageCapture.swift (PageCapture, CaptureImage, CaptureDelivery)
[^capture-geometry]: PageCaptureGeometry.swift (CaptureGeometry, CaptureFileName)
[^window-toolbar]: BrowserWindowController+DevToolbar.swift (capturePage, the toasts)
[^capture-tests]: PageCaptureTests.swift
[^harness-1863]: TASK-186.3 runtime harness
