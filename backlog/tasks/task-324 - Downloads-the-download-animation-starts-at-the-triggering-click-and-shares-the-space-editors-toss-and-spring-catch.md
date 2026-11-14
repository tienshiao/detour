---
id: TASK-324
title: >-
  Downloads: the download animation starts at the triggering click and shares
  the space editor's toss and spring catch
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T00:19:00Z'
updated_date: '2026-11-14T01:15:00Z'
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
- [x] #1 A download that starts within a few seconds of a click (left or right) in the web view that started it flies from that click point; in a split, from the pane that was clicked
- [x] #2 A download with no recent click in its web view (keyboard, script, background tab) flies from the centre of the page, as today
- [x] #3 The flight uses the same physics as the space editor's toss (one shared implementation), and the Downloads button catches it with the same kind of spring
- [x] #4 With the sidebar hidden, the flight still has a sensible destination, as today
- [x] #5 Reduce Motion: no flight, at most a fade or a pulse on the Downloads button
- [x] #6 The rules (click freshness, start-point choice, the shared toss) have tests; the animation is checked at runtime with /verify, including a context-menu download and a split pane
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Shared toss (Detour/Browser/Shared/Toss.swift): TossPath (from SpaceFlightPath, with a minimum duration so short or level throws arc), TossOverlayView, TossFlight, SpringCatch. The space celebration moves onto it.
2. Click record: a per-window local event monitor notes left and right clicks in the content area (point and time on ProcessInfo.systemUptime). DownloadFlightStart.point picks the click when it is fresh (≤ 5 s) and inside the content, else the middle.
3. DownloadAnimation: TossFlight from that point into the Downloads button (hop 40, minimum 0.5 s), which catches it with SpringCatch. A hidden sidebar flies to the old corner with no catcher. Reduce Motion: no flight; the button brightens back in.
4. Found at runtime: Download Linked File does nothing in Detour. WebKit reports it only through WKNavigationDelegatePrivate _webView:contextMenuDidCreateDownload: (macOS 12+), which Detour did not implement. Now implemented in the window, BrowserTab and Quick Detour (user: fix it in this task), with a reachability test.
5. Tests; runtime check; review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14 runtime (DetourVerify324a, local fixture page):
- A real left click on a download link flies from the click and arcs into the Downloads button (recorded with screencapture -v; the log showed start = click point).
- A target=_blank download link starts from the opener's click.
- Trap: System Events 'click at' performs an accessibility press, not a mouse event, so no mouseDown is seen. It is useless for click-point tests; use CGEvent on the HID tap. This misled me into replacing a BrowserWebView.mouseDown override with the window monitor (kept: it covers any view in the content area).
- Not checked at runtime, left to the user: Download Linked File after the fix (synthetic clicks on context-menu items did not trigger WebKit's items, and the user was at the machine); split pane; hidden sidebar; Reduce Motion.
Tests: TossPathTests 11, DownloadFlightStartTests 5, SpaceAppearanceTests 19, WebKitDelegateReachabilityTests 2: 37, 0 failures.

2026-11-14: Closing per the user: they run the four hands-on checks (Download Linked File, split pane, hidden sidebar, Reduce Motion); then code review and commit. The test hook that would let an agent do these checks is TASK-228.1.

2026-11-14: The user ran the hands-on checks (Download Linked File, split pane, hidden sidebar, Reduce Motion) and reported them complete, with no problems raised.
/code-review --fix found 7 issues and fixed all of them:
- Download Linked File's click is the right click that opened the menu: a 60 s limit for it (DownloadFlightStart.contextMenuMaxClickAge).
- The monitor counted any click in the content container: it now hit-tests and counts only web views.
- BrowserTab's context-menu download ran the close-the-tab-opened-for-a-download rule.
- The monitor was not removed in deinit.
- SpaceCelebration.burst could leak its overlay when there was no layer.
- Three copies of the window's download setup.
- A wrong comment.
Tests after the fixes: 287 across the download, Quick Detour, sidebar, space, toss, reachability and window-close suites, 0 failures. The review's click hit-test and the 60 s context-menu limit came after the user's hands-on check and were not re-checked in the running app.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Downloads now fly like the space editor's emoji.
- **Shared toss:** Detour/Browser/Shared/Toss.swift (TossPath, TossOverlayView, TossFlight, SpringCatch) is used by the space celebration and by DownloadAnimation.
- **The flight:** the icon is tossed under gravity (40 pt hop, at least 0.5 s) into the Downloads button, which catches it with a spring. A hidden sidebar: the old corner, nothing catches it. Reduce Motion: no flight; the button brightens back in.
- **Where it starts:** each window notes the last left or right click on a web view in its content area (a window event monitor). DownloadFlightStart takes that click if it is at most 5 s old (60 s for a context-menu download), else the middle of the page. A link that opens a new tab first starts at the click in the opener.
- **Bug fixed (user's choice to include it):** Download Linked File / Download Image did nothing; WebKit reports them only through WKNavigationDelegatePrivate _webView:contextMenuDidCreateDownload:, now implemented in the window, BrowserTab and Quick Detour.
- **Tests:** TossPathTests, DownloadFlightStartTests, and a reachability test for the context-menu selector; 287 tests across the related suites, 0 failures. /code-review --fix: 7 findings, all fixed.
- **Runtime:** a real click flies from the click; a new-tab link starts from the opener. The user checked Download Linked File, a split pane, the hidden sidebar and Reduce Motion by hand.
- **Not re-checked in the app:** the review's hit-test and the 60 s context-menu limit.
- **Follow-up:** TASK-228.1, the in-process test endpoint, so checks like these need no human.
<!-- SECTION:FINAL_SUMMARY:END -->
