---
id: TASK-161
title: >-
  Extensions: a frame in the same profile that knows a favicon extension's
  WebKit host gets that extension's favicon answers
status: To Do
assignee: []
created_date: '2026-10-04 18:40'
labels:
  - bug
  - extensions
  - security
dependencies: []
references:
  - Detour/Extensions/Runtime/FaviconSchemeHandler.swift
  - wiki/features/favicons.md
  - wiki/extensions/polyfill-layer.md
priority: medium
ordinal: 184000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Left open by TASK-152, filed 2026-10-04. Read from the code, not demonstrated from a page.

chrome.runtime.getURL('/_favicon/?pageUrl=…') is rewritten to detour-favicon://<the context's WebKit host>/_favicon/… and answered by FaviconSchemeHandler. Since TASK-152 the handler belongs to one profile and answers only when the URL's host is an extension context loaded in that profile whose manifest lists 'favicon', from that profile's history only. The handler is registered on every tab's configuration as well (Space.makeWebViewConfiguration, for extension frames inside pages), and WebKit does not tell a WKURLSchemeHandler which frame is asking. So the host in the URL is the only proof of who asks: any frame in a tab of the same profile, an ordinary web page included, that names the WebKit host of a 'favicon' extension loaded there gets what that extension would get, i.e. an icon for a page (or, through the same-host fallback, a site) means this profile visited it. The answer is image bytes, so a page learns it from whether an <img> loads at the icon's size or as the 1x1 transparent pixel.

The host is a random UUID per extension load, but a page that embeds one of the extension's web-accessible frames can read it. Other profiles stay protected; the gap is a web page reading its own profile's history through an extension the user gave 'favicon' to. Chrome serves _favicon only to the extension's own contexts.

First establish what the handler can learn about the requester (WKURLSchemeTask.request: mainDocumentURL, headers such as Origin or Referer, the private _frame of the task) and whether a page really can load detour-favicon:// as a subresource today (mixed-content and CSP rules may already refuse some cases). wiki/features/favicons.md records the gap.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The task records what a web page in the same profile can learn today, measured in a real web view: a page that knows the host loading detour-favicon://<host>/_favicon/… for a visited and a never-visited URL
- [ ] #2 A favicon request is answered only when it comes from a context of the extension named by the host (its pages, its frames inside pages if the manifest makes them web-accessible, its worker); any other frame gets the same transparent pixel as 'no icon'
- [ ] #3 If WebKit gives the handler no way to tell the requester, the task records what was tried and the chosen mitigation (for example not registering the handler on tab configurations, or a per-context unguessable token)
- [ ] #4 Tests in a real extension context cover: the extension's own page still gets its icons, a web page in the same profile naming the host is refused, an extension frame embedded in a page per the decided rule, and another extension's page naming the host is refused
- [ ] #5 wiki/features/favicons.md and wiki/extensions/polyfill-layer.md are updated, and the API Explorer if the extension-facing behaviour changes
<!-- AC:END -->
