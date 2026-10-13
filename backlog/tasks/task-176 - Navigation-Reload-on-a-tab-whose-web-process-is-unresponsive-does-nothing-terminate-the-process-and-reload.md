---
id: TASK-176
title: >-
  Navigation: Reload on a tab whose web process is unresponsive does nothing;
  terminate the process and reload
status: Done
assignee:
  - '@claude'
created_date: '2026-10-12 23:34'
updated_date: '2026-10-13 01:06'
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
- [x] #1 Reload on a tab whose web process is blocked loads the page in a new web process within a few seconds of the click, without a second click
- [x] #2 An unresponsive report with no pending user load terminates nothing
- [x] #3 The deliberate termination does not count towards the crash-reload cap (noteProcessTermination) and does not reload twice
- [x] #4 Works for a web view the window owns and for one the tab is its own delegate of
- [x] #5 Tests: the rule as a pure function, and a real WKWebView whose page blocks its main thread
- [x] #6 Stop on a healthy page ends the load and keeps its web process; a Stop the blocked process never reads ends with the page reloaded in a new process instead of a tab that stays loading
- [x] #7 A page showing a script dialog (alert, confirm, prompt) is not treated as unresponsive
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Spike (docs/harness/task176-unresponsive-web-process-spike.swift): what WebKit reports for a blocked page and what _killWebContentProcessAndResetState does.
2. UnresponsiveLoadRecovery (pure reducer): requested / answered / stopped / becameUnresponsive / becameResponsive / patienceElapsed / reset -> none / waitForPatience / terminate(thenIssue:).
3. BrowserTab: reload() and load(_:) go through issue(_:); stopLoading(); the private responsiveness callbacks and didStartProvisionalNavigation on both navigation delegates; isTerminatingUnresponsiveProcess so the window's termination handler neither reloads nor counts a crash.
4. Tests: the reducer, and a real web process whose page spins.
5. Runtime check through the window (reloadPage on an on-screen blocked page).
6. Wiki: platform/unresponsive-web-process.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Spike results (macOS 26.7, WebKit 21624.5; same in a window and in none): reload() on a blocked page sets isLoading and estimatedProgress 0.1 at once; _webViewWebProcessDidBecomeUnresponsive: arrives 3.00 s later; _killWebContentProcessAndResetState calls webViewWebContentProcessDidTerminate before it returns, after which url is nil and isLoading false; reload() then loads the page in a new process.
Decisions: (a) patience of 5 s after WebKit's report before replacing the process, because on this machine (load average 40-66) a healthy process can miss WebKit's 3 s, and WebKit's own 3 s verdicts on the GPU process misfired five times that day; (b) WebKit's 'responsive' report is ignored while a request is pending, because it is also sent when the view is hidden with the process still blocked (seen twice in the incident log); (c) the load issued in the new process is not tracked, so one termination per request; (d) a pending request is cleared by isLoading turning false as well as by a provisional start, so a navigation refused before it begins (download, external app) cannot be replayed later.
Not covered: goBack/goForward, Peek reloads (they call the Peek web view directly), loads started by web content.

Code review (2026-10-12), seven findings. Fixed: navigationPending is kept across the kill for a URL load; a repeated unresponsive report keeps the first deadline; a failed kill of an abandoned GPU process is logged with its errno. Changed after the review: (1) the original criterion 'a load stopped before the report does not terminate the process' left exactly the dead end of the incident (white pane, Stop that does nothing) when the user stopped within the 8 s, so Stop is now a request like a load: answered on a healthy page, rescued with a reload of the page when the process never reads it; (2) a script dialog blocks the web process by design, so the window tells the tab and reports are dropped while one is up; (3) the tab no longer implements webViewWebContentProcessDidTerminate for an unclaimed web view, because that switches off WebKit's own reload-when-visible after a crash. Not changed: the reaper and the recycler each keep their own 120 s timer (duplication noted). Checked for the reaper finding: a Quick Look preview of an HTML file inside the app (QLPreviewView) uses an in-process web view on the app's own GPU process, no second GPU process appears (spike, 2026-10-12); Detour is not sandboxed, so its open panel is in-process too. A system service that runs its own WebKit GPU process on Detour's behalf was not found, and is not ruled out.

Second code review (2026-10-12): fixed a load that starts no provisional load (a jump within the page, an external-app link, a download) staying 'unanswered' while an earlier load kept isLoading true, to be replayed in a new process the next time the page was busy: a main-frame navigation policy request now counts as an answer. Script dialogs are counted per web process, since a window a page opened shares its opener's process. Both regression tests were run against the code with the fix removed and failed.
Runtime check (docs/task-175/runtime-check-reload.log): a selected tab whose page blocks its main thread, then reloadPage. WebKit reported the process unresponsive 3.0 s after the reload, Detour terminated it 5.25 s later (reason=RequestedByClient), issued the reload again, and the page loaded once in a new web process with the pane still in the window.
Tests: UnresponsiveLoadRecoveryRuleTests 16, UnresponsiveLoadRecoveryTests 5 (real web process); full DetourTests run 2,180 tests, 11 skipped, 0 failures.
Not verified at runtime: Stop on a blocked page and the script-dialog bracket in showJSAlert (covered by tests at the tab level only; no test drives a real alert sheet). The crash cap is skipped by a guard in the window's termination handler that no test asserts; the runtime check showed one reload. No test covers a dialog in another tab of the same web process (needs a script-opened window).
Not covered by the rule: goBack/goForward, Peek reloads, loads started by web content, an extension's tabs.reload and tabs.update (they call the web view directly), a script paused in the Web Inspector.

Correction to the note above: UnresponsiveLoadRecoveryRuleTests has 15 tests.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A load or a Stop that a blocked web process never answers now gets a fresh web process. BrowserTab feeds a pure reducer (UnresponsiveLoadRecovery): reload() and load(_:) are requests, answered by a provisional start, a navigation policy request or isLoading turning false; when WebKit reports the process unresponsive and the request is still unanswered five seconds later, the tab terminates the process and issues the load again (after an unanswered Stop: a reload of the page it was on). A request made while the process is already reported unresponsive replaces it at once. Script dialogs are not hangs. Verified with a real web process in tests and through the window in a running Debug build. Wiki: platform/unresponsive-web-process.
<!-- SECTION:FINAL_SUMMARY:END -->
