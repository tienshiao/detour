---
type: Platform Quirk
title: WebKit's back swipe and unhandled scrolls
description: WKWebView's two-finger back swipe starts only when the back list has an item, no SPI makes it target anything else, and the one signal that a scroll went unused by the page (the private _webView:didNotHandleWheelEvent:) arrives only while the view's own back/forward gesture is off and left-edge rubber-banding is excluded — measured with a spike on macOS 26.7 for TASK-325.
tags: [webkit, gestures, navigation, scrolling, spi]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:59:26Z }
stale_after: 2027-05-01T00:00:00Z
sources:
  - id: spike
    resource: ../../docs/harness/task325-wheel-spike.swift
    title: TASK-325 wheel-event spike (results in its header)
  - id: task-325
    resource: backlog:TASK-325
    title: The back swipe on a tab opened from another tab closes it and returns to the opener
  - id: vgc
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/ViewGestureController.cpp
    title: ViewGestureController.cpp (canSwipeInDirection, PendingSwipeTracker)
  - id: vgc-mac
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/ViewGestureControllerMac.mm
    title: ViewGestureControllerMac.mm (handleScrollWheelEvent, trackSwipeGesture)
  - id: page-proxy
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebPageProxy.cpp
    title: WebPageProxy.cpp (wheelEventHandlingCompleted, rubberBandableEdgesRespectingHistorySwipe, recordNavigationSnapshot)
  - id: bf-list
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebBackForwardList.cpp
    title: WebBackForwardList.cpp (snapshot recorded in addItem)
  - id: webviewimpl
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebViewImpl.mm
    title: WebViewImpl.mm (scrollWheel, setAllowsBackForwardNavigationGestures)
  - id: back-or-close
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.navigateBackOrCloseChildTab
  - id: feature
    resource: ../tabs/back-swipe-to-opener.md
    title: Back swipe to the opener
---

A browser that wants a back swipe to do something other than go back in
history (TASK-325: close a tab opened from another tab and return to its
opener) cannot reuse WebKit's swipe. It has to run its own, and the only way
to respect the page (carousels, maps, `preventDefault` wheel listeners) is a
private delegate callback that WebKit suppresses unless the view's own gesture
is off.

# Behavior

## WebKit's swipe needs a back item

