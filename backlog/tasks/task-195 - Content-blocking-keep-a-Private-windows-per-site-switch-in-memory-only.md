---
id: TASK-195
title: 'Content blocking: keep a Private window''s per-site switch in memory only'
status: To Do
assignee: []
created_date: '2026-10-24 16:07'
labels:
  - content-blocker
  - privacy
  - site-settings
dependencies: []
priority: low
ordinal: 231000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from TASK-188 (user decision 2026-10-24: a per-site switch set in a Private window lives in memory until the last Private window closes and is never written to disk). The picture in picture switch does this already (SiteSetting.persistsInPrivate = false). Content blocking still saves the Private profile's rows to browser.db (it always did, TASK-187 kept it), so a site visited in Private leaves its hostname on disk. Flip contentBlocking.persistsInPrivate, delete existing Private contentBlocking rows in a migration, and check the reload-on-toggle path still works in a Private window.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Turning content blocking off for a site in a Private window writes nothing to the database and lasts until the last Private window closes
- [ ] #2 Existing Private contentBlocking rows are removed by a migration, with a test
- [ ] #3 Non-Private profiles are unchanged
<!-- AC:END -->
