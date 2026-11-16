---
id: TASK-362
title: >-
  TabStore: deleteSpace accepts a Private space, leaving that space's undo
  entries inert on the stack
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T10:40:00Z'
labels:
  - spaces
  - incognito
  - undo
dependencies: []
references:
  - Detour/Browser/TabStore.swift
priority: low
type: bug
ordinal: 443000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-357's agent. The UI never offers deleting a Private space, but TabStore.deleteSpace allows it; that space's older undo entries then stay on the stack (inert after TASK-357's guards, but still there).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 deleteSpace on a Private space is refused, or drops that space's undo entries like removeIncognitoSpace does
- [x] #2 A test covers it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Decide: refuse (deleteSpace returns .notDeleted for a Private space) rather than drop its undo entries: deleteSpace of a Private space is a half-removal (the space leaves spaces before Delete Space registers, so that undo is refused anyway; it skips endPrivateSessionIfUnused, so the Private session is never reset), and no caller passes one (Settings and staging list normal spaces only; the sidebar's Delete Space is never offered in a Private window).
2. Simplify the guard to nonIncognitoSpaces.count > 1 plus !isIncognito.
3. Test: deleteSpace on a Private space is refused, leaves the space and its undo entries, and removeIncognitoSpace still drops them; fails on the old code.
4. Wiki tabstore invariants, profiles-and-spaces Delete row, log; review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Premise confirmed by a failing test against the old deleteSpace: it returned .deleted for a Private window's space, and the later removeIncognitoSpace found no space to drop the entries for, so the Private close's undo stayed on the stack. Reading the code: the space left spaces before 'Delete Space' registered, so that undo was refused (an un-undoable half removal), and endPrivateSessionIfUnused never ran (Private session not reset).
Chosen by Claude (not yet confirmed by the user): deleteSpace REFUSES a Private window's space (.notDeleted); a Private space goes only with its window (removeIncognitoSpace). Alternative: let deleteSpace drop that space's undo entries like removeIncognitoSpace (would also need the Private session reset, and the window would still show a removed space). No caller passes one: Settings and automation staging list normal spaces only, the sidebar never offers Delete Space in a Private window, deleteSpaceFromUndoStack only sees normal spaces; no test teardown deletes a Private space with deleteSpace. The old spaces.count > 1 guard is subsumed by nonIncognitoSpaces.count > 1.
Tests: new testDeleteSpaceRefusesAPrivateWindowsSpace (fails on the old code, 3 assertions); PrivateWindowUndoTests 19, LinkRouteStoreTests 42, TabStoreTests 40, UndoAfterDeleteSpaceTests 8, ArchivedTabRestoreTests 20 = 129, 0 failures; PrivateWindowUndoTests re-run after the review tidy: 19/0.
/code-review medium --fix: code correct; fixed a wiki bullet the new invariant had split (forceRemoveSpace line); removed a vacuous assertion in the test. Skipped: the sidebar's delete handler would show its confirmation and then do nothing for a Private space (unreachable: never offered).
Runtime: not applicable (no UI path).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
TabStore.deleteSpace now refuses a Private window's space (.notDeleted): it goes only with its window through removeIncognitoSpace, which drops its undo entries and ends the Private session. Before, deleteSpace removed it as an un-undoable half removal that left its undo entries on the stack and the session un-reset (confirmed by a failing test). No UI offered it. Refusing is Claude's choice, to confirm. 1 new test; 129 tests across 5 suites pass. Wiki tabstore and profiles-and-spaces updated.
<!-- SECTION:FINAL_SUMMARY:END -->
