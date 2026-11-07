---
id: TASK-132.10
title: >-
  Tabs: tab group model in TabStore (membership, title, colour, collapsed) with
  persistence
status: Done
assignee:
  - '@claude'
created_date: 2026-10-03 23:09
updated_date: '2026-11-07T23:43:00Z'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 142000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add tab groups for normal tabs: a group id on the tab and a group record on the Space (title, colour from Chrome's nine names, collapsed). This is the model the tabGroups extension API and the sidebar stripe build on; no user-facing way to create a group is required yet. Decide and enforce the invariants alongside split groups: a split pair is wholly inside or outside a group; whether members must be contiguous (Chrome's are) and, if so, snap insertions and move blocks the way split groups do. Pinned tabs and favourites are never grouped (Chrome ungroups on pin).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A tab can be added to a new or existing group and removed from it; a group with no members left is removed
- [x] #2 Group title, colour and collapsed state can be read and changed
- [x] #3 Closing, archiving, pinning, making a favourite, moving to another space or detaching a member updates membership and never leaves a split pair half in a group
- [x] #4 Undo of a close or move restores the tab's group membership when the group still exists
- [x] #5 Groups and membership survive a relaunch; a database from before the migration loads with no groups
- [x] #6 Observers are notified of group creation, change and removal
- [x] #7 Unit tests cover the invariants; docs/data-model.md describes the model
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Model: `TabGroup` (final class: id, title, color, isCollapsed) in `Space.tabGroups`; `TabGroupColor` = Chrome's nine names as raw strings (grey blue red yellow green pink purple cyan orange); membership as `BrowserTab.tabGroupID`, like `splitGroupID`. Groups are per space and hold only normal tabs.
2. Invariants (held by construction, checked by a sanitizer at load and after Undo Delete Space): members contiguous in `space.tabs`; a split pair is wholly in or out; every tabGroupID names a group of the space and every group has a member (an emptied group is removed in the same mutation); pinned backing tabs, favourites, Peeks and Quick Detours are never members.
3. Placement rule, pure and tested (TabInsertion / a new TabGroups.swift): a block (lone tab or split pair) landing in a gap joins the group on both sides of it; otherwise keeps its preferred group (its own when moving, the remembered one for undo) only while it lands next to a member of that group; otherwise is ungrouped. A block that is the whole of its group carries it and snaps out of other groups' interiors, as moveTabGroup does. Insertions keep snapping out of split interiors first.
4. Store API: createTabGroup(tabIDs:…), addTabs(_:toGroup:), ungroupTabs(_:), updateTabGroup(id, title/color/collapsed), moveTabGroup(id, toGapIndex:), lookups. Placement follows Chrome's TabStripModel (new group gathers at the first tab; tabs left of an existing group join at its left edge, right ones at its right edge; ungrouped tabs leave to the right edge unless already a prefix). Pinned, favourite, other-space or unknown ids throw and change nothing. No undo for group mutations themselves (no user UI yet).
5. Every existing mutation: close/archive, pin (incl. pinSplitGroup), detach to favourite, cross-space move leave the group; within-space move, removeTabFromSplit, unpin, insertTab use the placement rule; createSplit/addTabInSplit put the new pair in the anchor's group; close undo and move undo rejoin the remembered group when it still exists and the slot is next to it (or rejoin via the split partner's group).
6. Observers: didCreate/didUpdate/didRemove/didMove TabGroup and didChangeTabGroupMembership(of:), default no-ops.
7. Persistence: migration v23 (tab.tabGroupID, tabGroup table with spaceID FK cascade); groups saved per space in the snapshot and in the space unit of the isolating save; no FK from tab to tabGroup (the sanitizer clears dangling ids). Main may add its own v23 before the epic lands: renumber at that merge.
8. Tests: pure placement rules, TabStore group mutations and every mutation in #5, undo, sanitizer, migration from v22 and save/relaunch round trip. docs/data-model.md and a wiki page.

9. (Added after review) Undo of Pin Tab and Pin Split also restores the group. An undo recreates a removed group only after its tab is back in the list (reinstateTabGroup), so no observer sees a group without members.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-07, decisions (user): (a) a tab opened from a grouped tab (target=_blank, window.open, child tab) joins the opener's group when it lands next to it, as in Chrome; one that follows siblings outside the group stays ungrouped. (b) Undo of closing a group's last tab recreates the group (same id, title, colour, collapsed) with the tab; this goes beyond AC #4, which only asks for a rejoin while the group exists. Also decided (not asked): members are contiguous (Chrome; needed for TASK-132.19 header rows); a tab dropped between two members joins the group; undo of a close or move whose group still exists puts the tab back inside that group, clamped to the group's current range if it moved.

