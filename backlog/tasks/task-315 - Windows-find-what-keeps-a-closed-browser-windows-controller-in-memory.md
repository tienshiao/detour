---
id: TASK-315
title: 'Windows: find what keeps a closed browser window''s controller in memory'
status: To Do
assignee: []
created_date: '2026-11-09T17:50:00Z'
labels:
  - window
  - memory
  - bug
dependencies: []
references:
  - TASK-314
  - Detour/Browser/Window/BrowserWindowController.swift
  - docs/harness/task314-harness.patch
priority: low
type: bug
ordinal: 377000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found under TASK-314 (2026-11-09). In the user's production app (0.4.2 build 10), a browser window they had closed was still in memory hours later. Its controller was alive and its window was still in NSApp.orderedWindows. A link placement then showed it again. TASK-314 stops closed windows from being picked, so this is now a leak of one window (its controller, sidebar, palette and views), not a functional bug.

What we know:
- A plain closed window is freed. Harness mode 'leak' (TASK-314 patch) keeps only a weak reference: the controller is gone within 1 s of performClose, and 'leaks --traceTree' finds nothing at its address.
- RoutedOpenRecord holds its windows weakly, so it isn't the holder.
- A closed-but-alive NSWindow keeps its window number and stays in CGWindowList as off-screen, so a running app can be checked for retained closed windows without a debugger (CGWindowListCopyWindowInfo with .optionAll, layer 0, onscreen false, browser-window size).
- The retained window's known history: it was one of two browser windows restored at launch, the two windows sometimes showed the same space and tab, and it received a quarantine Open in. When and how the user closed it is not known.

Candidates to replay, each followed by close + weak-ref check + leaks --traceTree: two windows sharing a selected tab (web view ownership hand-over, script message handlers added by the owning window: releaseOwnedWebViewHandlers only acts when the window owns the web view at close), Peek, find bar, command palette open at close, extension popovers, a Quick Detour or quarantine Open in into the window, Combine sinks or closures capturing self strongly.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The holder is found by replaying a history in the Debug build where a closed window stays alive; leaks --traceTree names the retain path
- [ ] #2 Fixed so that every replayed history frees the window after close, with a test that closes a window after that history and asserts a weak reference to its controller becomes nil
<!-- AC:END -->
