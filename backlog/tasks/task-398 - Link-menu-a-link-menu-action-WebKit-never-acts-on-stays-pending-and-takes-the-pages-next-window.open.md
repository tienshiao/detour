---
id: TASK-398
title: >-
  Link menu: a link menu action WebKit never acts on stays pending and takes the
  page's next window.open
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:43:00Z'
labels:
  - navigation
  - context-menu
  - link-routing
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
  - Detour/Browser/Window/BrowserWebView.swift
priority: low
type: bug
ordinal: 479000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-379, reported as pre-existing); read from code, not reproduced. The link menu's items (Open Link in New Tab, in New Window, in Split View, in Quick Detour; `contextMenuOpenInNewTab(_:)` and the rest in `BrowserWebView.swift`) set `BrowserWindowController.contextMenuLinkAction` and replay WebKit's own menu item, expecting WebKit to call `webView(_:createWebViewWith:for:windowFeatures:)` (`BrowserWindowController+WKUIDelegate.swift`), which reads it and sets it back to nil at its top. Nothing else clears it: if WebKit never calls `createWebViewWith` for the replay (the replayed item's action does nothing, the link's page went away), the action stays set, and the window's NEXT `createWebViewWith` (a page's own `window.open` or `target=_blank` link, in any tab of that window) is treated as that menu choice: routed or opened as the menu item would, skipping the paths a page's own request takes (the `data:` refusal and the extension-context checks; the comment at the top of `createWebViewWith` names the same risk for an early return). Whether a replay can fail to reach `createWebViewWith` in practice is not known.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A link menu action is consumed only by the new-window request its replay produces; a later window.open or target=_blank link of a page is never treated as a menu choice
- [ ] #2 A test replays a menu item whose action makes no request, then a page window.open, and shows the page request takes the page path (a data: URL is refused)
<!-- AC:END -->
