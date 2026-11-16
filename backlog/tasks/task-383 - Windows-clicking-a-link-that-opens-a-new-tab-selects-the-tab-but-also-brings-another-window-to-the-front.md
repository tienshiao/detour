---
id: TASK-383
title: >-
  Windows: clicking a link that opens a new tab selects the tab but also brings
  another window to the front
status: Done
assignee: []
created_date: '2026-11-16T21:22:00Z'
updated_date: '2026-11-16T22:25:00Z'
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
- [x] #1 The cause is found and recorded in the task (reproduced in a /verify run with the steps written down)
- [x] #2 Opening a link in a new tab leaves the window it was clicked in at the front, and no other window comes forward
- [x] #3 A test covers the fix where the cause is in testable code (a TabStore/policy rule or a delegate path)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User's details (2026-11-16): the window that comes forward is another Detour window showing the same space. Steps: two Detour windows on the same space; the front one shows a Reddit thread (https://www.reddit.com/r/xteinkereader/comments/1teaa7g/whats_your_favorite_new_font_on_crosspoint_13/), the one behind a YouTube video tab. Click a photo in a comment: it opens larger in a new tab, which is selected in the front window, and the window behind comes forward. The user thinks it happens only when the photo is directly above the window behind (its page, sidebar or tab), "almost like the click was passed through to the Detour window underneath".

That the pointer's position over the window behind matters points to the WindowServer delivering an event to it, not to app code picking a window: nothing in the new-tab path orders a window front, and the browser window is opaque (no click-through by alpha). Plan: reproduce in an isolated /verify run with two windows on one space, the back one placed under the click point, and a local fixture page with an image link (target=_blank, and a window.open variant). Use real HID clicks (CGEvent tap). The automation endpoint's in-process clicks skip WindowServer hit-testing, so if only the real click reproduces it, the cause is at that level. Then log key/main window changes (NSWindow.didBecomeKey/didBecomeMain with timestamps) and the mouseDown/mouseUp windows around the click.

REPRODUCED 2026-11-16 on main 0dba81a3 (isolated /verify run, DETOUR_DATA_DIR=DetourVerify383, real HID clicks via CGEvent): window 1 (YouTube, playing) behind, window 2 (Reddit thread) in front, same space. A real click on the comment photo with the photo over a TAB ROW of window 1's sidebar opens the photo in a new tab in window 2 (window 2 stays key), and ~0.5 s later a 260x71 window (the tab hover card) appears beside window 1's sidebar and window 1 is ordered ABOVE window 2 (CGWindowList z-order). Over an empty part of window 1's sidebar, or over its web content, nothing happens; a plain target=_blank, an onclick window.open and an onpointerdown window.open on a local page behave the same (only the row matters).

Two faults:
A. Showing the hover card for a window that is not in front raises that window: TabHoverCardController.show() adds the card as a child window (addChildWindow ordered .above) and orderFront()s it, which orders the parent's group to the front. Measured separately: with window 2 key and window 1's sidebar uncovered, just resting the pointer on a window-1 tab row shows the card and puts window 1 above window 2.
B. TabCellView.recheckHover() (and NewTabCellView's, FauxAddressBar's similar check) decides hover from window.mouseLocationOutsideOfEventStream + bounds.contains, with no check that this window is the one under the pointer. The sidebar re-checks visible cells after a tab-list change (TabSidebarViewController recheckHoverForVisibleCells, incl. a 0.3 s delayed pass), so adding the new tab to the shared space marks window 1's row under the pointer hovered through window 2, and the card (fault A) follows. Tracking-area hover (mouseEntered) is not affected: the window server already accounts for occlusion.

Fix (2026-11-16):
- A: TabHoverCardController.show() shows a card only when its parent window is key (isKeyWindow, injectable). Chosen by Claude, to confirm with the user: the alternative was to keep cards for background windows and order the card in without raising its parent (not measured). The dismissal rule already hid a card when its window resigned key.
- B: new PointerWindow (Browser/Shared): isOver(window) = the topmost window at NSEvent.mouseLocation (windowNumber(at:belowWindowWithWindowNumber: 0), any app's) is this window or one of its children. TabCellView.recheckHover, NewTabCellView.recheckHover and FavoriteTileView.recheckHover (found by the review) require it.

Tests: TabHoverCardTests + TabHoverCardControllerTests + PointerWindowTests + SidebarLayoutTests + TabThumbnailTests: 120 tests, 0 failures. New: testAWindowThatIsNotKeyShowsNoCardAndKeepsItsPlaceBehind (fails without the guard: the background window comes in front, checked by disabling it), PointerWindowTests (2). The recheckHover gate itself has no unit test (it reads the real pointer); checked at runtime.

Runtime (/verify, isolated DetourVerify383, real HID pointer via CGEvent, before the review's two edits: folding the guard into show()'s first guard, and the favourite tile gate): (1) the reported case: Reddit photo clicked over a tab row of the YouTube window behind: new tab opens in the front window, no card, the front window stays in front (CGWindowList order), and the covered row is not drawn hovered (app screenshot of the back window). (2) Resting on an uncovered row of a background window: no card, the window stays behind. (3) Resting on a row of the key window: the card shows, window order unchanged.

Code review (medium --fix): 7 findings, 2 fixed (above). Left: no card when a window becomes key with the pointer already on a row (no enter event; until the pointer moves to another row); windowNumber(at:) and click-through overlays of other apps not measured; hoverBegan still arms the timer for a non-key window (on purpose: it may become key during the delay); no unit test for the recheckHover gate; the new test's start order now waits up to 5 s for the window server. Not verified: the signed production build.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A link that opens a new tab no longer brings another Detour window forward. Cause: the window behind (same space) re-checked hover after its tab list changed, counted the tab row under the pointer as hovered although the front window covered it, and showed that row's hover card; the card is a child window, and ordering it in brought its parent in front. Fix: the hover card shows only for the key window, and position-based hover re-checks (tab rows, the New Tab row, favourite tiles) count only where their window is the topmost one under the pointer. Tests 120/0; reproduced and verified with real pointer input in an isolated run.
<!-- SECTION:FINAL_SUMMARY:END -->
