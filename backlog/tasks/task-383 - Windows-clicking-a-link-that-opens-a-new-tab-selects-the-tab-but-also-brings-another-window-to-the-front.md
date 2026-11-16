---
id: TASK-383
title: >-
  Windows: clicking a link that opens a new tab selects the tab but also brings
  another window to the front
status: To Do
assignee: []
created_date: '2026-11-16T21:22:00Z'
labels:
  - window
  - links
dependencies: []
priority: medium
type: bug
ordinal: 464000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user on 2026-11-16 in the released 0.4.4 (running since Nov 15): clicking a link that opens a new tab (target=_blank or similar) selects the new tab, but a different window also comes to the front.

Not yet known: whether the window that comes forward is another Detour window or another app's; whether that Detour window shows the same space; which site/link; whether Peek, a Link Route or a pinned/favourite tab was involved; how often.

What the code reading on 2026-11-16 (main f555314c) ruled out or found:
- The production log has no link-routing lines ("Link routed ...") in the last 3 h, so a Link Route that sends the link to another window (AppDelegate.openLink brings that window forward) is unlikely.
- The new-tab paths (decidePolicy's _blank Peek/new-tab branch in BrowserWindowController+Navigation.swift, createWebViewWith in BrowserWindowController+WKUIDelegate.swift) call selectTab on the window whose delegate fired; none orders a window front. Delegates are rewired on every claim (wireOwnedWebView).
- The only window-ordering calls reachable from a page or an extension: WKExtensionTabConformance.activate (Quick Detour only; otherwise tabShouldSelectNotification, which every window showing that space handles with selectTab), WKExtensionWindowConformance.focus (windows.update focused:true), ExtensionManager's windows.create (shouldBeFocused), _webViewFullscreenMayReturnToInline (PiP), and DownloadOpenedTabPolicy.restoreWindows (a link that becomes a download). An extension reacting to tabs.onCreated/onActivated with windows.update({focused:true}) is the leading suspect to check first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause is found and recorded in the task (reproduced in a /verify run with the steps written down)
- [ ] #2 Opening a link in a new tab leaves the window it was clicked in at the front, and no other window comes forward
- [ ] #3 A test covers the fix where the cause is in testable code (a TabStore/policy rule or a delegate path)
<!-- AC:END -->
