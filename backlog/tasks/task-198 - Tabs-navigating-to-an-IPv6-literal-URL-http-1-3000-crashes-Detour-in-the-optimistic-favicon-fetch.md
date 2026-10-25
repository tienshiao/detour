---
id: TASK-198
title: >-
  Tabs: navigating to an IPv6 literal URL (http://[::1]:3000/) crashes Detour in
  the optimistic favicon fetch
status: To Do
assignee: []
created_date: '2026-10-25 00:17'
labels:
  - bug
  - crash
  - tabs
  - dev-mode
dependencies: []
priority: high
ordinal: 234000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-195 subagent 2026-10-24. Loading an IPv6-literal URL programmatically (e.g. http://[::1]:8895/) kills Detour at Detour/Browser/BrowserTab.swift:1191: the optimistic favicon fetch builds URL(string: "\(scheme)://\(host)/favicon.ico")! from url.host, which is ::1 without brackets, so URL(string:) returns nil and the force unwrap traps. The branch runs for any non-error-page navigation with page == nil, so typing [::1] in the command palette likely crashes too (not yet checked). Dev mode treats [::1] as local (TASK-186.1), so this hits local development directly.

Fix direction: build the favicon URL with URLComponents from the page URL (keeping the brackets and the port; check whether the port should be kept), never force-unwrap; search for other places that rebuild a URL from url.host the same way (favicon loader, hover card, dev-mode labels, AddressInputClassifier).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Navigating to http://[::1]:<port>/ (typed in the palette and programmatically) loads the page without crashing, and its favicon is requested from the right URL
- [ ] #2 A test that would have crashed before covers the favicon URL for an IPv6 host (with and without a port)
- [ ] #3 Other URL rebuilds from url.host checked and fixed where they lose IPv6 brackets
<!-- AC:END -->
