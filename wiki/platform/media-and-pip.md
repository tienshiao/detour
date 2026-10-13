---
type: Platform Quirk
title: Media and picture-in-picture
description: WebKit media behaviour Detour has to accommodate — picture-in-picture needs the video's view on screen to start and to return, a standalone video URL ends its navigation with error 204, and audio and capture state gate sleeping and GPU process recycling.
tags: [webkit, media, picture-in-picture, navigation, tabs]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-13T06:19:15Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-79
    resource: backlog:TASK-79
    title: Closing a tab with a playing video starts picture-in-picture that vanishes mid-transition
  - id: task-121
    resource: backlog:TASK-121
    title: A standalone video URL shows the error page with "Plug-in handled load"
  - id: task-122
    resource: backlog:TASK-122
    title: A background tab whose load fails never shows the error page
  - id: task-105
    resource: backlog:TASK-105
    title: GPU-process recycle valve
  - id: browser-tab
    resource: ../../Detour/Browser/BrowserTab.swift
    title: BrowserTab.swift
  - id: window-controller
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.swift
  - id: ui-delegate
    resource: ../../Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
    title: BrowserWindowController+WKUIDelegate.swift
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift
  - id: classification-tests
    resource: ../../DetourTests/NavigationErrorClassificationTests.swift
    title: NavigationErrorClassificationTests.swift
---

Two WebKit media behaviours have caused bugs, and both come from the same
fact: WebKit's media machinery assumes the web view stays alive and, for
picture-in-picture (PiP), stays in a window at the moments that matter.
Detour hides, re-parents and releases web views constantly, so it has to
arrange those moments by hand.

# Behavior

## Picture-in-picture

- **PiP has to be switched on.** Detour enables it with the private C
  function `WKPreferencesSetAllowsPictureInPictureMediaPlayback`, declared in
  [BrowserTab.swift](../../Detour/Browser/BrowserTab.swift) with
  `@_silgen_name` and called from `makeWebView(configuration:)`. The sources
  do not record what happens without it.
- **Entering PiP is a page-side call.** `BrowserTab.enterPictureInPicture()`
  evaluates script that finds the first playing `<video>` supporting the
  mode and calls `webkitSetPresentationMode('picture-in-picture')`. It walks
  into iframes through `contentDocument`, so a video in a cross-origin
  iframe is not reached.
- **WebKit needs the video on screen to start the animation.** It captures
  the video's on-screen frame as the animation origin, so the view must stay
  in the window for a moment after PiP is requested.
- **The PiP window dies with the web view.** Releasing the web view (a tab
  closing, sleeping, being torn down) ends PiP immediately.[^task-79]
- **"Return to window" is a two-step handshake.** WebKit's PiP controller
  asks the UI delegate through the private method
  `_webViewFullscreenMayReturnToInline:` and queues an exit-PiP request that
  only fires once the document is visible again. If the app does not put the
  web view back in a window, the video never returns inline.

## Standalone media URLs

Opening a bare media URL (an `.mp4`, for example) makes WebKit render a media
document. Once the media player takes over fetching the resource, WebKit
cancels the main-resource load and reports it through
`webView(_:didFail:withError:)` as `WebKitErrorDomain` code 204
(`WebKitErrorPlugInWillHandleLoad`, message "Plug-in handled load"). The
document is committed and keeps playing. No `didFinish` follows.[^task-121]

In WebKit's source this is `WebLocalFrameLoaderClient::committedLoad`
cancelling with `pluginWillHandleLoadError`; WebKit's own fallback logic
treats it like a cancellation.[^task-121]

## Audio and capture state

- "Is this tab audible" comes from KVO on the private key `_isPlayingAudio`
  of the web view, mirrored into `BrowserTab.isPlayingAudio`.
- Camera and microphone capture run in WebKit's GPU process, not the page's
  web process.[^task-105] `WKWebView.cameraCaptureState` and
  `microphoneCaptureState` are public; screen-share capture has no public
  state.

# Why it matters here

## Closing a playing tab started PiP that vanished

`selectTab` starts PiP for the tab being switched away from when it is
playing audio. The close paths settle selection onto a neighbour *before*
removing the tab (so the removal observer sees selection already settled).
`selectTab` therefore saw a still-playing tab being left and entered PiP; a
moment later the store's teardown paused media and released the web view,
killing the PiP window mid-animation.[^task-79]

## A video URL showed the error page — but only in a selected tab

The window's navigation delegate forwarded every failure it did not ignore
to the tab, which loaded the [error page](../features/error-pages.md). The
ignored set had 102 and `NSURLErrorCancelled` but not 204, so the video
played for about a second and was then replaced by "Plug-in handled load".
Measured: the web view's URL became the `browser-error:` page within 4 s of
the load, and again after a reload.[^task-121]

It looked window-dependent because, at the time, a tab that no window had
claimed had no failure handlers at all: the same URL loaded in the
background played fine and broke once the tab was selected.[^task-121][^task-122]

# Workaround

## PiP

