---
id: TASK-85
title: >-
  Peek: target="_blank" links in a pinned tab or favourite should open in a Peek
  instead of a new tab
status: Done
assignee: []
created_date: '2026-09-15 18:41'
updated_date: '2026-09-15 19:04'
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
- [x] #1 Clicking a target=_blank cross-host link in a pinned tab opens a Peek anchored to that tab instead of a new tab
- [x] #2 Same behaviour for a favourite's backing tab, including a link fired from the unfocused pane of a pinned split (peekHostTab)
- [x] #3 Cmd-click, context-menu Open in New Tab/Window, script-initiated window.open popups, and _blank links in normal tabs keep their current behaviour
- [x] #4 The same-host _blank decision is made and implemented consistently, with the peek-vs-tab routing in a pure function covered by unit tests
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Finding (WebKit spike, macOS 26 WebKit): a user-activated target=_blank link calls decidePolicyFor with navigationType .linkActivated and targetFrame == nil BEFORE createWebViewWith; returning .cancel suppresses the new web view. So cross-host _blank links in pinned tabs/favourites already Peek via the existing branch; only same-host _blank links fell through to createWebViewWith -> new tab. window.open() never reaches decidePolicyFor (createWebViewWith only, type .other).
Decision (user, 2026-09-15): every user-activated _blank link in a pinned tab or favourite peeks, same-host included (in-place navigation is not an option for _blank, and a new tab defeats the pinned-app model).
1. Add PeekAnchor.shouldPeek(anchorURL:to:opensNewWindow:) — pure: new-window link activation (targetFrame nil) peeks whenever the target has a host; otherwise the existing cross-host rule. Keep shouldPeekCrossHostNavigation as the in-place rule.
2. decidePolicy Peek branch passes opensNewWindow: navigationAction.targetFrame == nil. Branch order unchanged, so Cmd-click (new tab), Shift-click (peek), Option-click (split) still win; context-menu Open in New Tab/Window goes through createWebViewWith with contextMenuLinkAction set (not a linkActivated decidePolicy) and window.open never hits decidePolicy — both unchanged. Normal tabs have no anchor; clicks inside an open Peek are excluded by peekHostTab.
3. Unit tests in PeekAnchorTests: same-host _blank peeks, cross-host _blank peeks, hostless _blank target does not, in-place same-host still does not.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Verified with a standalone WKWebView spike (swiftc, macOS 26 WebKit): _blank link -> decidePolicyFor(linkActivated, targetFrame nil) then createWebViewWith only if allowed; window.open -> createWebViewWith only (type .other). Implemented PeekAnchor.shouldPeek(anchorURL:to:opensNewWindow:) and the decidePolicy Peek branch passes targetFrame == nil. Hostless _blank targets (blob:, about:blank) keep opening a tab. Tests added to PeekAnchorTests.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Found via a WKWebView spike that _blank links reach decidePolicyFor (targetFrame nil) before createWebViewWith, so cross-host ones already peeked; same-host ones opened a tab. Per the user's decision, PeekAnchor.shouldPeek now peeks every hosted _blank link from a pinned tab/favourite (incl. the unfocused pinned split pane via peekHostTab), keeping the cross-host rule for in-place links and all modifier/context-menu/window.open/normal-tab behaviour. Verified by PeekAnchorTests; not exercised in the running app.
<!-- SECTION:FINAL_SUMMARY:END -->
