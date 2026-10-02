---
id: TASK-78
title: >-
  Command palette: after Cmd+L and Return the page does not regain keyboard
  focus
status: Done
assignee:
  - '@claude'
created_date: '2026-09-14 08:03'
updated_date: '2026-10-02 01:45'
labels:
  - window
  - command-palette
  - bug
dependencies: []
priority: medium
ordinal: 78000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-76 review (2026-09-14): BrowserWindowController.dismissCommandPalette only restores first responder in the peek case, so after opening the palette with Cmd+L and committing with Return, the window (or the palette's field) keeps first responder and the page's web view receives no key events at all until the user clicks into it — page shortcuts, typing into an autofocused field, and scrolling with the keyboard all do nothing. Fix: on dismissal, return first responder to the pane's web view (the selected tab's, or the peek web view when a peek is showing) in every dismissal path — commit, Esc, click-outside — mirroring how the peek case already does it; check the new-tab path (Cmd+T commits a navigation in a new tab whose web view is created during the dismissal) and the split case (focus the focused pane, selectedTabID). Files: Detour/Browser/Window/BrowserWindowController.swift (dismissCommandPalette, showCommandPalette), Detour/Browser/CommandPalette/CommandPaletteView.swift.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After Cmd+L, typing a URL and pressing Return, the loaded page receives keyboard input without a click (verified in the signed build: space scrolls the page, or a page shortcut works)
- [x] #2 The same holds for Cmd+T into a new tab, for Esc-dismissal (focus returns to the page that was showing), and for a split, where the focused pane regains first responder
- [x] #3 A unit test on BrowserWindowController covers dismissCommandPalette restoring first responder to the pane web view in the commit and Esc paths
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add BrowserWindowController.restoreWebContentFocus(): focus presented peek web view, else selectedTab (focused pane) web view, only when hosted in this window.
2. dismissCommandPalette: when a palette was showing, call it (replaces peek-only branch) — covers Esc / click-outside / commit-in-place.
3. paletteLoadURL + didRequestSwitchToTab: call it again after selectTab/load so new-tab and switch paths focus the newly hosted web view.
4. Unit tests: commit (in place + new tab) and Esc paths leave the pane web view first responder; split focuses selectedTabID pane.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented BrowserWindowController.restoreWebContentFocus() (peek web view if presented, else selectedTab = focused split pane; only when hosted in this window). dismissCommandPalette calls it when a palette was showing (replaces the peek-only branch); paletteLoadURL (defer) and didRequestSwitchToTab call it again after selectTab so the new tab's / switched-to web view gets focus. commandPaletteView is now private(set) for tests.
Tests: DetourTests/CommandPaletteFocusTests (commit in place, commit into new tab, Esc, Esc in split) — all 4 pass, and all 4 fail with the helper disabled. Full suite: 1749 passed; 3 failures in BrowserTabWakeTests (2) and ExtensionPrivateStoreTests (1) reproduce in isolation and don't touch the changed code (WebKit RBS entitlement errors under an unsigned build in a scratch DerivedData — default DerivedData bundle is blocked by App Management).
AC #1/#2 still need a manual check in the signed build.

Code review fix: selectTab now dismisses the palette with restoringFocus: false and focuses the incoming tab at its end (if a palette was showing) — otherwise focus could stay on an outgoing tab kept parented for PiP (e.g. Cmd+2 with the palette open while a video plays). CommandPaletteFocusTests + ExtensionActiveTabTests pass.

Runtime verify attempt (2026-10-01): built and launched an isolated debug build, but the shell has no Accessibility/Screen Recording grant (AXIsProcessTrusted=false, CGPreflightScreenCaptureAccess=false) — synthetic keys dropped, window titles unreadable. AC #1/#2 still need a manual check.

Runtime verification (2026-10-01, Developer ID-signed Debug build in a scratch DerivedData, isolated DETOUR_DATA_DIR profile, synthetic keys via CGEvent, no mouse clicks). Test pages report each keydown/scroll to a local server and into document.title.
- Cmd+T, URL, Return, space: page got space and scrolled 0->700.
- Cmd+L, URL, Return, space: page got space and scrolled 0->700; AX focused element = AXWebArea.
- Cmd+L then Esc, and Cmd+T then Esc: the showing page got the next key.
- Split (C|D), seeded via DB: with D focused, Cmd+L/Esc and Cmd+L/commit keys went to D only; relaunched with C focused, Cmd+L/Esc key went to C only; Cmd+T commit out of the split focused the new tab.
- Control with restoreWebContentFocus() disabled: after Cmd+L commit and after Esc, AX focus stayed on the window and the page got no keys (bug reproduced), so the harness detects the failure.
Not runtime-verified: click-outside dismissal (same commandPaletteDidDismiss path as Esc), peek, and the PiP tab-switch case from code review.
Observed, out of scope: on launch the sidebar's 'Search Archive…' field holds first responder.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Dismissing the command palette now returns first responder to the page. New BrowserWindowController.restoreWebContentFocus() focuses the presented peek's web view, else the selected tab's (the focused pane in a split), when hosted in this window; dismissCommandPalette calls it whenever a palette was showing, and the commit paths (new tab, switch-to-tab) and selectTab call it again once the incoming web view is hosted (selectTab dismisses without restoring so focus never lands on an outgoing PiP-parented tab). Covered by DetourTests/CommandPaletteFocusTests (4 tests, fail without the fix) and verified at runtime in the signed build with synthetic keys: Cmd+L/Cmd+T commit, Esc, and both panes of a split, plus a fix-disabled control that reproduced the bug.
<!-- SECTION:FINAL_SUMMARY:END -->
