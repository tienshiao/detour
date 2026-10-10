---
id: TASK-168
title: >-
  Navigation: a sign-in popup (Google sign-in from claude.ai) cannot reach the
  page that opened it or close itself, so the sign-in never completes
status: To Do
assignee: []
created_date: '2026-10-10 07:08'
labels:
  - bug
dependencies:
  - TASK-167
references:
  - Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
  - wiki/platform/wkwebview-delegate-order.md
priority: high
ordinal: 191000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-10-10. Signing in to claude.ai with Google opens the Google OAuth screen in a new tab. The user completes it, and then nothing happens: the Google tab stays open on its last page and the claude.ai tab never receives the result.

Likely causes (read from the code, not yet reproduced):

1. No opener. createWebViewWith returns nil and loads the URL into an unrelated tab (TASK-167), so the popup's window.opener is null and the opening page's window.open() returned null. A popup sign-in flow hands its result back through that link (postMessage to window.opener, or the opener polling/closing the window it opened), so the result has nowhere to go.

2. The close callback is never called. The window implements `webView(_:didClose:)`, which is not a WKUIDelegate method; WebKit calls `webViewDidClose(_:)`. So a page's window.close() has never closed a tab. Once the popup is a real child window, it will call window.close() when it is done and the tab has to go away.

After the popup closes, the tab that opened it should be selected again (it is the tab's parent), so the user lands back on the signed-in page.

Not established: which mechanism claude.ai's Google sign-in uses (Google Identity Services popup with a postMessage relay, or a redirect back to a claude.ai callback page that messages its opener), and whether anything else is in the way once the opener link exists — cross-origin opener policy headers, storage partitioning or tracking prevention between accounts.google.com and claude.ai, or the popup features (the popup opens as a tab here; Peek routing treats popup-style opens as their own tab on purpose, TASK-85). Establish it with a local fixture that reproduces the flow, then with the real sign-in.

Depends on TASK-167, which makes a page-opened window a real WebKit child.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause is recorded: which mechanism the claude.ai Google sign-in uses to return its result, and what stopped it in Detour
- [ ] #2 A window opened by a page has window.opener set, and opener.postMessage from it reaches the opening page, including when the two are on different origins
- [ ] #3 window.close() called by a page-opened tab closes that tab, and the tab that opened it becomes selected again when the closed tab was the selected one
- [ ] #4 window.close() does not close a tab the user opened themselves (WebKit's rule for script-closable windows is kept)
- [ ] #5 The opening page sees closed == true on its window handle after the popup tab is closed, whether the page or the user closed it
- [ ] #6 Tests with local fixture pages cover the popup round trip (open, message the opener, close) in a real BrowserWindowController
- [ ] #7 Signing in to claude.ai with Google completes in the running app: the Google tab goes away and the claude.ai tab ends up signed in (checked by the user if it needs their account)
<!-- AC:END -->
