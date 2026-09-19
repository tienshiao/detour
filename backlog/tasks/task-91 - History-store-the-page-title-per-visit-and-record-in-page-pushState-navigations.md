---
id: TASK-91
title: >-
  History: store the page title per visit, and record in-page (pushState)
  navigations
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-19 20:33'
updated_date: '2026-09-19 22:29'
labels:
  - history
dependencies:
  - TASK-87
references:
  - Detour/Storage/HistoryDatabase.swift
  - Detour/Browser/TabStore.swift
  - Detour/Browser/BrowserTab.swift
  - Detour/Browser/InternalPages/HistoryPageBridge.swift
priority: medium
ordinal: 91000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up to TASK-86/88, from the user's observation that a page's title should not be normalized onto its URL: titles change over time.

Today historyURL holds ONE title per URL (recordVisit upserts title = excluded.title) and historyVisit has none. Consequences:
- The newest title relabels every older visit of that URL. TASK-88 fixed how a WRONG title got stored (SPA title settling late), not the fact that one write renames all visits - the user's 68 youtube.com/ visits all showed a single video's title.
- Pages whose title legitimately changes (news front pages, dashboards, documents, unread counters) lose what they were called on the day they were visited.
- PRIVACY: historyURL is one row per URL shared by ALL profiles, so the title is shared too. A Work-profile visit titled '(3) Inbox - you@work' becomes the title the Personal profile's History page shows for that URL. The History page takes visit times from in-scope visits only (TASK-86), but the title still crosses profiles.

