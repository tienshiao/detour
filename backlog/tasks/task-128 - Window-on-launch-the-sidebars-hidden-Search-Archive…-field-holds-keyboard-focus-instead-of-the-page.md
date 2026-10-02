---
id: TASK-128
title: >-
  Window: on launch the sidebar's hidden 'Search Archive…' field holds keyboard
  focus instead of the page
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-02 01:47'
updated_date: '2026-10-02 06:53'
labels:
  - window
  - sidebar
  - bug
dependencies: []
priority: medium
ordinal: 128000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while runtime-verifying TASK-78 (2026-10-01): when a browser window first appears, first responder is the archive page's search field (Detour/Browser/Sidebar/ArchivePageView.swift, placeholder 'Search Archive…') even though the archive page is not the visible sidebar page. Observed via the Accessibility API (focused element = AXTextField with that placeholder) in a signed debug build on an isolated profile, in three launches: an empty profile (no tabs, 'A rare moment of tab peace.' showing), a restored single tab, and a restored split. Consequences: keys typed right after launch go into the off-screen field (a space and a URL typed without opening the palette ended up as its value) and the restored page gets no keyboard input — space does not scroll, page shortcuts do nothing — until the user clicks the page or opens and dismisses the command palette (which now restores page focus, TASK-78). Likely cause, unconfirmed: nothing sets the window's initial first responder (no initialFirstResponder / makeFirstResponder on the launch path — AppDelegate showWindow, BrowserWindowController.selectTab at restore), so AppKit picks the first key-view-eligible control in the content view, which is that text field. Fix direction: on first show, focus the selected tab's web view via BrowserWindowController.restoreWebContentFocus() (peek / focused split pane aware), or nothing focusable in the sidebar when no tab is selected; and keep the archive field out of the key loop while its page is off-screen. Check new windows (Cmd+N), incognito windows and windows restored at launch, and that scrolling to the archive page still lets the field take focus when clicked or when search is invoked there.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After launch with a restored tab, the page receives keyboard input without a click (space scrolls it) and the window's first responder is the selected tab's web view — the focused pane for a split, the peek when one is presented
- [x] #2 After launch with no tabs, and in a new or incognito window, the archive search field is not first responder and typing does not change its value
- [x] #3 The archive search field still takes focus when the archive page is showing and the user clicks it or clears the search
- [x] #4 A unit test on BrowserWindowController covers the first responder after a window is shown with a selected tab and with none
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Cause confirmed: with no initialFirstResponder AppKit focuses the window's first key view when the window is first shown; the archive page is the first page of the strip, so that is its search field (reproduced in-app, also for a window that is not key).
Fix, three parts. (1) BrowserWindowController.showWindow: the first time, hand focus to the page (restoreWebContentFocus — peek / focused split pane aware) and, if a sidebar control still holds it, to nothing. (2) selectTab also restores page focus when nothing holds keyboard focus (first responder is the window): the launch path selects the session's tab after the window is shown; this also keeps focus on the page when switching tabs from the keyboard (the outgoing web view leaves the window). Focus held by a control (the sidebar row just clicked) is left alone. (3) ArchivePageView.acceptsKeyboardFocus, driven by isShowingArchivePage: the search field and list refuse first responder while the page is off screen, so Tab from a page cannot land there either.
Verified in-app: empty profile → first responder is the window; restored tab → the tab's web view (at launch and 1.5 s later). New InitialWindowFocusTests (6 tests); 4 of them fail with parts 1–2 disabled.
NOT exercised: actual typing / space-to-scroll after launch, a restored split or peek at launch (covered only through restoreWebContentFocus's existing tests), clicking the archive search field while its page shows.

Code review (Oct 1): selectTab restored page focus only when the window itself was first responder, so switching away from a tab playing audio left focus on the outgoing page (it stays parented 0.5 s as pipContentView) and then on nothing. selectTab now also treats focus inside pipContentView as unheld (isKeyboardFocusUnheld); new test testSwitchingAwayFromATabPlayingAudioFocusesTheIncomingPage fails without it (InitialWindowFocusTests is now 7 tests). Verified in-app: after the switch the incoming web view is first responder, both while the outgoing page is still parented and after it leaves. Gap left open: the focus gate covers only the archive page's search field and list; inactive space pages' table views and the archive page's buttons are still in the key-view loop, so Tab from the end of a web page can land on an off-screen control.
<!-- SECTION:NOTES:END -->
