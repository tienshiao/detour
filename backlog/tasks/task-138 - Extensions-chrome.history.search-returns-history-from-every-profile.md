---
id: TASK-138
title: 'Extensions: chrome.history.search returns history from every profile'
status: To Do
assignee: []
created_date: '2026-10-04 01:58'
labels: []
dependencies: []
references:
  - wiki/extensions/polyfill-layer.md
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: high
ordinal: 161000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The history.search handler in ExtensionPolyfillHandler (Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift) calls HistoryDatabase.shared.searchHistoryGlobal(query:maxResults:startTime:endTime:), which has no profile or space filter. An extension holding the history permission in one profile therefore reads URLs, titles and visit counts recorded in every other profile. History is otherwise profile-scoped everywhere (the History page, the palette, own-title matching — see wiki/decisions/history-own-title-matching.md), and the project's rule for extension APIs is that another profile's objects are refused. Found by reading the code while writing wiki/extensions/polyfill-layer.md; not yet observed from extension JS.

Check the other chrome.history methods the polyfill exposes for the same gap while here, and whether titles need the own-visit rule (a URL visited in two profiles must not surface the other profile's title).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 chrome.history.search from an extension context returns only entries with visits in that context's profile, and their visit counts, last-visit times and titles come from that profile's visits
- [ ] #2 Every other chrome.history method the polyfill implements is scoped to the calling context's profile, or the task records why it needs no scoping
- [ ] #3 Tests in a real extension context cover isolation (a URL visited only in another profile is not returned; a URL visited in both returns this profile's data), permission gating, and both transports, per the CLAUDE.md extension-API test rules
- [ ] #4 The API Explorer extension and the wiki pages (extensions/polyfill-layer.md, architecture/history-database.md) are updated
<!-- AC:END -->
