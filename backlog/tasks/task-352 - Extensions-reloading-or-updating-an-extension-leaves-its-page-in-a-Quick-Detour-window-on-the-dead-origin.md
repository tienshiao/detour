---
id: TASK-352
title: >-
  Extensions: reloading or updating an extension leaves its page in a Quick
  Detour window on the dead origin
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:37:00Z'
labels:
  - extensions
  - quick-detour
dependencies: []
references:
  - Detour/Browser/Profile.swift
  - wiki/extensions/extension-pages.md
priority: low
type: bug
ordinal: 432000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in the wiki content lint. Profile.extensionPageLocations (used by retargetExtensionPages on a context reload and by the update path's open-pages count) walks the profile's spaces' tabs, pinned entries, favourites and their Peeks, but not TabStore.quickDetourTabs. If an extension page can be shown in a Quick Detour window (e.g. an options page opened there, or a link to chrome-extension:// followed in one), a reload or update would leave it on the old base URL and a deferred update would not count it as busy. Not reproduced: first establish whether a Quick Detour window can show an extension page.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Whether a Quick Detour (or quarantine) window can show an extension page is established and recorded
- [ ] #2 If it can: such a page is rehomed on a context reload and counted as an open page by the deferred-update check, with a test
- [ ] #3 wiki/extensions/extension-pages.md lists every place a page can be
<!-- AC:END -->
