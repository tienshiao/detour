---
id: TASK-31
title: 'Profiles: deleting a profile must remove its per-profile rows'
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 00:58'
updated_date: '2026-09-13 01:06'
labels:
  - profiles
  - storage
dependencies: []
priority: low
ordinal: 31000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-27 work. AppDatabase.deleteProfile only deletes the profile row (after checking no space references it). Rows keyed by profileID are left behind with no foreign keys: profileExtension (per-profile enabled state, TASK-26), extensionInstalledEvent (onInstalled ledger, TASK-22/29), favorite, contentBlockerWhitelist, and any other profileID-keyed table (audit the migrations in Detour/Storage/Database.swift). It is harmless while profile ids are fresh UUIDs, but it is unbounded growth and a correctness trap for any future code that enumerates those tables. Delete them in the same transaction as the profile row, only when the profile row is actually deleted. Do not touch rows keyed by extension alone (extension, extensionStorage, extensionPermission). Also note (without widening this task) whether the profile's on-disk WKWebsiteDataStore is removed on delete.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Deleting a profile removes its profileExtension, extensionInstalledEvent, favorite and contentBlockerWhitelist rows (and any other profileID-keyed rows the audit finds) in one transaction with the profile row
- [x] #2 When deleteProfile refuses because a space still references the profile, no rows are deleted
- [x] #3 Other profiles' rows and extension-keyed tables are untouched; AppDatabaseTests cover both cases
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit the AppDatabase migrations (v1-v10) for profileID-keyed tables.
2. In AppDatabase.deleteProfile, after the space guard passes, delete the profile's profileExtension, extensionInstalledEvent, favorite and contentBlockerWhitelist rows in the same write, then the profile row. Leave extension, extensionStorage and extensionPermission alone.
3. Check HistoryDatabase and the WKWebsiteDataStore for per-profile state; note only.
4. AppDatabaseTests: delete removes every per-profile row; the space-guarded refusal deletes nothing; another profile's rows and the extension-keyed tables survive.
5. Run AppDatabaseTests, then the full DetourTests target.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Audit of browser.db migrations v1-v10, profileID-keyed tables: space (the guard; references profile without cascade), contentBlockerWhitelist (v1), profileExtension (v2), favorite (v4), extensionInstalledEvent (v9). No other table carries a profileID.

Finding: contentBlockerWhitelist, profileExtension and favorite already declare profileID REFERENCES profile ON DELETE CASCADE, and GRDB enforces foreign keys by default, so in practice only extensionInstalledEvent (no foreign key, by design) was leaking. deleteProfile now deletes all four explicitly so it does not depend on FK enforcement; the test runs with foreign keys on and off. Against the unfixed code it failed 5 assertions: extensionInstalledEvent with FKs on, all four with FKs off.

Not changed:
- saveProfiles (the session save) also deletes profile rows not in the saved set; it relies on the cascades and leaves extensionInstalledEvent rows. TabStore.deleteProfile calls deleteProfile first, so the normal path is covered.
- History is not per profile: HistoryDatabase (history.db) keys visits by spaceID, and has no profile column.
- On-disk site data is not removed: Profile.dataStore is WKWebsiteDataStore(forIdentifier: profile id), and neither TabStore.deleteProfile nor Profile calls WKWebsiteDataStore.remove(forIdentifier:). The WKWebExtensionController configured with the same identifier is not cleaned either.
- No migration added.

Tests: AppDatabaseTests 19/19 (2 new).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
AppDatabase.deleteProfile now deletes the profile's profileExtension, extensionInstalledEvent, favorite and contentBlockerWhitelist rows in the same write transaction as the profile row, after the space guard passes; a refused delete deletes nothing, and extension-keyed tables (extension, extensionStorage, extensionPermission) are untouched. Three of those tables already cascaded from the profile row while foreign keys are enforced, so the real leak was extensionInstalledEvent; the explicit deletes remove the dependence on FK enforcement. History is keyed by space, not profile, and the profile's on-disk WKWebsiteDataStore (identifier = profile id) is not removed on delete (noted, not changed). Verified with 2 new AppDatabaseTests (delete with FKs on and off, other profile's rows survive; space-guarded refusal) that fail against the old code; AppDatabaseTests 19/19 pass.
<!-- SECTION:FINAL_SUMMARY:END -->
