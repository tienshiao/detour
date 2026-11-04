---
id: TASK-187
title: >-
  Storage: a per-site settings table, with content blocking's site list migrated
  into it
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:21'
updated_date: '2026-10-24 11:03'
labels:
  - storage
  - feature
dependencies: []
priority: medium
ordinal: 214000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decided by the user 2026-10-24: per-site preferences get one table of their own, and content blocking moves into it, before dev mode (TASK-186.5) and picture in picture (TASK-188) add their own per-site switches.

Today content blocking is the only per-site setting: `ContentBlockerWhitelist` holds a per-profile host set loaded from the session DB table `contentBlockerWhitelist(profileID, host)` (hosts lowercased; a stored host also covers its subdomains), toggled from the faux address bar's popover.

Proposed: `siteSetting(profileID, site, setting, value)`, primary key `(profileID, site, setting)`, `setting` a string enum (`contentBlocking`, `devMode`, `pictureInPicture`, …), `value` a boolean override (a missing row = the setting's default). A small store with an in-memory cache per profile, replacing `ContentBlockerWhitelist`'s own cache, and one rule per setting for how a site matches: content blocking keeps "the host or any parent host", others may be exact.

Migration: copy every `contentBlockerWhitelist` row to `(profileID, host, 'contentBlocking', false)` and drop the old table in the same migration; profile deletion and the Private profile keep today's behaviour (check `profile-data-removal` in the wiki). Content blocking must behave exactly as before: same hosts off, same subdomain coverage, same toggle.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A siteSetting table and store exist, tested first (set/clear/query per profile, per setting matching rules)
- [x] #2 A migration moves every content-blocking exception into it, tested against a database built with the previous schema; the old table is removed
- [x] #3 Content blocking's toggle and enforcement use the new store with no change in behaviour (existing ContentBlocker tests pass, plus a migration test)
- [x] #4 Deleting a profile removes its site settings
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Tests first: SiteSettingsStoreTests (set/clear/query per profile and setting, persistence across a new store, content blocking's host-or-parent matching, most specific site wins), a v18 migration test against a database migrated to v17 (rows copied as contentBlocking=false, hosts lowercased, duplicates and orphaned profile ids dropped, old table gone), AppDatabaseTests' per-profile deletion covering siteSetting; ContentBlockerWhitelistTests kept and pointed at the store.
2. Migration v18: siteSetting(profileID FK profile ON DELETE CASCADE, site, setting, value BOOLEAN), primary key (profileID, site, setting); INSERT OR IGNORE ... SELECT lower(host) ... 'contentBlocking', 0 FROM contentBlockerWhitelist WHERE the profile exists; DROP TABLE contentBlockerWhitelist.
3. SiteSettingRecord + AppDatabase load/save/delete; deleteProfileRows deletes siteSetting rows explicitly (as the other per-profile tables); ContentBlockerWhitelistRecord and its DB functions removed.
4. SiteSettingsStore (Browser/SiteSettings/): SiteSetting enum (contentBlocking only for now; devMode / pictureInPicture come with TASK-186.5 / TASK-188) with its matching rule; per-profile cache loaded at init; shared instance over AppDatabase.shared.
5. ContentBlockerWhitelist keeps its API and pure rules (covers, entriesCovering, toggleHost) but reads and writes the store; ContentBlockerManager stops loading its own cache.
6. Wiki: content-blocking, session-database, profile-data-removal; new page for site settings if warranted.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (2026-10-24):
- siteSetting(profileID FK profile cascade, site, setting, value BOOLEAN), PK (profileID, site, setting); migration v18 copies contentBlockerWhitelist rows as contentBlocking=0 (lower(host), INSERT OR IGNORE, only rows whose profile exists) and drops the old table.
- SiteSettingRecord; AppDatabase.saveSiteSetting / deleteSiteSettings / loadSiteSettings; deleteProfileRows deletes siteSetting rows; ContentBlockerWhitelistRecord and its DB functions removed.
- SiteSettingsStore (Browser/SiteSettings): SiteSetting enum (contentBlocking only; devMode / pictureInPicture come with their tasks) with its matching rule site(_:covers:); cache loaded at init; override() = most specific covering site; unknown setting rows ignored and kept. shared over AppDatabase.shared.
- ContentBlockerWhitelist: same API, backed by the store; entriesCovering uses the store's rule; isWhitelisted = override == false. ContentBlockerManager no longer loads a cache of its own.
- Tests first (red against empty-value stubs, then green): SiteSettingsStoreTests 10 (incl. the v18 migration against a database migrated to v17, with mixed case, a duplicate spelling and an orphaned profile id); ContentBlockerWhitelistTests and AppDatabaseTests' per-profile deletion pointed at the new table.
- Code review (/code-review --fix): 8 findings, no blockers. Fixed: toggleHost now takes its direction from isWhitelisted (a more specific blocking-on row could make it clear the parent instead), new test testTogglingAHostWithAMoreSpecificBlockingOnOverrideTurnsBlockingOff; stale deleteProfileRows comment. Not fixed: SQLite lower() is ASCII-only vs Swift lowercased (hosts reach the store as ASCII/punycode); the store's cache is not told when deleteProfileRows removes a profile (UUIDs are never reused); Private rows persist as before (decision noted on TASK-186.5 and TASK-188); per-call lowercasing, save() vs upsert, no @MainActor (all callers are main-thread today).
- Tests: AppDatabaseTests, ContentBlockerTests, ContentBlockerWhitelistTests, ExtensionDatabaseTests, ProfileDataRemovalTests, ProfileDeletionUndoTests, SessionSave* (3 suites), SiteSettingsStoreTests, RuntimeInstalledEventTests: 175 passed, 0 failed (before review fixes); after them the reviewer's run of ContentBlockerWhitelistTests + SiteSettingsStoreTests + AppDatabaseTests: 57 passed.
- Runtime upgrade (isolated profile): built the previous commit (7b0ebb2), created a real v17 database, added 4 whitelist rows (mixed case, a duplicate spelling, one for the Private profile), then launched this build: v18 applied, 3 siteSetting rows (duplicates merged, Private row kept), old table gone, profile and space unchanged. Not checked at runtime: the popover switch itself (no UI change; enforcement covered by ContentBlockerWhitelistTests' real-WebView test).
- Trap recorded: hand-editing the schema of a Debug-build database (recreating an old table with sqlite3) makes GRDB's eraseDatabaseOnSchemaChange wipe it on the next launch (looks like a new profile id); build the old commit to make an old database instead.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Per-site preferences now live in one siteSetting table read through SiteSettingsStore (per-profile cache, per-setting matching rule, most specific site wins). Migration v18 moved content blocking's site list into it and dropped contentBlockerWhitelist; ContentBlockerWhitelist keeps its API on top of the store, so the switch behaves as before. Tests first (store, migration against a v17 database, profile deletion); verified with a real v17-to-v18 upgrade in an isolated profile. Wiki: new Site settings page, session database, profile data removal, content blocking.
<!-- SECTION:FINAL_SUMMARY:END -->
