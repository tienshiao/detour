---
id: TASK-24
title: >-
  Extensions: give extension-page tabs a durable identity so they survive a
  relaunch
status: Done
assignee:
  - '@claude'
created_date: '2026-09-12 19:07'
updated_date: '2026-09-12 23:11'
labels:
  - extensions
  - tabs
  - persistence
dependencies:
  - TASK-14
priority: low
ordinal: 24000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-14 (804e431) rehomes open extension pages when their context reloads mid-session, but a persisted tab, pinned entry or favourite whose URL is webkit-extension://<uuid>/... is dead after a relaunch: WebKit mints a fresh base URL per context load, so the restored host matches no loaded context, BrowserTab.wakeConfiguration falls back to the space configuration, and the page cannot load. Persist the extension id plus the page path (and query/fragment) alongside the URL for extension-scheme tabs, pinned entries and favourites, and resolve them to the current context base URL at restore time (Profile.extensionContext(for:).baseURL); fall back to closing the tab when the extension is no longer installed or enabled. Consider the same identity for the closed-tab record (TASK-14 currently skips the record for closes on disable/uninstall because the archived URL would be dead).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An extension options page open in a tab, a pinned entry and a favourite all reopen on the correct page after quit and relaunch
- [x] #2 A persisted extension page whose extension was uninstalled while the app was closed is dropped cleanly rather than restored as a blank tab
- [x] #3 TabStore persistence tests cover the round trip for the three kinds
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Schema v8: nullable extensionID column on tab, pinnedTab, favorite, closedTab (the stored URL already carries path/query/fragment; only the id was missing). Records gain the field.
2. Pure helpers (ExtensionPageURL.swift): isExtensionPageURL, extensionOriginBaseURL(host:), classifyPersistedExtensionPage(url:extensionID:enabledExtensionIDs:) -> notExtensionPage | restorable(id, host) | unavailable.
3. Profile: pendingExtensionOrigins (dead host -> extension id) for pages with no live origin; extensionID(forPageURL:) = live context lookup ?? pending map; isAwaitingExtensionContext; resolvePendingExtensionPages() = retargetExtensionPages(from: pending base, to: context base) (store parameter added so tests can use an in-memory TabStore).
4. TabStore.saveNow / closed-tab records write extensionID via that lookup. restoreSession classifies every tab / pinned entry / backing tab / favourite / closed record against AppDatabase.enabledExtensionIDs(for:): unavailable is skipped at restore; restorable extension pages restore sleeping without interaction state and register their origin.
5. Resolution is lazy: contexts load asynchronously after restoreSession, so ExtensionManager.loadExtensionsIntoProfile (and the enable/install paths) call resolvePendingExtensionPages before notifyExistingTabs; wake() does not load a page on a pending origin.
6. Dormant pinned/favourite materialisation and reopenClosedTab create extension-page tabs sleeping; reopen rewrites a closed record onto the current base via its id.
7. Disable keeps pending origins and registers the unloaded one (tiles keep identity, re-enable moves them); uninstall forgets them. Both close pages on pending origins.
8. Tests: ExtensionPagePersistenceTests (classifier, round trip for all kinds, save-before-context-load, uninstalled/disabled drop incl. split dissolution, lazy wake path) + 2 ExtensionPageRehostTests (re-enable moves dormant tile, disable/uninstall close pending pages).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design decisions:
- Schema: one nullable extensionID column per table (tab, pinnedTab, favorite, closedTab; migration v8). The URL column already holds path/query/fragment in encoded form, so a separate path column would duplicate it; restore rewrites the stored URL with rewriteExtensionPageURL(from: webkit-extension://<dead host>/, to: context.baseURL).
- The id is derived at save time: Profile.extensionID(forPageURL:) = the loaded context claiming the URL's host (the TASK-10/14 reverse lookup extensionID(forOriginScheme:host:)), falling back to Profile.pendingExtensionOrigins (dead host -> id) so a page restored in this launch but not yet resolved (or on a disabled extension's origin) still saves its id. No per-tab/entry identity property: a tab that navigates away simply stops matching.
- Resolution timing: ExtensionManager.initialize starts an async Task that awaits WKWebExtension loads, so contexts ALWAYS load after TabStore.restoreSession (and after the window selects the restored tab). Restoring after contexts load would delay first paint on extension I/O; instead restore keeps the pages sleeping on the dead origin and registers the origin, and loadExtensionsIntoProfile calls Profile.resolvePendingExtensionPages right after loading contexts and before notifyExistingTabs. That reuses TASK-14's retargetExtensionPages wholesale (tabs, live+dormant pinned entries, favourites and backing tabs, rehost notification, announce-once ordering), so the displayed tab is rebuilt through the normal claimWebView -> wakeIfNeeded -> wake path. Enable and install paths resolve too.
- wake() on a pending origin builds the web view but does not load (a load into the space configuration would only produce an error page) and seeds lastAttemptedURL so the URL observer does not wipe tab.url — which the resolver needs to find the tab.
- Restored extension pages are never eager (the selected tab too) and drop their interaction state: its back/forward list is on the dead origin and retarget would discard it anyway.
- Dormant pinned-entry/favourite materialisation (makeTab(loading:)) and reopenClosedTab now create extension-page tabs sleeping so wake resolves the context configuration; previously they were built from the space configuration and dead even within a session.
- Unavailable (extension uninstalled, globally or per-profile disabled per AppDatabase.enabledExtensionIDs, or a legacy row with no id) is dropped at restore so nothing is ever shown: a session tab is skipped (split partner left lone by sanitizeSplitGroups; selection moved to the first tab / live pinned tab); a pinned entry whose home URL is unavailable is dropped with its backing tab (a lone pinned split partner is dissolved by sanitizePinnedSplitGroups); a backing tab on an unavailable page is dropped leaving its entry/favourite dormant; a favourite whose URL is unavailable is dropped; a closed-tab record is deleted from memory and DB.
- Closed-tab record: now carries the id, so Cmd+Shift+T reopens an extension page across a context reload or relaunch (rewritten onto the live base, or pending if the context has not loaded; a record whose extension is gone is skipped). TASK-14's disable/uninstall closes still write no record and register no undo (unchanged; a re-enable-then-reopen flow would need splitting closeTab's undoable flag).
- Disable/uninstall: pages on pending origins are closed too (they are on no loaded origin, so closeExtensionPages on the unloaded base alone missed them). A disable keeps the pending origins and registers the unloaded origin so dormant tiles keep their identity and a re-enable moves them; an uninstall forgets them.

