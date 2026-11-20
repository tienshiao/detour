---
id: TASK-413
title: >-
  Tests: evaluate_js's timeout case sometimes reports script_error instead of
  timeout (AutomationPageTests.testEvaluateTimesOutAndRefusesBadArguments)
status: To Do
assignee: []
created_date: '2026-11-20T00:19:00Z'
labels:
  - tests
  - automation
dependencies: []
priority: low
type: bug
ordinal: 494000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
testEvaluateTimesOutAndRefusesBadArguments asks evaluate_js for `new Promise(() => {})` with timeout_ms 200 and expects code "timeout". It fails intermittently with "script_error" (AutomationPageTests.swift:197): in the TASK-411 full run, in the 0.5.0 release full run (2026-11-19, 5082 tests, this the only failure) and in one class-only rerun right after it; it passed in the next class-only run, alone, and 14/14 alone during TASK-411. So it is not just load in full runs.

Suspected cause, not confirmed: the promise is unreferenced, so if JavaScriptCore collects it (and the evaluation wrapper's async function waiting on it) before the 200 ms deadline, WebKit completes callAsyncJavaScript with an error. AutomationPage.toolError maps that to script_error only when the error is WKError.javaScriptExceptionOccurred, so log the NSError's code and message on failure to confirm. If it is collection: the test should keep the promise reachable (e.g. assign it to a window property), and evaluate_js should probably name an unreachable result rather than call it a script error (WKError.javaScriptAsyncFunctionResultUnreachable, if that is the code).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The failing run's WKError code and message are recorded in the task
- [ ] #2 The test no longer depends on garbage-collection timing, and 20 class-only runs in a row pass
- [ ] #3 If the cause is an unreachable result, evaluate_js reports it under its own code or message, with a test
<!-- AC:END -->
