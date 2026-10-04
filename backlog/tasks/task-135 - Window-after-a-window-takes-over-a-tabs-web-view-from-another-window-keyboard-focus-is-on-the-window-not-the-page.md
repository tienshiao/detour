---
id: TASK-135
title: >-
  Window: after a window takes over a tab's web view from another window,
  keyboard focus is on the window, not the page
status: In Progress
assignee: []
created_date: '2026-10-04 01:54'
updated_date: '2026-10-04 08:22'
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
- [ ] #1 Reproduced or refuted by hand or with real key events: two windows on one space with the same tab selected, switch windows, type — the result is recorded
- [ ] #2 After a window becomes key and takes over the web view, the page has keyboard focus when focus was not held by a control in that window (the TASK-128 rule), and focus held by a control such as the sidebar or the palette is left alone
- [ ] #3 The window losing the web view shows its snapshot and keeps no stale first responder
- [ ] #4 Tests cover the hand-off focus rule; InitialWindowFocus, CommandPaletteFocus and SidebarPageFocus tests still pass
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
<!-- SECTION:NOTES:END -->
