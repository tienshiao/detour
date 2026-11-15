---
id: TASK-341
title: >-
  Navigation: clicking a link to tv.apple.com (or any domain a Mac app claims)
  opens that app instead of the page
status: To Do
assignee: []
created_date: '2026-11-15T07:19:00Z'
labels: []
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController+Navigation.swift
  - Detour/Browser/ExternalApps/ExternalAppLaunchPolicy.swift
priority: medium
type: bug
ordinal: 417000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported Nov 14 2026: clicking an Apple TV+ result on Google opens the TV app; typing the same URL with Cmd+L loads it in the tab.

Root cause (WebKit source, NavigationState.mm tryInterceptNavigation): on macOS HAVE(APP_LINKS) is on, and when the navigation delegate answers a plain WKNavigationActionPolicyAllow WebKit first offers the URL to LSAppLink. If an installed app claims the domain (associated domains / applinks), the app opens and the load is ignored. WebKit tries it for any main-frame navigation to a different host than the current page, except back/forward, and only when shouldOpenExternalURLsPolicy is ShouldAllow. That rules out the app's own load() (typed URLs, which is why Cmd+L works) but not link clicks, redirects or script navigations; no user gesture is needed. Detour never sees the app launch: it bypasses ExternalAppLaunchPolicy (TASK-84), which only covers non-web schemes. The private _WKNavigationActionPolicyAllowWithoutTryingAppLink (Allow + 2, macOS 10.11+) skips the app-link attempt.

Detour answers .allow in BrowserWindowController+Navigation.swift, BrowserTab.swift (around line 1813) and QuickDetourWindowController+WebKit.swift, so tabs, peeks and Quick Detour windows are all affected. Open product question: never hand http(s) links to apps (as Chrome does), or ask first using the TASK-84 sheet. The user chose to leave it as is for now (Nov 14 2026).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Clicking a link from one site to a domain an installed app claims (e.g. tv.apple.com with the TV app) loads the page in Detour unless the chosen policy says otherwise
- [ ] #2 The same holds for target=_blank links, peeks and Quick Detour windows
- [ ] #3 Typed URLs and links to non-web schemes behave as before (TASK-84 prompt unchanged)
<!-- AC:END -->
