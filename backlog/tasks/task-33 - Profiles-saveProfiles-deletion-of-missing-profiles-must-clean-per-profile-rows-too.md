---
id: TASK-33
title: >-
  Profiles: saveProfiles deletion of missing profiles must clean per-profile
  rows too
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 01:41'
updated_date: '2026-09-13 02:06'
labels:
  - profiles
  - storage
dependencies: []
priority: low
ordinal: 33000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-31 work. AppDatabase.saveProfiles (called from TabStore's session save) deletes every profile row not in the saved set with ProfileRecord.filter(!ids.contains(...)).deleteAll, relying on foreign-key cascades. extensionInstalledEvent has no foreign key, so a profile removed this way (rather than through deleteProfile, which TASK-31 made explicit) leaves its onInstalled ledger rows behind, and the cascades only run while foreign keys are enforced. Route both deletion paths through one helper that deletes the per-profile rows (the TASK-31 list: profileExtension, extensionInstalledEvent, favorite, contentBlockerWhitelist) with the profile row, in the same transaction, never deleting a profile a space still references. Also schedule the on-disk data store removal from the data-store task for profiles removed this way, if that task has landed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Profiles removed by saveProfiles lose the same per-profile rows as deleteProfile, in one transaction, with and without foreign keys enforced
- [x] #2 saveProfiles never deletes a profile still referenced by a space; the rows of profiles in the saved set are untouched
- [x] #3 AppDatabaseTests cover the saveProfiles removal path
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. AppDatabase: one private static helper deleteProfileRows(ids:in:) that, inside the caller's write transaction, skips ids a space still references (logged), deletes the TASK-31 per-profile rows (profileExtension, extensionInstalledEvent, favorite, contentBlockerWhitelist) and the profile row, and records the TASK-32 pending data removal for each profile row it deleted. Returns the deleted ids.
2. deleteProfile(id:) and saveProfiles route through it; saveProfiles computes the stored ids missing from the saved set, deletes them via the helper, then saves the set, all in one transaction. A referenced profile is kept instead of failing the whole write on the foreign key.
3. Check which runtime paths make saveProfiles remove a profile and whether it can be live; record in notes. saveProfiles only records the pending removal (retried at the next launch, which re-checks the profile table), it does not remove data immediately.
4. AppDatabaseTests: saveProfiles removal with foreign keys on and off (per-profile rows gone, pending recorded, saved-set rows untouched, extension tables untouched); a space-referenced profile is kept with its rows and no pending record while the others are saved.
5. Run AppDatabaseTests, ProfileDataRemovalTests, TabStoreTests, then the full DetourTests target.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: AppDatabase.deleteProfileRows(ids:in:) (private static) is the only place a profile row is deleted. Per id, inside the caller's write transaction: skip (and log) if a space references it; delete profileExtension, extensionInstalledEvent, favorite, contentBlockerWhitelist rows; delete the profile row; if a row was deleted, record the TASK-32 pending data removal (never for the Private profile id). deleteProfile(id:) wraps it for one id; saveProfiles reads the stored ids, passes those missing from the saved set, then saves the set, all in one transaction.

Behaviour change: previously a missing profile still referenced by a space made the whole saveProfiles write fail on the foreign key (so the other profiles were not saved either) and, with foreign keys off, was deleted outright. Now it is kept and the rest is saved. saveProfiles only records the pending removal; the removal runs at the next launch (AppDelegate), which re-checks that the id is not in the profile table or in memory.

Can saveProfiles remove a live profile? No, for a single TabStore: saveNow passes every profile it holds (all non-Private profiles plus the built-in Private one; isIncognito is only ever true for TabStore.incognitoProfileID). A row missing from the set is one that store does not own:
(a) restoreSession returns nil before loading profiles when the saved session has no spaces (e.g. quitting or crashing within the 1 s debounce after ensureDefaultProfile saved its row on first launch); ensureDefaultSpace creates a new Default profile and the first save drops the unloaded rows (and the Private row, which gets no pending removal). Covered by ProfileDataRemovalTests.testSessionSaveRemovingUnloadedProfilesRecordsTheirDataRemoval.
(b) a profile TabStore.deleteProfile removed from memory whose row delete failed.
(c) tests only: two TabStores over one database (TabStoreTests) or forceRemoveProfile + saveNow (TestEnvironmentSetup). There the pending row can name a profile another store still holds, which is why the session save never removes data itself; the launch retry is skipped in the test host and TestEnvironmentSetup drops leftover rows.

Against the old saveProfiles the 3 new tests failed 15 assertions (with foreign keys off the referenced profile was deleted, per-profile rows leaked, no pending record; with foreign keys on extensionInstalledEvent leaked and the referenced profile failed the whole save).

Tests: AppDatabaseTests +2 (removal with foreign keys on/off incl. Private row; referenced profile kept while the rest saves, on/off), ProfileDataRemovalTests +1 (session-save path). AppDatabaseTests + ProfileDataRemovalTests + TabStoreTests: 62 tests, 0 failures.

Correction to (a): a normal quit saves the session (applicationWillTerminate -> saveNow), so (a) needs a crash or force-quit within that first second, or a database whose space rows are otherwise gone.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
AppDatabase.deleteProfile and saveProfiles now delete profiles through one private helper that, in the caller's transaction, skips any profile a space references and otherwise deletes the TASK-31 per-profile rows (profileExtension, extensionInstalledEvent, favorite, contentBlockerWhitelist) and the profile row and records the TASK-32 pending data-store removal (never for the Private profile). saveProfiles therefore no longer leaks ledger rows, no longer depends on foreign-key enforcement, keeps a referenced profile instead of failing the whole save (or, with foreign keys off, deleting it), and schedules the on-disk removal for the next launch. With a single TabStore the path cannot remove a live profile: it only drops rows the store does not hold (a launch whose session had no spaces, or a failed deleteProfile row delete). 2 AppDatabaseTests (foreign keys on and off) and 1 session-save test added; they failed 15 assertions against the old code.
<!-- SECTION:FINAL_SUMMARY:END -->
