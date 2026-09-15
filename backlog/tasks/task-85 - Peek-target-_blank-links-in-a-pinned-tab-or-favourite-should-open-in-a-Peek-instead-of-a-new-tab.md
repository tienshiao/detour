---
id: TASK-85
title: >-
  Peek: target="_blank" links in a pinned tab or favourite should open in a Peek
  instead of a new tab
status: To Do
assignee: []
created_date: '2026-09-15 18:41'
labels:
  - peek
  - navigation
dependencies: []
priority: medium
ordinal: 85000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
In a pinned tab or favourite, an ordinary cross-host link click opens a Peek (decidePolicy in BrowserWindowController+Navigation.swift, the 'Peek mode' branch using peekHostTab + PeekAnchor.shouldPeekCrossHostNavigation), but a link with target="_blank" never reaches that branch: WebKit routes it to WKUIDelegate webView(_:createWebViewWith:for:windowFeatures:) (BrowserWindowController+WKUIDelegate.swift), whose .none case always adds and selects a new normal tab. Expected: when the firing web view's tab is a pinned entry or favourite backing tab, a user-activated target=_blank link (navigationAction.navigationType == .linkActivated) opens in a Peek anchored to that tab, just like an untargeted link. Keep existing behaviour for: Cmd-click / context-menu 'Open in New Tab/Window' (contextMenuLinkAction), script window.open() popups (navigationType .other — OAuth/payment popups need a real window and opener), normal tabs, and clicks inside an open Peek. Open question to settle in the plan: whether same-host _blank links should also Peek (untargeted same-host links navigate in place, which is not an option for _blank) or only cross-host ones, mirroring PeekAnchor.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Clicking a target=_blank cross-host link in a pinned tab opens a Peek anchored to that tab instead of a new tab
- [ ] #2 Same behaviour for a favourite's backing tab, including a link fired from the unfocused pane of a pinned split (peekHostTab)
- [ ] #3 Cmd-click, context-menu Open in New Tab/Window, script-initiated window.open popups, and _blank links in normal tabs keep their current behaviour
- [ ] #4 The same-host _blank decision is made and implemented consistently, with the peek-vs-tab routing in a pure function covered by unit tests
<!-- AC:END -->
