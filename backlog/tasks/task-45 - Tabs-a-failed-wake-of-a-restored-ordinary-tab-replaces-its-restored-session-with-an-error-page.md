---
id: TASK-45
title: >-
  Tabs: a failed wake of a restored ordinary tab replaces its restored session
  with an error page
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 05:38'
updated_date: '2026-09-13 10:44'
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
- [x] #1 An ordinary tab restored asleep with cached interaction state whose first navigation on wake fails keeps its restored interaction state (back/forward), favicon, and persisted title; no error page is shown over the restored session
- [x] #2 A tab created sleeping (TabStore.makeTab(loading:)) and an extension page awaiting its context still keep their URL across wake, as TASK-28 requires
- [x] #3 A tab whose user-initiated load() fails still shows the error page as today
- [x] #4 Unit tests cover the failed-wake-of-restored-tab case and the sleeping-tab URL preservation case
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Replace wake()'s lastAttemptedURL seeding with a dedicated flag on BrowserTab (e.g. awaitingFirstNavigation / pendingWakeURL) set when a fresh web view is built and cleared by the url observer's first non-nil emission; the observer ignores nil while the flag is set, so tab.url survives the new web view's initial nil URL for extension pages awaiting a context and tabs created sleeping (TASK-28) without touching lastAttemptedURL.
2. lastAttemptedURL is then set only by load(), retarget(to:) and the url observer, so didFailProvisionalNavigation early-returns for a restored tab whose first navigation fails (keeps interaction state, favicon, persisted title) while a user load() that fails still shows the error page. Check reload(): when webView.url is nil and lastAttemptedURL is nil, fall back to tab.url so a restored tab that failed offline can be reloaded.
3. Tests (BrowserTabWakeTests): (a) sleeping tab with cachedInteractionState (captured from a real WKWebView that loaded a loopback/HTML page) woken then given didFailProvisionalNavigation: url/title/favicon unchanged, no error page URL loaded; (b) sleeping tab created with a url: after wake and a run-loop turn tab.url is still that url; (c) load() then didFailProvisionalNavigation shows the error page.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Shape: wake() no longer seeds lastAttemptedURL. Two flags on BrowserTab: awaitingFirstURL (set when a fresh web view is built, cleared by the url observer's first non-nil emission; nil emissions are ignored meanwhile so tab.url survives — the TASK-28/TASK-24 guarantee) and restoringSession (set when wake hands the web view cached interaction state; cleared by a commit, a user load()/reload(), or releasing the web view). While restoringSession is set a provisional failure keeps the session, the persisted title outranks the raw URL, and WebKit's about:blank fallback after the failed restore reaches neither tab.url nor the retry target. Review finding folded in: restoring interactionState starts no navigation, so claimWebView's safety net was the real restore navigation and it went through load(url), re-arming the error page; it now calls loadIfStalled(), which kicks the tab's URL without marking it user-attempted. reload() falls back to the tab's url when the web view shows nothing. Tests: BrowserTabWakeTests (7) cover failed wake keeps session/title/favicon, reload after a failed wake retries and a failing retry shows the error page, a commit ends the protection, the in-session sleep→wake cycle, TASK-28 sleeping-tab URL preservation, and a failed user load showing the error page.

Full-suite flake fixed: testFailedWakeAfterSleepKeepsItsSession asserted the committed title synchronously after the HTML load; WKWebView's title lands through KVO a turn later, so under suite load it read the URL fallback. The test now waits for the title before sleeping the tab.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A restored tab whose first navigation fails on wake keeps its restored session, favicon and persisted title instead of getting an error page, while tabs created sleeping and extension pages awaiting a context still keep their URL across wake. The fix separates 'first URL emission pending' and 'session restore in flight' from lastAttemptedURL, and the window's stalled-load safety net no longer counts as a user navigation. Verified with BrowserTabWakeTests and the full suite.
<!-- SECTION:FINAL_SUMMARY:END -->
