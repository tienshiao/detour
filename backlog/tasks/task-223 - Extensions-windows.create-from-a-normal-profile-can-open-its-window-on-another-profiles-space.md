---
id: TASK-223
title: >-
  Extensions: windows.create from a normal profile can open its window on
  another profile's space
status: To Do
assignee: []
created_date: '2026-10-28T07:56:00Z'
labels:
  - extensions
  - security
  - profiles
dependencies: []
references:
  - wiki/extensions/tab-and-window-bridge.md
  - TASK-214
  - TASK-132.23
priority: medium
ordinal: 259000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-214 (2026-10-28). openNewWindowUsing in ExtensionManager places a normal window with AppDelegate.assignDefaultSpace: the key normal window's space, else lastActiveSpaceID, else the first normal space. None of these looks at the calling extension's profile, so an extension enabled in profile A can open a window whose tabs load on a profile B space, with B's cookies, storage and history, and the window then belongs to B's extension contexts rather than A's. tabs.create does not have this problem: it adds the tab to the caller's own space (space(for:)). Open question for the user before work starts: where the window goes when the caller's profile has no space open in any window (its last active space, a new space on that profile, or refuse the call). TASK-132.23 (epic branch) proposes that windows.create yields a new space; the answer here should not contradict it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A windows.create call from a normal profile's extension context opens its window on a space of that same profile, from both transports, in the promise and callback forms
- [ ] #2 The case where the caller's profile has no open space follows the user's recorded decision, with a test
- [ ] #3 A test with two normal profiles fails before the fix (the window lands on the other profile's space) and passes after
- [ ] #4 wiki/extensions/tab-and-window-bridge.md 'Opening a window' records the rule
<!-- AC:END -->
