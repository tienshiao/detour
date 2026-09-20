---
id: TASK-94
title: >-
  Command palette: history suggestions show and match another profile's page
  title
status: To Do
assignee: []
created_date: '2026-09-20 03:12'
updated_date: '2026-09-20 03:16'
labels: []
dependencies:
  - TASK-93
references:
  - Detour/Browser/CommandPalette/SuggestionProvider.swift
  - Detour/Storage/HistoryDatabase.swift
priority: medium
ordinal: 94000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The command palette's history suggestions (SuggestionProvider -> HistoryDatabase.recentHistory / searchHistory / bestURLCompletion, all scoped to one spaceID) return HistoryURL rows, whose title is historyURL.title: one row per URL shared by every profile, overwritten by the latest visit anywhere. So a suggestion in the personal profile can DISPLAY the title a work-profile visit gave the URL (e.g. '(3) Inbox - you@work'), and searchHistory can MATCH a URL through such a title. This is the palette-side twin of TASK-93 (History page search) and is worse, because there the foreign title is shown, not only matched. The visit filter (v.spaceID = ?) already keeps out URLs the space never visited; only the title leaks. Fix direction (same rule as TASK-93, no new index): display the title of the space's own latest visit of the URL (COALESCE(visit title, URL title) for pre-TASK-91 visits), and let a title-only FTS match count only when an in-scope visit carries the matched title; URL-text matches are unaffected. Decide while planning whether the scope should be the space (today's behaviour) or the space's profile, as on the History page. visitCount/lastVisitTime used for ranking and frecency are also cross-profile aggregates - note whether that matters, but do not widen scope without asking. Out of scope: chrome.history.search (searchHistoryGlobal), global by design.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A suggestion row never displays a title that only an out-of-scope visit gave the URL; it shows the title of the scope's own latest visit (URL-level title only for visits recorded before per-visit titles)
- [ ] #2 Typing a word that appears only in another profile's title of a URL does not surface that URL; a word in the URL text, or in a title the scope's own visit carries, still does
- [ ] #3 Recent-history suggestions (empty query) and inline URL completion follow the same display rule
- [ ] #4 Ranking and result counts for single-profile use are unchanged; SuggestionProviderTests and HistoryDatabaseTests pass, with new positive and negative cross-profile cases for searchHistory, recentHistory and bestURLCompletion
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user, 2026-09-19): the palette STAYS scoped to the single space (today's behaviour) - do not widen it to the profile. The task is only about the title: what a suggestion displays and what a title match may go through must come from in-scope (this space's) visits. This settles the space-vs-profile question in the description.
<!-- SECTION:NOTES:END -->
