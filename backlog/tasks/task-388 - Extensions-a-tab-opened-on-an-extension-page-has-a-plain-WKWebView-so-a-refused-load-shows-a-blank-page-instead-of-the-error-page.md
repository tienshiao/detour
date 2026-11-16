---
id: TASK-388
title: >-
  Extensions: a tab opened on an extension page has a plain WKWebView, so a
  refused load shows a blank page instead of the error page
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:41:00Z'
updated_date: '2026-11-16T21:49:00Z'
labels:
  - extensions
  - error-page
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - Detour/Browser/BrowserTab.swift
priority: low
type: bug
ordinal: 469000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-381, its notes and code review); the blank page was measured in TASK-381 (wiki/extensions/extension-pages.md), the cause read from code. `TabStore.addExtensionTab(in:url:context:)` (`Detour/Browser/TabStore.swift`) builds `WKWebView(frame:configuration:)` directly from `context.webViewConfiguration` and wraps it with `BrowserTab(webView:servedExtensionOriginHost:)`. Every other tab's web view comes from `BrowserTab.makeWebView(configuration:)`, a `BrowserWebView` with the error scheme's `ErrorSchemeHandler`, the internal-page scheme handler and the internal-page, favicon-link and media-session bridges. So a refused load in such a tab (another extension's URL passed to `tabs.create`, which WebKit refuses since TASK-381) shows a blank page instead of the error page naming the URL. Pre-existing.

Two minor cleanups from the same review, to fold in: `context.webViewConfiguration` (a fresh copy per read) is built twice per call, once by each caller's `!= nil` check (`ExtensionManager` tabs.create and windows.create, `ExtensionManager+OptionsPage`) and once inside `addExtensionTab`; and `addExtensionTab` repeats the two lines of `addTab(in:webView:parentID:)`.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A tab opened by addExtensionTab whose load WebKit refuses (another extension's page through tabs.create) shows the error page naming the URL, as a space tab does
- [ ] #2 Such a tab's web view is built the way other tabs' are (BrowserTab.makeWebView: BrowserWebView, scheme handlers, bridges) and still loads its own extension's pages with the extension's configuration
- [ ] #3 The configuration is read once per call and addExtensionTab reuses addTab(in:webView:); tests cover the refused load and the extension's own page
<!-- AC:END -->
