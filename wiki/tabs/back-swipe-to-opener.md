---
type: Feature
title: Back swipe to the opener
description: "On a tab opened from another tab, with no back history, the two-finger back swipe does what the Back button does — closes the tab and selects its opener — through Detour's own swipe (WebKit's needs a back item): when a pane's web view is in that mode, how a swipe starts from the scrolls the page did not use, the veneer that shows during it, the decisions per case (splits, Peek, pinned tabs, Quick Detour), and what is verified only by hand."
tags: [tabs, navigation, gestures, webkit, split]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-15T08:05:00Z }
sources:
  - id: rules
    resource: ../../Detour/Browser/Window/NavigationSwipe.swift
    title: NavigationSwipe.swift (rules, pending tracker, momentum filter, opener-picture cache, tracker seam)
  - id: window
    resource: ../../Detour/Browser/Window/BrowserWindowController+NavigationSwipe.swift
    title: BrowserWindowController+NavigationSwipe.swift (mode, delegate callbacks, sessions, pictures)
  - id: overlay
    resource: ../../Detour/Browser/Window/NavigationSwipeOverlayView.swift
    title: NavigationSwipeOverlayView.swift (the veneer)
  - id: back-core
    resource: ../../Detour/Browser/Window/BrowserWindowController.swift
    title: BrowserWindowController.navigateBackOrCloseChildTab(_:)
  - id: tests
    resource: ../../DetourTests/NavigationSwipeTests.swift
    title: NavigationSwipeTests
  - id: checks
    resource: ../../docs/harness/task325-swipe-checks.py
    title: TASK-325 runtime checks through the automation endpoint
  - id: quirk
    resource: ../platform/back-swipe-and-unhandled-scrolls.md
    title: WebKit's back swipe and unhandled scrolls
  - id: task-325
    resource: backlog:TASK-325
    title: The back swipe on a tab opened from another tab closes it and returns to the opener
  - id: task-332
    resource: backlog:TASK-332
    title: "Tabs: Reopen Closed Tab restores a child tab's link to its opener"
---

# What it does

A tab opened from another one (a `target=_blank` link, Cmd+click, a
script's `window.open`) starts with no back history. The Back button already
closes such a tab and selects its opener (`parentID`). The two-finger back
swipe now does the same: the page follows the fingers to the right, the
opener's picture shows underneath, releasing early springs it back, and
completing it closes the tab and selects the opener. The closed tab is an
ordinary closed tab: Reopen Closed Tab brings it back, still closing to its
opener while that tab is open.[^task-325][^task-332]

Once the tab has history of its own, the swipe walks it with WebKit's own
gesture, as before; it closes to the opener only from the first page. With
no opener left (none, closed, asleep in a pinned slot, or in another
space), the swipe on a first page does nothing, as before.

# How it works

WebKit's swipe cannot be retargeted (see
[the platform page](../platform/back-swipe-and-unhandled-scrolls.md)), so a
pane in this state runs Detour's own swipe instead.

## The mode

`NavigationSwipeRules.mode` decides, per hosted pane, between `.webKit` and
`.ownSwipe(canGoForward:)`:

