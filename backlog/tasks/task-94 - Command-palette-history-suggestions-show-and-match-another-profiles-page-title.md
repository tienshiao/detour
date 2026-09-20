---
id: TASK-94
title: >-
  Command palette: history suggestions show and match another profile's page
  title
status: Done
assignee:
  - '@claude'
created_date: '2026-09-20 03:12'
updated_date: '2026-09-20 07:21'
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
- [x] #1 A suggestion row never displays a title that only an out-of-scope visit gave the URL; it shows the title of the scope's own latest visit (URL-level title only for visits recorded before per-visit titles)
- [x] #2 Typing a word that appears only in another profile's title of a URL does not surface that URL; a word in the URL text, or in a title the scope's own visit carries, still does
- [x] #3 Recent-history suggestions (empty query) and inline URL completion follow the same display rule
- [x] #4 Ranking and result counts for single-profile use are unchanged; SuggestionProviderTests and HistoryDatabaseTests pass, with new positive and negative cross-profile cases for searchHistory, recentHistory and bestURLCompletion
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design (Fable). The palette runs these queries synchronously on the main thread per keystroke, so unlike TASK-93 the title half must NOT scan the scope's visits. FTS stays the candidate generator over both columns (fast path, ranking unchanged); a candidate URL qualifies if the space visited it AND (it matches in the FTS url column OR some in-scope visit's own title - COALESCE(v.title, h.title) - passes history_title_matches). The function therefore only runs on visits of candidate URLs. Accepted limitation (palette only): an own title is findable only while the shared URL-level title also contains the word; the URL text usually matches anyway. Display: all three lookups (recentHistory, searchHistory, bestURLCompletion) return HistoryURL with title replaced by the scope's latest visit's own title (ORDER BY visitTime DESC, id DESC LIMIT 1), falling back to the URL-level title for legacy NULL-title visits; one shared SQL fragment, computed only for the rows that survive LIMIT. Scope stays the single space (user decision). Not changed, noted: ORDER BY rank / visitCount still use cross-profile aggregates (ordering only). Steps: 1 (Opus) implement + tests in HistoryDatabaseTests and SuggestionProviderTests (positive + negative cross-profile for each lookup). 2 (Fable) /code-review, timing check, runtime check of the palette. 3 commit + merge.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user, 2026-09-19): the palette STAYS scoped to the single space (today's behaviour) - do not widen it to the profile. The task is only about the title: what a suggestion displays and what a title match may go through must come from in-scope (this space's) visits. This settles the space-vs-profile question in the description.

Implemented (5ef9353) after two /code-review rounds. Label = the space's latest NON-EMPTY own visit title; the shared historyURL.title only when no other space has a visit of the URL, else '' (displayTitle shows the URL). searchHistory: FTS over both columns stays the candidate gate + ranking; a candidate qualifies if the space visited it AND (FTS url-column match OR an in-scope visit's own title passes the shared titleMatchCondition = LIKE/GLOB prefilter + history_title_matches). Review findings fixed: legacy NULL-title fallback leaked the other profile's title (now guarded, also in the matcher input); FTS5 keyword tokens (NOT/AND/OR) were a syntax error returning nothing in palette, History page and chrome.history.search - all tokens now quoted via ftsPrefixQuery; weak ordering tests replaced by full-order + id-tiebreak + filter-before-LIMIT tests; projection deduped (labelledSelect). Accepted + pinned by tests: (1) an own title is findable only while the shared title also contains the word (FTS gate; main-thread per-keystroke budget) - root fix would be indexing every title a URL has had (schema migration), which would also let TASK-93 drop its scan; (2) match and label can come from different own visits (a row is a URL). Documented, not fixed: faviconURL/rank/visitCount remain cross-space; legacy-guard hole when another space's NULL-title visits set the shared title and were then deleted (90-day legacy window only). Timings, 50k visits, Debug: search 'a' 17.0 ms (was 18.4), URL token 8.4 (18.9), title-only 3.6 (2.5), miss 0.6, recentHistory 28.3 (25.2; pre-existing full aggregation - candidate follow-up), worst case one URL with 5,000 non-matching own visits 25 ms. Validation: full suite 1449 tests, 5 skipped, 0 failures; runtime check in the real app against the on-disk isolated DB with a seeded foreign-space visit (labels own, 'budget'/'secret' empty, foreign-only URL never returned, 'NOT wiki' works, provider rows correct). Real-key palette typing not done (screen locked); palette UI code unchanged.

2026-09-20 follow-ups decided by the user: TASK-96 (index every title a URL has had) and TASK-97 (recentHistory aggregation) filed. NOT filed, by decision: a profile-aware guard for the History page's legacy NULL-title fallback in searchVisits - it only affects pre-TASK-91 visits and ages out with the 90-day expiry.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Palette history suggestions (recent, search, inline completion) now show the space's own latest visit title and never match through a title only another profile's visit gave the URL; scope stays the single space. Also fixed: uppercase NOT/AND/OR in any history search was an FTS syntax error that returned nothing. No schema change. Verified by 1449 passing tests, two code-review rounds and a runtime check of the production path.
<!-- SECTION:FINAL_SUMMARY:END -->
