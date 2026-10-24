---
type: Platform Quirk
title: WKWebView snapshots on macOS
description: What WKWebView.takeSnapshot really captures on macOS — a software paint at the device scale, clipped to the visible viewport whatever rect is asked for — how a whole-document capture is made instead (the private _usesContentsRect, or createPDF rasterised), what each does with fixed, sticky, filtered and GPU content, and the NSImage size quirks that decide how to get device pixels out.
tags: [webkit, snapshot, retina, dev-mode, private-api]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-24T21:45:00Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: wkwebview
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm
    title: WKWebView.mm (takeSnapshotWithConfiguration, createPDFWithConfiguration)
  - id: config-private
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKSnapshotConfigurationPrivate.h
    title: WKSnapshotConfigurationPrivate.h (_usesContentsRect, macOS 15.0)
  - id: webpage
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/WebPage.cpp
    title: WebPage.cpp (preSnapshotSetup, takeSnapshot, paintSnapshotAtSize)
  - id: webpage-cocoa
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/Cocoa/WebPageCocoa.mm
    title: WebPageCocoa.mm (drawToPDF)
  - id: frameview
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/LocalFrameView.cpp
    title: LocalFrameView.cpp (paintContentsForSnapshot)
  - id: capture
    resource: ../../Detour/Browser/DevMode/PageCapture.swift
    title: PageCapture.swift (PageCapture, CaptureImage, CaptureDelivery)
  - id: geometry
    resource: ../../Detour/Browser/DevMode/PageCaptureGeometry.swift
    title: PageCaptureGeometry.swift (CaptureGeometry, CaptureFileName)
  - id: tests
    resource: ../../DetourTests/PageCaptureTests.swift
    title: PageCaptureTests.swift
  - id: harness
    resource: ../../docs/harness/task186-3-harness.patch
    title: TASK-186.3 runtime harness
  - id: task-186-3
    resource: backlog:TASK-186.3
    title: "Dev mode: capture buttons in the dev toolbar"
---

The dev toolbar's capture buttons ([dev mode](../features/dev-mode.md#captures))
needed a picture of the visible page and of the whole page, at device pixels.
`WKWebView.takeSnapshot` does the first; on macOS it cannot do the second
with a public rect. Found with a standalone spike (a `WKWebView` in a window,
a 5320 px page of coloured bands with a fixed header, a sticky bar, a canvas,
a blurred box and a bottom marker, scrolled to 2000) and the WebKit source,
then confirmed in Detour at 2x.[^task-186-3][^harness]

# Behavior

## takeSnapshot on macOS is a software paint of the viewport

