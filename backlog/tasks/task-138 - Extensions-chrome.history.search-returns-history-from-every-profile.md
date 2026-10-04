---
id: TASK-138
title: 'Extensions: chrome.history.search returns history from every profile'
status: In Progress
assignee: []
created_date: '2026-10-04 01:58'
updated_date: '2026-10-04 08:24'
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
- [x] #1 chrome.history.search from an extension context returns only entries with visits in that context's profile, and their visit counts, last-visit times and titles come from that profile's visits
- [x] #2 Every other chrome.history method the polyfill implements is scoped to the calling context's profile, or the task records why it needs no scoping
- [x] #3 Tests in a real extension context cover isolation (a URL visited only in another profile is not returned; a URL visited in both returns this profile's data), permission gating, and both transports, per the CLAUDE.md extension-API test rules
- [x] #4 The API Explorer extension and the wiki pages (extensions/polyfill-layer.md, architecture/history-database.md) are updated
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Storage (TDD): add HistoryDatabase.searchURLs(query:spaceIDs:from:until:limit:), one row per URL built on the same in-scope visit select as the History page's searchVisits (shared helper: scope filter, time window, candidate gate, own-title matcher). Count, typed count and last-visit time are aggregated from in-scope historyVisit rows; the title is the representative visit's own. Storage tests first, red against a stub that still answers globally.
2. Handler: history.search resolves the calling context's profile (the handler's weak profile back-reference), takes the scope from the History page's rule (the spaces currently using the profile; none for Private, a deleted or released profile), queries off the main thread and replies on main. Validate the query object so bad arguments reject (promise) / set runtime.lastError (callback).
3. Remove searchHistoryGlobal once it has no caller; move the three existing tests that used it as a premise onto the shared FTS index directly.
4. Audit the other chrome.history members in historyJS (getVisits, addUrl, deleteUrl, deleteRange, deleteAll, onVisited, onVisitRemoved) and record the finding.
5. Tests in a new file (DetourTests/ExtensionHistoryScopeTests.swift): handler-level and real-extension-context cases through Profile.extensionController - isolation across two profiles, permission gating, page and service-worker transports, bad arguments in promise and callback form, Private profile.
6. Docs: wiki (polyfill-layer, history-database, history-recording-and-search, history-own-title-matching), docs/extensions.md if it states the old behaviour, wiki-lint, wiki/log.md. API Explorer only if its history section needs it.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## What was wrong, confirmed from extension JS
The red run (new tests against the old handler) reproduced the leak in a real extension context: with one extension loaded in two profiles, profile A's extension page and its service worker both received profile B's URL for chrome.history.search({text:''}), and a URL A had visited twice came back with visitCount 5, B's last-visit time and B's title. Searching a word that only B's history holds returned B's page.

## Fix
- HistoryDatabase.searchURLs(query:spaceIDs:from:until:limit:) replaces searchHistoryGlobal (removed, no caller left). It is built on the same inner select as the History page's searchVisits, now factored out as scopedVisitsSelect: scope filter, [from, until) window, candidate gate, own-title matcher, ROW_NUMBER per URL. A row is the newest in-scope, in-range visit that itself qualified, as on the History page.
- visitCount, typedCount and lastVisitTime are aggregated from the scope's own historyVisit rows (all of them, not only those in the window), in an outer select over the rows that survived LIMIT. historyURL.visitCount / lastVisitTime are never read. typedCount used to be a constant 0.
- The handler takes the scope from HistoryPageBridge.scope(forProfile:), the same function the History page uses (the tab overload now delegates to it), with the handler's own weak profile reference. The last-active space plays no part. The query runs off the main thread and replies on main.
- New model type HistoryURLEntry (Detour/Storage/Models).

## Rules
- Scope = the spaces currently using the calling context's profile.
- Private profile: it records no visits (TabStore.recordHistoryVisit returns early for incognito spaces), so the answer is an empty list. The handler does not query at all for it: scope(forProfile:) is nil for the Private profile, a deleted profile and a released one, and a profile no space uses has an empty scope. No scope means no history, never everyone's.
- Title: the visit's own. For a title-less visit (recorded before per-visit titles, TASK-91) the shared historyURL.title stands in only while no space outside the profile has visited the URL; otherwise the item has no title of its own and the handler falls back to the URL, as before. This is stricter than the History page (unguarded COALESCE) on purpose: the result goes to extension code. The History page is unchanged.
- Arguments are validated now: query must be an object, text a string, maxResults a non-negative integer, startTime/endTime numbers; null is absent for the optional ones. A refusal rejects the promise / sets runtime.lastError. Before, search({}) and search() were read leniently and answered with the whole history.

