---
id: TASK-288
title: >-
  Command palette: discover site searches from OpenSearch descriptions (active
  at once, no keyword)
status: To Do
assignee: []
created_date: '2026-11-07T09:43:00Z'
updated_date: '2026-11-07T09:59:00Z'
labels:
  - command-palette
  - search
dependencies:
  - TASK-287
references:
  - wiki/features/command-palette.md
priority: low
type: feature
ordinal: 335000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user on 2026-11-07 while TASK-287 (manual site search and Settings > Search) was being built; split out to keep that change reviewable.

Sites advertise their search through an OpenSearch description: a `<link rel="search" type="application/opensearchdescription+xml" href=…>` in the page head, pointing at an XML document whose `<Url type="text/html" template="…{searchTerms}…">` is the results URL. Chrome uses these to add site searches without the user typing a URL template. Decided with the user: discovered entries follow Chrome's current behaviour, listed in Settings > Search as inactive (keyword = the site's host) until the user turns them on, so no keyword starts taking Tab/Space by surprise.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Visiting a page in a normal profile whose head links an OpenSearch description adds a site search for that site with no keyword, named from the description, template converted from {searchTerms} to the site-search placeholder; it works at once through host matching (Tab when the palette completes to that site)
- [ ] #2 Nothing is discovered or fetched from a Private window, Quick Detour quarantine or a non-http(s) page; a description is fetched at most once per site per launch, with a size and time limit
- [ ] #3 A description whose template is not http(s), has no {searchTerms}, or points to another host than the page is ignored; a site already in the list (same host) is not added again, and one the user removed is not re-added
- [ ] #4 Discovered entries are marked as discovered in Settings > Search and can be edited (given a keyword) or removed
- [ ] #5 Tests cover parsing (valid, malformed, missing template), the add/skip rules and the Private refusal; the site-search wiki page describes discovery
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision changed 2026-11-07 (user): TASK-287 gained Arc-style host and name matching, so a discovered site only takes Tab when the field completes to that same site. Discovered entries are therefore active at once with no keyword (Arc), not listed inactive (Chrome) as first decided.
<!-- SECTION:NOTES:END -->
