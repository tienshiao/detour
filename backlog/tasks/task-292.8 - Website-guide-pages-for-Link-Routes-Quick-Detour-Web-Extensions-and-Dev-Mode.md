---
id: TASK-292.8
title: >-
  Website: guide pages for Link Routes, Quick Detour, Web Extensions and Dev
  Mode
status: To Do
assignee: []
created_date: '2026-11-08T06:59:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
parent_task_id: TASK-292
priority: medium
ordinal: 349000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Links from other apps and power-user features, written to the pilot template (TASK-292). Link Routes and Quick Detour have Arc counterparts (Air Traffic Control, Little Arc); Dev Mode does not. The Web Extensions page sets expectations honestly: which extensions are known to work, which are known not to, and that support is in progress. Captures come from the staged demo profile and kit in docs/task-110 (public pages only, no personal data, every launch with DETOUR_DATA_DIR set).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each page follows the template from the pilot (H1 + lede, media, what/why, how-to steps, FAQ, related features, download) with its own title tag and meta description pairing the feature name with the generic search phrase
- [ ] #2 Steps, menu paths and shortcuts on each page were checked against the current release build
- [ ] #3 Images and loops have alt text or aria-labels describing what is on screen, fixed dimensions, and loops meet the TASK-110 size and reduced-motion rules
- [ ] #4 Pages are in the sitemap and linked from the home page entry for the feature
- [ ] #5 The Web Extensions page says how to install a CRX and lists known working and known broken extensions as of its date
- [ ] #6 A Coming from Arc box appears only on pages whose feature Arc had in comparable form
<!-- AC:END -->
