---
id: TASK-168
title: >-
  Navigation: a sign-in popup (Google sign-in from claude.ai) cannot reach the
  page that opened it or close itself, so the sign-in never completes
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-10 07:08'
updated_date: '2026-10-10 07:55'
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
- [x] #2 A window opened by a page has window.opener set, and opener.postMessage from it reaches the opening page, including when the two are on different origins
- [x] #3 window.close() called by a page-opened tab closes that tab, and the tab that opened it becomes selected again when the closed tab was the selected one
- [x] #4 window.close() does not close a tab the user opened themselves (WebKit's rule for script-closable windows is kept)
- [x] #5 The opening page sees closed == true on its window handle after the popup tab is closed, whether the page or the user closed it
- [x] #6 Tests with local fixture pages cover the popup round trip (open, message the opener, close) in a real BrowserWindowController
- [ ] #7 Signing in to claude.ai with Google completes in the running app: the Google tab goes away and the claude.ai tab ends up signed in (checked by the user if it needs their account)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Spike (shared with TASK-167): opener link, postMessage and where window.close() is reported.
2. Failing tests in PageOpenedWindowTests: a popup on another origin messages its opener; a popup that closes itself closes its tab and the opener is selected again; the opener reads closed on its handle after its own close() and after the user closes the tab; a tab the user opened and navigated is not closed by its page.
3. Implement webViewDidClose (the WKUIDelegate method; webView(_:didClose:) was never called): close the tab, and when it was the selected one select the tab that opened it.
4. Establish which mechanism claude.ai's Google sign-in uses, then check the real sign-in in the running app.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Findings so far, 2026-10-10

From the TASK-167 spike (docs/harness/task167-window-open-spike.swift):
- With createWebViewWith returning nil the popup has no opener and the opening page's window.open() returned null. With a web view returned, window.opener is set and opener.postMessage reaches the opening page.
- window.close() is reported as webViewDidClose(_:) on the closing web view's UI delegate, whether the child, the opener (on its handle) or a noopener child called it; the opener then reads closed === true. Detour implemented webView(_:didClose:), which is not a WKUIDelegate method, so no page had ever closed a tab.

Change (with TASK-167's): the popup tab is a real child (TASK-167), and webViewDidClose closes the tab; when it was the selected tab of the window's active space, the tab that opened it (parentID) is selected again ahead of the close rule's siblings, except for a split pane, which keeps the split rule. The tab is closed like a user close and stays reopenable. WebKit's own rule for which windows a script may close is kept (a script-opened window, or one with nothing to go back to).

Not established: which mechanism claude.ai's Google sign-in uses (AC #1), and whether anything else is in the way once the opener link exists. Needs the running app.

## Status: NOT BUILT, NOT RUN

Same blocker as TASK-167: xcodebuild cannot run until Xcode's first-launch components are installed (admin). Code and tests are written, uncompiled and unrun. No acceptance criterion is checked.

## Built and run, 2026-10-10 (replaces 'NOT BUILT' above)

Tests: the four TASK-168 cases in PageOpenedWindowTests fail against the old code where they should (the cross-origin message, the self-closing popup, the opener's closed flag) and pass with the fix; the fourth (a page cannot close a tab the user opened and navigated) passes before and after. 83 tests across the navigation suites, 0 failures (listed in TASK-167).

AC #5 holds as tested: the opener reads closed === true after its own close() call and after the tab is closed through the window (BrowserWindowController.closeTab).

Runtime (/verify, Debug build, isolated profile): a page on http://localhost opens http://127.0.0.1/popup.html with popup features. Observed: window.open returned a window; the popup tab opened selected, parented to the opener; the popup reported opener=set; the opener received the message from the other origin; 1.5 s later the popup called window.close(), its tab left the session (it is in the closed-tab list), the opener tab was selected again and read popup.closed === true.

Still open: AC #1 (which mechanism claude.ai's Google sign-in uses) and AC #7 (the real sign-in). Both need the user's Google account in a build with this change; nothing else was found in the way with the fixture, but cross-origin opener policy headers and tracking prevention between accounts.google.com and claude.ai are not covered by a loopback fixture.

## Final checks, 2026-10-10

Review (/code-review --fix, shared with TASK-167): webViewDidClose handles normal tabs only; a window.close() from a Peek, a pinned tab or a favourite is ignored. Filed as TASK-171 (what each should do is a product decision). Before this task none of them could close either, since the delegate method was never called.

AC #4 as tested: WebKit lets a script close a window a script opened, or one with nothing to go back to; a tab the user opened and has navigated in (two history entries) is not closed by its page. A user-opened tab with a single history entry can close itself, as in Safari; that rule is WebKit's and is kept.

Full DetourTests run on the final code: 2,095 tests, 0 failures, 11 skipped. /verify repeated on a build of the final code: popup on another origin opens with an opener, messages it, closes itself; its tab leaves the session and is in the closed-tab list; the opener is selected again and reads closed === true.

Left open, both need the user's Google account in a build with this change: AC #1 (which mechanism claude.ai's sign-in uses) and AC #7 (the real sign-in completes). The task stays In Progress until the user has tried it.
<!-- SECTION:NOTES:END -->
