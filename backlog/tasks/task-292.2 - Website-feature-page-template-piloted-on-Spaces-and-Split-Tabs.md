---
id: TASK-292.2
title: 'Website: feature page template, piloted on Spaces and Split Tabs'
status: To Do
assignee: []
created_date: '2026-11-08T06:59:00Z'
labels:
  - website
dependencies:
  - TASK-292.1
references:
  - docs/task-110/README.md
parent_task_id: TASK-292
priority: medium
ordinal: 343000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The template every feature page uses gets settled on two real pages before the rest are written. Rules from planning (see TASK-292): the H1 is the feature name with a one-line plain outcome; search phrasing lives in the title tag, meta description, slug, lede and FAQ headings; the order is H1 + lede, media, what it does and why, how to use it (numbered steps, shortcuts, related settings), Coming from Arc (only where Arc had the feature in comparable form), FAQ (3-6 real questions), related features, download. BreadcrumbList structured data on subpages; no HowTo markup (Google dropped those rich results).

Spaces is a headline feature with an Arc counterpart; Split Tabs exercises a still image instead of a loop. Captures come from the staged demo profile and kit in docs/task-110 (public pages only, no personal data, every launch with DETOUR_DATA_DIR set).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Spaces and Split Tabs pages are live at /features/spaces/ and /features/split-tabs/
- [ ] #2 Each page follows the template from the pilot (H1 + lede, media, what/why, how-to steps, FAQ, related features, download) with its own title tag and meta description pairing the feature name with the generic search phrase
- [ ] #3 Steps, menu paths and shortcuts on each page were checked against the current release build
- [ ] #4 Images and loops have alt text or aria-labels describing what is on screen, fixed dimensions, and loops meet the TASK-110 size and reduced-motion rules
- [ ] #5 The home page Spaces and Split Tabs sections link to their pages
- [ ] #6 Pages have BreadcrumbList structured data that validates in the Rich Results Test
- [ ] #7 The template is documented in the website repo (sections, title and H1 rules, when to include Coming from Arc) so later page tasks follow it
- [ ] #8 Checked in a browser at desktop and phone widths
<!-- AC:END -->
