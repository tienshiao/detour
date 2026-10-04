---
id: TASK-147
title: >-
  Extensions: chrome.sessions.restore returns a hash of the tab's UUID instead
  of its extension tab id
status: To Do
assignee: []
created_date: '2026-10-04 02:29'
labels: []
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
  - wiki/extensions/tab-and-window-bridge.md
priority: low
ordinal: 170000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The sessions.restore handler in ExtensionPolyfillHandler (Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift) replies with { tab: { id: tab.id.hashValue, url } }. tab.id is the BrowserTab's UUID; its hashValue is not the id WebKit hands extensions for that tab (and Swift hash values are seeded per process, and can exceed the range of a JS safe integer), so an extension that passes the returned id to chrome.tabs.get / update / sendMessage gets 'tab not found' or the wrong tab. Read from the code while writing wiki/extensions/polyfill-layer.md; not observed from extension JS. Check the other sessions.* handlers and any other handler that builds a tab id itself for the same mistake.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 sessions.restore returns the same tab id that chrome.tabs.query reports for the restored tab, and a full tabs.Tab-shaped object where the API promises one; a test in a real extension context round-trips the id through chrome.tabs.get and fails before the fix
- [ ] #2 No polyfill handler derives a tab id from a UUID hash; the task lists what was checked
- [ ] #3 The API Explorer extension and wiki/extensions/polyfill-layer.md are updated
<!-- AC:END -->