On AppKit WebKit asks the page's process to paint (`WebPage::takeSnapshot`,
`SnapshotOption::InViewCoordinates`); `afterScreenUpdates` is ignored. The
bitmap is `rect` x `snapshotWidth / rect.width` x the page's device scale
(the window's backing scale, or `_overrideDeviceScaleFactor`).[^wkwebview]

- **Only the viewport is painted.** In view coordinates
  `paintContentsForSnapshot` paints the frame view itself rather than its
  document ("the snapshot will contain whatever content the document is
  currently scrolled to").[^frameview] A rect of `(0, -scrollY, docWidth,
  docHeight)` returns an image of the full size that is blank (the page's
  background) everywhere but the part that was on screen. Measured: 1000 x
  5320 at scroll 2000 → rows 2000-2699 painted, the rest white.
- **WebGL and video are missing**: WebKit's own comment says the software
  snapshot does not capture hardware-accelerated content. A 2D canvas is
  captured.
- **The web view's bounds exclude its siblings.** In Detour the dev toolbar
  and a docked Web Inspector are siblings of the web view in the tab's
  container, so `rect = webView.bounds` gives the page alone (checked with
  the inspector docked: 1172 x 330 pt → 2344 x 660 px, no inspector).[^harness]

## Whole-document captures

| | `_usesContentsRect` (private) | `createPDF`, rasterised |
|---|---|---|
| API | `-[WKSnapshotConfiguration _setUsesContentsRect:]`, macOS 15.0+ (setter only: KVC on `_usesContentsRect` throws) | Public, macOS 11+ |
| What WebKit does | `SnapshotOption::FullContentRect`: rect = the frame view's whole contents size, layout viewport overridden to it, painted in document coordinates[^webpage] | `drawToPDF`: the contents size, viewport overridden the same way, into a PDF context[^webpage-cocoa] |
| Size | Always contents size x device scale: `snapshotWidth` is ignored, so it cannot be capped | Any scale: draw the page into a bitmap of the size you choose |
| Fidelity | The same paint as the visible snapshot | Vector text and shapes, but CSS `filter` (a `blur(2px)` box) is dropped; shadows survive |
| Fixed elements | Laid out against the whole document: a `top: 0` header appears once at the top | The same |
| Sticky elements | At their place in the flow, as at scroll 0 | The same |
| Scroll position | Unchanged after | Unchanged after |

Neither scrolls the page or stitches tiles. Detour uses `_usesContentsRect`
while the raw image (contents x device scale) stays within 2^26 px, and
scales it down to its caps afterwards; above that, or if the selector is
missing, it rasterises the PDF straight at the capped size
(`CaptureGeometry.fullPageMethod`).[^geometry]

## Getting device pixels out

- **Visible capture:** the `NSImage` is sized in **points** (1000 x 700 at
  2x) and its one representation (`NSCGImageSnapshotRep`) reports
  `pixelsWide` 1000, but `cgImage(forProposedRect: nil, context: nil,
  hints: nil)` returns the 2000 x 1400 bitmap. Encoding `tiffRepresentation`
  or a rep built from the image size would resample to 1x.
- **`_usesContentsRect`:** WebKit sizes the `NSImage` in **pixels** (2000 x
  10640 for a 1000 x 5320 pt page at 2x), so `image.size` is not points
  either. Detour reads the `CGImage` in both cases and works out the scale
  from the page's metrics.
- `window.devicePixelRatio` is the device scale x the page zoom (and the
  pinch scale); dividing by `pageZoom` gives the scale the snapshot uses.
  `document.documentElement.scrollWidth/Height` are CSS pixels; points are
  CSS pixels x `pageZoom`.
- Write the PNG with `CGImageDestination` and `kCGImagePropertyDPIWidth/Height`
  = 72 x pixels per point (144 at 2x), so Preview and paste targets show it
  at the page's size.

## Testing at 2x on a 1x display

`-[WKWebView _setOverrideDeviceScaleFactor:]` makes WebKit render and
snapshot at that scale in any window (`PageCaptureWebViewTests` use it; a
setter only, call it through its IMP). For the whole app, the TASK-110
virtual display (`docs/task-110/vdisplay.m`) adds a 1600 x 1000 pt @2x
screen; move the window onto it.

# Gotchas

- `WebPage::drawToPDF` returns without calling its completion handler when
  the page has no local main frame, so a `createPDF` call can go unanswered;
  `PageCapture` fails after a 60 s timeout instead of hanging.
- A page that scrolls an inner element (`html, body { height: 100%;
  overflow: hidden }` with a scrolling `div`) has a contents size equal to
  the viewport, so its "full page" is the visible area.
- An XCTest that is `async` and calls `wait(for:)` blocks the main actor:
  the web view never finishes loading. Keep web view tests synchronous and
  wait on expectations.

[^task-186-3]: Dev mode: capture buttons in the dev toolbar
[^harness]: TASK-186.3 runtime harness
[^wkwebview]: WKWebView.mm (takeSnapshotWithConfiguration, createPDFWithConfiguration)
[^frameview]: LocalFrameView.cpp (paintContentsForSnapshot)
[^webpage]: WebPage.cpp (preSnapshotSetup, takeSnapshot, paintSnapshotAtSize)
[^webpage-cocoa]: WebPageCocoa.mm (drawToPDF)
[^geometry]: PageCaptureGeometry.swift (CaptureGeometry, CaptureFileName)
