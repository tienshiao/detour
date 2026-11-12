---
id: TASK-293.2
title: >-
  Import from Arc: turn a snapshot into Detour profiles, spaces, pinned entries,
  favourites and history without duplicates
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-12T09:22:00Z'
labels:
  - import
dependencies:
  - TASK-293.1
parent_task_id: TASK-293
ordinal: 385000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Takes the snapshot from TASK-293.1 and the user's choices and changes TabStore and history.db. User decisions (Nov 12 2026): each Arc profile goes to a NEW Detour profile by default, the Arc default profile included (the window can point it at an existing one); Arc's unpinned Today tabs come over as sleeping normal tabs unless the user unticks them. Re-importing (after a later export, or a second direct import) is expected while Arc users move over gradually.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Imported spaces keep their names and emoji (an Arc symbol icon gets a default emoji) and take a colour from Arc's theme; they land in the Detour profile chosen for their Arc profile, a new profile named after the Arc profile by default
- [ ] #2 Pinned tabs and folders keep their order and nesting; an Arc split view of two tabs becomes a pinned split, a larger one its first two as a split and the rest as plain entries; favourites become Detour Favorites on the matching profile
- [ ] #3 Unpinned tabs come over as sleeping normal tabs when selected; nothing imported creates a web view until the user opens it
- [ ] #4 History from the last 90 days is written to the matching profile's history in one background transaction, attributed to an imported space of that profile, and shows up in the History page and the command palette
- [ ] #5 Importing the same data twice adds nothing; importing a newer export adds only what is new; a deleted imported item is not resurrected unless the user imports it again on purpose (rule recorded)
- [ ] #6 The import is saved as one change, and a failure part-way leaves the session as it was
- [ ] #7 Mapping and dedupe are unit-tested (pure mapping function plus TabStore integration), including the history write
<!-- AC:END -->
