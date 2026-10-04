---
id: TASK-132.23
title: 'Extensions design: report each space as a WebKit window'
status: To Do
assignee: []
created_date: '2026-10-04 00:27'
updated_date: '2026-10-04 00:30'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 155000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Today a BrowserWindowController is the WKWebExtensionWindow, and it reports only its active space's tabs. Consequences found during TASK-132.2 (2026-10-03): switching a window's space swaps its whole tab list with no events; a tab in a space no window is showing belongs to no window (extensionWindow() is nil) and is absent from tabs.query; a window changes profile, and so which extension contexts it belongs to, when it switches to a space on another profile; WebKit learns of a window only at context load or when it becomes key (TASK-132.22). For the Claude extension that means its session tabs drop out of every window when the user switches space mid-task.

Proposal the user is in favour of (2026-10-03): make the Space the WebKit window. A tab's window is its space and never changes on a space switch; a space switch is a focus change; a space has exactly one profile; window opened/closed is space created/deleted; an extension's windows.create yields a new space (which matches the user's early idea of a separate space for Claude's tabs).

Decided:
- Pinned tabs and favourites are reported as tabs in a space's window (user: 'I'm good with reporting pins/favorites in a space as a tab in a window'). A pinned entry's live tab belongs to its space. A favourite's live backing tab is profile-level, so it gets ONE home space, so it appears once in tabs.query: the space it is selected in, else the last space it was used in, else the profile's first space. Not reporting favourite tabs is ruled out: content scripts run in them regardless, and unreported tabs fail every runtime.sendMessage with 'tab not found' (TASK-50, runaway CPU on a Google Calendar favourite with 1Password).
- A favourite or pinned tile with no live page stays unreported, as today.

To design (each needs a stated rule):
- One space shown in two browser windows, or in none: which frame, state, focus and active tab the space-window reports (candidate: the frontmost browser window showing it; minimised when none shows it), and what windows.update({focused, state, left, top, width, height}) and captureVisibleTab do.
- The active tab of a space. WebKit drops a window's whole tab list unless it names an active tab that is in the list (WebExtensionWindow::tabs(), same on WebKit main). For a space not on screen the remembered selection (Space.selectedTabID / its displayable-tab fallback) is a natural answer. For a space on screen with nothing selected the user does not want an active tab reported; the candidate is a stand-in that satisfies WebKit and is masked from extensions in the polyfill (marked not-highlighted, rewritten to active: false, excluded from active queries, no activation event, captureVisibleTab refused, default-tab calls wrapped). This replaces the direction written in TASK-132.21. Not yet confirmed by the user.
- Extension-created windows: windows.create(type normal) creates a space (naming, emoji/colour, whether it is ephemeral, where it is shown), windows.remove deletes one with its tabs (confirmation?). Popup-type windows (TASK-132.18) are not spaces, so there are two kinds of WebKit window.
- Private: the incognito space of a Private window.
- tabs.move / tabs.create({windowId}) across spaces, including the existing Move to Space rules.
- Peek tabs (TASK-50/51) and split panes under the new mapping.
- Migration of the placement rule and activation funnel (ExtensionTabLifecycle, ExtensionActiveTabTracker, BrowserTab.extensionWindow()) and which verified 1Password behaviours need re-checking (TASK-51, TASK-52, TASK-81 windows.getCurrent with no key window).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A design document states the rule for every item under 'To design', with the WebKit behaviour each rule relies on cited from source or measured
- [ ] #2 The design says what tabs.query, windows.getAll, windows.getCurrent / getLastFocused, tab.windowId and the tabs/windows events report for: one window with several spaces, two windows on one space, a space no window shows, a Private window, and a space switch
- [ ] #3 The favourite home-space rule and the pinned-tab rule above are written into the design
- [x] #4 The nothing-selected rule is confirmed with the user and TASK-132.21 is rewritten or closed to match
- [ ] #5 TASK-132.22 is rewritten or closed in terms of space lifecycle
- [ ] #6 Implementation is split into follow-up tasks with tests named; nothing is implemented in this task
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-03: nothing-selected rule confirmed by the user as 'we can try your proposal' — the masked stand-in. TASK-132.21 is rewritten to that approach and records the three alternatives (leave it; unmasked stand-in; placeholder blank tab) plus the weak points to watch, as the starting point if it does not hold up in testing. The design should carry the same rule and alternatives.
<!-- SECTION:NOTES:END -->
