---
id: TASK-14
title: >-
  Extensions: reload or close open extension pages when their context is
  reloaded
status: To Do
assignee: []
created_date: '2026-09-12 03:50'
labels:
  - extensions
  - webkit
dependencies: []
priority: low
ordinal: 14000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
When a WKWebExtensionContext is unloaded and reloaded mid-session (Profile.recoverFromBackgroundLoadFailure from TASK-2, disable/enable, update), WebKit assigns the new context a fresh webkit-extension://<UUID>/ base URL. Any extension page still open in a tab (options page, an extension tab opened via TabStore.addExtensionTab, a pinned popup) keeps the old UUID origin: its native chrome.* bindings die with the old context, and since TASK-10 every polyfill call from it is rejected with 'Unrecognized extension origin' (the bridge no longer trusts the body's extensionID). Nothing currently reloads or closes such tabs, so the user is left with a dead page until they navigate manually. Found by the 2026-09-11 code review of TASK-10 (skipped there as intended behaviour of the fix). Fix: on context reload, find tabs whose URL host is the old context's base URL host and re-navigate them to the same path under the new base URL (or close them if the extension is being disabled/removed). Consider doing this alongside TASK-11, which handles the other reload consequence (site-access grants).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After a context reload via the recovery path, an open options/extension tab is re-navigated to the equivalent page under the new base URL and its polyfill and native APIs work again without user action
- [ ] #2 Disabling or uninstalling an extension closes its open extension tabs (or navigates them away) instead of leaving dead pages
- [ ] #3 Tabs of other extensions and ordinary web pages are untouched; a unit test covers the URL rewrite from old to new base URL including path and query
- [ ] #4 Tabs whose old-origin page is a snapshot in a non-owning window are handled the same way (no reliance on an attached webView)
<!-- AC:END -->