Design (Safari's model: a title on the URL-level item AND on each visit; Chrome/Firefox keep it on the URL only):
- New migration: nullable historyVisit.title. recordVisit writes the tab's title onto the visit row it inserts, and still updates historyURL.title as 'latest known title'.
- historyURL.title keeps feeding what wants one row per URL: command palette suggestions, bestURLCompletion, FTS (historySearch), chrome.history for extensions. No behaviour change there.
- The History page shows COALESCE(visit.title, url.title): per-visit and therefore per-profile for every visit recorded from now on. Old visits have no title of their own (it was never stored - no backfill possible) and fall back to the URL title.
- TASK-88's late-title correction targets the VISIT the tab recorded (BrowserTab keeps the recorded visit id next to lastRecordedHistoryURL/At; recordVisit must hand the new visit id back) and refreshes historyURL.title as latest-known. It must no longer be able to rename other visits, in particular another profile's.
- History-page search keeps matching the URL-level title in FTS at first; a title that a page USED to have is then not searchable. Decide in the plan whether to index visit titles too (bigger index; needs its own FTS table or a contentless one) or to leave that out - record the decision.
- Cross-profile title in search results/suggestions: searchVisits should return the in-scope visit's own title when it has one. The command palette's URL-level title is still shared across profiles - decide whether that is acceptable (it is today's behaviour) or whether suggestions should prefer the latest in-scope visit title; record the decision.

Second part - visits that are never recorded: TabStore records a visit only when tab.isLoading goes false. history.pushState / replaceState navigations do not toggle isLoading at all (verified with a real WKWebView in TASK-88: HistoryTitleUpdateTests.testPushStateRecordsNoVisitAndNeverRenamesThePageItLeft), so single-page-app page views reach the history only when an unrelated subframe/resource load happens to toggle isLoading - and then with whatever URL/title exist at that moment. Record same-document navigations deliberately: a tab URL change while not loading is a visit, recorded once URL and title have settled (one 'record when settled' path shared with the normal recorder rather than a second ad-hoc one), with the existing exclusions (incognito, non-http(s), error pages, internal pages) and the 30 s dedup. replaceState-only URL rewrites (query-string churn, e.g. the History page's own ?q=) should not each become a visit - define the rule (e.g. path change, or pushState-like growth of the back/forward list) and test it.

Interactions: TASK-87's delete APIs recompute historyURL aggregates; when the latest visit of a URL is deleted, historyURL.title should fall back to the newest remaining visit's title (or stay as is if none has one).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A migration adds a nullable per-visit title; new visits store the title they were recorded with, and historyURL.title still carries the latest known title
- [x] #2 The History page shows each visit's own title, falling back to the URL-level title for visits recorded before the migration
- [x] #3 Two visits to the same URL with different titles show their different titles (test); a later visit or a late title correction never changes an earlier visit's title (test)
- [x] #4 Cross-profile: profile B visiting a URL with a different title does not change the title profile A's History page shows for A's visits (test)
- [x] #5 The TASK-88 late-title correction updates the visit the tab recorded (and the URL-level latest title), under the same guards and the 60 s window; it cannot touch another visit
- [x] #6 Command palette suggestions, URL completion, FTS search and the extensions history API keep working from the URL-level title; the decisions on indexing visit titles and on cross-profile suggestion titles are recorded in the task
- [x] #7 An in-page navigation (history.pushState) records a visit for the new URL once its title has settled, with the existing exclusions and dedup; replaceState-only rewrites do not flood the history (rule defined and tested)
- [x] #8 Deleting the latest visit of a URL (TASK-87 APIs) leaves historyURL.title consistent with the newest remaining visit
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Branch task-91-visit-titles is STACKED on task-87-history-deletion (not yet merged: its real-event runtime pass needs an unlocked screen).

Decisions (Fable):
A. Migration h4: nullable historyVisit.title. recordVisit writes the tab's title onto the visit row AND keeps upserting historyURL.title (latest known). No backfill - old visits fall back to the URL title via COALESCE(v.title, h.title) in visits()/searchVisits().
B. recordVisit hands the new visit id back (completion on the writer queue -> main) and BrowserTab keeps lastRecordedVisitID next to lastRecordedHistoryURL/At. A dedup-skipped recording keeps the previous id only if it was for the same URL; otherwise nil.
C. TASK-88's correction becomes updateTitle(visitID:url:title:): UPDATE that one historyVisit row; update historyURL.title only if that visit is still the newest visit of the URL (an old tab must not override a newer visit's latest-known title). No id yet (async write still in flight) -> skip; the dedup-branch retry and the next title event cover it. Same policy guards and 60 s window. It can no longer rename other visits, another profile's included.
D. FTS stays on the URL-level title (historySearch synchronized with historyURL): History search does not find a title a page USED to have. Not indexing visit titles now - a second FTS table over visits multiplies the index for a marginal feature; revisit if asked. searchVisits still DISPLAYS the in-scope visit's own title.
E. Command palette / completion / extensions API keep the shared URL-level title (today's behaviour, cross-profile). Preferring the latest in-scope visit title in suggestions is a possible follow-up, not this task.
F. Deleting visits (TASK-87 reconcile): when a URL survives, historyURL.title becomes the newest remaining visit's non-null title (unchanged if none has one).
G. In-page navigations: a tab URL change while NOT loading is a candidate visit, recorded through the SAME recorder once it has settled (debounce ~1 s; URL unchanged and still not loading when it fires), so title/dedup/exclusions/error-page/incognito rules are shared. replaceState rule: record only when the web view's current back/forward ITEM is a different item from the one the tab last recorded (pushState and popstate traversal create/select another item; replaceState rewrites the same item's URL) - pure policy function, unit-tested; the History page's own ?q= rewrites and query-string churn therefore never record. The 30 s dedup still applies.

Steps: 1. (Opus) DB: migration, recordVisit title + id, updateTitle(visitID:), COALESCE in queries, reconcile title fallback, tests. 2. (Opus) TabStore/BrowserTab: visit id plumbing, correction retarget, same-document recorder + policy, tests incl. real-WKWebView pushState/replaceState. 3. Fable review, /code-review, runtime check (YouTube-like local SPA page), commit; merge after TASK-87.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (uncommitted) verified at runtime in an isolated instance against a local SPA page: normal load recorded 'SPA Home'; pushState to /watch?v=1 recorded as its own visit carrying its settled title 'Video one' (set 600 ms after the push); the page left kept 'SPA Home'; replaceState query churn (&t=10) recorded nothing. The page's second pushState was never reached: the Mac's screen was locked and WebKit throttles timers of hidden pages - covered by SameDocumentVisitTests, re-check on an unlocked screen. Back/forward item identity verified against real WKWebView: pushState and popstate traversal select a different WKBackForwardListItem, replaceState mutates the same item's url; a loadHTMLString document has NO current item (policy refuses; tests use the loopback HTTP server). Code review (8 findings) being fixed: id hand-back ordering + retry the correction when the id arrives; recording generation token; a dedup-skipped recording must not revive an old visit's correction window or follow the tab into another space; same-document navigations while isLoading were dropped (isLoading gate removed - item identity already excludes uncommitted navigations); a deleted visit's title surviving at the URL level (hadTitle in the staging table, blank when nothing titled remains); nil baseline item made replaceState look like a new entry (adopt baseline without recording). KNOWN LIMITATION kept by decision D: History search matches the URL-level title, so a row can show an in-scope visit title that does not contain the query, and the match can come from a title another profile's visit gave the URL - candidate follow-up: FTS over visit titles. New behaviour to be aware of: same-page #fragment navigations now record a visit (distinct URL + back/forward item; matches Chrome).

Committed on task-91-visit-titles (stacked on task-87-history-deletion); NOT merged - waits for TASK-87's unlocked-screen pass. Review fixes applied (see previous note); one deliberate narrowing: the recording generation is bumped whenever a pass changes which visit the tab holds (every recording, every dedup pass that clears the id), NOT on a dedup pass that continues the same visit - bumping there discarded the tab's own in-flight id and lost the late-title correction (verified by mutation testing both ways). Validation: targeted 190 tests x3 stable; full suite 1380 tests, 5 skipped, 0 failures. Runtime (isolated instance, page driven from native timers because the locked screen throttles hidden-page timers): load 'SPA Home'; pushState /watch?v=1 -> own visit 'Video one' (title set 300 ms after the push); two replaceState rewrites -> nothing; pushState /home -> 'SPA Home again'; #section-2 -> its own visit. Accepted costs: a cross-document load that takes >30 s after commit can record a second visit; the first pushState after a tab without a baseline item is not recorded. Test-infra finding: a WKWebView with NO navigation delegate never sends the request for load(_:) - offscreen tests that need a real load must install one.
<!-- SECTION:NOTES:END -->
