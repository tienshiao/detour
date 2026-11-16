---
id: TASK-382
title: >-
  Extensions: a web page in a tab built from an extension's configuration can
  navigate to that extension's private pages
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T15:44:00Z'
labels:
  - extensions
  - security
  - webkit
dependencies: []
references:
  - wiki/extensions/extension-pages.md
  - TASK-381
priority: high
type: bug
ordinal: 463000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 in TASK-381's review, read from WebKit's source and not measured. A tab whose web view was built from extension A's configuration (WKWebExtensionContext.webViewConfiguration, which sets _requiredWebExtensionBaseURL to A — e.g. A's options page opened by Detour) keeps that configuration when the page navigates to an ordinary web page (a link in the options page). That web page can then navigate the tab to A's non-web-accessible pages live, with no sleep or relaunch, because WebKit's extension scheme handler accepts A's pages in that configuration. TASK-381 closed the page-chosen-URL route through sleep, Reload and relaunch; this is the live route. Measure first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Whether a web page loaded in an extension-configured tab can load that extension's non-web-accessible page is measured and recorded
- [ ] #2 If it can: such a navigation is refused (or the tab moves to a web configuration when it leaves the extension's origin), with tests; the extension's own navigation between its pages still works
<!-- AC:END -->
