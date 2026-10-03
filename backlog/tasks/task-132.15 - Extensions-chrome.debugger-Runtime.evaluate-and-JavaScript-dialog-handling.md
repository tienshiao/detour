---
id: TASK-132.15
title: 'Extensions: chrome.debugger Runtime.evaluate and JavaScript dialog handling'
status: To Do
assignee: []
created_date: '2026-10-03 23:09'
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
- [ ] #1 Evaluating an expression, a promise and a multi-statement block returns the by-value result with the right CDP type; undefined and unserialisable values are reported the way CDP does
- [ ] #2 A thrown error and a syntax error return exceptionDetails with className and description, and the extension's 'Illegal return statement' retry path succeeds for code with a top-level return
- [ ] #3 timeout ends a never-settling evaluation with an error
- [ ] #4 let/const redeclaration across two replMode evaluations does not fail
- [ ] #5 On an attached tab a dialog raises javascriptDialogOpening and is answered by handleJavaScriptDialog; on a tab that is not attached Detour's own panel still shows
- [ ] #6 A pending dialog is released when the debugger detaches or the tab closes
- [ ] #7 Page.frameNavigated fires once per main-frame navigation with the frame's URL
<!-- AC:END -->
