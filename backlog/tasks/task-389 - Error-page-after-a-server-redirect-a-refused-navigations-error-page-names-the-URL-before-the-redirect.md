---
id: TASK-389
title: >-
  Error page: after a server redirect, a refused navigation's error page names
  the URL before the redirect
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:42:00Z'
labels:
  - navigation
  - error-page
  - webkit
dependencies: []
references:
  - Detour/Browser/BrowserTab.swift
  - wiki/features/error-pages.md
priority: low
type: bug
ordinal: 470000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-372, its final notes); read from code, not measured. TASK-372 made a failed navigation whose error names no URL (a refused `webkit-extension://` main frame: -1008 with no `NSURLErrorFailingURLErrorKey`) name `BrowserTab.provisionalURL`, the web view's URL when the provisional navigation started. It is set in `BrowserTab.didStartProvisionalNavigation()`, which three navigation delegates forward: the tab's own (`BrowserTab`), `BrowserWindowController+Navigation` and `QuickDetourWindowController+WebKit`. None implements `webView(_:didReceiveServerRedirectForProvisionalNavigation:)`, so after a server redirect `provisionalURL` still names the URL before the redirect: a page that redirects to an extension page WebKit refuses would get an error page naming the pre-redirect URL. Whether WebKit follows an http redirect into a `webkit-extension://` main frame at all (and with which error) is not measured.

Suggested in TASK-372: update `provisionalURL` on the server-redirect callback in each delegate. Per CLAUDE.md, each new optional WebKit delegate method gets a row in `WebKitDelegateReachabilityTests`. Wiki: wiki/features/error-pages.md, wiki/platform/wkwebview-delegate-order.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 What a main-frame server redirect to a refused extension page reports is measured and recorded in this task
- [ ] #2 If it can happen: the error page names the URL the redirect led to, in a window-owned tab, a background tab and a Quick Detour window
- [ ] #3 Tests cover it, and each new delegate method has a WebKitDelegateReachabilityTests row
<!-- AC:END -->
