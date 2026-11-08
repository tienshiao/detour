---
id: TASK-302
title: >-
  Link Routes: an app-only route is flagged invalid until its URL condition is
  switched to Any URL
status: To Do
assignee: []
created_date: '2026-11-08T08:41:00Z'
labels:
  - link-routes
  - ui
dependencies: []
references:
  - TASK-292.7
priority: low
ordinal: 363000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while checking the Quarantine guide page at runtime (TASK-292.7, v0.4.0): in Settings › Links, a new route starts with the URL condition "Domain is" and an empty pattern. Choosing an app in "From app" (to send, say, every link from Mail to Quarantine) still leaves the route flagged invalid, because the empty "Domain is" pattern counts as a broken condition. The user has to know to switch the URL condition to "Any URL". The Quarantine page currently tells people to do that. (A route needs at least one condition: LinkRoute.swift ~113-115; editor in LinksSettingsViewController.)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A route with an app chosen and an empty URL pattern is treated as app-only (any URL from that app), or the editor otherwise makes app-only routes possible without a hidden step (approach agreed with the user)
- [ ] #2 A route with neither an app nor a URL pattern is still refused with a clear message
- [ ] #3 LinkRoute validation tests cover app-only, URL-only and both
- [ ] #4 The website's Quarantine and Link Routes pages drop the Any URL workaround
<!-- AC:END -->
