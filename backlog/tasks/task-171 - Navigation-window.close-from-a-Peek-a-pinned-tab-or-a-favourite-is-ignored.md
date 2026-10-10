---
id: TASK-171
title: 'Navigation: window.close() from a Peek, a pinned tab or a favourite is ignored'
status: To Do
assignee: []
created_date: '2026-10-10 07:46'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
  - wiki/tabs/tab-lifecycle.md
priority: low
ordinal: 194000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-10 by the review of TASK-168. webViewDidClose closes a tab only when the closing web view belongs to a normal tab (space.tabs). WebKit also lets a page close a window that has nothing to go back to, which includes a Peek the app loaded (one history entry), a pinned tab and a favourite. For those WebKit calls webViewDidClose, nothing matches, and the page stays on screen while the page itself and any opener read window.closed === true.

The case that matters: a _blank link or a tab-style window.open from a pinned tab opens as a Peek (TASK-85); a page there that finishes and calls window.close() (a 'you can close this window' confirmation) stays up.

What each should do is a product decision: a Peek is presumably dismissed (closePeekOverlay), a pinned tab presumably goes dormant like Cmd+W, a favourite deactivates. Before TASK-168 none of this could happen, because the delegate method had the wrong name and was never called.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 What window.close() does for a Peek, a pinned tab and a favourite is decided and recorded
- [ ] #2 A Peek whose page calls window.close() is dismissed and its host tab is on screen again
- [ ] #3 Tests in a real window cover each decided case
<!-- AC:END -->
