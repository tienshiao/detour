---
id: TASK-293.2
title: >-
  Import from Arc: turn a snapshot into Detour profiles, spaces, pinned entries,
  favourites and history without duplicates
status: Done
assignee:
  - '@claude'
created_date: '2026-11-12T09:22:00Z'
updated_date: '2026-11-12T16:28:00Z'
labels:
  - import
dependencies:
  - TASK-293.1
parent_task_id: TASK-293
ordinal: 385000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Takes the snapshot from TASK-293.1 and the user's choices and changes TabStore and history.db. User decisions (Nov 12 2026): each Arc profile goes to a NEW Detour profile by default, the Arc default profile included (the window can point it at an existing one); Arc's unpinned Today tabs come over as sleeping normal tabs unless the user unticks them. Re-importing (after a later export, or a second direct import) is expected while Arc users move over gradually.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Imported spaces keep their names and emoji (an Arc symbol icon gets a default emoji) and take a colour from Arc's theme; they land in the Detour profile chosen for their Arc profile, a new profile named after the Arc profile by default
- [x] #2 Pinned tabs and folders keep their order and nesting; an Arc split view of two tabs becomes a pinned split, a larger one its first two as a split and the rest as plain entries; favourites become Detour Favorites on the matching profile
- [x] #3 Unpinned tabs come over as sleeping normal tabs when selected; nothing imported creates a web view until the user opens it
- [x] #4 History from the last 90 days is written to the matching profile's history in one background transaction, attributed to an imported space of that profile, and shows up in the History page and the command palette
- [x] #5 Importing the same data twice adds nothing, and importing a newer export or a direct import after an export adds only what Detour does not already have; an item deleted in Detour after an import comes back on the next import (user, Nov 12 2026); an Arc profile or space goes back to the Detour profile or space it went to before, even if renamed, while that still exists
- [x] #6 The import is saved as one change, and a failure part-way leaves the session as it was; there is no undo of an import (user, Nov 12 2026)
- [x] #7 Mapping and dedupe are unit-tested (pure mapping function plus TabStore integration), including the history write
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. ArcImportPlanner (pure, Detour/Import/Arc): snapshot + ArcImportOptions + ArcImportExistingState -> ArcImportPlan (new profiles, spaces new or reused, folders, pinned entries, favourites, sleeping tabs, history targets, links).
2. Dedupe by content only (user): same URL in the same folder of the matched space, same tab URL in the space, same favourite URL on the profile, same visit (URL, space, time). importLink table (migration v25) remembers only Arc profile/space -> Detour profile/space.
3. TabStore.applyArcImport (TabStore+ArcImport.swift): stale check, then one pass (dormant entries and favourites, sleeping tabs with the archive clock at import), profile rows written as addProfile does, one saveNow, links for what was saved. No undo (user). Two small hooks in TabStore.swift (adoptImportedProfile, adoptImportedSpace) because the store's setters are file-private.
4. TabStore.importArcHistory: read off main, HistoryDatabase.importVisits in one background transaction per profile.
5. Tests: ArcImportPlannerTests, ArcImportTabStoreTests; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 12 2026, user decisions: (1) re-import brings back what was deleted in Detour: dedupe is by content only (same URL in the same folder path of the matched space; same favourite URL on the profile); the only memory kept is Arc profile/space -> Detour profile/space, so a renamed space is reused, not duplicated. (2) No undo for an import.

Nov 12 2026, implementation and checks:
- Bug found by the integration tests: the session snapshot does not write profile rows (addProfile writes its own), so a new profile's space failed its foreign key on save; adoptImportedProfile now writes the row.
- /code-review medium --fix: 8 findings. Fixed by the review: a linked space is reused only when it is in this import's target profile (+1 test); the favicon guess uses the shared faviconFallbackURL(for:) (IPv6/percent-encoded hosts). Fixed by me after: a Today split keeps Arc's width share (ArcTabListItem); links are recorded only for spaces the save wrote (.savedExcept); the stale-plan check keeps folders and entries inside their own space (+1 test); ArcImportError is LocalizedError so history failures read as sentences. Left on purpose: Today tabs are not deduped against pinned entries (Arc allows both; recorded in the wiki); a stale .existing profile target falls back silently: the window (TASK-293.3) must refresh its choices before importing.
- Tests: ArcImportPlannerTests 17/0, ArcImportTabStoreTests 9/0, ArcSidebarReaderTests 18/0, ArcExportReaderTests 9/0 (53/0 after the fixes). Before the review fixes, a regression run of 23 suites (AppDatabase, History*, Session*, Favorite*, Pinned*, Profile*, Split, SpaceEntry + the Arc suites) was 550/0.
- /verify: Debug build into .derived (dylib = this build), DETOUR_DATA_DIR=DetourVerify2932: migrations v24 -> v25 ran and created importLink, app stayed up, no errors in its output; quit by PID, its defaults keys and data folder removed. The import has no entry point until TASK-293.3, so applying a real Arc import at runtime is that task's check (AC #5).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Arc import's mapping and apply step: ArcImportPlanner (pure) turns a snapshot plus the user's choices into an exact plan (a new Detour profile per Arc profile, '(Arc)' on a taken name; link -> same-named -> new space; folders by name per parent; shared per-level sort order; two-pane splits with Arc's width share; Today tabs as sleeping tabs; favourites; history targets), deduping by content only and remembering just where each Arc profile and space went (importLink, migration v25). TabStore.applyArcImport checks the plan still fits, adds everything in one pass with no web views, saves once, and records links for what was saved; no undo. HistoryDatabase.importVisits writes the last 90 days per profile in one background transaction without duplicating or renaming newer pages. 26 new tests (planner + real TabStore with relaunch, re-import, stale plans, history readers); 550-test regression run clean; app launches and migrates. Runtime import of real Arc data is TASK-293.3's check.
<!-- SECTION:FINAL_SUMMARY:END -->
