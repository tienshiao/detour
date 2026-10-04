---
id: TASK-152
title: >-
  Extensions: favicon.lookup answers from every profile's history, without a
  permission check
status: Done
assignee: []
created_date: '2026-10-04 08:53'
updated_date: '2026-10-04 10:23'
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
- [x] #1 The task records which extension-facing API reaches favicon.lookup and what a caller can learn from it today
- [x] #2 A lookup answers only from favicons recorded by visits in the calling context's profile; a URL visited only in another profile gets the same answer as a URL never visited
- [x] #3 An extension without the permission the API requires in Chrome gets no answer, and the Private profile's extension learns nothing about other profiles
- [x] #4 Tests in a real extension context cover isolation across two profiles, permission gating and both transports, per the CLAUDE.md extension-API test rules; storage-level tests fail before the fix
- [x] #5 The API Explorer extension and wiki/extensions/polyfill-layer.md are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Establish the routes (AC #1) and record them.
2. Storage tests first (FaviconLookupScopeTests) against a scoped lookup signature that still runs the unscoped query, to see them fail; then HistoryDatabase.faviconURL(for:visitedInSpaces:): a URL, or for the fallback a host, answers only when a visit in the given spaces exists.
3. FaviconSchemeHandler belongs to one profile (built with it in Profile.extensionController and Space.makeWebViewConfiguration): the WebKit host in the URL must be an extension context loaded in that profile and holding 'favicon'; the lookup is scoped to that profile's spaces (HistoryPageBridge.scope(forProfile:), so Private and a deleted profile get nothing). The process-wide permitted-host set goes.
4. Remove the favicon.lookup polyfill message (no polyfill API sends it; it returns the icon URL, which Chrome never exposes).
5. Tests in real extension contexts (ExtensionFaviconScopeTests): two profiles, permission, Private, the tab route, the worker, the retired message from both transports.
6. API Explorer section, wiki pages, epic-branch merge check (git merge-file against the epic working tree).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
AC #1 — the routes, read from the code on main (a98904c), 2026-10-04:
(a) chrome.runtime.getURL('/_favicon/?pageUrl=…&size=…'), Chrome's favicon API (permission 'favicon'). The polyfill rewrites it to detour-favicon://<the context's WebKit host>/_favicon/…, and FaviconSchemeHandler answers with the icon's bytes through FaviconPNGLoader, or a 1x1 transparent PNG. The handler is registered on every profile's extension configuration AND on every tab's configuration (Space.makeWebViewConfiguration, for extension frames inside pages). Its only gate was a process-wide set of WebKit hosts whose extension declares 'favicon', filled at load time by any profile; the lookup (HistoryDatabase.faviconURL(for:)) had no scope.
(b) the polyfill message 'favicon.lookup' (ExtensionPolyfillHandler). No polyfill API sends it (added in cfbfc91 with the first favicon attempt and left behind), but any extension context can post it by hand through webkit.messageHandlers.detourPolyfill or runtime.sendNativeMessage('detourPolyfill', …). No permission check, same unscoped lookup, and it returns the icon's URL rather than bytes.
What the lookup matches: the exact page URL in historyURL (one row per URL for all profiles), then the most recently visited row whose URL starts with https://<host> or http://<host> — a string prefix, so example.com also matched example.com.evil.test.
What a caller learned: an icon (or an icon URL) for a page means some profile visited that page, and through the host fallback that some profile visited that site. Through (a) any extension holding 'favicon' in any profile, the Private profile included, and any frame in any profile's tab that named such an extension's WebKit host; through (b) any extension at all.

What changed.
- HistoryDatabase.faviconURL(for:visitedInSpaces:): a page answers only when one of the given spaces visited it; the same-host fallback picks the page of that host those spaces visited most recently. The unscoped lookup stays for the History page's own rows and is renamed faviconURLInAnyProfile(for:), so a call site cannot cross profiles without saying so (and a stale caller no longer compiles). 'Same host' is now the URL's host (end of string, '/', or ':port'), as index ranges, instead of a LIKE prefix.
- FaviconPNGLoader.pngData takes a Scope with no default (.spaces / .everyProfile).
- FaviconSchemeHandler holds its profile (built with it in Profile.extensionController and Space.makeWebViewConfiguration). A request is answered only when the URL's host is an extension context loaded in that profile whose manifest lists 'favicon', and the lookup is scoped by HistoryPageBridge.scope(forProfile:) — the same scope as the History page and chrome.history, so Private, a deleted profile and a profile no space uses get nothing. A refusal is the transparent pixel, the same as 'no icon'. The process-wide permitted-host set and its grant/revoke calls in Profile are gone.
- The favicon.lookup message is removed (decision: remove rather than gate — nothing sends it and it returned the icon URL, which Chrome never exposes). Both transports now get 'Unknown polyfill message type'.
- API Explorer: a Favicon section (Show Favicon through chrome.runtime.getURL('/_favicon/…'), and a raw favicon.lookup button that must be refused); 'favicon' added to its permissions.

