---
id: TASK-38
title: >-
  Tabs: Move to Space loses extension pages (rebuilds the tab in the space
  configuration)
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 03:21'
updated_date: '2026-09-13 19:36'
labels:
  - extensions
  - tabs
  - bug
dependencies: []
priority: low
ordinal: 38000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-34 work, not yet confirmed. The sidebar context menu's Move to Space appears to rebuild the moved tab with addTab(in:url:), i.e. a new web view in the destination space's configuration, instead of moving the BrowserTab. A webkit-extension:// page cannot load in a space configuration (TASK-24: extension pages must be built through TabStore.makeTab(loading:) so BrowserTab.wake uses the owning context), so moving an extension page tab is likely to give a dead tab; moving to a space of a different profile has no context for the extension at all. Also check whether ordinary tabs lose back/forward history on the move. First confirm the current behaviour with a test, then fix: within the same profile move the tab (or rebuild via makeTab(loading:) with the rehomed URL); across profiles, rebuild through the destination profile's context if the extension is enabled there, otherwise refuse the move for extension pages. Keep split groups and pinned state rules from CLAUDE.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A test demonstrates the current Move to Space behaviour for an ordinary tab and an extension page tab, and the finding is recorded
- [x] #2 Moving an extension page tab to another space of the same profile keeps a loadable page; to a space of another profile it loads there if the extension is enabled in that profile, and is otherwise refused without losing the tab
- [x] #3 Ordinary tabs keep their existing (or improved, if history loss is found) behaviour; split members and pinned entries follow the documented rules; tests cover each case
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Confirm with a test first: BrowserWindowController+TabSidebar didRequestMoveTabAt closes the tab (archiving it to the closed-tab stack and registering a Close Tab undo) and calls addTab(in: dst, url:), so the moved tab loses interaction state/history, an extension page gets a dead tab, and a pinned entry becomes an ordinary tab.
2. Add TabStore.moveTab(id:from:to:) for normal tabs and movePinnedEntry(id:from:to:) for pinned entries, returning Bool. Same profile: move the BrowserTab object (remove from src with leaveSplitGroup / dissolvePinnedSplit, set tab.spaceID = dst.id, insert at the end of dst via insertTab / append entry, keep the web view). Different profile: sleep(force: true) + ExtensionTabLifecycle.didClose(tab) as the profile-swap path in updateSpace does, so wake rebuilds from the destination configuration; for an extension page rehome the URL onto the destination profile origin (rehomedTileURL / dormantTilePage as TASK-34) when the extension is enabled there, otherwise return false and leave the tab. Split groups: a member leaves its group. Keep pinned entries pinned (dormant entries move as dormant).
3. Register one Move to Space undo that moves back. Notify src (tabStoreDidRemoveTab / DidRemovePinnedEntry) and dst (insert) observers; scheduleSave.
4. Window: didRequestMoveTabAt uses the new API, handles selection when the moved tab was selected (pick the next tab as closeTab(at:wasSelected:) does), and shows the dormant-tile refusal toast on false.
5. Tests (MoveTabToSpaceTests): normal tab keeps identity and web view within a profile; pinned entry stays pinned; cross-profile move sleeps the tab and it wakes from the destination configuration; extension page within a profile keeps loading; extension page to a profile where the extension is disabled is refused; undo restores the source; split member leaves its group; no closed-tab record is created.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Confirmed by characterization tests: the old handler closed the tab (closed-tab record + Close Tab undo) and rebuilt it from the destination space configuration, so extension pages died and pinned entries were unpinned. Fix: TabStore.moveTab / movePinnedEntry move the objects within a profile (web view kept) and across profiles sleep or retarget the tab so wake rebuilds from the destination configuration; extension pages are rehomed onto the destination origin or refused; dormant entries move dormant; one Move to Space undo. Extra fix: moves across the incognito boundary are refused and the Move to submenu is hidden in incognito windows, since moving the live web view would carry private session history into a persistent profile. Review pass (ceda589): destination-profile refusal toast, store asked before selection settles, host Peek parked and its peekURL retargeted or dropped, undo restores parentID and re-resolves pinned entries by id with a sanitize pass, selection fallback follows tabToSelectOnEntry. Known limits: undo does not re-form a normal-tab split; a same-profile move reports close+open to the contexts (TASK-61 filed by the review for a didMoveTab seam). MoveTabToSpaceTests; full suite 1104 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Move to Space moves the tab or pinned entry itself instead of closing and recreating it: history and identity survive, extension pages stay loadable or are refused with a toast, pinned entries stay pinned, and the move is undoable. Verified by MoveTabToSpaceTests plus the split, pinned and lifecycle suites.
<!-- SECTION:FINAL_SUMMARY:END -->
