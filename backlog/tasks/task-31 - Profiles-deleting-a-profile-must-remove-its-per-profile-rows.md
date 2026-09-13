---
id: TASK-31
title: 'Profiles: deleting a profile must remove its per-profile rows'
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 00:58'
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
- [ ] #1 Deleting a profile removes its profileExtension, extensionInstalledEvent, favorite and contentBlockerWhitelist rows (and any other profileID-keyed rows the audit finds) in one transaction with the profile row
- [ ] #2 When deleteProfile refuses because a space still references the profile, no rows are deleted
- [ ] #3 Other profiles' rows and extension-keyed tables are untouched; AppDatabaseTests cover both cases
<!-- AC:END -->