`allowsBackForwardNavigationGestures` hands scroll events to
`ViewGestureController` first (`WebViewImpl::scrollWheel`). Its
`PendingSwipeTracker` starts a swipe only when the main frame is pinned to the
edge in the swipe direction, the event is mostly horizontal, and
`canSwipeInDirection` is true, which is `!!backForwardList.backItem()` for
back. With no back item the event goes to the page and nothing else happens.
The two-finger swipe on a freshly opened tab is a no-op, while the Back button
and Cmd+[ already close it through `navigateBackOrCloseChildTab`.

When the page has wheel listeners (`willHandleHorizontalScrollEvents`), the
tracker waits for WebCore's verdict on each event and starts the swipe from
`eventWasNotHandledByWebCore`, asynchronously. It then calls
`trackSwipeEventWithOptions:` on the stored `NSEvent`, so starting
`NSEvent.trackSwipeEvent` from a later callback is something WebKit itself
relies on.

## SPI that does not help

| SPI | Why not |
|---|---|
| `_tryToSwipeWithEvent:ignoringPinnedState:` | Skips only the pinned check; still ends in `canSwipeInDirection`, so still needs a back item |
| `_alternateWebViewForNavigationGestures` (configuration) | iOS only in `WKWebView.mm`; it would navigate in another page's history, not close anything |
| `_webViewDidBeginNavigationGesture:` and the will/did-end callbacks (`WKNavigationDelegatePrivate`) | Fire only for a WebKit swipe that already has a target item |
| `_setCustomSwipeViews:` | Changes what slides during WebKit's swipe; does not change when it starts |

## The unhandled-scroll signal

`WebPageProxy::wheelEventHandlingCompleted` calls the private
`WKUIDelegate` method `_webView:didNotHandleWheelEvent:` (macOS 10.13.4+)
for every event that neither the scrolling tree nor the page consumed. Both
the UI-side scrolling path (`RemoteLayerTreeEventDispatcher`) and the
web-process path end there.

Measured with synthetic two-finger scroll events on a page with no back item
(macOS 26.7):[^spike]

| `allowsBackForwardNavigationGestures` | `_rubberBandingEnabled` | Back-direction scroll the page cannot use | Reported? |
|---|---|---|---|
| on | default (all edges) or 0 | plain page | **no** (vertical scrolls are reported with 0, horizontal never) |
| off | default (all edges) | plain page | no: the left rubber band consumes it |
| off | all but left (14), or 0 | plain page; overflow-x scroller already at `scrollLeft` 0 | **yes**: began, changed, ended and phaseless events |
| off | all but left (14), or 0 | overflow-x scroller at `scrollLeft` 600 under the pointer | no: the page scrolled it (600 to 456) |
| off | 0 | `wheel` listener calling `preventDefault` | no: the listener got the events |
| off | all but left (14) | forward direction | no: the right edge still rubber-bands |
| off | all but right (11), or neither side (10) | forward direction, plain page | **yes** (with 10, back is reported too) |
| off | neither side (10) | forward direction, overflow-x scroller at `scrollLeft` 200 | no: the page scrolled it (200 to 344) |

Why the view's gesture being on hides horizontal events even with
rubber-banding 0 was not found in the source. The measurement is what counts.

`_rubberBandingEnabled` is a `_WKRectEdge` bit mask (left 1, top 2, right 4,
bottom 8). The setter takes an integer, so key-value coding throws
`NSUnknownKeyException`; call `_setRubberBandingEnabled:` through its
implementation pointer. The value survives navigations. It only takes effect
with the gesture off, because with it on `rubberBandableEdgesRespectingHistorySwipe`
replaces the left and right edges with `!backItem` / `!forwardItem`.

## Turning the gesture off also stops snapshots

`setAllowsBackForwardNavigationGestures(false)` also calls
`setShouldRecordNavigationSnapshots(false)`. WebKit records the snapshot of
the page being left in `WebBackForwardList::addItem`, when the next item is
added. If the gesture is still off then, a later WebKit swipe back to that page
has no snapshot to show. Re-enabling the gesture before the next main-frame
navigation commits avoids that. A same-document navigation (`pushState`) adds
an item without a navigation-policy callback, so its first page can still miss
its snapshot. This is a source reading, not measured.

# Why it matters here

TASK-325 wants the back swipe on a tab opened from another tab, with no back
history, to close it and return to the opener the way the Back button does.
None of WebKit's swipe can be bent to that. Without the unhandled-scroll
signal, the app's own swipe would have to guess from `_pinnedState`. On the
`overflow-x` page above, `_pinnedState` reported the main frame pinned left
(11) while the inner scroller was mid-scroll, so a guess would close the tab
when the user meant to scroll a carousel back.

# Workaround

The page-respecting shape: while a tab has an opener and no back item, turn its view's back/forward
gesture off and exclude the left edge from rubber-banding. Then start the
app's own swipe from the `_webView:didNotHandleWheelEvent:` events, and put
both back when the tab gains history, after WebKit's own swipe has ended,
so that a trailing event from that swipe cannot start a second one. The
alternatives weighed are in TASK-325's notes.[^task-325] Detour does this
now: [Back swipe to the opener](../tabs/back-swipe-to-opener.md).

In the app (macOS 26.7) a tab web view's `_rubberBandingEnabled` reads 15
(all edges) by default, and the mode's 14 and 10 read back as set.

`NSEvent.trackSwipeEvent` started from that callback in Detour does track a
real trackpad gesture: synthetic events cannot drive it, so this was a hand
check, which the user ran on a real trackpad on 2026-11-15 and reported
working.[^task-325] Three-finger "swipe between pages"
arrives as `swipe(with:)`, not scroll events, and WebKit ignores it while
its gesture is off (and does nothing with it without a back item). Scroll-based
tracking applies only when `NSEvent.isSwipeTrackingFromScrollEventsEnabled`
is true, and `trackSwipeEvent` raises an Objective-C exception for anything
but a scroll event in its began or changed phase.

[^spike]: docs/harness/task325-wheel-spike.swift, run 2026-11-14 on macOS 26.7 with synthetic CGEvent scrolls sent through `window.sendEvent`.
[^task-325]: TASK-325
