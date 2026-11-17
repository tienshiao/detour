---
id: TASK-408
title: Trim the back/forward cache of tabs hidden for a while, keeping their history
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-17T20:36:00Z'
updated_date: '2026-11-17T21:30:00Z'
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
- [ ] #3 Back/Forward still work on a trimmed tab, including the back swipe and its pictures (TASK-376), checked at runtime
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
<!-- SECTION:NOTES:END -->
