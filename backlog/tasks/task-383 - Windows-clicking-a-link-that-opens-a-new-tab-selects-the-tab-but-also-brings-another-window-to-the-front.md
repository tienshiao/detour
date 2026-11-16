---
id: TASK-383
title: >-
  Windows: clicking a link that opens a new tab selects the tab but also brings
  another window to the front
status: To Do
assignee: []
created_date: '2026-11-16T21:22:00Z'
updated_date: '2026-11-16T21:29:00Z'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User's details (2026-11-16): the window that comes forward is another Detour window showing the same space. Steps: two Detour windows on the same space; the front one shows a Reddit thread (https://www.reddit.com/r/xteinkereader/comments/1teaa7g/whats_your_favorite_new_font_on_crosspoint_13/), the one behind a YouTube video tab. Click a photo in a comment: it opens larger in a new tab, which is selected in the front window, and the window behind comes forward. The user thinks it happens only when the photo is directly above the window behind (its page, sidebar or tab), "almost like the click was passed through to the Detour window underneath".

That the pointer's position over the window behind matters points to the WindowServer delivering an event to it, not to app code picking a window: nothing in the new-tab path orders a window front, and the browser window is opaque (no click-through by alpha). Plan: reproduce in an isolated /verify run with two windows on one space, the back one placed under the click point, and a local fixture page with an image link (target=_blank, and a window.open variant). Use real HID clicks (CGEvent tap). The automation endpoint's in-process clicks skip WindowServer hit-testing, so if only the real click reproduces it, the cause is at that level. Then log key/main window changes (NSWindow.didBecomeKey/didBecomeMain with timestamps) and the mouseDown/mouseUp windows around the click.
<!-- SECTION:NOTES:END -->
