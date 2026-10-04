---
id: TASK-133
title: 'Tabs: the Control+Tab switcher does not swallow the keys it handles'
status: To Do
assignee: []
created_date: '2026-10-04 01:24'
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
- [ ] #1 A test fails on the current code: a key the switcher handles (Control+Tab; and Escape, Return, an arrow and a letter while it is active) is returned as nil by the monitor's closure, and a key it does not handle is returned unchanged
- [ ] #2 With the fix those keys no longer reach the first responder: verified in the running app that Control+Tab does not move keyboard focus or reach the page, and that Return, Escape, arrows and letters typed while the overlay is up do not reach the page or the sidebar
- [ ] #3 When the switcher has been deallocated the monitor passes events through unchanged
- [ ] #4 Control+Tab switching itself (TASK-108) behaves as before, and RecentTabOrderTests and the switcher's tests pass
- [ ] #5 The task records what the leak visibly caused before the fix, or that nothing was observable
<!-- AC:END -->
