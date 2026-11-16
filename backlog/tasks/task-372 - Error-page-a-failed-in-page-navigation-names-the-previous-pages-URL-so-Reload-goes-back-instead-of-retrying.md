---
id: TASK-372
title: >-
  Error page: a failed in-page navigation names the previous page's URL, so
  Reload goes back instead of retrying
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T10:32:00Z'
labels:
  - navigation
  - error-pages
dependencies: []
references:
  - wiki/features/error-pages.md
priority: medium
type: bug
ordinal: 453000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-352's probe. When a navigation started inside a page fails (script location change, link click, tabs.update), Detour's error page records the previous page's URL as failedURL; its Reload then returns to the old page instead of retrying the URL that failed. Seen in Quick Detour and space tabs.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The error page shows and retries the URL that failed
- [ ] #2 Tests cover a script navigation, a link click and tabs.update failing
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Confirm with failing tests in NavigationFailureURLTests: script, link, tabs.update to a refused loopback port and to a refused webkit-extension:// page.
2. Find which failures name the previous page and why (log didStart/didFail URLs and the error's userInfo).
3. Fix in BrowserTab.didFailProvisionalNavigation without breaking the typed/redirect/reload cases.
4. Check what adopting the failing URL grants (wakeConfiguration rehosts a tab whose URL is an extension page) before committing the fix.
5. Wiki (error-pages, wkwebview-delegate-order, extension-pages), Backlog notes, commit on lane-b.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Investigation (2026-11-16, lane-b):
- Premise narrower than reported. On main (da0771c2) a script location change, a clicked link and tabs.update (loadURL(_:for:)) to a refused loopback port all name the target: TASK-170's step 3 takes NSURLErrorFailingURLErrorKey, which every network failure carries. NavigationFailureURLTests 8/8 on unchanged app code, including the new testATabsUpdateToADeadHostNamesIt.
- What reproduces: a refused webkit-extension:// main frame (the only kind TASK-352's probe used). WebKit's extension scheme handler fails the task with an NSError whose userInfo is nil; the delegate gets -1008 with only _WKRecoveryAttempterErrorKey, no failing URL. By then WebKit has reverted webView.url to the committed page, so lastAttemptedURL is the opener and the error page, tab.url and Reload name it. Logged in the tab: at didStartProvisionalNavigation webView.url is already the target; at didFailProvisionalNavigation it is the opener again.
- Fix written and tested, NOT committed: BrowserTab records webView.url at didStartProvisionalNavigation (nil when blank/error scheme/internal), clears it on commit, uses it when the error has no failing URL. Five tests (script, link, tabs.update, background tab, Reload, all with a web-accessible war.html) failed 5/5 without it and pass with it; whole suite 15/15 with it (incl. 2 probes). Parked as docs/harness/task372/provisional-url-fallback.patch (applies on lane-b's commit; header explains).
- Why parked (security, decision for the lead): adopting a refused extension URL makes it tab.url, and BrowserTab.wakeConfiguration builds a tab whose url is an extension page from that extension's own context configuration. Probe B (with the patch): a web page sets location.href to the extension's non-web-accessible options.html -> error page naming it -> sleep(force:) -> showsExtensionPage true while asleep -> wake -> reload() -> options.html LOADS (title 'Opts'). So the fix would let any web page get a non-web-accessible extension page loaded in a tab after one sleep + Reload.
- Pre-existing on main (probe A, unpatched tree): window.open('webkit-extension://<id>/options.html') from a web page in a space tab -> child tab's error page names options.html and tab.url keeps it (the observer's provisional URL survives because the child has no committed page) -> sleep/wake/reload loads options.html. Not tried: relaunch instead of sleep. Out of scope here; reported to the lead.
- Options for the lead: (a) adopt, and guard wake so a refused/page-chosen extension URL cannot rehost the tab (needs state that survives relaunch, or a rule at wake); (b) adopt only when the owning extension asked (tabs.update), an extension API path change; (c) show-only: the error page names the URL, tab.url and Reload unchanged; (d) close as is. Whichever: the wake hole of probe A exists already.
- Committed: testATabsUpdateToADeadHostNamesIt (+ profile/extension fixture in the suite); wiki error-pages.md, wkwebview-delegate-order.md, extension-pages.md, log.md. No app code change, so no /verify (tests and docs only); the brief's closed-port /verify recipe passes on unpatched main anyway (same as the passing tests).
- AC #1 not checked (only refused extension pages reproduce, and their fix waits for the decision). AC #2 not checked: script/link/tabs.update are covered for network failures on main; the refused-extension-page versions live in the parked patch.

/code-review medium --fix (2026-11-16): 7 findings. Fixed: task status wording removed from wiki/features/error-pages.md. Recorded in the patch header: no redirect update of provisionalURL, probes to drop, the Reload test's fixed 300 ms wait (shared with the existing TASK-170 test). Left for the lead: the wake hole on main (probe A) deserves its own task; the hand-copied extension/profile tearDown follows the existing suites' pattern.
<!-- SECTION:NOTES:END -->
