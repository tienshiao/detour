---
id: TASK-132.26
title: 'Wiki: refresh the Claude extension epic page from the merged code'
status: To Do
assignee: []
created_date: '2026-11-04T09:05:00Z'
labels:
  - docs
dependencies: []
parent_task_id: TASK-132
priority: low
ordinal: 310000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
wiki/extensions/claude-extension-epic.md is past its stale_after date (wiki-lint warning). It was drafted from the TASK-132 tasks before any code existed (wiki/log.md, wiki creation). The epic's code (side panel, automation parking, getContexts, externally_connectable, declarativeNetRequest header rules, tab handle registry) is now on epic-claude-extension, merged with main at 45f5da1. Update the page from the code following wiki/meta/conventions.md' ingest workflow, link the component pages, and set stale_after.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The page describes what the epic's code does now, checked against the code, with links to the source files and to related wiki pages
- [ ] #2 wiki-lint passes with no staleness warning for the page, and wiki/log.md has a line
<!-- AC:END -->
