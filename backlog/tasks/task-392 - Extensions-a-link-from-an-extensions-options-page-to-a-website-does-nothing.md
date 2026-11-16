---
id: TASK-392
title: 'Extensions: a link from an extension''s options page to a website does nothing'
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:42:00Z'
labels:
  - extensions
  - navigation
dependencies: []
references:
  - wiki/extensions/extension-pages.md
  - Detour/Extensions/Runtime/ExtensionPageNavigationPolicy.swift
priority: low
type: bug
ordinal: 473000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-382); measured there. A web view built from an extension context's configuration (an options page or other extension page in a tab) never navigates its main frame away from the extension: WebKit ignores every main-frame navigation whose URL is not that extension's (`NavigationState.mm` `isUnsupportedWebExtensionNavigation`, read from WebKit main), after the navigation delegate's `.allow`, silently: no provisional load, no failure callback, no request. Measured in TASK-382: a plain link (no `target=_blank`) from the fixture extension's options page to a loopback page, clicked through the endpoint, did nothing and the server saw no request; `location.href` from the page and `webView.load` of an http URL into the tab did the same. So a link from an extension's options page to the extension's website, a help page or a sign-in page silently does nothing, where Chrome follows it.

Suggested fix: in the navigation policy of such a tab, cancel a main-frame navigation to a web URL and open it in a new tab of the same space instead (the extension tab as its opener). It must keep TASK-382's rule (a web frame cannot top-navigate the tab to the extension's private pages). Wiki: wiki/extensions/extension-pages.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Clicking a plain link to an http(s) page in an extension's tab opens that page in a new tab of the same space, and the extension tab stays on its page
- [ ] #2 The extension's own links, Back, its frames and tabs.update still navigate the tab, and a web frame's top navigation to the extension's private pages stays refused (TASK-382)
- [ ] #3 Tests cover it through both navigation delegates (a window-owned and a background tab)
<!-- AC:END -->
