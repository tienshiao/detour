---
id: TASK-133
title: 'Tabs: the Control+Tab switcher does not swallow the keys it handles'
status: In Progress
assignee: []
created_date: '2026-10-04 01:24'
updated_date: '2026-10-04 08:09'
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
- [ ] #2 With the fix those keys no longer reach the first responder: verified in the running app that Control+Tab does not move keyboard focus or reach the page, and that Return, Escape, arrows and letters typed while the overlay is up do not reach the page or the sidebar
- [x] #3 When the switcher has been deallocated the monitor passes events through unchanged
- [ ] #4 Control+Tab switching itself (TASK-108) behaves as before, and RecentTabOrderTests and the switcher's tests pass
- [ ] #5 The task records what the leak visibly caused before the fix, or that nothing was observable
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
<!-- SECTION:NOTES:END -->
