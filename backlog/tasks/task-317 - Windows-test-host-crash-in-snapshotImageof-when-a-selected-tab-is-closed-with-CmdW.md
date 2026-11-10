---
id: TASK-317
title: >-
  Windows: test host crash in snapshotImage(of:) when a selected tab is closed
  with Cmd+W
status: To Do
assignee: []
created_date: '2026-11-10T08:59:00Z'
labels:
  - window
  - crash
  - bug
dependencies: []
references:
  - TASK-315
  - Detour/Browser/Window/BrowserWindowController.swift
  - Detour/Browser/Window/BrowserWindowController+TabStore.swift
  - DetourTests/WindowCloseReleaseTests.swift
priority: low
type: bug
ordinal: 379000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen once on 2026-11-10 while working on TASK-315, in the test host (Debug), in a run of WindowCloseReleaseTests against the unfixed BrowserWindowController.swift (HEAD 750bd43). The crash happened during testAWindowThatClosedATabIsFreed, which ran before any of the leaking histories (picture in picture, docked inspector), so the TASK-315 leak is not its cause. Not reproduced in 4 later runs with the TASK-315 fix (19 tests each, one with -test-iterations 3). Crash report: ~/Library/Logs/DiagnosticReports/Detour-2026-11-10-004707.ips on the user's Mac (not committed: it carries machine identifiers).

EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS, 'possible pointer authentication failure': a message sent to a freed or garbage object. Crashing thread:
  objc_msgSend
  BrowserWindowController.snapshotImage(of:)  BrowserWindowController.swift:1972 (HEAD numbering)
  BrowserWindowController.tabStoreDidRemoveTab(_:at:in:)  +TabStore.swift:29 (inlined selectAdjacentTabAfterRemoval -> selectTab)
  TabStore.notifyObservers / TabStore.closeTab(id:in:archivedAt:undoable:registersUndo:)  TabStore.swift:2854
  BrowserWindowController.closeTab(at:wasSelected:archivedAt:)  :2746
  BrowserWindowController.closeCurrentTab(_:)  :2703
  WindowCloseReleaseTests.testAWindowThatClosedATabIsFreed (wc.closeCurrentTab(nil) on a window showing 'Release Work' with the second of two loopback tabs selected)

The puzzle: tabStoreDidRemoveTab only re-selects when the observer's selectedTabID is the removed tab, and the closing window's own closeTab(at:wasSelected:) settles its selection before calling store.closeTab. So the observer that crashed was a window other than the one closing the tab, on the same (freshly created) space, with that tab selected. The test made no such window. Candidates: an earlier test's window still registered as a TabStore observer (TabStore observers are weak wrappers; a controller whose windowWillClose never ran, e.g. a window closed by tearDown before it was ever shown, or a freed controller's stale entry), a window whose activeSpaceID was reassigned when its own space was force-removed in a previous tearDown, or the closing window itself notified twice. Then snapshotImage(of:) messaged a view that was already gone (the previous tab's container or web view).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The crash is reproduced (a test or a harness loop that fails), or the window and view involved are identified from evidence
- [ ] #2 Fixed with a test that fails without the fix, or closed with the evidence for why it cannot happen in the app
<!-- AC:END -->
