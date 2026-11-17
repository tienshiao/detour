---
id: TASK-408
title: Trim the back/forward cache of tabs hidden for a while, keeping their history
status: To Do
assignee: []
created_date: '2026-11-17T20:36:00Z'
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
- [ ] #1 Measured first: memory and GPU IOSurfaces held by a few tabs with cached back entries, before and after clearing (record the numbers here)
- [ ] #2 A tab hidden longer than a delay the user confirms has its back/forward cache cleared once; the visible tab and audible/capturing tabs are never trimmed
- [ ] #3 Back/Forward still work on a trimmed tab, including the back swipe and its pictures (TASK-376), checked at runtime
- [ ] #4 The private selector is called only after respondsToSelector, and a missing selector disables the feature quietly
<!-- AC:END -->