## AC #2: the other chrome.history members
historyJS implements getVisits, addUrl, deleteUrl, deleteRange, deleteAll, onVisited and onVisitRemoved as JS-only stubs: getVisits answers [], the four writes resolve without doing anything, and the two events never fire (nothing calls __extensionDispatchHistoryEvent; grep finds only its definition). None of them makes a native request, reads or writes the history database, so there is nothing to scope. history.search is the only native history.* case in ExtensionPolyfillHandler. Recorded in wiki/extensions/polyfill-layer.md with the note that making any of them real requires the same scoping.

## Behaviour changes an extension can see
- Results are ordered newest in-profile visit first (with text they were ordered by FTS rank, then the shared visit count).
- endTime is exclusive (it was inclusive) and the range now selects a URL by any in-profile visit inside it, not by the shared last-visit time.
- Text is matched like the History page: against the URL text and the profile's own titles, folded (strasse finds Straße).
- Malformed queries are refused (above).

## Found, not changed (outside this task)
- favicon.lookup in the same handler calls HistoryDatabase.faviconURL(for:), which is unscoped and has no permission gate: any extension in any profile, Private included, can learn whether a URL or a host has a favicon recorded by any profile. Not a chrome.history method; needs its own task.
- chrome.history exists and search rejects when the manifest lacks the history permission; Chrome leaves the namespace undefined. The stubs (getVisits and the writes) answer without the permission, but they reveal nothing.
- Chrome defaults startTime to 24 hours ago and reads maxResults 0 as no limit; here an omitted startTime means no lower bound and maxResults 0 returns nothing. Unchanged.
- WebKit rewrites every error text that crosses runtime.sendNativeMessage: prefix 'Invalid call to runtime.sendNativeMessage(). ', first letter capitalised, full stop appended; a worker's callback form gets the prefix twice. Recorded in the wiki; the new tests compare case-insensitively.

## Tests (worktree build, private DerivedData, data dir DetourTests-history)
New files, so nothing is appended to the shared polyfill suites: DetourTests/HistoryURLSearchTests.swift (storage, 13 tests) and DetourTests/ExtensionHistoryScopeTests.swift (14 tests: the query parser, the handler through handleNativeMessage with real profiles and spaces, and real extension contexts through Profile.extensionController with one extension in two profiles - extension page and service worker, promise and callback form, permission gate, bad arguments, Private profile).

Red run, new tests against the old behaviour (the scoped signature stubbed to answer globally, the old lenient parse): 27 tests, 25 failed. All 12 storage isolation tests failed; testFTSKeywordTokensAreSearchable passed (not about scope). 13 of 14 extension tests failed; testHandlerRefusesAnExtensionWithoutTheHistoryPermission passed, as the gate already existed. One of the 13, the real-context permission test, failed for a test reason, not a product one: it compared WebKit's rewritten error text case-sensitively. The helper now ignores case.

After the fix, 0 failures:
- HistoryURLSearchTests 13, ExtensionHistoryScopeTests 14, HistoryDatabaseTests 128, HistoryTitleIndexTests 12, the 9 history cases of ExtensionPolyfillTests, ExtensionPolyfillIntegrationTests testHistorySearchWithController and testAllPolyfillNamespacesExist: 178 tests.
- HistoryDeletionIntegrationTests 63, InternalPageIntegrationTests 12, HistoryTimeRangeTests 18 (the History page shares the refactored select and the scope function): 93 tests.
Three existing HistoryDatabaseTests used searchHistoryGlobal as a premise; they now read the shared FTS index directly (sharedIndexURLs) or call searchURLs.

## Not verified
- Not run in the app (/verify) and no /code-review: left to the supervising session. The API Explorer History section now prints each result's visit count, typed count and last-visit time, so the same search from two profiles' popups shows the difference.
- searchURLs was not benchmarked. With empty text the window function runs over every in-scope visit in the range; it is off the main thread, but a DatabaseQueue serialises the palette's main-thread read behind it. HistoryBenchmarkTests has no leg for it.
- The whole test suite was not run, only the suites above.
<!-- SECTION:NOTES:END -->
