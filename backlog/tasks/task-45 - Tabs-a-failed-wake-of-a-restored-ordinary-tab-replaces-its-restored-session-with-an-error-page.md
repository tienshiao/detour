---
id: TASK-45
title: >-
  Tabs: a failed wake of a restored ordinary tab replaces its restored session
  with an error page
status: To Do
assignee: []
created_date: '2026-09-13 05:38'
labels:
  - bug
  - tabs
  - session-restore
dependencies: []
priority: medium
ordinal: 45000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
BrowserTab.wake() (BrowserTab.swift, ~line 545) now seeds lastAttemptedURL for every tab that has never had a web view: 'if awaitingExtensionContext || lastAttemptedURL == nil { lastAttemptedURL = url }'. Before TASK-28 wake() never touched lastAttemptedURL; the seed exists so the URL observer does not clear tab.url on the new web view's first nil emission (extension pages awaiting a context, tabs created sleeping by TabStore.makeTab(loading:)). The side effect for an ordinary tab restored asleep with a cachedInteractionState: didFailProvisionalNavigation used to early-return because lastAttemptedURL was nil, so a failing restore navigation (offline relaunch, DNS failure, captive portal) left the restored back/forward state in place. Now it runs showErrorPage, which loads the error page over the just-restored interaction state, sets url = failedURL, clears favicon/faviconURL/previousHost, and updateTitle's 'webView?.url ?? lastAttemptedURL' fallback replaces the persisted title with the raw URL at wake. Restoring interactionState does start a navigation to the current back/forward item, so the failure path is reachable in practice. Desired behaviour: an ordinary restored tab that fails its first navigation offline keeps its restored session state, favicon, and persisted title (as before TASK-28), while extension pages and tabs created sleeping keep the URL-preservation behaviour TASK-28 added. Suggested shape from the review: keep the URL-preservation concern separate from failure/title state, e.g. seed a dedicated pendingRestoreURL (or equivalent) that the url KVO sink (BrowserTab.swift ~325-328) consults, and leave lastAttemptedURL set only by load() and the url observer. Whatever the shape, add tests for both the ordinary-restore-fails-offline case and the TASK-28 sleeping-tab URL preservation so neither regresses. Found by the 2026-09-13 code review of the TASK-28..TASK-39 commits (verified PLAUSIBLE, deferred for a product decision).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An ordinary tab restored asleep with cached interaction state whose first navigation on wake fails keeps its restored interaction state (back/forward), favicon, and persisted title; no error page is shown over the restored session
- [ ] #2 A tab created sleeping (TabStore.makeTab(loading:)) and an extension page awaiting its context still keep their URL across wake, as TASK-28 requires
- [ ] #3 A tab whose user-initiated load() fails still shows the error page as today
- [ ] #4 Unit tests cover the failed-wake-of-restored-tab case and the sleeping-tab URL preservation case
<!-- AC:END -->
