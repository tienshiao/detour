---
id: TASK-132.2
title: 'Extensions: resolve a WebKit tabId to its BrowserTab in polyfill handlers'
status: To Do
assignee: []
created_date: '2026-10-03 23:07'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 134000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Polyfilled APIs that take a tabId (tabs.group, tabGroups, chrome.debugger) need the BrowserTab behind it, and WebKit exposes no lookup from its tab identifier. No handler in ExtensionPolyfillHandler does this today. Candidate: the polyfill reads chrome.tabs.get(tabId) and chrome.windows.getAll() and sends the window ordinal and tab index, which map onto the arrays Detour itself returns from openWindowsFor and BrowserWindowController.extensionTabs; native validates (URL) and returns a stable token the polyfill caches per tabId. Must work from the service worker (sendNativeMessage) and from extension pages (message handler), and in reverse (BrowserTab to tabId) for events and for groupId on Tab objects.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A handler given a tabId from tabs.query gets the right BrowserTab for normal, pinned, favourite and Peek tabs, in a window that is not key, and for an unselected tab
- [ ] #2 A tabId of a closed tab, or one from another profile's context, is refused with an error and never resolves to a different tab
- [ ] #3 Resolution stays correct after tabs are reordered, moved between spaces, or the window switches space between two calls
- [ ] #4 Tests cover the positive and refused cases
<!-- AC:END -->
