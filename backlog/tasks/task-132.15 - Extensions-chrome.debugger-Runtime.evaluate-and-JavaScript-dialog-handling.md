---
id: TASK-132.15
title: 'Extensions: chrome.debugger Runtime.evaluate and JavaScript dialog handling'
status: Done
assignee:
  - '@claude'
created_date: 2026-10-03 23:09
updated_date: '2026-11-08T05:28:00Z'
labels: []
dependencies:
  - TASK-132.13
parent_task_id: TASK-132
priority: high
ordinal: 147000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Runtime.evaluate({expression, returnByValue: true, awaitPromise: true, replMode, timeout}) in the page's main world, answering in CDP shape: {result: {type, value, ...}} or exceptionDetails with exception.className and description. The extension first sends the code wrapped in a block with replMode true and retries as an async function when the error is a SyntaxError mentioning 'Illegal return statement', so error class and text matter. Dialogs: while a tab is attached, alert / confirm / prompt / beforeunload emit Page.javascriptDialogOpening ({type, message, url}) and wait for Page.handleJavaScriptDialog({accept, promptText}) instead of showing Detour's panel; Page.frameNavigated fires for main-frame navigations.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Evaluating an expression, a promise and a multi-statement block returns the by-value result with the right CDP type; undefined and unserialisable values are reported the way CDP does
- [x] #2 A thrown error and a syntax error return exceptionDetails with className and description, and the extension's 'Illegal return statement' retry path succeeds for code with a top-level return
- [x] #3 timeout ends a never-settling evaluation with an error
- [x] #4 let/const redeclaration across two replMode evaluations does not fail
- [x] #5 On an attached tab a dialog raises javascriptDialogOpening and is answered by handleJavaScriptDialog; on a tab that is not attached Detour's own panel still shows
- [x] #6 A pending dialog is released when the debugger detaches or the tab closes
- [x] #7 Page.frameNavigated fires once per main-frame navigation with the frame's URL
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Spike: CSP vs each WebKit evaluation path (callAsyncJavaScript body, eval in .page / a named world, evaluateJavaScript).
2. Runtime.evaluate: syntax check in the DetourDebugger world (nothing runs), an in-house tokenizer (ExtensionDebuggerReplSource) that rewrites the final statement to capture the completion value, compile-checked; run through callAsyncJavaScript in .page (CSP-proof, top-level await).
3. V8-shaped RemoteObject and exceptionDetails (value-mirror.cc, injected-script.cc); V8 wording for the extension's 'Illegal return statement' retry; timeout gives 'Execution was terminated'.
4. Dialogs: with Page enabled, javascriptDialogOpening / handleJavaScriptDialog / javascriptDialogClosed instead of the sheet, following Chromium page_handler.cc for release; hooks in the window, Quick Detour and AutomationUIDelegate.
5. Page.frameNavigated per main-frame commit; Page.getFrameTree; Runtime.enable/disable as domain switches.
6. Tests, API Explorer, docs and wiki, runtime check.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented by an Opus subagent in worktree rt15 (branch task-132.15); cherry-picked onto the epic as 9636390, 39df27b, d6c6560. The AutomationUIDelegate halves were merged into one class with 132.14's context-menu SPI.
Scope addition: Page.getFrameTree (the Claude extension reads frameTree.frame.loaderId/url around screenshots; it shares frameNavigated's frame model). Also Runtime.enable/disable as domain switches, for 132.16.
CSP measurements (page served with script-src 'self'):
- eval / new Function in .page: refused.
- callAsyncJavaScript in .page with the code as the body: allowed, and it sees page globals.
- eval in a named world: allowed, but the world has no page globals.
- evaluateJavaScript: allowed, by value only, no top-level await.
Decision on a parser: the subagent asked to vendor acorn (MIT, about 246 KB, run in a native JSContext). Not done: shipping third-party code is the user's call (raised with them). An in-house tokenizer sits behind the single boundary ExtensionDebuggerEvaluation.prepare.
Decisions:
- beforeunload is left out: WebKit dispatches it only when the delegate implements the SPI, and the window is every tab's delegate.
- With Page enabled, hasBrowserHandler is false and no sheet is shown.
- Detach, close, Stop and Page.disable dismiss the dialog (false) with no event; a navigation dismisses it with javascriptDialogClosed.
- An attached tab without Page: sheet if displayed, an immediate answer if parked (Chromium's background-tab rule).
Limitations:
- The completion value is lost after if/loop/switch/try/label as the last statement.
- let/const and var don't persist between evaluations.
- eval inside the evaluated code is subject to the page's CSP.
- No termination of a synchronous loop.
- No child frames, objectIds or navigatedWithinDocument.
Subagent tests: Runtime 10, RuntimeExtension 6, RuntimeUnit 12, plus Debugger, Polyfill, Quick Detour, parking and reachability suites: 366 tests, 0 failures.
Subagent runtime check (harness docs/harness/task132.15-harness.patch):
- evaluate on parked and selected tabs, and Claude's two-step retry gave 15;
- alert and confirm answered by the extension with no sheet;
- the sheet came back after detach;
- frameNavigated and getFrameTree's loaderId;
- detach released a pending confirm.
Not checked: the API Explorer buttons by hand, Quick Detour dialogs at runtime, the real Claude extension (TASK-132.20).

Review of the cherry-picked commits (/code-review --fix): 10 findings, 8 fixed.
- The timeout cap: 1e300 trapped Duration.
- getFrameTree answers while a dialog is pending.
- A pending dialog is released when a load is issued (a dialog-held process never commits) and on a web process crash.
- Two tokenizer bugs: a regex right after a template's '${', and a string continued over CR LF.
- New tests for Page.disable and load release.
- Dead code removed.
I added the release on back/forward (BrowserTab.goBack/goForward, used by the window and Quick Detour).
Skipped: frameNavigated ordering after a load-time dialog; scriptIDsByURL growth.
Tests on the merged epic: a combined 684-test run (both tasks plus the related suites). The 23 failures were all page-load timeouts while the screen was locked (from 20:54). The 7 affected suites rerun unlocked: 113/113 pass.
Runtime check of the merged build (harness task132.15, profile DetourVerify13215-9), all as the subagent saw:
- evaluate on parked and selected tabs, and Claude's retry gives 15;
- alert and confirm answered by the extension with attachedSheet=false;
- 'No dialog is showing' error;
- frameNavigated with a new loaderId and a stable frame id;
- the sheet is back after detach;
- detach released a pending confirm, and the in-flight evaluate failed 'Detached while handling command.'
Cleaned up. Window captures did not save; the attachedSheet checks stand instead.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Runtime.evaluate, JavaScript dialogs and frames for chrome.debugger.
- Evaluation runs in the page's main world through callAsyncJavaScript (CSP-proof, top-level await). Completion values come from an in-house tokenizer that rewrites the final statement, each rewrite compile-checked; results and exceptions are V8-shaped, with the 'Illegal return statement' wording for the extension's retry; timeout gives 'Execution was terminated'.
- With Page enabled, alert/confirm/prompt raise javascriptDialogOpening and wait for handleJavaScriptDialog instead of Detour's sheet. They are released on detach, close, Stop, Page.disable, load/back/forward and a crash, with WebKit's handler called once.
- Page.frameNavigated fires once per main-frame commit; Page.getFrameTree (scope addition); Runtime.enable/disable switches.
Limits:
- the completion value is lost after if/loop/switch/try/label;
- no persistence of let/const/var between evaluations;
- no termination of synchronous loops;
- no beforeunload;
- main frame only.
acorn was not vendored (the user's call).
<!-- SECTION:FINAL_SUMMARY:END -->
