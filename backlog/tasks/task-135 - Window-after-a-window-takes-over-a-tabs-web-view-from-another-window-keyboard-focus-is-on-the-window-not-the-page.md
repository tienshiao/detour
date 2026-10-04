---
id: TASK-135
title: >-
  Window: after a window takes over a tab's web view from another window,
  keyboard focus is on the window, not the page
status: Done
assignee: []
created_date: '2026-10-04 01:54'
updated_date: '2026-10-04 19:41'
labels:
  - bug
dependencies: []
priority: low
ordinal: 158000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed 2026-10-03 while exercising TASK-132.3 in the running app (two windows on the same space, the same tab selected in both). It is not caused by that task: commit 96756a5 neither added nor removed a makeFirstResponder in the claim path.

When a window claims a tab's web view that another window was hosting — BrowserWindowController.ensureOwnsWebView(), and the hand-off on windowDidBecomeKey — the claiming window's first responder afterwards is the NSWindow itself, not the web view. Seen three times in the harness log (steps 7g, 8c, 8e; .claude/scratch/review132/run2/harness.log in the main checkout, untracked). claimWebView has no makeFirstResponder; selectTab restores web content focus only when the palette was showing or keyboard focus is unheld (TASK-128), and the become-key hand-off does not go through that. Likely effect, not yet confirmed by hand: switching with Cmd-backtick to a second window showing the same tab leaves the page without keyboard focus until it is clicked.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Reproduced or refuted by hand or with real key events: two windows on one space with the same tab selected, switch windows, type — the result is recorded
- [x] #2 After a window becomes key and takes over the web view, the page has keyboard focus when focus was not held by a control in that window (the TASK-128 rule), and focus held by a control such as the sidebar or the palette is left alone
- [x] #3 The window losing the web view shows its snapshot and keeps no stale first responder
- [x] #4 Tests cover the hand-off focus rule; InitialWindowFocus, CommandPaletteFocus and SidebarPageFocus tests still pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Tests first (WebViewHandoffFocusTests): two regular windows on one space with the same tab; 'becoming key' is the delegate call.
2. windowDidBecomeKey (after the Peek restore) and ensureOwnsWebView give the page focus when nothing in the window holds it (isKeyboardFocusUnheld, the TASK-128 rule).
3. The losing window clears a first responder that now lives in the other window.
4. Runtime check with real key events (AC #1) in /verify.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Tests before the fix (the new focus call switched off): WebViewHandoffFocusTests 7 tests, 4 failing — the window taking over, switching back, ensureOwnsWebView and becoming key with nothing focused all left the window as first responder ('got Optional(<NSWindow …>)'). The three others passed without the fix: focus held by a control and an open palette are left alone, and the losing window's first responder already fell back to the window (AppKit does that when the view leaves).

With the fix: WebViewHandoffFocusTests 7/7 (run together with NewProfileExtensionLoadTests 8, RuntimeInstalledEventLoadFailureTests 14, RuntimeInstalledEventTests 19: 48 tests, 0 failures).

Runtime check 2026-10-04, harness build of the batch branch at 822e798, isolated profile, SCREEN LOCKED (so no real key or mouse events; calls go through the app's own entry points).
AC #1 NOT done: with the screen locked the app is not active and no window becomes key (isKeyWindow stayed false for both windows after makeKeyAndOrderFront), so the real hand-off never ran. Owed: two windows on one space with the same tab, Cmd-backtick, type.

Integrated on branch bugfix-batch; full DetourTests suite there: 1970 tests, 11 skipped (gated measurement legs), 0 failures. Code review of the batch range run with --fix. InitialWindowFocusTests, CommandPaletteFocusTests and SidebarPageFocusTests pass in it. Left In Progress for AC #1 (a real window switch and typing, which needs an unlocked screen).

Runtime check with posted key events, 2026-10-04 12:37, SCREEN UNLOCKED, run by the user (open -n, isolated profile DetourVerify135): the harness build of the first batch branch (822e798, with the fix; .claude/task133-135-keys-harness.patch), log in .claude/scratch/task135-harness/out/verify.log of the bugfix-batch-2 worktree. The app was active from the start (appActive=true) and windows became key, unlike the locked-screen run.
Two windows on one space with the same tab (a page with a focused text input that logs keydown), keys posted with NSApp.postEvent to the key window:
- second window opened on the tab: it is key, hosts the web view, first responder = the selected web view; 'q' typed reached the input.
- Cmd+backtick (posted) switched to the first window without the harness's makeKeyAndOrderFront fallback: first window key, web view moved to it, its first responder = the selected web view; the second window's first responder = the window (no stale responder, AC #3 at runtime). 'w' typed reached the input, document.hasFocus() true. The page saw the keydown of the backtick itself; it was not inserted as text.
- second window made key again (makeKeyAndOrderFront): web view back in it, first responder = the selected web view; 'e' typed reached the input.
Input after the three steps: 'Aqwe' (the leading 'a' was typed before the test; it became 'A' when the tab lost focus earlier in the run with no keydown logged, which reads as the system's automatic capitalisation, not checked).
So with the fix a window that takes over the web view on becoming key gives the page keyboard focus and typing lands in it (AC #2 at runtime). NOT shown by this run: the bug itself at the keyboard. The build ran with the fix on (old behaviour=false); before the fix only the unit tests show the window as first responder (4 of 7 failing). The harness has a switch (DETOUR_VERIFY_OLD) that turns the focus call off for a reproduction run.
Harness limits: keys are posted in-process (NSApp.postEvent), not typed on the keyboard; tab B's data: page never loaded in this build (it predates TASK-159), which affects only the Control+Tab part of the log, not the two-window steps (both on tab A).

Reproduction run, 2026-10-04 12:40, same build and launch with DETOUR_VERIFY_OLD=1 (focusWebContentIfUnheld switched off), screen unlocked, app active from the start, same log file (second 'harness armed' block).
- second window opened on the tab (selectTab, not a hand-off): key, first responder = the selected web view, 'q' reached the input, as with the fix.
- Cmd+backtick (posted) switched to the first window and the web view moved to it, but the first window's first responder was THE WINDOW; 'w' did not reach the page (no keydown logged, input unchanged).
- second window made key again: web view back in it, first responder = the window; 'e' did not reach the page.
Input at the end: 'Aq' (with the fix: 'Aqwe'). So AC #1 is REPRODUCED: before the fix, a window that takes the web view over on becoming key leaves keyboard focus on the window and typing is lost. Whether a click then restores it was not tried.
The user reported that another test may have started a browser towards the end of this run. The log does not show an effect: NSApp.keyWindow was the harness's own window at both hand-off steps ('first', then 'second'; an interrupted app would log 'none'), Cmd+backtick switched without the fallback, and the lost keys are explained by the first responder logged before each key was posted. Not excluded: a deactivation in the 0.8 s between a key's post and the page snapshot, which would not change what the first responder was.
document.hasFocus() read true in both runs at every two-window step, so it does not tell the two behaviours apart; the first responder and the input's value do.
The Control+Tab part of the same run showed the TASK-133 leak again (the page got Control+Tab, Control+x, Control+ArrowRight, Control+Escape), as expected with the switch on.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A window that takes over a tab's web view from another window (on becoming key, or through ensureOwnsWebView) now gives the page keyboard focus when nothing in the window holds it (focusWebContentIfUnheld, the TASK-128 rule); focus held by the sidebar, the palette or the find bar is left alone, and the window that lost the web view keeps no stale first responder. WebViewHandoffFocusTests: 4 of 7 failed with the call off, 7/7 with it. Checked in the running app with posted key events, screen unlocked, both behaviours in one harness build: with the call off, after Cmd+backtick the first responder was the window and typed letters never reached the page; with it, the page's web view was first responder after each switch and the letters landed in its input. Keys were posted in-process, not typed on the keyboard, and 'a click restores focus' was not tried.
<!-- SECTION:FINAL_SUMMARY:END -->
