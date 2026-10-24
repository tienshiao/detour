---
id: TASK-182
title: >-
  Command palette: complete a typed host prefix to the site (youtube.com), not
  to one deep URL
status: To Do
assignee: []
created_date: '2026-10-24 08:03'
labels:
  - command-palette
  - feature
dependencies: []
priority: medium
ordinal: 204000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
With many YouTube video tabs open, typing `youtube` after Cmd+T only offers the video tabs: the top hit and inline completion take the first open tab whose display URL starts with the query (`youtube.com/watch?v=…`), so getting to https://youtube.com/ means typing the whole domain.

Firefox-style origin completion: while the query could still be a host (no whitespace, `/`, `?` or `#`), complete to the matching **host** rather than a URL. Open tabs first (their host), else the space's history ranked by host frecency (the bestURLCompletion weights, summed per host). The top-hit row opens the site root: an open tab already at the root is offered as Switch to Tab, otherwise the root URL (the space's own visit of it when there is one, for title and favicon). Up to two more matching visited hosts follow the verbatim row. Once the query has a path (`youtube.com/`) completion is URL-level as today.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Typing a host prefix with only deep-URL tabs open completes the field to the host and the top row opens the site root
- [ ] #2 A tab already showing the site root is offered as the top hit (Switch to Tab)
- [ ] #3 History host completion ranks hosts by summed frecency, scoped to the space
- [ ] #4 Other visited hosts matching the prefix appear as rows (at most two) after the verbatim row
- [ ] #5 A query containing a path keeps URL-level completion
- [ ] #6 The instant (tab-only) pass and SuggestionProvider share one top-hit rule
<!-- AC:END -->
