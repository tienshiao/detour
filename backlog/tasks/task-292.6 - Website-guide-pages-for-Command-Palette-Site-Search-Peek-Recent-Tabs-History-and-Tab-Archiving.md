---
id: TASK-292.6
title: >-
  Website: guide pages for Command Palette, Site Search, Peek, Recent Tabs,
  History and Tab Archiving
status: To Do
assignee: []
created_date: '2026-11-08T06:59:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
parent_task_id: TASK-292
priority: medium
ordinal: 347000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Getting around and finding things again, written to the pilot template (TASK-292). Site Search has no Arc counterpart, so its page has no Arc box. Each is its own page. Captures come from the staged demo profile and kit in docs/task-110 (public pages only, no personal data, every launch with DETOUR_DATA_DIR set).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each page follows the template from the pilot (H1 + lede, media, what/why, how-to steps, FAQ, related features, download) with its own title tag and meta description pairing the feature name with the generic search phrase
- [ ] #2 Steps, menu paths and shortcuts on each page were checked against the current release build
- [ ] #3 Images and loops have alt text or aria-labels describing what is on screen, fixed dimensions, and loops meet the TASK-110 size and reduced-motion rules
- [ ] #4 Pages are in the sitemap and linked from the home page entry for the feature
- [ ] #5 A Coming from Arc box appears only on pages whose feature Arc had in comparable form
<!-- AC:END -->
