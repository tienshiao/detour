---
id: TASK-170
title: >-
  Navigation: when a page-started navigation fails, the error page names the
  page the tab was on, and Reload goes back to it
status: To Do
assignee: []
created_date: '2026-10-10 07:46'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/BrowserTab.swift
  - wiki/platform/wkwebview-delegate-order.md
  - DetourTests/PageOpenedWindowTests.swift
priority: medium
ordinal: 193000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-10 by the review of TASK-167 and confirmed with a test (not committed). In an ordinary selected tab showing page P, the page sets location.href to a URL on a server that refuses the connection. The error page appears, but for P: its failedURL is P's URL, the tab's URL is P and Reload retries P instead of the URL that failed. A link clicked to a dead host should behave the same way (not run). A sign-in popup that has committed one page and is then redirected to a dead callback URL is the same case.

Cause as understood: BrowserTab.didFailProvisionalNavigation raises the error page for lastAttemptedURL. For a load the tab starts itself (load(_:)) that is set up front and protected by navigationPending. For a navigation the page starts, the only source is the URL observer on WKWebView.url, and by the time WebKit reports the provisional failure the web view's URL has gone back to the committed page, so the observer has written P back. WebKit's source commits the page load state before calling the failure delegate; the test agrees with that order but did not observe it directly.

The failed URL is in the error (NSURLErrorFailingURLErrorKey). TASK-167 uses it only when the tab has no URL of its own (nil or about:blank), for a window a page opened. Using it more widely changes what existing tabs show: for a typed URL that redirects to a host that fails, the error would name the redirect target rather than what was typed (and that is what Reload would retry), and a restored session's failure is deliberately not an error page at all (TASK-45). Decide those cases, test first.

The test that showed it (PageOpenedWindowTests fixture): open /opener selected in a window; stop a second loopback server to get a dead port; run location.href = '<dead>/target' in the tab; wait for the error scheme; ErrorPage.originalURL(from:) of the web view's URL was the opener's URL, expected the dead one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A failing test in a real window shows the error page naming the wrong URL for a page-started navigation (script location change and a clicked link) to a server that refuses the connection
- [ ] #2 The error page, the tab's URL and Reload all use the URL that failed
- [ ] #3 The rule for a typed URL that redirects to a failing host is decided and recorded, and a failed session restore still shows no error page (TASK-45)
- [ ] #4 A background tab (its own navigation delegate) and a selected tab behave the same
<!-- AC:END -->