| Need | What the code does |
|---|---|
| Start PiP when switching away from a playing tab | `selectTab` calls `enterPictureInPicture()` on the outgoing tab (and on its playing Peek, before the Peek UI is hidden) when `isPlayingAudio` is true |
| Keep the video on screen long enough to capture | The outgoing container is remembered in `pipContentView`; `removeContentViews()` leaves it parented and removes it 0.5 s later. For a split, the PiP pane is re-parented as a direct subview at its on-screen frame with its autoresizing mask cleared, so a window resize during the hold cannot move it off the captured frame |
| Do not rip out a tab re-selected inside that 0.5 s | The delayed cleanup checks whether the view is now the selected tab's container and only drops the stale reference |
| Do not start PiP for a tab that is being closed | `settlingSelectionForClose { … }` sets `selectionLeavesClosingTab`; `selectTab` skips both PiP entries (tab and Peek) while it is set. Used by `closeTab(at:wasSelected:)`, `closePinnedTab(at:)` and the close-split-group handler |
| Still start PiP when a tab moves to another space | Move-to-space settles selection through the same helpers but is deliberately **not** wrapped: the tab stays alive |
| Bring the video back on "Return to window" | `_webViewFullscreenMayReturnToInline(_:)` finds the tab (or Peek host) that owns the web view among space tabs, pinned entries' and favourites' backing tabs, switches to its space, selects it and activates the window. Selecting claims the web view, which makes the document visible and lets WebKit's queued exit run |
| Leave PiP when the user comes back themselves | `selectTab` calls `exitPictureInPicture()` on the incoming tab and its Peek |
| Keyboard focus while the outgoing page is still parented | `isKeyboardFocusUnheld` treats focus inside `pipContentView` as held by nobody, so the incoming page gets it — see [keyboard focus](../sidebar/keyboard-focus.md) |

Removal paths that select *after* the store has torn the tab down (an
extension's `tabs.remove`, "back closes a child tab") never entered PiP,
because teardown has already cleared `isPlayingAudio` and the web
view.[^task-79]

## Media documents

The error classification lives in `extension Error` in
[BrowserWindowController+Navigation.swift](../../Detour/Browser/Window/BrowserWindowController+Navigation.swift):

| Predicate | Matches | Meaning |
|---|---|---|
| `isSupersededNavigationError` | `WebKitErrorDomain` 102, `NSURLErrorCancelled` | Another callback will follow for the load that replaced this one |
| `isPlugInHandledLoadError` | `WebKitErrorDomain` 204 | The page is showing fine, and this **is** the end of the navigation |
| `isIgnoredNavigationError` | either | Do not show an error page |

The distinction matters to anything that waits for a navigation to end.
`BrowserTab.didFailProvisionalNavigation(error:)` uses
`isIgnoredNavigationError`. A tab no longer acts on a failure after commit at
all (see [error pages](../features/error-pages.md)), which is where the 204
arrives.
`OffscreenDocumentHost.failLoad` uses `isSupersededNavigationError` alone: for
an [offscreen document](../extensions/offscreen-documents.md) a 204 must
settle `createDocument` as a failure, because no `didFinish` will ever
arrive and waiting on one would hang the call.[^task-121]

## Audio and capture as gates

- `TabStore.sleepStaleTabs` never sleeps a tab that is playing audio;
  `BrowserTab.sleep(force:)` refuses unless forced, and a forced sleep pauses
  media first — see [sleeping and archiving](../tabs/sleeping-and-archiving.md).
- `teardown()` and `retarget(to:)` call `pauseAllMediaPlayback` before
  releasing the web view.
- The [GPU process recycler](./gpu-iosurface-limit.md) will not kill the GPU
  process while any tab plays audio or captures camera or microphone, since
  a recycle cuts media off.

# Tests and what is not verified

- [NavigationErrorClassificationTests](../../DetourTests/NavigationErrorClassificationTests.swift)
  pins the three predicates, including code 204 in another domain not being
  ignored.
- The 204 fix was checked in a running Debug build: the video tab's URL stays
  on `https://` through load and reload.[^task-121]
- The close-without-PiP fix has no automated test, and the PiP transition
  itself was not observed at runtime when it was made; it was verified by
  reading the code paths and building.[^task-79]

# Related

- [Tab lifecycle](../tabs/tab-lifecycle.md) — the close paths that settle selection before removing a tab.
- [Peek](../tabs/peek.md) — a playing Peek enters PiP with its host.
- [Split tabs hosting](../tabs/split-tabs-hosting.md) — how a split pane is dismantled and why the PiP pane is special-cased.
- [Web view ownership](../architecture/webview-ownership.md) — claiming a web view is what makes its document visible again.
- [Error pages](../features/error-pages.md) — what a non-ignored failure turns into.
- [WKWebView delegate order](./wkwebview-delegate-order.md) — the other failure callbacks and what each means.
- [Offscreen documents](../extensions/offscreen-documents.md) — the caller that needs "will another callback follow?".
- [GPU IOSurface limit](./gpu-iosurface-limit.md) — the recycler's media gate.
- [WebKit source lookup](./webkit-source-lookup.md) — where `committedLoad` lives.

[^task-79]: Closing a tab with a playing video starts picture-in-picture that vanishes mid-transition
[^task-121]: A standalone video URL shows the error page with "Plug-in handled load"
[^task-122]: A background tab whose load fails never shows the error page
[^task-105]: GPU-process recycle valve
