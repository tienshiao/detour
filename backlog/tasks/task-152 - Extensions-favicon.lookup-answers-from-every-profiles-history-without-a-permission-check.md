---
id: TASK-152
title: >-
  Extensions: favicon.lookup answers from every profile's history, without a
  permission check
status: To Do
assignee: []
created_date: '2026-10-04 08:53'
labels:
  - bug
  - extensions
  - security
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
  - wiki/extensions/polyfill-layer.md
priority: high
ordinal: 175000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-04 while fixing TASK-138 (chrome.history.search was not scoped to the calling profile); read from the code, not yet observed from extension JS.

The 'favicon.lookup' case in ExtensionPolyfillHandler (Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift) calls HistoryDatabase.shared.faviconURL(for:) with the page URL the extension sent. The lookup has no profile or space filter and the case has no permission gate, so any extension in any profile, the Private profile included, can ask whether a URL (or host) has a favicon recorded and so learn that some profile visited it. History is profile-scoped everywhere else (the History page, the palette, chrome.history.search since TASK-138), and the project's rule for extension APIs is that another profile's objects are refused.

First establish which polyfill API sends favicon.lookup (the _favicon URL support, the 'favicon' permission) and what the lookup actually matches (exact URL, host).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The task records which extension-facing API reaches favicon.lookup and what a caller can learn from it today
- [ ] #2 A lookup answers only from favicons recorded by visits in the calling context's profile; a URL visited only in another profile gets the same answer as a URL never visited
- [ ] #3 An extension without the permission the API requires in Chrome gets no answer, and the Private profile's extension learns nothing about other profiles
- [ ] #4 Tests in a real extension context cover isolation across two profiles, permission gating and both transports, per the CLAUDE.md extension-API test rules; storage-level tests fail before the fix
- [ ] #5 The API Explorer extension and wiki/extensions/polyfill-layer.md are updated
<!-- AC:END -->
