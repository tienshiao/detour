---
id: TASK-293.1
title: >-
  Import from Arc: read Arc's sidebar, profiles and history on this Mac and the
  Arc Data Export file
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-12T09:22:00Z'
labels:
  - import
dependencies: []
parent_task_id: TASK-293
ordinal: 384000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The importer takes two sources (user, Nov 12 2026): Arc's own files on this Mac (direct import, works only while Arc and its data are still there; Arc stops working Dec 22 2026) and the Markdown file Arc's Settings › Advanced › Export Data writes (survives the shutdown, but carries only links: no profiles, history or IDs). Both have to come out as one source-neutral snapshot so the mapping (TASK-293.2) and the window (TASK-293.3) don't care which one was read. The survey of the on-disk format is in TASK-293's notes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One pure, nonisolated snapshot model covers both sources: Arc profiles (name, directory), spaces (title, emoji or icon, colour, profile), each space's pinned tree (folders nested to any depth, tabs, split views) and unpinned tabs in Arc's order, favourites per profile
- [ ] #2 The direct reader parses StorableSidebar.json from sidebar.containers only (the sync shadows are ignored), names profiles from User Data/Local State, and reads each profile's History from a copy, limited to visits newer than Detour's history retention
- [ ] #3 The export reader parses Arc Data Export.md into the same snapshot, checked against a file exported from Arc 1.172 or later
- [ ] #4 Unknown item kinds (Easels, Notes, anything new) and unreadable entries are counted and named in the snapshot instead of failing the whole read; a missing or unreadable Arc install or file is a typed error
- [ ] #5 Unit tests against synthetic fixtures: nested folders, several profiles, an empty sidebar, a split view, an unknown item kind, Arc's built-in untitled personal space, and an export file
- [ ] #6 Wiki page on both formats with the Arc version they were checked against, linked from wiki/index.md
<!-- AC:END -->
