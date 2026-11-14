---
id: TASK-293.4
title: >-
  Website: migration section of the Switching from Arc hub built around the
  importer
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-12T09:23:00Z'
updated_date: '2026-11-14T01:36:00Z'
labels:
  - import
  - website
dependencies:
  - TASK-293.3
parent_task_id: TASK-293
ordinal: 387000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Arc hub (detour-website src/pages/arc/) leaves migration out until an import exists (user, Nov 7 2026). The held-back manual guide is src/pages/arc/_move.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The hub has a migration section that walks through File › Import from Arc… for both sources and says what does not come across
- [x] #2 It says to import or export before Dec 22 2026, when Arc stops working, and that an export file can be imported later
- [x] #3 The held-back manual guide is replaced or removed, and the site builds
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14: written on the website branch arc-import (commit below), not merged. The importer is not in a release (v0.4.3 predates it), so per the website pattern the branch is rebased and fast-forwarded onto website main right before publish-release.sh for the next release. The section: before Dec 22 in Arc (export file, passwords, Air Traffic Control routes), the launch offer and File › Import from Arc… step by step in the app's own words (ArcImportText / ArcImportWindowController), what an export file lacks (no profiles, emoji, colors or history; the Favorites guess), what does not come across, and what to do after. Also: two FAQ entries (can I import; what if I miss the deadline), meta description and lede mention importing, and the "not in Detour" list no longer says Detour cannot import. _move.md removed. Astro build passes (23 pages). Not checked: the rendered page in a browser (no layout change; existing h3/ol/kbd styles).

2026-11-14: also on arc-import: the hub's Spaces row now says Spaces are made from the sidebar's + (TASK-289, same release). Still outdated for that release, outside this task: features/spaces.md (Make a Space via Settings, the Settings › Spaces still) and profiles.md (choose a Space's Profile in Settings › Spaces).
<!-- SECTION:NOTES:END -->
