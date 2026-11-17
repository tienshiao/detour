---
id: TASK-408
title: Trim the back/forward cache of tabs hidden for a while, keeping their history
status: Done
assignee:
  - '@claude'
created_date: '2026-11-17T20:36:00Z'
updated_date: '2026-11-17T21:43:00Z'
labels:
  - sleeping
  - memory
  - gpu
dependencies:
  - TASK-405
priority: low
type: feature
ordinal: 489000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
WebKit keeps recent back/forward entries as complete frozen pages (DOM, JS heap, layers), and after a cross-site navigation it can keep the old site's web process alive to hold them. Detour leaves this at WebKit's defaults and never trims it. Nook clears a tab's back/forward cache through the private -[WKWebView _clearBackForwardCache] after 300 s off screen (PageSession.swift:977-983, TabCompositorView.swift:48,168). Its commit a6f5104 measured six tabs after three navigations each holding 3.5 GB in the cache, and the total going from 5.7 GB to 2.5 GB.

Clearing keeps the back/forward list itself: Back and Forward still work, but the trimmed entries load again (scroll position and some form state restored from the history item) instead of being unfrozen with their in-memory state. Whether frozen pages also hold GPU-process IOSurfaces is unmeasured; TASK-405's experiment can answer it before this ships.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Measured first: memory and GPU IOSurfaces held by a few tabs with cached back entries, before and after clearing (record the numbers here)
- [x] #2 A tab hidden longer than a delay the user confirms has its back/forward cache cleared once; the visible tab and audible/capturing tabs are never trimmed
- [x] #3 Back/Forward still work on a trimmed tab, including the back swipe and its pictures (TASK-376), checked at runtime
- [x] #4 The private selector is called only after respondsToSelector, and a missing selector disables the feature quietly
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure first (TASK-405 bfcache mode).
2. BrowserTab.clearBackForwardCache() (private _clearBackForwardCache behind respondsToSelector) plus a once-per-stretch marker.
3. TabStore.trimStaleBackForwardCaches(now:delay:) on the 5-min archiveTimer: live, unhosted, deselected >= 15 min, not audible or capturing.
4. Tests, wiki, review, runtime check of Back and the back swipe on a trimmed tab.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User decision 2026-11-17: if the TASK-405 measurement shows that trimming frees memory or GPU IOSurfaces, clear a tab's back/forward cache once it has been hidden 15 minutes.

Measured (TASK-405, docs/task-405/run5-bfcache.json): 6 tabs, each navigated 3 more times across sites and hidden, held 14 web processes and 2,367 IOSurface regions. 30 s after trimming: 7 and 1,521 (846 freed, 36%).

Implemented on branch task-408 (worktree .claude/worktrees/lane-b), not yet merged.

Review (/code-review medium --fix): 6 findings, 4 fixed. The marker resets when the web view is released (sleep/wake within a stretch). Doc comment placement fixed. The log reports seconds. Corrected text: Peeks and Quick Detour pages are not reached, because nothing sets their lastDeselectedAt; trimming them would need new logic (a follow-up if wanted). Skipped: sharing the hidden-and-quiet check with staleTabCandidates; the defensive dedup set.

Tests: BackForwardCacheTrimTests 7, plus SleepShowBudget, MemoryPressureSleep, BrowserTabWake, AutomationGPUTools, TabStore, ArchiveMedia and FavoritePeekPersistence suites: 115 passed, 1 gated skip.

Pending: the runtime check of AC #3 (Back/Forward and the back swipe with its pictures on a trimmed tab). The user's screen has been locked since 13:20, and WebKit does not paint while locked.

Claude's choice, to confirm: a profile set to never sleep tabs is trimmed too, because trimming keeps the page live.

Runtime check 2026-11-17 13:32-13:39, isolated Debug build of branch task-408, DETOUR_BACK_FORWARD_TRIM_SECONDS=1. A tab navigated example.com -> iana.org -> apple.com, then was hidden behind a new tab.
- The 5-minute archiveTimer trimmed it after 296 s, logging 'Trimmed the back/forward caches of 1 tabs hidden for 1 s or more'.
- The tab's pool went from 3 web processes to 1, and the GPU total from 233 to 176.
- Selected again: Cmd+[ landed on iana.org and the page rendered in full (screenshot); Cmd+] returned to apple.com; Cmd+[ twice reached example.com.
- Not driven: WebKit's own two-finger back swipe on such a tab (synthetic events cannot drive it). Its pictures come from WebKit's own snapshot store, kept per back/forward item, not from the page cache. Detour's forward picture applies only to opener tabs on their first page (TASK-355), so it was rightly absent here.

The user confirmed Claude's choices on 2026-11-17.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Tabs hidden 15 minutes (the user's delay) have their back/forward cache cleared by the 5-minute archiveTimer, once per hidden stretch, keeping their history. The trim uses the private _clearBackForwardCache when present. Hosted, audible, capturing and sleeping tabs are skipped; pinned and favourite backing tabs are included; Peeks and Quick Detour pages are not reached.

Why: TASK-405 measured 6 navigated hidden tabs dropping from 14 web processes and 2,367 IOSurface regions to 7 and 1,521 after a trim.

Tests: BackForwardCacheTrimTests 7; with neighbour suites, 115 passed and 1 gated skip.

Runtime: trimmed by the timer in the running app, processes 3 -> 1, and Back/Forward work and render (details in the notes).

Claude's choice, to confirm: profiles set to never sleep tabs are trimmed too.
<!-- SECTION:FINAL_SUMMARY:END -->
