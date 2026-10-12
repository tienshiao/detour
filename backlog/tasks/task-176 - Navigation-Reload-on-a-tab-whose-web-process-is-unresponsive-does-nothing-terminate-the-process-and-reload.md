---
id: TASK-176
title: >-
  Navigation: Reload on a tab whose web process is unresponsive does nothing;
  terminate the process and reload
status: To Do
assignee:
  - '@claude'
created_date: '2026-10-12 23:34'
labels:
  - webkit
  - navigation
  - bug
dependencies:
  - TASK-175
priority: medium
ordinal: 199000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found with TASK-175. BrowserTab.reload() ends in webView.reload(), which only queues a message to the web process. When that process's main thread is blocked (TASK-175: 1h35m in a sync IPC; any long hang does the same) the reload never starts, WKWebView.isLoading stays true so the sidebar shows Stop instead of Reload, Stop does nothing either, and the pane is white. Detour has no handling at all for an unresponsive web process (no _webViewWebProcessDidBecomeUnresponsive:, no _webProcessIsResponsive).

Observed timing in the installed app: Reload at 16:15:21, WebKit's didBecomeUnresponsive at 16:15:24 (its 3 s responsiveness timer starts with the reload). WebKit's flag is not a steady signal: it reads responsive again every time the view is hidden (WebPageProxy stops the timer on a visibility change; seen at 16:15:26 and 16:15:54 with the process still blocked), so the rule has to key on 'a load the user asked for has not started' plus the unresponsive report, not on the flag alone.

What to build: a load the user asked for (Reload, Cmd+R, a favourite's double-click, a typed URL) that has not started when WebKit reports the process unresponsive terminates the web process and issues the load again in a fresh one. Stop withdraws the request. A page that is merely busy and that the user has not asked to reload is left alone.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Reload on a tab whose web process is blocked loads the page in a new web process within a few seconds of the click, without a second click
- [ ] #2 A pending load that the user stopped before the unresponsive report does not terminate the process
- [ ] #3 An unresponsive report with no pending user load terminates nothing
- [ ] #4 The deliberate termination does not count towards the crash-reload cap (noteProcessTermination) and does not reload twice
- [ ] #5 Works for a web view the window owns and for one the tab is its own delegate of
- [ ] #6 Tests: the rule as a pure function, and a real WKWebView whose page blocks its main thread
<!-- AC:END -->
