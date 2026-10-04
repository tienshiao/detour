---
id: TASK-133
title: 'Tabs: the Control+Tab switcher does not swallow the keys it handles'
status: Done
assignee: []
created_date: '2026-10-04 01:24'
updated_date: '2026-10-04 09:02'
labels:
  - bug
dependencies: []
priority: medium
ordinal: 156000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-03 by a code review of the Claude-extension epic branch; the code predates that work and is on main (TASK-108).

RecentTabSwitcher's local event monitor is installed as
    MainActor.assumeIsolated { self?.handle(event) ?? event }
(Detour/Browser/Window/RecentTabSwitcher.swift, init). handle(_:) returns NSEvent? and returns nil to swallow an event: Control+Tab and Control+Shift+Tab ('Ours even when there is nothing to switch to'), and while the switcher is active Escape, Return, the arrow keys and every other key ('Nothing typed while switching reaches the page'). Optional chaining flattens the result to NSEvent?, so a nil from handle and a nil from a dead self are the same nil, and '?? event' turns both back into the event. A standalone Swift program with the same shape (a method returning Int?, called through optional chaining inside a generic closure, followed by ?? event) returned the event in the swallow case. So the monitor most likely never swallows anything: the switcher acts on the key AND the key continues to the key window's first responder.

Not yet observed in the app, and what it visibly breaks is unknown. Candidates to check: Control+Tab reaching AppKit's key-view navigation (focus moving to the next key view) or the page; Return, Escape, arrows and typed characters reaching the page or the sidebar while the overlay is up.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A test fails on the current code: a key the switcher handles (Control+Tab; and Escape, Return, an arrow and a letter while it is active) is returned as nil by the monitor's closure, and a key it does not handle is returned unchanged
- [x] #2 With the fix those keys no longer reach the first responder: verified in the running app that Control+Tab does not move keyboard focus or reach the page, and that Return, Escape, arrows and letters typed while the overlay is up do not reach the page or the sidebar
- [x] #3 When the switcher has been deallocated the monitor passes events through unchanged
- [x] #4 Control+Tab switching itself (TASK-108) behaves as before, and RecentTabOrderTests and the switcher's tests pass
- [x] #5 The task records what the leak visibly caused before the fix, or that nothing was observable
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extract the monitor closure's expression into RecentTabSwitcher.monitorResult(for:switcher:) so it can be tested without a live event stream.
2. Tests first (RecentTabSwitcherMonitorTests): Control+Tab, Control+Shift+Tab, and Escape/Return/arrows/letter/space while active return nil; unhandled keys, another window's events and a released Control return the event; a nil switcher returns the event.
3. Fix: guard-let the switcher, then return handle(event) unflattened.
4. Runtime check of what the leak caused (AC #2, #5) in /verify.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Tests before the fix (monitorResult with the original expression 'switcher?.handle(event) ?? event'): RecentTabSwitcherMonitorTests 10 tests, 6 failing with 9 assertion failures — every swallow case returned the event (Control+Tab, Control+Shift+Tab, Control+Tab with nothing to switch to, Escape, Return, arrows/letter/space while active); the 4 pass-through cases passed. So the monitor never swallowed anything, as the task suspected.
After the fix: RecentTabSwitcherMonitorTests 10/10, RecentTabOrderTests 10/10.

Runtime check 2026-10-04, harness build of the batch branch at 822e798, isolated profile, SCREEN LOCKED (so no real key or mouse events; calls go through the app's own entry points).
AC #2 and AC #5 NOT done: they need real key events reaching a page, which a locked screen does not deliver. Owed: with a page focused, Control+Tab (does focus move, does the page see Tab), and Return / Escape / arrows / letters while the overlay is up; and the same on main to record what the leak caused.

Integrated on branch bugfix-batch; full DetourTests suite there: 1970 tests, 11 skipped (gated measurement legs), 0 failures. Code review of the batch range run with --fix. Left In Progress for AC #2 and #5 (real key events against a page, which need an unlocked screen). wiki/tabs/tab-switching.md no longer lists the leak as an open defect.

Runtime check with real key events, 2026-10-04 (screen unlocked): a temporary harness in a Debug build of the batch branch, isolated profile, posts NSEvents with NSApp.postEvent to a tab whose page logs every keydown; a temporary environment switch puts the old monitor expression back, so both behaviours ran in the same build (2 runs old, 4 runs fixed; the app was the active app in one of the fixed runs, results were the same).

What the leak caused (AC #5), old expression: holding Control+Tab and typing x, Right arrow and Escape, the page received keydown for Control+Tab, Control+x, Control+ArrowRight and Control+Escape, on top of what the switcher did with them. A later 'Control+Tab, Return' did not switch tabs in either old run (it did in every fixed run); my reading, not verified, is that the leaked Control+Tab comes back from the page unhandled and reaches the switcher a second time. Keyboard focus did not move in these runs: the first responder stayed the page's web view.

With the fix (AC #2): the page's key log holds only the plain letter typed before the test and the Control modifier's own flagsChanged (passed on by design); no Tab, letter, arrow or Escape. The first responder stays the selected web view throughout, never the sidebar. Control+Tab tap flips to the previous tab, Control+Tab then Return commits, Escape cancels (AC #4 at runtime).
Limit: Return while switching could not be observed directly at the page, because the commit switches tabs before a leaked Return would be delivered; it takes the same path as the other swallowed keys (the monitor returning nil), which RecentTabSwitcherMonitorTests pins for Return too.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Control+Tab switcher's event monitor returned 'self?.handle(event) ?? event', which turned every swallowed key (handle's nil) back into the event, so keys the switcher acted on also went to the page. The monitor now calls RecentTabSwitcher.monitorResult(for:switcher:), which passes events on only when the switcher is gone. Unit tests failed before the fix (6 of 10). Measured in the launched app with real posted key events: before, the page received Control+Tab, the letter, the arrow and Escape, and a later Control+Tab + Return failed to switch; after, the page receives none of them, focus stays on the page, and switching works.
<!-- SECTION:FINAL_SUMMARY:END -->
