---
id: TASK-172
title: >-
  Navigation: a web view no window hosts has no UI delegate, so its window.open,
  window.close and dialogs do nothing
status: To Do
assignee: []
created_date: '2026-10-10 07:46'
labels:
  - bug
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
  - Detour/Browser/BrowserTab.swift
  - wiki/tabs/tab-lifecycle.md
priority: low
ordinal: 195000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-10 by the review of TASK-167; an existing gap that the change adds one entry point to. A window becomes a web view's UI delegate when it claims it (wireOwnedWebView). The reference is weak and nothing hands it back: windowWillClose returns the navigation delegates to their tabs (handBackNavigationDelegates, TASK-122) but not the UI delegates. A tab that was never claimed has none at all.

For such a web view WebKit's UI callbacks go nowhere: window.open() returns null with no tab, window.close() is ignored, alert/confirm/prompt and file pickers silently do nothing. Cases: a tab loaded in the background and never selected, every tab of a window that has closed until another window claims it, and since TASK-167 a window opened by a tab of a space the window is not showing (createWebViewWith sets that child's uiDelegate to the window by hand, which is lost the same way when the window closes).

BrowserTab is already the navigation delegate of an unclaimed web view. Whether it should also answer the UI delegate's window requests (which need a window to pick a space, select a tab and show a sheet) or route them to some window is the design question.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 What an unclaimed web view's window.open, window.close and JavaScript dialogs do is decided and recorded
- [ ] #2 A background tab that was never selected can open a window and close itself, in a test
- [ ] #3 Closing the window that hosted a tab does not leave that tab's web view without a UI delegate
<!-- AC:END -->
