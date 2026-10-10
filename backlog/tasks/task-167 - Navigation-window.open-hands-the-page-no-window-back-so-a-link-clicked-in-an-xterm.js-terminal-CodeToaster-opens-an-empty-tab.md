---
id: TASK-167
title: >-
  Navigation: window.open() hands the page no window back, so a link clicked in
  an xterm.js terminal (CodeToaster) opens an empty tab
status: To Do
assignee: []
created_date: '2026-10-10 07:07'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
  - Detour/Browser/TabStore.swift
  - Detour/Browser/BrowserTab.swift
  - wiki/platform/wkwebview-delegate-order.md
priority: high
ordinal: 190000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-10. In CodeToaster (a web app with an xterm.js terminal) the terminal sometimes prints a link such as http://localhost:5173/. Clicking it opens a new tab, but the tab never loads the URL and the address bar stays empty.

Likely cause (read from the code, not yet reproduced): BrowserWindowController's createWebViewWith always returns nil. For a page's own window.open it creates an unrelated tab with TabStore.addTab(in:url:) and loads the request URL into it itself, so the page's window.open() call returns null and the new tab has no opener relationship with the page.

xterm.js's web-links addon opens a link in two steps: `const w = window.open(); w.opener = null; w.location.href = uri`, and when window.open() returns null it only logs 'Opening link blocked as opener could not be cleared'. In Detour the first step creates a tab for the empty/about:blank request and returns null, so the second step never runs: an empty tab with no URL, which is the report. The same shape (open a blank window, then navigate or write into it) is common outside xterm.js.

The fix direction is for a page-initiated new window to be a real WebKit child: a WKWebView created with the configuration WebKit passes to createWebViewWith, adopted by a new tab (TabStore.addTab(in:webView:) exists and is used by Peek's expand-to-tab) and returned to WebKit, which then performs the navigation itself. Things that must keep working and need deciding along the way: the Peek routing for pinned tabs and favourites (TASK-85), the refusal of internal pages and of data: URLs (TASK-86, TASK-159), the context menu's Open in New Tab / New Window actions that also arrive here, tab insertion next to the opener, extension tab lifecycle reporting for the adopted web view, the tab's profile/data store and content rules (the supplied configuration is the opener's), and noopener opens (window.open with 'noopener', rel=noopener links) where WebKit gives the page no handle either way.

TASK-168 (sign-in popups) builds on this one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause is reproduced and recorded: what createWebViewWith receives for a bare window.open() and what the page gets back, in a test or a standalone spike
- [ ] #2 window.open() with no URL followed by assigning location.href on the returned window opens one new tab that loads the assigned URL and shows it in the address bar (the xterm.js web-links sequence)
- [ ] #3 window.open(url) returns a non-null window to the page and the new tab loads the URL once, not twice
- [ ] #4 A window opened with noopener still opens a tab that loads its URL
- [ ] #5 Peek routing for pinned tabs and favourites, the internal-page and data: refusals, and the context menu's Open in New Tab / Open in New Window still behave as before, covered by the existing tests
- [ ] #6 The new tab is inserted next to its opener, uses the opener's profile, and is reported to extensions like any other new tab
- [ ] #7 Tests in a real BrowserWindowController with a local fixture page cover the blank-then-navigate sequence and window.open(url)
- [ ] #8 Checked at runtime with a page that reproduces the xterm.js link click; the wiki's delegate-order page records what was learned
<!-- AC:END -->
