---
id: TASK-132.3
title: >-
  Extensions: unselected tabs stay renderable and able to take synthesized input
  while an extension is driving them
status: To Do
assignee: []
created_date: '2026-10-03 23:07'
updated_date: '2026-10-03 23:15'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 135000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Product decision: Claude must drive tabs that are not selected. Today a hidden tab's web view is not in a window, only one window owns a tab's web view, a sleeping tab has no web view, and WebKit drops a hidden tab's WebContent to a background assertion about 1 s after commit (see the hidden web view load stalls investigation). Screenshots (takeSnapshot) and NSEvent-based input both need a web view that lays out and paints. Design and build the mechanism that keeps a tab 'automation-attached': woken, hosted somewhere it renders at the tab's real size without being visible or stealing focus, exempt from sleep/archive, and handed back cleanly when the tab is selected, moved to another window, or released.

**Constraint (user, 2026-10-03):** "I don't want a solution that elevates priority on all background tabs. If we're elevating thread priority, we should only do that for the ones that the extension is interacting with." The user accepts WebKit's de-prioritisation of ordinary hidden tabs. So anything that keeps a hidden tab's WebContent at foreground priority, painting, or awake must be scoped per tab to a live extension attachment (for example chrome.debugger attached, or a command in flight) and dropped when that ends. A tab that is only a member of the extension's tab group, with nothing attached, is not elevated. No app-wide or profile-wide setting, and no change to how other hidden tabs load.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An automation-attached tab that is not selected produces a snapshot of its current page at the content-area size, not a blank or stale image
- [ ] #2 A sleeping tab is woken when attached, and an attached tab is not put to sleep or archived
- [ ] #3 Selecting the tab, showing it in a second window, or closing it while attached leaves web view ownership consistent (no blank pane, no double-hosted web view)
- [ ] #4 Attaching never changes the selected tab, the key window or the first responder
- [ ] #5 Releasing the attachment returns the tab to normal hidden-tab behaviour
- [ ] #6 docs/webview-ownership.md describes the attached state
- [ ] #7 Only tabs with a live extension attachment are kept at elevated priority or kept rendering; every other hidden tab, including unattached members of the extension's tab group, keeps today's background de-prioritisation, verified by comparing the process assertion state of an attached and an unattached hidden tab
- [ ] #8 No app-wide, profile-wide or configuration-level change raises the priority of hidden tabs in general
<!-- AC:END -->
