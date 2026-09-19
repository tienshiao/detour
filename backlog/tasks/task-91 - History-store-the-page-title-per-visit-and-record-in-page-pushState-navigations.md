---
id: TASK-91
title: >-
  History: store the page title per visit, and record in-page (pushState)
  navigations
status: To Do
assignee: []
created_date: '2026-09-19 20:33'
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
- [ ] #1 A migration adds a nullable per-visit title; new visits store the title they were recorded with, and historyURL.title still carries the latest known title
- [ ] #2 The History page shows each visit's own title, falling back to the URL-level title for visits recorded before the migration
- [ ] #3 Two visits to the same URL with different titles show their different titles (test); a later visit or a late title correction never changes an earlier visit's title (test)
- [ ] #4 Cross-profile: profile B visiting a URL with a different title does not change the title profile A's History page shows for A's visits (test)
- [ ] #5 The TASK-88 late-title correction updates the visit the tab recorded (and the URL-level latest title), under the same guards and the 60 s window; it cannot touch another visit
- [ ] #6 Command palette suggestions, URL completion, FTS search and the extensions history API keep working from the URL-level title; the decisions on indexing visit titles and on cross-profile suggestion titles are recorded in the task
- [ ] #7 An in-page navigation (history.pushState) records a visit for the new URL once its title has settled, with the existing exclusions and dedup; replaceState-only rewrites do not flood the history (rule defined and tested)
- [ ] #8 Deleting the latest visit of a URL (TASK-87 APIs) leaves historyURL.title consistent with the newest remaining visit
<!-- AC:END -->
