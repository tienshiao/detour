---
id: TASK-212
title: Rename Air Traffic Control to Link Routes
status: To Do
assignee: []
created_date: '2026-10-27 02:19'
labels:
  - settings
  - links
dependencies: []
priority: low
ordinal: 248000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decision (user, 2026-10-26): 'Air Traffic Control' is Arc's name, so the feature built in TASK-191 (and the Quick Detour target from TASK-193.5) is called Link Routes. The Settings pane keeps the name Links, and each entry stays a route; the code types (LinkRoute, LinkRouteStore, LinkRouteResolver) already use the generic name.

Other browsers checked for naming: Edge 'Automatic profile switching', Firefox Multi-Account Containers 'Always open this site in…', Vivaldi workspace rules, browser pickers 'Rules'.

Scope: the one user-visible sentence on the Links pane (LinksSettingsViewController.swift, 'Air Traffic Control opens links in…'), any other user-visible text found, code comments in Detour/ and DetourTests/, the wiki (wiki/features/link-routing.md and the pages that mention it), and the harness patches in docs/harness. Old Backlog tasks and git history keep the old name.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 No user-visible text says Air Traffic Control; the Links pane's description reads 'Link Routes open links in the space you choose: …' or similar
- [ ] #2 grep -ri 'air traffic' over Detour/, DetourTests/, wiki/ and docs/ finds nothing except a wiki note that the feature was formerly named after Arc's
- [ ] #3 The wiki page for the feature is titled Link Routes; wiki-lint passes
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Queued (user, 2026-10-26): ahead of TASK-194, after TASK-211 (order: 210, 211, this task, 194, 201, 202, 209).
<!-- SECTION:NOTES:END -->
