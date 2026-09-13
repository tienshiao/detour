---
id: TASK-54
title: >-
  Spaces: switching away and back drops a favourite backing tab as the space's
  selected tab
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 08:45'
updated_date: '2026-09-13 09:32'
labels:
  - bug
  - favourites
  - spaces
dependencies: []
priority: medium
ordinal: 54000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed 2026-09-13: with a favourite's backing tab selected (its web view shown), swipe to another space and back — the favourite is no longer selected; the first pinned or first normal tab is shown instead. Cause: BrowserWindowController.setActiveSpace saves the outgoing selection into space.selectedTabID (line ~383) but, on return, restores it only if the id is in space.tabs or space.pinnedEntries (~402-403); favourite tabs live on space.profile.favorites, so the check fails and the fallback picks the first live pinned or first normal tab. selectTab itself already accepts favourite tabs (isFavoriteTab, ~811). Fix the guard to also accept the active profile's favourite tabs (Profile.favoriteTabs, added in TASK-50) and audit the other selectedTabID validity checks for the same gap: TabStore.restoreSession's dropped-tab fallback (~990), updateSpace's profile-swap fallback (~1673), and session restore's initial selection (~734-760, ~842) — a favourite selected at quit should also be re-selected at launch.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Selecting a favourite's backing tab, switching to another space and back (swipe, Cmd+shortcut, menu) re-selects the same favourite tab and shows its web view
- [x] #2 A favourite backing tab selected at quit is selected again after relaunch in that space
- [x] #3 The fallback to the first pinned/normal tab is used only when the saved selected tab is neither a normal, pinned, nor favourite tab of the space's profile
- [x] #4 Unit test on the pure selection-restore rule (or a BrowserWindowController-free helper) covers normal, pinned, favourite and stale ids
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a pure rule (Browser/Window/SpaceSelectionRestore.swift): given the saved selectedTabID and the space's normal tab ids, live pinned tab ids and the profile's favourite tab ids, return the id to select — the saved id when it is any of the three, else the first live pinned, else the first normal tab, else nil (today's fallback order in setActiveSpace).
2. BrowserWindowController.setActiveSpace uses the rule; the three copies of the 'id is a tab of this space' predicate (selectedTab, selectTab guard, displayableTab) share one Space-level lookup (Space.displayableTab(id:) or equivalent) so they cannot drift.
3. Audit: restoreSession's dropped-tab fallback (~990) already covers favourite backing tabs via droppedTabIDs; updateSpace's profile-swap fallback (~1673) deliberately moves off the old profile's favourites; launch selection (AppDelegate) goes setActiveSpace then selectTab(restored.tabID) and is fixed by step 2 (no more transient first-pinned selection). Record findings in notes.
4. Tests: SpaceSelectionRestoreTests (normal, pinned, favourite, stale id, empty space); a TabStore round-trip test asserting a favourite backing tab selected at save is the space's selectedTabID after restoreSession.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fix: Space.displayableTab(id:) is the single membership rule (pinned → favourite → normal); BrowserWindowController.selectedTab, the selectTab guard and displayableTab use it, and setActiveSpace restores selection through Space.tabToSelectOnEntry() (saved id if displayable, else first live pinned, else first normal). Audit: restoreSession's dropped-tab fallback already covers dropped favourite backing tabs via droppedTabIDs; updateSpace's profile-swap fallback deliberately moves off the old profile's favourites; the launch path (setActiveSpace then selectTab(restored.tabID)) no longer transiently selects and wakes the first pinned tab. Review folded the initially separate pure rule into Space so the two predicates cannot drift, and routed ExtensionTabObserver's lookup through it too. Tests: SpaceEntrySelectionTests (9) and a FavoritePeekPersistenceTests round trip of a selected favourite backing tab. Full suite 957 tests green in the worktree.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A favourite's backing tab now survives as the space's selected tab across space switches and relaunch: selection restore and every 'is this a tab of the space' check go through Space.displayableTab(id:), which knows the profile's favourite backing tabs. Verified with SpaceEntrySelectionTests, FavoritePeekPersistenceTests and the full suite.
<!-- SECTION:FINAL_SUMMARY:END -->