Tests.
- Before the fix (scoped signature over the old unscoped query): FaviconLookupScopeTests 12 tests, 7 failing with 10 assertion failures — out-of-scope URL, out-of-scope host, newest in-scope visit, empty scope, a space outside the scope, and the host prefix (a.example matched a.example.evil.test), in both lookups.
- After: FaviconLookupScopeTests 12/12, ExtensionFaviconScopeTests 7/7 (19 tests, 0 failures).
- ExtensionFaviconScopeTests could not run before the fix (the handler had no database seam), so the scope was taken out once instead (.everyProfile in the handler): 3 of 7 failed with 5 assertion failures — profile A got B's page and B's host, B got A's page, A's tab got B's page, and B's icon was downloaded for A's worker. Restored afterwards.
- Real contexts cover: one extension in two profiles (own pages, the shared page, the other's page, the other's host, a never-visited page; refused lookups download nothing), another profile's WebKit host from an extension page and from a tab, a tab's own handler, an extension without 'favicon', the Private profile (page and worker), the worker, and favicon.lookup from an extension page (webkit.messageHandlers) and from the worker (runtime.sendNativeMessage).
- Transports: _favicon is an image URL, not a request/response API, so 'both transports' is an <img> in an extension page and fetch() in the worker. Measured: the worker's fetch rejects ('Load failed') for every page, before and after, although the request reaches the scheme handler (with the scope removed, B's icon was downloaded for A's worker); so a worker cannot read favicons at all, and the test pins that the handler's answer for another profile's page equals the one for a never-visited page.

Not changed, on purpose.
- Which icon a URL has stays shared (historyURL.faviconURL, set by the latest visit from anywhere — the accepted rule in wiki/architecture/history-database.md). Scope decides whether the lookup answers.
- WebKit does not tell a scheme handler which frame asks, so a frame in the SAME profile that knows the WebKit host of a 'favicon' extension loaded there gets what that extension gets (the host is a random UUID per load, readable by a page that embeds one of the extension's web-accessible frames). Recorded in wiki/features/favicons.md; needs its own task.

Merging into epic-claude-extension (simulated with git merge-file against that branch's working tree, 2026-10-04): Profile.swift, TabStore.swift, HistoryDatabase.swift, FaviconPNGLoader, FaviconSchemeHandler, popup.html and popup.js merge cleanly. Two conflicts: (1) ExtensionPolyfillHandler.swift — the epic inserts the 'Tab id bridge' cases directly after the favicon.lookup case this task deletes; resolve by keeping the epic's cases and deleting the favicon.lookup case (keeping it no longer compiles: faviconURL(for:) is gone). (2) TestExtensions/api-explorer/manifest.json — both add permissions on the same line; keep both sets.

Review and the runtime check happen at batch integration.

Suites run with the fix (2026-10-04): FaviconLookupScopeTests, ExtensionFaviconScopeTests, HistoryDatabaseTests, InternalPageIntegrationTests, HistoryDeletionIntegrationTests, ExtensionHistoryScopeTests, ExtensionPolyfillProfileWiringTests, ExtensionPolyfillIntegrationTests, ExtensionPolyfillTests: 484 tests, 7 skipped (gated legs), 0 failures.

Integrated on branch bugfix-batch-2 (worktree .claude/worktrees/bugfix-batch-2), 2026-10-04. Full DetourTests suite on the integrated tree: 2081 tests, 10 skipped (gated legs), 0 failures; after the review fixes 2083 tests, 10 skipped, 1 failure — ExtensionPolyfillIntegrationTests.testStorageManagedInRealExtensionContextSurvivesGarbageCollection ('no collection observed in 10 rounds'), a garbage-collection timing test outside this batch that passed in the first run and passes alone (26/26). Code review of the range a98904c..HEAD run with --fix (high).
Review: nothing wrong found in the favicon scoping. One efficiency note, accepted: the scoped same-host fallback joins and sorts the in-scope visits of every URL on the host to pick one row (the unscoped query ordered historyURL rows). It runs only for a page with no exact row, off the main thread; ordering by the shared lastVisitTime instead would let another profile's visits choose which of the profile's own icons is answered, so the in-scope order stays.
Runtime check (harness build, isolated profile, real install of the API Explorer, a real visit to https://www.wikipedia.org/ in profile A, the icon fetched from the network, a second profile B with one space; extension pages opened the way the app opens them): profile A's page got 32x32 for the visited page and 1x1 for a never-visited one; profile B's page got 1x1 for the page A visited; favicon.lookup posted by hand was refused in both ('Unknown polyfill message type: favicon.lookup'). Not checked at runtime: the Private profile (covered by tests), the API Explorer's own buttons (the harness ran the same calls from its page).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
An extension's favicons (chrome.runtime.getURL('/_favicon/…'), served on detour-favicon://) now come from the calling profile's history only: FaviconSchemeHandler belongs to a profile, accepts only that profile's extension hosts holding 'favicon', and looks up through HistoryDatabase.faviconURL(for:visitedInSpaces:); a refusal is the same transparent pixel as 'no icon'. The favicon.lookup polyfill message (no sender, no permission check, returned the icon URL) is removed. Storage tests failed before the fix; real-context tests cover two profiles, another profile's host, a tab's handler, the permission, Private, the worker and both transports of the removed message, and fail with the scope taken out. Verified in the running app with a real visit and two profiles. Merging into epic-claude-extension conflicts in two places (ExtensionPolyfillHandler's favicon.lookup case, the API Explorer manifest's permissions line); the resolutions are in the notes. Left for its own task: a frame in the same profile that knows a favicon extension's WebKit host gets that extension's answers.
<!-- SECTION:FINAL_SUMMARY:END -->
