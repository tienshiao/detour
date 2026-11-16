---
id: TASK-372
title: >-
  Error page: a failed in-page navigation names the previous page's URL, so
  Reload goes back instead of retrying
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T21:45:00Z'
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
- [x] #1 The error page names the URL that failed, including a refused extension page whose error names no URL (script, link, tabs.update, window.open child, background tab); a refused extension page never becomes the tab's url and Reload acts on the page the tab was on (the user's decision, 2026-11-16)
- [x] #2 Tests cover a script navigation, a link click and tabs.update failing (network and refused extension page), a background tab, a window.open child and Reload
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
User's decision 2026-11-16, option (c) 'show it, don't adopt', on top of TASK-381 (595434a5):
1. Apply the parked provisionalURL fallback (record webView.url at didStartProvisionalNavigation, clear on commit, use when the error has no failing URL).
2. lastAttemptedURL (Reload's target) = the failed URL when mayAdopt, else the tab's url; the error page names the failed URL either way. A window.open child (url nil) keeps reload()'s fallback to the error page's URL, refused again.
3. Tests: five refused-extension cases with tab.url unchanged, Reload loads the page, window.open child; drop the probes; Reload waits for the next document instead of 300 ms.
4. Run NavigationFailureURLTests, ExtensionPageProvenanceTests, BrowserTabWakeTests, BrowserTabUnclaimedNavigationTests, PageOpenedWindowTests, CommittedLoadFailureTests.
5. /verify through the endpoint (docs/harness/task372-endpoint-checks.py); wiki; /code-review; commit.
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

Decision (the user, 2026-11-16, relayed by the lead): option (c) 'show it, don't adopt' — the error page names the refused extension URL; the tab's url and Reload stay on the page the tab was on. Built on TASK-381 (595434a5: mayAdopt gate, servedExtensionOriginHost, currentPageURL).
Implementation: BrowserTab.provisionalURL = webView.url at didStartProvisionalNavigation (blank/error scheme/internal excluded), cleared on commit and in releaseWebView; didFailProvisionalNavigation names key ?? provisionalURL ?? lastAttemptedURL; lastAttemptedURL (Reload's target) = that URL when mayAdopt, else the tab's url. TASK-381 had Reload retry the refused URL; nothing in it relied on that (ExtensionPageProvenanceTests 7/7 unchanged).
Chosen by Claude (not yet confirmed by the user): a window.open child has no page of its own (url nil), so its Reload keeps reload()'s fallback and retries the error page's URL, refused again; alternative: Reload does nothing there (one guard in reload()).
Tests: NavigationFailureURLTests 14 (6 new: script, link, tabs.update, background tab, Reload loads the page, window.open child; probes dropped; both Reload tests now mark the document and wait for the next one instead of sleeping 300 ms). Without the BrowserTab change 5 of them fail (the window.open case passes on 381's code). Affected suites 44/44 after the review fixes: NavigationFailureURLTests 14, ExtensionPageProvenanceTests 7, BrowserTabWakeTests 11, BrowserTabUnclaimedNavigationTests 3, PageOpenedWindowTests 7... (per-suite counts 3/7/2/7/14/11 as xcodebuild printed them).
Runtime (/verify, DetourVerify-372, build of this tree before the review's two-line follow-up): docs/harness/task372-endpoint-checks.py 10/10 — trusted clicks on a loopback page: dead-port link -> error page and list_tabs url name the dead URL, Cmd+R retries it; link to an installed extension's options.html -> error page names it (screenshot: 'Looks like you took a Detour.' + the webkit-extension URL), url stays the page, Cmd+R loads the page ('Links'); window.open of options.html -> child error page names it, url empty, Cmd+R refused again. Defaults keys and the data dir removed.
/code-review medium --fix: 6 findings; fixed: stale load(_:) comment, provisionalURL cleared in releaseWebView, parked patch removed, harness script cleanups. Not fixed: provisionalURL is not updated on a server redirect (a redirect to a refused extension page would name the pre-redirect URL; needs didReceiveServerRedirect in both delegates + reachability rows). The reviewer asked about a typed refused extension URL: typed webkit-extension:// is a search (AddressInputClassifier), so load(_:) only sees page-chosen ones (Open Link in New Tab, routed links), which the decision covers.
Not verified: a relaunch with this change (TASK-381's check covers url/extensionID persistence, unchanged here); Quick Detour (same BrowserTab method).

User decisions 2026-11-16: confirmed: a window.open child with no page of its own keeps reload()'s fallback, so its Reload retries the error page's URL and is refused again (rather than a Reload that does nothing there). Follow-up filed: TASK-389 (provisionalURL is not updated on a server redirect).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A failed navigation whose error names no URL now gets an error page naming the URL it was loading: BrowserTab records webView.url at didStartProvisionalNavigation and falls back to it. In practice that is a refused webkit-extension:// main frame (-1008, userInfo nil); network failures already named their target (TASK-170). Per the user's decision (option c), a refused extension page is named but never adopted: tab.url stays on the page the tab was on (TASK-381) and Reload loads that page; a window.open child with no page keeps no URL and its Reload is refused again (Claude's choice). Tests: 6 new in NavigationFailureURLTests (5 fail without the change), Reload tests wait for the next document; 44/44 across the affected suites; runtime 10/10 through the endpoint. Follow-up candidate: provisionalURL is not updated on a server redirect.
<!-- SECTION:FINAL_SUMMARY:END -->