Not done / follow-ups to consider:
- Undo closures in closeTab / closePinnedTab / closeSplitGroup still rebuild from the space configuration, so undoing the close of an extension page within a session gives a dead tab (pre-existing, not a relaunch issue).
- Peek URLs are not given an identity (a peek cannot show an extension page today; TASK-14 notes the same).
- An extension that is installed and enabled but whose WKWebExtension fails to load leaves its restored pages pending: displayed as an empty page rather than an error page, kept (with id) for the next launch.
- No real quit/relaunch of the app was performed (UI verification is blocked for the shell host). AC #1/#2 evidence is the persistence round trip through AppDatabase (in-memory) + TabStore.restoreSession + real WKWebExtension contexts with fresh base URLs.

Validation: ExtensionPagePersistenceTests 8/8, ExtensionPageRehostTests 16/16; AppDatabase/Extension*/Pinned*/Split*/TabStore classes 455 tests 0 failures; full DetourTests 716 tests 0 failures (private DerivedData /tmp/claude/detour-dd-task24, data dir DetourTests-task24).

Review follow-up (rebased onto TASK-26, 458d904):
- Installed-but-disabled is now a distinct classifier case, PersistedExtensionPage.disabled(extensionID:originHost:), decided from AppDatabase.installedExtensionIDs() and enabledExtensionIDs(for:). This supersedes the earlier note that disabled pages are dropped. At restore a disabled extension's pinned entries and favourites are kept as dormant tiles with their pending origin registered, so the next save still writes the id and a later enable resolves them. Its closed-tab records are kept too. Open session tabs and backing tabs on its pages are dropped, matching a mid-session disable. Not installed, or a row with no id: .unavailable, dropped as before (AC #2).
- reopenClosedTab / canReopenClosedTab: a disabled extension's record is skipped and KEPT (in memory and DB), so it reopens after re-enable. A record whose extension is uninstalled is discarded. The chosen record is deleted by tab id (deleteClosedTab) rather than popping the space's newest row, since skipped records can sit above it.
- Opening a dormant tile of a disabled extension gives a sleeping tab whose origin is pending, so wake leaves it unloaded (blank), with no crash and no dead load.
- Hooks wired into TASK-26's design: resolvePendingExtensionPages after loads in loadExtensionsIntoProfile, applyEnabledState .loaded and install. closePagesOfUnloadedExtension(uninstalling: false) in applyEnabledState .unloaded and in install's no-replacement-context branch, and (true) in uninstall. applyEnabledState .unchanged for a now-disabled extension also closes pages on pending origins (a context that never loaded has nothing to unload).
- Tests: classifier cases for disabled and uninstalled; testDisabledExtensionsTilesSurviveARelaunchAndResolveWhenEnabled (disable while closed, relaunch twice, reopen skips and keeps the record, dormant tile opens as a pending sleeping tab, enable resolves tiles and the closed tab onto the new base). The enable step calls resolvePendingExtensionPages directly on the in-memory store, as applyEnabledState .loaded does. Results: ExtensionPagePersistenceTests 9/9, ExtensionPageRehostTests 16/16, ExtensionEnabledStateTests 8/8; AppDatabase + Extension* + Pinned* + Split* + TabStore classes 464/0 failures; full DetourTests 725/0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Extension pages now carry a durable identity across relaunches. Migration v8 adds a nullable extensionID column to tab, pinnedTab, favorite and closedTab; saves derive it from the loaded context claiming the origin, falling back to Profile.pendingExtensionOrigins. restoreSession classifies each page as not-extension, restorable (enabled), disabled (installed, not enabled) or unavailable (not installed / no id). Unavailable pages are dropped everywhere, with selection and split groups kept valid. A disabled extension's pinned entries, favourites and closed records are kept dormant with their identity, while open tabs on its pages are dropped. Restorable tabs come back sleeping. Kept pages register a pending origin, which ExtensionManager resolves after loading contexts (launch, enable via TASK-26's applyEnabledState, install) through TASK-14's retargetExtensionPages. wake() leaves a pending page unloaded. Dormant tiles and Reopen Closed Tab build extension pages sleeping; reopen skips and keeps a disabled extension's record. Verified with ExtensionPagePersistenceTests (9) and ExtensionPageRehostTests; full DetourTests 725 tests, 0 failures. No real app quit/relaunch was performed.
<!-- SECTION:FINAL_SUMMARY:END -->
