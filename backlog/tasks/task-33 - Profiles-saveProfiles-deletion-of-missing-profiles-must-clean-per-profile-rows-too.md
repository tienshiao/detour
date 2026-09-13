---
id: TASK-33
title: >-
  Profiles: saveProfiles deletion of missing profiles must clean per-profile
  rows too
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 01:41'
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
- [ ] #1 Profiles removed by saveProfiles lose the same per-profile rows as deleteProfile, in one transaction, with and without foreign keys enforced
- [ ] #2 saveProfiles never deletes a profile still referenced by a space; the rows of profiles in the saved set are untouched
- [ ] #3 AppDatabaseTests cover the saveProfiles removal path
<!-- AC:END -->
