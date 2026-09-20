---
id: TASK-96
title: >-
  History: index every title a URL has had, so own-title search needs no
  shared-title gate or visit scan
status: To Do
assignee: []
created_date: '2026-09-20 07:21'
labels: []
dependencies: []
references:
  - Detour/Storage/HistoryDatabase.swift
priority: medium
ordinal: 96000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
historyURL.title is one row per URL, shared by every profile and overwritten by the newest visit anywhere; the FTS5 index covers only that title (plus the URL). Per-visit titles (TASK-91) are not indexed. Two accepted limitations follow. (1) Command palette (TASK-94, searchHistory, space-scoped, runs on the main thread per keystroke): FTS is the candidate gate, so a space's own visit title is findable only while the shared title also contains the word - e.g. personal saw 'Budget 2026', work later retitled the URL 'Dashboard', typing 'budget' in personal finds nothing. Pinned by a test. (2) History page (TASK-93, searchVisits, profile-scoped): avoids the gate by scanning in-scope visit titles with a LIKE/GLOB prefilter + history_title_matches, 18-40 ms per 50k visits, 220 ms when every title is non-ASCII. Root fix: an FTS index over the distinct titles each URL has had per scope (visit-level or (urlID, spaceID, title) rows), maintained on visit insert/title update/delete/expiry, built for existing data by a schema migration. Then the palette can gate on own titles and searchVisits can drop its scan. Keep the isolation rules from TASK-93/94: a title may only match or display through in-scope visits; all FTS tokens stay quoted (ftsPrefixQuery). Rejected earlier, do not revisit: 'visit title equals the matched URL-level title', unfiltered scan (380 ms/50k).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A schema migration builds the title index for existing history; fresh and migrated databases give identical search results
- [ ] #2 Palette search finds a URL by a word that appears only in this space's own visit title, even after another profile retitled the URL (the TASK-94 limitation test is inverted)
- [ ] #3 A title that only another space/profile's visits gave a URL never matches or displays (existing TASK-93/94 isolation tests still pass)
- [ ] #4 The index stays correct through visit delete, clear history, range delete, 90-day expiry, profile/space deletion and title updates of an existing visit (SPA retitle, TASK-88)
- [ ] #5 searchVisits no longer scans visit titles, or the task records measured reasons to keep the scan
- [ ] #6 Timings on the 50k-visit fixture recorded before/after for palette search, History page search (ASCII and non-ASCII titles) and visit insert; no per-keystroke palette query regresses
<!-- AC:END -->