- The own swipe is for a **normal tab** (in its space's list) whose opener
  resolves as the Back button resolves it (`parentTab(for:)`, through
  `Space.openerTab(id:)`: a tab or live pinned tab of the window's active
  space), with **no back item**.
- In it, WebKit's `allowsBackForwardNavigationGestures` is off and the left
  edge does not rubber-band (`_setRubberBandingEnabled:` 14, or 10 when the
  tab also has a forward item, so forward scrolls are reported too). The
  view's own mask is read first and restored after.
- A main-frame load turns WebKit's gesture back on at
  `didStartProvisionalNavigation`, before the commit, so WebKit still
  records the snapshot of the page being left. The commit or failure
  re-decides.
- Entering the mode waits until WebKit's own swipe is over
  (`_webViewDidBeginNavigationGesture:` to
  `_webViewDidRemoveNavigationGestureSnapshot:`, with a 5 s watchdog that
  refreshes whichever window hosts the view then). The flag is the view's
  and survives a re-claim: clearing it there would let a re-selection during
  WebKit's swipe arm the own mode early.
  The mode remembers when it came on (`armedAt`); only a gesture whose
  began event is later can start the own swipe. Together these stop a swipe
  that went back to the first page from also closing the tab.
- The mode lives on the web view (`BrowserWebView.navigationSwipe`) and only
  while a window hosts it: `wireOwnedWebView` and `removeContentViews` (and
  window close) put WebKit's gesture back; every claim re-applies the mode.
  Re-evaluated on every pane's `canGoBack`/`canGoForward`/`isLoading`, store
  changes (an opener closed, pinned, restored) and the callbacks above.

## Starting and tracking a swipe

- The private `WKUIDelegate` method `_webView:didNotHandleWheelEvent:`
  feeds `PendingNavigationSwipe`, WebKit's `PendingSwipeTracker` rules: a
  began event (after `armedAt`), mostly horizontal (|dy| < |dx| / 2), in a
  direction the tab can go, then 15 pt of horizontal travel. A carousel or a
  `preventDefault` listener uses the scrolls, so none are reported.
- `beginNavigationSwipe` decides the outcome first
  (`NavigationSwipeRules.outcome`); nothing starts when it is `.none`. It
  then puts a veneer over the pane and starts the tracker:
  `SystemNavigationSwipeTracker` calls `NSEvent.trackSwipeEvent` on the
  event that crossed the threshold (bounds 0…1 back, -1…0 forward, WebKit's
  consume-mouse-events option), only for a scroll event in its began or
  changed phase and only with "swipe between pages" set to scrolling.
- A navigation starting in the pane, its history changing, the tab
  closing, the content being replaced (tab switch, ownership moving to
  another window) or resized cancels the swipe; the handler then stops the
  tracking.

## Completing it

`finishNavigationSwipe` ends the session first, then decides again for the
same tab id (still hosted here, same outcome). The outcome runs through the
Back button's own core, `navigateBackOrCloseChildTab(_:)`, applied to the
pane that **received** the swipe: in a split that need not be the focused
pane. That core now selects the opener before closing the tab, so the close
no longer moves the selection to a neighbour (and wakes it) first. Forward
calls `goForward()`. The rest of the gesture (its momentum) is swallowed for
up to 2 s (`NavigationSwipeMomentumFilter`, in `BrowserWebView.scrollWheel`),
or it would scroll the opener.

A three-finger "swipe between pages" arrives as `swipe(with:)`, which WebKit
ignores while its gesture is off; `BrowserWebView` hands it to the window,
which applies the same outcome at once (no tracking).

## What shows during it

Live views never move (as for split veneers): `NavigationSwipeOverlayView`
sits over the swiped pane, below the drag handle, and is kept through the
completing `selectTab` (it is in `removeContentViews`' keep-list as
`finishingOverlay`), then lifted over the newly hosted opener and faded in
0.15 s. Selecting any tab other than the swipe's result
(`finishingSelectionID`) removes it at once, so a stale picture never covers
an unrelated tab.

- **Back**: a `cacheDisplay` picture of the pane slides right over the
  opener's picture, dimmed and shadowed as WebKit's is.
- **The opener's picture** is taken by `takeSnapshot` at one pixel per point
  as the opener leaves the screen (`stampDeselected`), only when a tab opened
  from it is open, with its frame in the content area; up to 4 per window
  (`OpenerUnderlayCache`), dropped when the opener is selected again or its
  last child closes. A split opener comes back as its panes at their frames.
  Without one, the opener's 480 px switcher preview across the top, else a
  plain page background. Pictures are per window and in memory only, so the
  first swipe after a relaunch falls back.
- **An opener that was asleep** is woken by the close; the veneer stays
  until its load commits (or 1 s).
- **Forward** (PROVISIONAL): a plain card slides in from the right and stays
  until the forward page commits (or 1 s). WebKit's picture of the forward
  page is in its own store, which Detour cannot read; picturing the page as
  the user leaves it going back was the other option.
- **A split pane**: a plain background, since the close re-tiles the window.

# Decisions per case

| Case | Behaviour | Why |
|---|---|---|
| Child in a split | The pane that received the swipe closes; its opener is selected (the partner stays selected when it is the opener, and goes back to single hosting) | The Back button's result for that pane (the user's decision, corrected for pane focus) |
| Peek | The Peek's web view keeps WebKit's gesture (its own history; Back acts on it too); the tab under an open Peek starts nothing | Back targets the Peek while one is open; the overlay also swallows scrolls |
| Quick Detour | Unchanged: WebKit's gesture, history only | Its Back is history only and its tab has no opener |
| Pinned tab or favourite with a `parentID` | WebKit's gesture; never swiped closed | `TabStore.closeTab` closes normal tabs only. The Back button on a pinned child still selects the opener without closing it (behaviour before TASK-325) |
| Reopened child | Closes to its opener again while that tab is still an opener `Space.openerTab` resolves (the record carries `parentID` since v26); with the opener closed, archived, moved or asleep meanwhile, no opener and WebKit's gesture | The record is the tab's only life after closing (TASK-332) |
| Child brought back by Undo Close Tab (or Undo Close Both Splits) | The same rule: its captured opener only while `Space.openerTab` resolves it; an opener closed since (even if its own close was undone first: a new tab) leaves no opener | One rule for every way a closed tab comes back (the user's decision on TASK-332, 2026-11-14) |

# Edge cases

- Navigate › Back (Cmd+[) with the page focused closes a child with no
  back item too, since TASK-331. Before it the item was disabled there
  (also on a build from before TASK-325): `WKWebView`'s own `goBack:`
  action, enabled only with a back item, sits ahead of the window
  controller in the responder chain. `BrowserWebView` now hands `goBack:`
  and `goForward:` to the controller ([Browser commands](../features/browser-commands.md)).
- `pushState` adds a back item without a provisional navigation, so WebKit
  may miss the first page's snapshot for its later swipe back (source
  reading).
- A web view hosted mid-load (a claim during its provisional navigation)
  enters the mode before the commit; its first page may then lack WebKit's
  snapshot.
- Right-to-left layouts are not handled (WebKit swaps the directions; this
  does not).

# Tests

`NavigationSwipeTests`: the rules (mode, edges, outcome per case, clamping
and completion), the pending tracker (threshold, began-after-arming,
vertical, momentum, reversal, forward), the momentum filter, the picture
cache and geometry; and in a window (Private, scripted tracker): the mode on
a child, none without an opener, off when the opener closes or the tab is
left, off during a load, held until WebKit's swipe ends, a completed swipe
closing to the opener, a cancelled one leaving the tab, a navigation
cancelling it, an unfocused split pane closing, a split child returning to
its partner, and the Back button's result. `WebKitDelegateReachabilityTests`
checks the three private callbacks.

At runtime, `docs/harness/task325-swipe-checks.py` drives a Debug build
through the endpoint's Debug-only `navigation_swipe` tool (state; begin at a
progress with the veneer showing; finish or spring back), which runs a
swipe's completion through the same code with a scripted tracker. Synthetic
events cannot drive `trackSwipeEvent`, so the real trackpad gesture (follow,
spring, momentum, the 15 pt start) is checked by hand only.[^checks]

# Related

- [WebKit's back swipe and unhandled scrolls](../platform/back-swipe-and-unhandled-scrolls.md): the WebKit behaviour this rests on.
- [WKWebView snapshots](../platform/wkwebview-snapshots.md): what the opener's picture costs and why it is taken on leaving.
- [Split tab hosting](./split-tabs-hosting.md): the veneer rule and pane focus.
- [Web view ownership](../architecture/webview-ownership.md): why the mode lives only while a window hosts the view.
- [Closed tabs and the Archived Tabs page](./closed-tabs-and-archive.md): what Reopen Closed Tab restores.
- [Peek](./peek.md): Back acts on the Peek while one is open.

[^task-325]: The back swipe on a tab opened from another tab closes it and returns to the opener
[^checks]: TASK-325 runtime checks through the automation endpoint
[^task-332]: Tabs: Reopen Closed Tab restores a child tab's link to its opener