2026-11-07, implementation: model, pure rules and colours in Detour/Browser/TabGroup.swift; store API and the mutation helpers in TabStore+TabGroups.swift; every insertion site in TabStore.swift goes through placement(forGap:intent:in:) (byPosition / rejoin / carry), every exit through leaveTabGroup, every mutation ends with settleTabGroups. Migration v23 (tab.tabGroupID, no FK; tabGroup with FK to space, cascade); groups saved per space and inside the space unit of the isolating save. SessionSnapshot.tabGroups has no default, so a snapshot cannot drop groups by omission.
/code-review high --fix: 10 findings, 7 fixed by the review (tabStoreDidMoveTabGroup for a carried group, new dormant panes not announced in unpinSplitGroup, four missing mutation tests, a TabGroup<->record mapping in one place, a duplicated rule switch, the snapshot default, the addTabs lookup). The two it skipped were fixed afterwards: an undo now recreates a removed group only once its tab is in the list (create is reported with the member present, before the insertion), and Undo Pin Tab / Undo Pin Split restore the group (my original choice not to was not the user's; it was inconsistent with close and move). The tenth (O(n·m) lookup) was fixed by the review too.
Tests: TabGroupPlacementTests 17/0, TabGroupStoreTests 40/0, SessionSnapshotRepairTests 10/0. Affected suites (30 suites: TabStore, Split*, Pinned*, Favorite*, Session*, MoveTabToSpace, QuickDetour*, Sidebar*, UndoAfterDeleteSpace, AppDatabase, SiteSearch*, ArchivedTabRestore, ExtensionPage{Favorite,Undo}, ProfileDeletionUndo, TabInsertion, TabCloseSelection, SpaceEntrySelection and the two new ones): 601 tests, 0 failures. Full suite not run.
Runtime (/verify, DETOUR_DATA_DIR=DetourVerify-tg1, build of 15:42 from this worktree): a fresh launch migrated through v23 (tabGroup table with the FK, tab.tabGroupID); with a seeded group on A, B and the non-adjacent D, a relaunch and the app's own save cleared D and kept A, B and the group row (same id, title, colour). Not checked at runtime: anything on screen (there is no UI yet, TASK-132.11) and undo (tests only). Data dir and its two defaults keys deleted.
Not done here, on purpose: closedTab rows keep no group (Reopen Closed Tab and the Archived Tabs page restore ungrouped); making a favourite has no group-restoring undo; the timer archive closes grouped tabs like any other (an idle agent tab of the Claude extension can be archived out of its group after the profile's threshold).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Tab groups in TabStore, the model TASK-132.11 (stripe) and TASK-132.12 (chrome.tabGroups) build on. A TabGroup (title, one of Chrome's nine colour names, collapsed) lives in Space.tabGroups; membership is BrowserTab.tabGroupID, like a split. Invariants held in every mutation: members contiguous, a split pair wholly in or out, only normal tabs (pin, favourite and Move to Space take a tab out), no empty group. One pure placement rule decides where an entering tab or split lands and which group it joins: between two members it joins; next to its own or its opener's group it keeps that one (user decision: opened tabs join the opener's group); a whole group is carried and snaps out of others. Chrome-like API: createTabGroup, addTabs(_:toTabGroup:), ungroupTabs, updateTabGroup, moveTabGroup, throwing TabGroupError and changing nothing for pinned, favourite, other-space or unknown ids. Undo of a close, move or pin puts the tab back into its group and recreates a group the action removed (user decision). Observers: create, update, move, remove, membership change. Persistence: migration v23 (renumber when the epic merges into main), sanitizer at load and after Undo Delete Space. Tests: 57 new across two suites; 601/0 over the affected suites; runtime migration and relaunch checked. Docs: docs/data-model.md, wiki/tabs/tab-groups.md. Follow-ups not filed: closed-tab records keep no group; the archive timer can archive an idle grouped tab.
<!-- SECTION:FINAL_SUMMARY:END -->
