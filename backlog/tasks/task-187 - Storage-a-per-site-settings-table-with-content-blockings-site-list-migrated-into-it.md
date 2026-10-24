---
id: TASK-187
title: >-
  Storage: a per-site settings table, with content blocking's site list migrated
  into it
status: To Do
assignee: []
created_date: '2026-10-24 09:21'
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
- [ ] #1 A siteSetting table and store exist, tested first (set/clear/query per profile, per setting matching rules)
- [ ] #2 A migration moves every content-blocking exception into it, tested against a database built with the previous schema; the old table is removed
- [ ] #3 Content blocking's toggle and enforcement use the new store with no change in behaviour (existing ContentBlocker tests pass, plus a migration test)
- [ ] #4 Deleting a profile removes its site settings
<!-- AC:END -->
