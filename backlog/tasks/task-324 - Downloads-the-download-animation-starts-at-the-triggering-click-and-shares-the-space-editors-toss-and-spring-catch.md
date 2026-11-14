---
id: TASK-324
title: >-
  Downloads: the download animation starts at the triggering click and shares
  the space editor's toss and spring catch
status: To Do
assignee: []
created_date: '2026-11-14T00:19:00Z'
labels:
  - downloads
  - ui
  - animation
dependencies:
  - TASK-289
references:
  - Detour/Browser/Downloads/DownloadAnimation.swift
  - Detour/Browser/Window/BrowserWindowController+Navigation.swift
  - Detour/Browser/Window/BrowserWebView.swift
  - Detour/Browser/Sidebar/SpaceCelebration.swift
priority: low
ordinal: 391000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user on 2026-11-13, after TASK-289 gave the space editor a physics-based celebration (the emoji is tossed under gravity into its switcher button, which catches it with a spring). The user wants the download animation and that one to feel like one family.

As of 2026-11-13, `DownloadAnimation` (Detour/Browser/Downloads/DownloadAnimation.swift) flies an SF Symbol from the centre of the page to the sidebar's Downloads button. Its path is a quadratic curve with a fixed control point 250 pt above the midpoint, 0.6 s, ease-in, shrinking to 0.4× and fading to 60%. On arrival the icon just vanishes and the button does not react. It ignores Reduce Motion and draws into the window's root layer. It is triggered from `BrowserWindowController+Navigation.swift` (`triggerDownloadAnimation`, for both `didBecome download` callbacks and for .crx installs).

Why the click point is not just read at the callback: WebKit does not say where a download was triggered from, and the `didBecome download` callbacks come only after the server responds (possibly seconds after the click), when the pointer may have moved. Peek reads `mouseLocationOutsideOfEventStream` at the link decision, which is close enough there but not here. The idea discussed with the user: `BrowserWebView` remembers its last left- or right-click (location and time), and a download started soon after a click in that web view flies from it. A right-click covers Download Linked File from the context menu.

The shared toss (TASK-289): `SpaceFlightPath.toss` and the spring catch in `TabSidebarViewController.popSpaceButton` / `SpaceCelebration`. A download is thrown up and out of the page, so a bigger hop than the space's 8 pt likely suits it. The colour wash and sparkle belong to a space and are not wanted here.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A download that starts within a few seconds of a click (left or right) in the web view that started it flies from that click point; in a split, from the pane that was clicked
- [ ] #2 A download with no recent click in its web view (keyboard, script, background tab) flies from the centre of the page, as today
- [ ] #3 The flight uses the same physics as the space editor's toss (one shared implementation), and the Downloads button catches it with the same kind of spring
- [ ] #4 With the sidebar hidden, the flight still has a sensible destination, as today
- [ ] #5 Reduce Motion: no flight, at most a fade or a pulse on the Downloads button
- [ ] #6 The rules (click freshness, start-point choice, the shared toss) have tests; the animation is checked at runtime with /verify, including a context-menu download and a split pane
<!-- AC:END -->
