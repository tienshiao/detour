---
id: TASK-226
title: >-
  Extensions: tabs.create adds its tab to the profile's first space, not the one
  in use
status: To Do
assignee: []
created_date: '2026-10-28T08:43:00Z'
labels:
  - extensions
  - profiles
dependencies: []
references:
  - wiki/extensions/tab-and-window-bridge.md
  - TASK-223
priority: low
ordinal: 262000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-223 (2026-10-28). Since TASK-223, windows.create opens a normal window on the caller's profile's most recently used space (TabStore.mostRecentlyUsedSpace(ofProfile:), the spaceUseOrder rule). tabs.create with no windowId still goes through ExtensionManager.space(for:), which picks the profile's first space in sidebar order. With two spaces on a profile and the second in use, an extension's new tab lands in the first space, possibly one no window shows, and the user never sees it. ExtensionPolyfillHandler.targetSpace (tabs created or restored by the polyfilled APIs, e.g. sessions.restore) uses a third rule: the global last active space if it is this profile's, else the profile's first. The three should agree.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 tabs.create without a windowId from a normal profile's context adds its tab to that profile's most recently used space, from both transports, in the promise and callback forms, with a test that fails before the change (two spaces on the profile, the second in use)
- [ ] #2 ExtensionPolyfillHandler.targetSpace uses the same rule, or the task records why it should differ
- [ ] #3 A profile with no space still gets no tab in another profile's space
- [ ] #4 wiki/extensions/tab-and-window-bridge.md 'Opening a window' no longer lists the difference
<!-- AC:END -->
