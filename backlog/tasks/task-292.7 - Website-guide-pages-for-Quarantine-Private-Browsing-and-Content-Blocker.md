---
id: TASK-292.7
title: 'Website: guide pages for Quarantine, Private Browsing and Content Blocker'
status: To Do
assignee: []
created_date: '2026-11-08T06:59:00Z'
labels:
  - website
dependencies:
  - TASK-292.2
parent_task_id: TASK-292
priority: medium
ordinal: 348000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The privacy pages, written to the pilot template (TASK-292). Quarantine and Private Browsing are separate pages (user, Nov 7 2026). Quarantine is pitched to privacy-conscious users as a way to triage incoming links (from mail, chat, unknown senders) without leaking data: none of your cookies, no history, tracking parameters stripped. Its page explains how that differs from a private window, and Private Browsing links across to it. Quarantine is not an Arc feature, so its page has no Arc box. Captures come from the staged demo profile and kit in docs/task-110 (public pages only, no personal data, every launch with DETOUR_DATA_DIR set).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Quarantine and Private Browsing are separate pages that each say when to use which and link to each other
- [ ] #2 The Quarantine page leads with link triage and states exactly what is and is not shared with your profiles, checked against the code and the running app
- [ ] #3 Each page follows the template from the pilot (H1 + lede, media, what/why, how-to steps, FAQ, related features, download) with its own title tag and meta description pairing the feature name with the generic search phrase
- [ ] #4 Steps, menu paths and shortcuts on each page were checked against the current release build
- [ ] #5 Images and loops have alt text or aria-labels describing what is on screen, fixed dimensions, and loops meet the TASK-110 size and reduced-motion rules
- [ ] #6 Pages are in the sitemap and linked from the home page entry for the feature
<!-- AC:END -->
