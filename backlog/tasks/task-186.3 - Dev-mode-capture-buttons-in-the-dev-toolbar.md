---
id: TASK-186.3
title: 'Dev mode: capture buttons in the dev toolbar'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:13'
updated_date: '2026-10-24 22:37'
labels:
  - dev-mode
  - feature
dependencies:
  - TASK-186.2
parent_task_id: TASK-186
priority: low
ordinal: 211000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Third part of TASK-186. Arc's toolbar has image capture buttons (see docs/dev-mode/arc-dev-toolbar.png). Proposed: capture the visible page and capture the full page, using WKWebView.takeSnapshot (full page needs the page's scroll size, or WKSnapshotConfiguration with a rect), to the clipboard and/or a file in Downloads with a toast. Decide which captures and where they go; an area-selection capture is optional.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The chosen capture buttons produce a correct image of the visible page (and full page, if chosen), delivered where decided
- [x] #2 Works in a split pane and on a Retina display at the right scale
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-24): two buttons, visible area and full page; the PNG goes to the clipboard with a confirming toast; Option-click saves it to Downloads instead.

Built (2026-10-24, Opus subagent): PageCaptureGeometry.swift (pure pixel math, caps, method choice, file naming), PageCapture.swift (snapshot, PNG encode via CGImageDestination at 72 x pixels-per-point dpi, scaling, PDF rasterising, clipboard, save), DevToolbarCaptureGroup.swift (camera = visible area, rectangle.expand.vertical = full page; order link | capture | inspector). Click copies PNG (public.png plus a lazily provided TIFF); Option-click saves to DownloadManager.shared.downloadsDirectory as 'Screenshot <host-port> <yyyy-MM-dd> at <HH.mm.ss>[ (full page)].png', never overwriting (' (2)'). Toasts: 'Screenshot copied', 'Full-page screenshot copied', 'Saved “name” to folder', errors; '(scaled down)' when capped. Buttons busy while a capture is in flight; 60 s timeout (WebKit's PDF call can never answer).

Findings (wiki/platform/wkwebview-snapshots.md): on macOS a WKSnapshotConfiguration rect larger than the view paints only the viewport (rest blank); afterScreenUpdates is ignored. Full page uses private _setUsesContentsRect: (macOS 15+, setter via method pointer, KVC throws; always device scale, ignores snapshotWidth) while the raw image is <= 2^26 px, then scales to the caps; above that or without the selector, createPDF rasterised at the capped size (public, but drops CSS filter). Snapshots are a software paint: no WebGL or video. Fixed headers appear once at the top, sticky elements at their place; scroll position unchanged. Caps: 16384 px long edge (GPU texture limit and paste-target limit), 2^26 px area. Scale: visible NSImage is sized in points with a rep reporting 1x, but cgImage(forProposedRect:) gives the real 2x bitmap; the private full-page NSImage is sized in pixels; scale = devicePixelRatio / pageZoom from an isolated world.

Runtime-found fixes: the toast sat over the capture buttons (now drops below a dev toolbar under it, shared devToolbarCovers(_:) with the find bar); separators stretched to 473 pt with two groups (fixed 1 pt width, also affects 186.4's group).

TDD: 36 tests, red 29 failed / 7 passed (3 UI group tests not test-first, 4 stub defaults that happened to match), green 36/36; separator test red 4 -> green.

/code-review --fix: 8 findings, 5 fixed: toast inset now checks the toast's real frame (a wide 'Saved' toast could cover the left pane's buttons in a split); save moved off the main thread to a serial queue (buttons stay disabled until written, no name race); timestamp taken at click time; single background trip for scale/rasterise + encode; shared devToolbarCovers. Skipped: sharing DownloadManager's ' (n)' loop (would renumber downloads), TIFF promise possibly being filled at quit for a huge capture (minor quit delay, unverified), the single static TIFF provider slot (only matters across pasteboards; production uses the general one).

Tests after review: 201/201 (PageCaptureGeometryTests, PageCaptureImageTests, PageCaptureWebViewTests, DevToolbarCaptureGroupTests, DevToolbarHostingTests, DevToolbarLayoutTests, WebInspectorControlTests, DevModeTests, DevModeSiteOverrideTests, SplitTabTests); unit tests run real web views at 2x via _overrideDeviceScaleFactor.

Runtime (docs/harness/task186-3-harness.patch on the TASK-110 virtual 2x display, this machine's monitor is 1x; final run after the review with the screen unlocked; a run started while locked was discarded): visible capture scrolled to 1000 = 2344x1660 px at 144 dpi (1172x830 pt x 2), matching the window capture; full page scrolled to 2400 = 2344x10640 px with every band and the bottom marker, scrollY unchanged; Option-click wrote to the seam folder with ' (2)' for a same-second repeat and '(full page)', pasteboard untouched; split: the unfocused pane's button captured only that pane; docked inspector open: visible capture is page only (no inspector, no toolbar), full page still whole; toasts legible below the toolbar in light and dark. ~/Downloads untouched; no new __WebInspector default. Not verified at runtime: the error toast, the PDF fallback path (unit-tested by forcing it), a page tall enough to be scaled down, a real keyboard Option-click.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Dev toolbar capture buttons: visible area and full page as a device-scale PNG to the clipboard (Option-click saves to Downloads), with toasts. Full page uses WebKit's private contents-rect snapshot with a createPDF fallback, capped at 16384 px. 201 tests pass; runtime harness at 2x clean after review.
<!-- SECTION:FINAL_SUMMARY:END -->
