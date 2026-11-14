---
id: TASK-337
title: >-
  Content blocking: a setting for the AdGuard URL Tracking list, so Detour does
  not fetch it when it is off
status: To Do
assignee: []
created_date: '2026-11-14T23:45:00Z'
labels:
  - links
  - content-blocker
  - settings
dependencies: []
references:
  - TASK-329
  - Detour/Browser/ContentBlocker/TrackingParameterList.swift
  - Detour/Browser/Settings/ContentBlockerSettingsViewController.swift
  - wiki/features/copy-url.md
priority: low
type: feature
ordinal: 411000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-329. Since TASK-329 every launch contacts filters.adtidy.org to refresh the AdGuard URL Tracking filter used by Copy URL, Copy Link and Share…, and there is no way to turn it off or to see that it is there. TASK-329 left the Settings row out while TASK-328 was changing the Settings panes. The content blocker lists already have rows with switches in the Content Blocking pane; this list is app-wide and only affects copied links, not blocking.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The Content Blocking pane shows the tracking-parameter list with a switch (on by default), its last update and its rule count, worded so it is clear it affects copied and shared links, not blocking
- [ ] #2 With the switch off, Detour makes no request to the list's host (at launch, Update Now or Clear Cache) and Copy URL uses the built-in names only; turning it on fetches the list
- [ ] #3 The setting is stored per data directory like the other content blocker settings; tests cover the off state and the fetch gate; checked at runtime with /verify
<!-- AC:END -->
